import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../util/pretty_string.dart';

/// DMA transfer type.
enum HarborDmaTransferType {
  /// Memory to memory.
  memToMem,

  /// Memory to peripheral.
  memToPeriph,

  /// Peripheral to memory.
  periphToMem,
}

/// Source of the data a DMA transfer moves.
enum HarborDmaSource {
  /// The controller reads the source beat itself over the master port
  /// (`dma_rdata`), same as a normal memory-to-memory or memory-to-peripheral
  /// copy.
  mem,

  /// A peripheral pushes each beat in over the `s_data`/`s_valid`/`s_last`
  /// stream ports instead of the controller reading it. Only used with a
  /// `periphToMem` channel.
  peripheralStream,
}

/// Where a DMA channel is allowed to write its destination beats.
enum HarborDmaTarget {
  /// No restriction. A destination address can be anywhere on the master
  /// bus, same as today.
  fabric,

  /// Destination addresses are clamped to [HarborDmaController.memRange].
  /// A beat whose destination falls outside the window sets CH_STATUS.error
  /// and is never written.
  sdram,
}

/// DMA transfer width.
enum HarborDmaTransferWidth {
  byte1(1),
  half(2),
  word(4),
  dword(8);

  final int bytes;
  const HarborDmaTransferWidth(this.bytes);
}

/// DMA channel configuration.
class HarborDmaChannelConfig with HarborPrettyString {
  /// Maximum burst length.
  final int maxBurstLength;

  /// Maximum transfer size in bytes.
  final int maxTransferSize;

  /// Whether scatter-gather is supported.
  final bool scatterGather;

  const HarborDmaChannelConfig({
    this.maxBurstLength = 16,
    this.maxTransferSize = 0xFFFFFF,
    this.scatterGather = false,
  });

  @override
  String toString() => 'HarborDmaChannelConfig(burst: $maxBurstLength)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborDmaChannelConfig(\n');
    buf.writeln('${c}maxBurst: $maxBurstLength,');
    buf.writeln('${c}maxTransfer: $maxTransferSize,');
    if (scatterGather) buf.writeln('${c}scatter-gather,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// DMA controller.
///
/// Multi-channel DMA engine for high-bandwidth memory transfers.
///
/// Each register sits in its own 64-bit-aligned slot, so a 32-bit access lands
/// in the low word on both a 32-bit and a 64-bit fabric, and the byte-address
/// decode needs no high/low-half selection. A block is 8 slots (0x40 bytes).
///
/// Global registers (block 0):
/// - 0x00: CTRL       (global enable, reset)
/// - 0x08: INT_STATUS (per-channel interrupt status, W1C)
/// - 0x10: INT_ENABLE (per-channel interrupt enable)
///
/// Per-channel register map (channel ch at byte 0x40 + ch*0x40):
/// - +0x00: CH_CTRL    (enable, type, width, irq_en)
/// - +0x08: CH_STATUS  (busy, complete, error)
/// - +0x10: CH_SRC     (source address)
/// - +0x18: CH_DST     (destination address)
/// - +0x20: CH_LEN     (transfer length in bytes, multiple of dataWidth/8)
///
/// Transfers move one bus beat (`dataWidth` bits, default 32) at a time over
/// the master port. CH_TYPE selects whether the source/destination
/// auto-increment (memToMem: both, memToPeriph: source only, periphToMem:
/// destination only).
///
/// With `source: HarborDmaSource.peripheralStream`, a `periphToMem` channel
/// takes its beat from the `s_data`/`s_valid`/`s_last`/`s_ready` stream ports
/// instead of a master read. See [HarborDmaSource].
class HarborDmaController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// Number of DMA channels.
  final int channels;

  /// Channel configuration.
  final HarborDmaChannelConfig channelConfig;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Address width for DMA transfers.
  final int addressWidth;

  /// Data width of the DMA master bus, in bits.
  ///
  /// This is the bus beat size the transfer engine moves per read/write
  /// cycle. It is a different value than [HarborDmaTransferWidth], which
  /// is the per-transfer element width set in CH_CTRL.
  final int dataWidth;

  /// Where a `periphToMem` transfer gets its data from.
  ///
  /// Defaults to [HarborDmaSource.mem], where the controller reads the
  /// source beat itself. With [HarborDmaSource.peripheralStream], the
  /// controller instead exposes `s_data`/`s_valid`/`s_last`/`s_ready` ports
  /// and a peripheral pushes each beat in directly.
  final HarborDmaSource source;

  /// Where a channel's destination address is allowed to land.
  ///
  /// Defaults to [HarborDmaTarget.fabric]: no restriction, same behavior as
  /// before this option existed. With [HarborDmaTarget.sdram], every
  /// destination beat is checked against [memRange] before the master write
  /// is issued.
  final HarborDmaTarget target;

  /// The allowed destination address window when [target] is
  /// [HarborDmaTarget.sdram]. Required in that mode, unused otherwise.
  final BusAddressRange? memRange;

  /// Bus slave port (register access).
  late final BusSlavePort bus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborDmaController({
    required this.baseAddress,
    this.channels = 4,
    this.channelConfig = const HarborDmaChannelConfig(),
    this.addressWidth = 32,
    this.dataWidth = 32,
    this.source = HarborDmaSource.mem,
    this.target = HarborDmaTarget.fabric,
    this.memRange,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborDmaController', name: name ?? 'dma') {
    if (target == HarborDmaTarget.sdram && memRange == null) {
      throw ArgumentError(
        'HarborDmaController: target sdram requires a memRange.',
      );
    }
    // Channel ch decodes at block ch+1 of 0x40 bytes inside a 4 KiB register
    // window, so channel 63 would wrap past the window and alias the globals.
    if (channels > 62) {
      throw ArgumentError(
        'HarborDmaController: at most 62 channels fit the 4 KiB register '
        'window (got $channels).',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // DMA master ports (directly exposed for memory bus connection)
    addOutput('dma_addr', width: addressWidth);
    addOutput('dma_wdata', width: dataWidth);
    createPort('dma_rdata', PortDirection.input, width: dataWidth);
    addOutput('dma_we');
    addOutput('dma_stb');
    createPort('dma_ack', PortDirection.input);
    addOutput('interrupt');

    // Peripheral stream source ports. Added only in stream mode, so a
    // default (mem source) controller stays byte-identical.
    if (source == HarborDmaSource.peripheralStream) {
      createPort('s_data', PortDirection.input, width: dataWidth);
      createPort('s_valid', PortDirection.input);
      createPort('s_last', PortDirection.input);
      addOutput('s_ready');
    }

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: 12,
      dataWidth: 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Global registers
    final globalEnable = Logic(name: 'global_enable');
    final intStatus = Logic(name: 'int_status', width: channels);
    final intEnable = Logic(name: 'int_enable', width: channels);

    // Per-channel state
    final chEnable = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_enable'),
    );
    final chBusy = List.generate(channels, (i) => Logic(name: 'ch${i}_busy'));
    final chComplete = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_complete'),
    );
    final chError = List.generate(channels, (i) => Logic(name: 'ch${i}_error'));
    final chSrc = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_src', width: addressWidth),
    );
    final chDst = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_dst', width: addressWidth),
    );
    final chLen = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_len', width: 24),
    );
    final chType = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_type', width: 2),
    );
    final chWidth = List.generate(
      channels,
      (i) => Logic(name: 'ch${i}_width', width: 2),
    );

    // Transfer engine state. The active channel is serviced through shadow
    // pointers/counter so the CPU-visible CH_SRC/CH_DST/CH_LEN stay as
    // programmed.
    final activeCh = Logic(name: 'active_ch', width: channels.bitLength);
    final dmaState = Logic(name: 'dma_state', width: 3);
    final xferCount = Logic(name: 'xfer_count', width: 24);
    final readData = Logic(name: 'read_data', width: dataWidth);
    final curSrc = Logic(name: 'cur_src', width: addressWidth);
    final curDst = Logic(name: 'cur_dst', width: addressWidth);
    final dmaAddrReg = Logic(name: 'dma_addr_reg', width: addressWidth);
    final dmaWdataReg = Logic(name: 'dma_wdata_reg', width: dataWidth);
    final dmaWeReg = Logic(name: 'dma_we_reg');
    final dmaStbReg = Logic(name: 'dma_stb_reg');

    // Peripheral stream source state. Only built in stream mode: holds the
    // s_last seen at the accepted beat, so the write-complete check below can
    // end the transfer on s_last even if CH_LEN has not run out yet.
    late final Logic streamLastReg;
    late final Logic sData, sValid, sLast;
    if (source == HarborDmaSource.peripheralStream) {
      streamLastReg = Logic(name: 'stream_last_reg');
      sData = input('s_data');
      sValid = input('s_valid');
      sLast = input('s_last');
    }

    // Transfer engine states.
    const sIdle = 0;
    const sRead = 1; // issue a read of the source beat
    const sWrite = 2; // issue a write of the read beat to the destination

    // Transfers move one bus beat. CH_LEN is in bytes (multiple of the beat
    // size, dataWidth / 8).
    final step = dataWidth ~/ 8;
    final dmaAck = input('dma_ack');
    final dmaRdata = input('dma_rdata');

    // Destination clamp for target: sdram. Only built when the clamp is
    // actually configured, so target: fabric (the default) adds no hardware
    // at all and stays byte-identical to the pre-target controller.
    final targetSdram = target == HarborDmaTarget.sdram;
    late final Logic dstInRange;
    if (targetSdram) {
      final rangeStart = Const(memRange!.start, width: addressWidth);
      final rangeEnd = Const(memRange!.end, width: addressWidth);
      dstInRange =
          curDst.gte(rangeStart) &
          (curDst + Const(step, width: addressWidth)).lte(rangeEnd);
    }

    // Element transfer type of the active channel (combinational select).
    var activeType = chType[0];
    for (var ch = 1; ch < channels; ch++) {
      activeType = mux(
        activeCh.eq(Const(ch, width: channels.bitLength)),
        chType[ch],
        activeType,
      );
    }
    // memToMem (0): both increment. memToPeriph (1): dst fixed.
    // periphToMem (2): src fixed.
    final srcInc = activeType.neq(Const(2, width: 2)).named('dma_src_inc');
    final dstInc = activeType.neq(Const(1, width: 2)).named('dma_dst_inc');
    final isPeriphToMem = activeType.eq(Const(2, width: 2));

    interrupt <= (intStatus & intEnable).or();

    output('dma_addr') <= dmaAddrReg;
    output('dma_wdata') <= dmaWdataReg;
    output('dma_we') <= dmaWeReg;
    output('dma_stb') <= dmaStbReg;

    if (source == HarborDmaSource.peripheralStream) {
      // Ready to accept the next word once the engine is waiting on a beat
      // for the active periphToMem channel.
      output('s_ready') <= dmaState.eq(Const(sRead, width: 3)) & isPeriphToMem;
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          globalEnable < Const(0),
          intStatus < Const(0, width: channels),
          intEnable < Const(0, width: channels),
          for (var i = 0; i < channels; i++) ...[
            chEnable[i] < Const(0),
            chBusy[i] < Const(0),
            chComplete[i] < Const(0),
            chError[i] < Const(0),
            chSrc[i] < Const(0, width: addressWidth),
            chDst[i] < Const(0, width: addressWidth),
            chLen[i] < Const(0, width: 24),
            chType[i] < Const(0, width: 2),
            chWidth[i] < Const(0, width: 2),
          ],
          activeCh < Const(0, width: channels.bitLength),
          dmaState < Const(sIdle, width: 3),
          xferCount < Const(0, width: 24),
          readData < Const(0, width: dataWidth),
          curSrc < Const(0, width: addressWidth),
          curDst < Const(0, width: addressWidth),
          dmaAddrReg < Const(0, width: addressWidth),
          dmaWdataReg < Const(0, width: dataWidth),
          dmaWeReg < Const(0),
          dmaStbReg < Const(0),
          if (source == HarborDmaSource.peripheralStream)
            streamLastReg < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: 32),

          // Transfer engine: round-robin pick a busy channel, then copy it
          // word by word over the master port until its length is exhausted.
          Case(dmaState, [
            CaseItem(Const(sIdle, width: 3), [
              // Pick the lowest-indexed busy channel (high-to-low so index 0
              // wins) and latch its shadow pointers/counter.
              for (var ch = channels - 1; ch >= 0; ch--)
                If(
                  chBusy[ch],
                  then: [
                    activeCh < Const(ch, width: channels.bitLength),
                    curSrc < chSrc[ch],
                    curDst < chDst[ch],
                    xferCount < chLen[ch],
                    dmaState < Const(sRead, width: 3),
                  ],
                ),
            ]),
            CaseItem(
              Const(sRead, width: 3),
              source == HarborDmaSource.peripheralStream
                  ? [
                      // A periphToMem channel takes its beat from the
                      // stream (s_ready is asserted combinationally by this
                      // state, see output('s_ready') above). Any other
                      // channel type still reads the source over the
                      // master port.
                      If(
                        isPeriphToMem,
                        then: [
                          If(
                            sValid,
                            then: [
                              readData < sData,
                              streamLastReg < sLast,
                              dmaState < Const(sWrite, width: 3),
                            ],
                          ),
                        ],
                        orElse: [
                          dmaAddrReg < curSrc,
                          dmaWeReg < Const(0),
                          dmaStbReg < Const(1),
                          If(
                            dmaAck,
                            then: [
                              readData < dmaRdata,
                              dmaStbReg < Const(0),
                              dmaState < Const(sWrite, width: 3),
                            ],
                          ),
                        ],
                      ),
                    ]
                  : [
                      dmaAddrReg < curSrc,
                      dmaWeReg < Const(0),
                      dmaStbReg < Const(1),
                      If(
                        dmaAck,
                        then: [
                          readData < dmaRdata,
                          dmaStbReg < Const(0),
                          dmaState < Const(sWrite, width: 3),
                        ],
                      ),
                    ],
            ),
            CaseItem(
              Const(sWrite, width: 3),
              targetSdram
                  ? [
                      // target: sdram checks the destination against
                      // memRange before it ever drives the master write. Out
                      // of range: raise CH_STATUS.error, drive no write, and
                      // stop the channel without completing it.
                      dmaAddrReg < curDst,
                      dmaWdataReg < readData,
                      If(
                        dstInRange,
                        then: [
                          dmaWeReg < Const(1),
                          dmaStbReg < Const(1),
                          If(
                            dmaAck,
                            then: [
                              dmaStbReg < Const(0),
                              dmaWeReg < Const(0),
                              If(
                                srcInc,
                                then: [
                                  curSrc <
                                      (curSrc +
                                          Const(step, width: addressWidth)),
                                ],
                              ),
                              If(
                                dstInc,
                                then: [
                                  curDst <
                                      (curDst +
                                          Const(step, width: addressWidth)),
                                ],
                              ),
                              If(
                                source == HarborDmaSource.peripheralStream
                                    ? xferCount.lte(Const(step, width: 24)) |
                                          (streamLastReg & isPeriphToMem)
                                    : xferCount.lte(Const(step, width: 24)),
                                then: [
                                  // Last word: complete the active channel
                                  // and raise its IRQ.
                                  for (var ch = 0; ch < channels; ch++)
                                    If(
                                      activeCh.eq(
                                        Const(ch, width: channels.bitLength),
                                      ),
                                      then: [
                                        chBusy[ch] < Const(0),
                                        chComplete[ch] < Const(1),
                                        intStatus <
                                            (intStatus |
                                                Const(
                                                  1 << ch,
                                                  width: channels,
                                                )),
                                      ],
                                    ),
                                  dmaState < Const(sIdle, width: 3),
                                ],
                                orElse: [
                                  xferCount <
                                      (xferCount - Const(step, width: 24)),
                                  dmaState < Const(sRead, width: 3),
                                ],
                              ),
                            ],
                          ),
                        ],
                        orElse: [
                          dmaWeReg < Const(0),
                          dmaStbReg < Const(0),
                          for (var ch = 0; ch < channels; ch++)
                            If(
                              activeCh.eq(Const(ch, width: channels.bitLength)),
                              then: [
                                chBusy[ch] < Const(0),
                                chError[ch] < Const(1),
                              ],
                            ),
                          dmaState < Const(sIdle, width: 3),
                        ],
                      ),
                    ]
                  : [
                      dmaAddrReg < curDst,
                      dmaWdataReg < readData,
                      dmaWeReg < Const(1),
                      dmaStbReg < Const(1),
                      If(
                        dmaAck,
                        then: [
                          dmaStbReg < Const(0),
                          dmaWeReg < Const(0),
                          If(
                            srcInc,
                            then: [
                              curSrc <
                                  (curSrc + Const(step, width: addressWidth)),
                            ],
                          ),
                          If(
                            dstInc,
                            then: [
                              curDst <
                                  (curDst + Const(step, width: addressWidth)),
                            ],
                          ),
                          If(
                            source == HarborDmaSource.peripheralStream
                                ? xferCount.lte(Const(step, width: 24)) |
                                      (streamLastReg & isPeriphToMem)
                                : xferCount.lte(Const(step, width: 24)),
                            then: [
                              // Last word: complete the active channel and
                              // raise its IRQ.
                              for (var ch = 0; ch < channels; ch++)
                                If(
                                  activeCh.eq(
                                    Const(ch, width: channels.bitLength),
                                  ),
                                  then: [
                                    chBusy[ch] < Const(0),
                                    chComplete[ch] < Const(1),
                                    intStatus <
                                        (intStatus |
                                            Const(1 << ch, width: channels)),
                                  ],
                                ),
                              dmaState < Const(sIdle, width: 3),
                            ],
                            orElse: [
                              xferCount < (xferCount - Const(step, width: 24)),
                              dmaState < Const(sRead, width: 3),
                            ],
                          ),
                        ],
                      ),
                    ],
            ),
          ]),

          // Register access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // The bus presents a BYTE address. Each block is 8 slots of 8
              // bytes (0x40): block 0 is the global registers, block ch+1 is
              // channel ch. Match the full in-block address, not just the
              // slot bits, so a byte offset inside a slot other than the
              // register's own first byte does not alias onto it.
              // Global registers (block 0)
              If(
                bus.addr.getRange(6, 12).eq(Const(0, width: 6)),
                then: [
                  Case(bus.addr.getRange(0, 6), [
                    // 0x00: CTRL
                    CaseItem(Const(0x00, width: 6), [
                      If(
                        bus.we & bus.selAny(0x00, 1),
                        then: [globalEnable < bus.dataIn[0]],
                        orElse: [bus.dataOut < globalEnable.zeroExtend(32)],
                      ),
                    ]),
                    // 0x08: INT_STATUS (W1C)
                    CaseItem(Const(0x08, width: 6), [
                      If(
                        bus.we,
                        then: [
                          intStatus <
                              (intStatus & ~bus.selMasked(0x08, channels)),
                        ],
                        orElse: [bus.dataOut < intStatus.zeroExtend(32)],
                      ),
                    ]),
                    // 0x10: INT_ENABLE
                    CaseItem(Const(0x10, width: 6), [
                      If(
                        bus.we,
                        then: [intEnable < bus.selMerge(intEnable, 0x10)],
                        orElse: [bus.dataOut < intEnable.zeroExtend(32)],
                      ),
                    ]),
                  ]),
                ],
              ),

              // Per-channel registers (channel ch at byte 0x40 + ch*0x40)
              for (var ch = 0; ch < channels; ch++)
                If(
                  bus.addr.getRange(6, 12).eq(Const(ch + 1, width: 6)),
                  then: [
                    Case(bus.addr.getRange(0, 6), [
                      // 0x00: CH_CTRL
                      CaseItem(Const(0x00, width: 6), [
                        If(
                          bus.we,
                          then: [
                            If(
                              bus.selAny(0x00, 1),
                              then: [
                                chEnable[ch] < bus.dataIn[0],
                                chType[ch] < bus.dataIn.getRange(4, 6),
                                // Start transfer when enable written
                                If(
                                  bus.dataIn[0] & globalEnable,
                                  then: [
                                    chBusy[ch] < Const(1),
                                    chComplete[ch] < Const(0),
                                  ],
                                ),
                              ],
                            ),
                            If(
                              bus.selAny(0x01, 1),
                              then: [chWidth[ch] < bus.dataIn.getRange(8, 10)],
                            ),
                          ],
                          orElse: [
                            bus.dataOut <
                                chEnable[ch].zeroExtend(32) |
                                    (chType[ch].zeroExtend(32) <<
                                        Const(4, width: 32)) |
                                    (chWidth[ch].zeroExtend(32) <<
                                        Const(8, width: 32)),
                          ],
                        ),
                      ]),
                      // 0x08: CH_STATUS
                      CaseItem(Const(0x08, width: 6), [
                        bus.dataOut <
                            chBusy[ch].zeroExtend(32) |
                                (chComplete[ch].zeroExtend(32) <<
                                    Const(1, width: 32)) |
                                (chError[ch].zeroExtend(32) <<
                                    Const(2, width: 32)),
                      ]),
                      // 0x10: CH_SRC
                      CaseItem(Const(0x10, width: 6), [
                        If(
                          bus.we,
                          then: [chSrc[ch] < bus.selMerge(chSrc[ch], 0x10)],
                          orElse: [bus.dataOut < chSrc[ch].zeroExtend(32)],
                        ),
                      ]),
                      // 0x18: CH_DST
                      CaseItem(Const(0x18, width: 6), [
                        If(
                          bus.we,
                          then: [chDst[ch] < bus.selMerge(chDst[ch], 0x18)],
                          orElse: [bus.dataOut < chDst[ch].zeroExtend(32)],
                        ),
                      ]),
                      // 0x20: CH_LEN
                      CaseItem(Const(0x20, width: 6), [
                        If(
                          bus.we,
                          then: [chLen[ch] < bus.selMerge(chLen[ch], 0x20)],
                          orElse: [bus.dataOut < chLen[ch].zeroExtend(32)],
                        ),
                      ]),
                    ]),
                  ],
                ),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,dma'],
    reg: BusAddressRange(baseAddress, 0x1000),
    properties: {'dma-channels': channels, '#dma-cells': 1},
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,dma'],
      'dma-channels': channels,
      '#dma-cells': 1,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'DMA',
    groupName: 'DMA',
    description: 'Multi-channel DMA controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}

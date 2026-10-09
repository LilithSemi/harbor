import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../bus/wishbone/wishbone_interface.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';

/// SPI master/slave controller.
///
/// Register map (each register in its own 64-bit-aligned slot, so a 32-bit
/// access lands in the low word on both a 32-bit and a 64-bit fabric, and the
/// byte-address decode needs no high/low-half selection):
/// - 0x00: CTRL    (control: enable, CPOL, CPHA, master/slave, loopback)
/// - 0x08: STATUS  (read-only: busy, tx_empty, rx_ready, overrun)
/// - 0x10: DATA    (write=TX, read=RX)
/// - 0x18: DIVIDER (clock divider for baud rate)
/// - 0x20: CS      (chip select output value)
///
/// Supports both master and slave mode. CPOL/CPHA configurable.
class HarborSpiController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborInputClockConsumer {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Whether this is a master (true) or slave (false) by default.
  final bool isMaster;

  /// Number of chip select lines (master mode).
  final int csCount;

  /// Data width in bits (typically 8).
  final int spiDataWidth;

  /// Wishbone slave address width. Defaults to 12 (the 0x1000 window).
  final int busAddressWidth;

  /// Wishbone slave data width. Must match the SoC fabric (e.g. 64 on an RV64
  /// SoC). The register file itself is 32-bit; wider buses zero-extend reads.
  final int busDataWidth;

  /// When true, an SD/MMC card is wired to chip select 0 in SPI mode. The
  /// device tree then carries an `mmc-spi-slot` child so Linux binds the
  /// in-tree `mmc_spi` driver on top of this controller (`harbor_spi`), giving
  /// a block device the kernel can mount as root.
  final bool sdCard;

  /// SD-over-SPI maximum clock. Conservative default for a first bring-up.
  final int sdMaxFrequency;

  /// When true, the controller gains an integrated DMA engine: a wishbone
  /// MASTER handshake (dma_*) plus DMA_ADDR/DMA_LEN/DMA_CTRL registers. The
  /// engine clocks the SPI continuously (no per-byte CPU poll) and moves bytes
  /// to/from memory itself, packing four SPI bytes into each 32-bit word write.
  /// This is the fast path for large transfers (an SD block or a kernel image).
  /// Default false keeps the controller a slave-only, byte-identical PIO device.
  final bool dma;

  /// DMA master address width. Defaults to the slave data width so it can point
  /// anywhere in a 64-bit SoC's DRAM.
  final int dmaAddressWidth;

  /// Controller input clock in Hz (the system clock the DIVIDER register
  /// divides). Emitted as `clock-frequency`, because a driver cannot pick a
  /// divider without it: SCK is this rate over 2 * (DIVIDER + 1). 0 leaves the
  /// property out.
  int clockFrequency;

  /// Bus slave port.
  late final BusSlavePort bus;

  /// DMA fabric master interface (only when [dma]). The engine drives full
  /// bus-width beats (sel all-ones) so it needs no width conversion to sit on
  /// the SoC arbiter alongside the core.
  WishboneInterface? _dmaBus;

  /// Interrupt output.
  Logic get interrupt => output('interrupt');

  HarborSpiController({
    required this.baseAddress,
    this.isMaster = true,
    this.csCount = 1,
    this.spiDataWidth = 8,
    this.busAddressWidth = 12,
    this.busDataWidth = 32,
    this.sdCard = false,
    this.sdMaxFrequency = 12000000,
    this.dma = false,
    this.dmaAddressWidth = 32,
    this.clockFrequency = 0,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborSpiController', name: name ?? 'spi') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // SPI pins
    addOutput('spi_clk');
    addOutput('spi_mosi');
    createPort('spi_miso', PortDirection.input);
    addOutput('spi_cs_n', width: csCount);
    addOutput('interrupt');

    // Integrated DMA engine: a real Wishbone MASTER interface (`dma`) at the
    // fabric data width, so `HarborSoc.addMaster` wires it to the arbiter next
    // to the core with no width conversion. Present only when [dma], so a
    // non-DMA controller stays byte-identical.
    if (dma) {
      final dmaRef = addInterface(
        WishboneInterface(
          WishboneConfig(
            addressWidth: dmaAddressWidth,
            dataWidth: busDataWidth,
          ),
        ),
        name: 'dma',
        role: PairRole.provider,
      );
      _dmaBus = dmaRef.internalInterface as WishboneInterface;
    }

    // Bus read-data width. The register file is 32-bit; a wider fabric sees the
    // registers zero-extended into the low word.
    final dw = busDataWidth;

    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: busAddressWidth,
      dataWidth: dw,
    );

    final clk = input('clk');
    final reset = input('reset');
    final miso = input('spi_miso');

    // Control register fields
    final enable = Logic(name: 'enable');
    final cpol = Logic(name: 'cpol');
    final cpha = Logic(name: 'cpha');
    final loopback = Logic(name: 'loopback');
    final divider = Logic(name: 'divider', width: 16);
    final csReg = Logic(name: 'cs_reg', width: csCount);

    // TX/RX state
    final txData = Logic(name: 'tx_data', width: spiDataWidth);
    final rxData = Logic(name: 'rx_data', width: spiDataWidth);
    final shiftReg = Logic(name: 'shift_reg', width: spiDataWidth);
    final bitCount = Logic(name: 'bit_count', width: 4);
    final divCount = Logic(name: 'div_count', width: 16);
    final busy = Logic(name: 'busy');
    final txEmpty = Logic(name: 'tx_empty');
    final rxReady = Logic(name: 'rx_ready');
    final spiClkReg = Logic(name: 'spi_clk_reg');
    // MISO is latched mid-bit (during the stable active half-period) rather than
    // on a clock edge, which is what keeps the async return path clean at these
    // rates. (An input synchronizer flop can be added for very high SCK, but it
    // is not needed here and previously mis-registered the pin.)
    final misoSample = Logic(name: 'miso_sample');

    output('spi_clk') <= spiClkReg ^ cpol;
    output('spi_mosi') <= shiftReg[spiDataWidth - 1];
    output('spi_cs_n') <= ~csReg;

    // DMA FSM states (3-bit dmaState).
    const dmaIdle = 0;
    const dmaKick = 1;
    const dmaWait = 2;
    const dmaWrite = 3;
    const dmaWriteWait = 4;

    // DMA engine state. Built ONLY when [dma] so a non-DMA controller is
    // byte-identical: no extra flops, no extra ports, nothing to elaborate.
    // `late` (not nullable) keeps the type non-null so no `!` is needed; every
    // reference below is inside an `if (dma)` guard, so an unbuilt controller
    // never touches them.
    late final Logic dmaAck,
        dmaAddr,
        dmaLen,
        dmaDir,
        dmaBusy,
        dmaDone,
        dmaState,
        dmaWord,
        dmaByteIdx,
        dmaAddrReg,
        dmaWdataReg,
        dmaWeReg,
        dmaStbReg;
    // One fabric beat is a full bus-width word. Packing that many SPI bytes
    // per beat (sel all-ones) keeps every write naturally aligned, so no
    // sub-word/byte-enable path is needed on a 64-bit fabric.
    final wordBytes = busDataWidth ~/ 8;
    final byteIdxWidth = (wordBytes - 1).bitLength; // 2 for x4, 3 for x8
    if (dma) {
      final wb = _dmaBus!;
      dmaAck = wb.ack;
      dmaAddr = Logic(name: 'dma_addr_reg', width: dmaAddressWidth);
      dmaLen = Logic(name: 'dma_len', width: 32);
      dmaDir = Logic(name: 'dma_dir'); // 0 = SD->mem, 1 = mem->SD
      dmaBusy = Logic(name: 'dma_busy');
      dmaDone = Logic(name: 'dma_done');
      dmaState = Logic(name: 'dma_state', width: 3);
      dmaWord = Logic(name: 'dma_word', width: busDataWidth); // one beat
      dmaByteIdx = Logic(name: 'dma_byte_idx', width: byteIdxWidth);
      dmaAddrReg = Logic(name: 'dma_addr_out', width: dmaAddressWidth);
      dmaWdataReg = Logic(name: 'dma_wdata_out', width: busDataWidth);
      dmaWeReg = Logic(name: 'dma_we_out');
      dmaStbReg = Logic(name: 'dma_stb_out');

      // Drive the Wishbone master. cyc == stb (single-beat, non-pipelined),
      // sel all-ones (full-width aligned writes). datMiso is unused on the
      // read path (SD -> mem).
      wb.cyc <= dmaStbReg;
      wb.stb <= dmaStbReg;
      wb.we <= dmaWeReg;
      wb.adr <= dmaAddrReg;
      wb.datMosi <= dmaWdataReg;
      wb.sel <= Const((1 << wordBytes) - 1, width: wordBytes);
    }

    // Status register: busy | tx_empty<<1 | rx_ready<<2, plus dma_busy<<3 |
    // dma_done<<4 only on a DMA build (identical bit pattern otherwise).
    final status = Logic(name: 'status', width: dw);
    if (dma) {
      status <=
          busy.zeroExtend(dw) |
              (txEmpty.zeroExtend(dw) << Const(1, width: dw)) |
              (rxReady.zeroExtend(dw) << Const(2, width: dw)) |
              (dmaBusy.zeroExtend(dw) << Const(3, width: dw)) |
              (dmaDone.zeroExtend(dw) << Const(4, width: dw));
      interrupt <= rxReady | dmaDone;
    } else {
      status <=
          busy.zeroExtend(dw) |
              (txEmpty.zeroExtend(dw) << Const(1, width: dw)) |
              (rxReady.zeroExtend(dw) << Const(2, width: dw));
      interrupt <= rxReady;
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          enable < Const(0),
          cpol < Const(0),
          cpha < Const(0),
          loopback < Const(0),
          divider < Const(1, width: 16),
          csReg < Const(0, width: csCount),
          txData < Const(0, width: spiDataWidth),
          rxData < Const(0, width: spiDataWidth),
          shiftReg < Const(0, width: spiDataWidth),
          misoSample < Const(0),
          bitCount < Const(0, width: 4),
          divCount < Const(0, width: 16),
          busy < Const(0),
          txEmpty < Const(1),
          rxReady < Const(0),
          spiClkReg < Const(0),
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),
          if (dma) ...[
            dmaState < Const(0, width: 3),
            dmaBusy < Const(0),
            dmaDone < Const(0),
            dmaAddr < Const(0, width: dmaAddressWidth),
            dmaLen < Const(0, width: 32),
            dmaDir < Const(0),
            dmaWord < Const(0, width: busDataWidth),
            dmaByteIdx < Const(0, width: byteIdxWidth),
            dmaAddrReg < Const(0, width: dmaAddressWidth),
            dmaWdataReg < Const(0, width: busDataWidth),
            dmaWeReg < Const(0),
            dmaStbReg < Const(0),
          ],
        ],
        orElse: [
          bus.ack < Const(0),
          bus.dataOut < Const(0, width: dw),

          // SPI shift engine
          If(
            busy & enable,
            then: [
              If(
                divCount.eq(Const(0, width: 16)),
                then: [
                  divCount < divider,
                  spiClkReg < ~spiClkReg,

                  // `spiClkReg` still holds the pre-toggle level here, so
                  // `spiClkReg ^ cpha` is true on the TRAILING edge (falling for
                  // mode 0). Shift on the trailing edge, inserting the bit
                  // latched during the preceding stable active phase.
                  If(
                    spiClkReg ^ cpha,
                    then: [
                      shiftReg <
                          (shiftReg << Const(1, width: spiDataWidth)) |
                              misoSample.zeroExtend(spiDataWidth),
                      bitCount < (bitCount + Const(1, width: 4)),
                      If(
                        bitCount.eq(Const(spiDataWidth - 1, width: 4)),
                        then: [
                          busy < Const(0),
                          // Capture the byte INCLUDING this final (8th) shift.
                          // shiftReg still holds the pre-shift value here.
                          rxData <
                              (shiftReg << Const(1, width: spiDataWidth)) |
                                  misoSample.zeroExtend(spiDataWidth),
                          rxReady < Const(1),
                          spiClkReg < Const(0),
                        ],
                      ),
                    ],
                  ),
                ],
                orElse: [
                  divCount < (divCount - Const(1, width: 16)),
                  // Between edges, continuously latch MISO throughout the ACTIVE
                  // half-period (SCLK high for mode 0, i.e. spiClkReg high after
                  // the leading edge). The last value held before the trailing
                  // edge is the stable mid-bit sample the shift consumes. Latching
                  // across the whole phase (not on the toggle cycle) avoids the
                  // registered-clock skew that reads MISO mid-transition.
                  If(
                    spiClkReg ^ cpha,
                    then: [
                      misoSample <
                          mux(loopback, shiftReg[spiDataWidth - 1], miso),
                    ],
                  ),
                ],
              ),
            ],
          ),

          // Bus access
          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),

              // Registers sit 8 bytes apart (see the map above). Decode every
              // address bit of the 0x1000 window and ignore the bits above it,
              // so absolute and relative addresses both work. An unused offset
              // reads 0 and ignores writes.
              Case(bus.windowAddr(0x1000), [
                // 0x00: CTRL
                CaseItem(Const(0x00, width: 12), [
                  If(
                    bus.we & bus.selAny(0x00, 1),
                    then: [
                      enable < bus.dataIn[0],
                      cpol < bus.dataIn[1],
                      cpha < bus.dataIn[2],
                      loopback < bus.dataIn[3],
                    ],
                    orElse: [
                      bus.dataOut <
                          enable.zeroExtend(dw) |
                              (cpol.zeroExtend(dw) << Const(1, width: dw)) |
                              (cpha.zeroExtend(dw) << Const(2, width: dw)) |
                              (loopback.zeroExtend(dw) << Const(3, width: dw)),
                    ],
                  ),
                ]),
                // 0x08: STATUS. Read-only, except DMA_DONE (bit 4) is
                // write-1-to-clear on a DMA build so a driver can acknowledge a
                // finished transfer without waiting for the next START to clear
                // it. Reading still returns the full status word.
                CaseItem(Const(0x08, width: 12), [
                  if (dma)
                    If(
                      bus.we & bus.selAny(0x08, 1),
                      then: [
                        If(bus.dataIn[4], then: [dmaDone < Const(0)]),
                      ],
                      orElse: [bus.dataOut < status],
                    )
                  else
                    bus.dataOut < status,
                ]),
                // 0x10: DATA
                CaseItem(Const(0x10, width: 12), [
                  If(
                    bus.we,
                    then: [
                      shiftReg < bus.selMerge(shiftReg, 0x10),
                      busy < Const(1),
                      txEmpty < Const(0),
                      bitCount < Const(0, width: 4),
                      divCount < divider,
                    ],
                    orElse: [
                      bus.dataOut < rxData.zeroExtend(dw),
                      rxReady < Const(0),
                    ],
                  ),
                ]),
                // 0x18: DIVIDER
                CaseItem(Const(0x18, width: 12), [
                  If(
                    bus.we,
                    then: [divider < bus.selMerge(divider, 0x18)],
                    orElse: [bus.dataOut < divider.zeroExtend(dw)],
                  ),
                ]),
                // 0x20: CS
                CaseItem(Const(0x20, width: 12), [
                  If(
                    bus.we,
                    then: [csReg < bus.selMerge(csReg, 0x20)],
                    orElse: [bus.dataOut < csReg.zeroExtend(dw)],
                  ),
                ]),
                // The DMA register block exists only on a DMA-capable build.
                if (dma) ...[
                  // 0x28: DMA_ADDR (word-aligned target/source in memory).
                  CaseItem(Const(0x28, width: 12), [
                    If(
                      bus.we,
                      then: [dmaAddr < bus.selMerge(dmaAddr, 0x28)],
                      orElse: [bus.dataOut < dmaAddr.zeroExtend(dw)],
                    ),
                  ]),
                  // 0x30: DMA_LEN (byte count, must be a multiple of 4).
                  CaseItem(Const(0x30, width: 12), [
                    If(
                      bus.we,
                      then: [dmaLen < bus.selMerge(dmaLen, 0x30)],
                      orElse: [bus.dataOut < dmaLen.zeroExtend(dw)],
                    ),
                  ]),
                  // 0x38: DMA_CTRL. Write bit0=START (self-clearing kick),
                  // bit1=DIR (0 = SD->mem read, 1 = mem->SD write). Read returns
                  // {dma_done<<1, dma_busy<<0} for polling without STATUS.
                  CaseItem(Const(0x38, width: 12), [
                    If(
                      bus.we & bus.selAny(0x38, 1),
                      then: [
                        If(
                          bus.dataIn[0],
                          then: [
                            dmaDir < bus.dataIn[1],
                            dmaBusy < Const(1),
                            dmaDone < Const(0),
                            dmaByteIdx < Const(0, width: byteIdxWidth),
                            dmaWord < Const(0, width: busDataWidth),
                            dmaState < Const(dmaKick, width: 3),
                          ],
                        ),
                      ],
                      orElse: [
                        bus.dataOut <
                            dmaBusy.zeroExtend(dw) |
                                (dmaDone.zeroExtend(dw) << Const(1, width: dw)),
                      ],
                    ),
                  ]),
                ],
              ]),
            ],
          ),

          // DMA byte-pump. Runs last so its writes to the shared shift-engine
          // state take priority, though by construction it never contends with
          // the shift engine or a PIO access in the same cycle. Read path only
          // (DIR=0): each byte clocks 0xFF out MOSI and captures MISO, one
          // bus-word of bytes packs little-endian, then a single fabric-master
          // write lands the beat. See the DMA register block above for the ABI.
          if (dma)
            Case(dmaState, [
              // dmaIdle: parked. START (from the DMA_CTRL write) moves us on.
              CaseItem(Const(dmaIdle, width: 3), []),
              // dmaKick: launch one SPI byte. 0xFF on MOSI clocks a read byte in.
              CaseItem(Const(dmaKick, width: 3), [
                shiftReg < Const(0xff, width: spiDataWidth),
                busy < Const(1),
                bitCount < Const(0, width: 4),
                divCount < divider,
                txEmpty < Const(0),
                dmaState < Const(dmaWait, width: 3),
              ]),
              // dmaWait: the shift engine sets rxReady when the byte lands.
              CaseItem(Const(dmaWait, width: 3), [
                If(
                  rxReady,
                  then: [
                    rxReady < Const(0),
                    // Pack this byte into its little-endian lane with a byte
                    // demux, NOT a variable barrel shift. `rxData << (idx*8)` on a
                    // busDataWidth-bit word synthesizes a full barrel shifter (a
                    // dense combinational blob that jams the router - the delta
                    // DMA routing-congestion hotspot). A wordBytes-way lane select
                    // is a handful of byte muxes and routes clean.
                    dmaWord <
                        cases(dmaByteIdx, {
                          for (var b = 0; b < wordBytes; b++)
                            Const(b, width: byteIdxWidth): [
                              if (b < wordBytes - 1)
                                dmaWord.getRange((b + 1) * 8, busDataWidth),
                              rxData,
                              if (b > 0) dmaWord.getRange(0, b * 8),
                            ].swizzle(),
                        }, defaultValue: dmaWord),
                    dmaByteIdx < (dmaByteIdx + Const(1, width: byteIdxWidth)),
                    dmaLen < (dmaLen - Const(1, width: 32)),
                    // Beat full on the last byte-slot, or short-tail on the final
                    // byte (DMA_LEN should be a multiple of wordBytes; a partial
                    // tail zero-pads the unfilled high bytes of the beat).
                    If(
                      dmaByteIdx.eq(Const(wordBytes - 1, width: byteIdxWidth)) |
                          dmaLen.eq(Const(1, width: 32)),
                      then: [dmaState < Const(dmaWrite, width: 3)],
                      orElse: [dmaState < Const(dmaKick, width: 3)],
                    ),
                  ],
                ),
              ]),
              // dmaWrite: present the packed word to the fabric master.
              CaseItem(Const(dmaWrite, width: 3), [
                dmaAddrReg < dmaAddr,
                dmaWdataReg < dmaWord,
                dmaWeReg < Const(1),
                dmaStbReg < Const(1),
                dmaState < Const(dmaWriteWait, width: 3),
              ]),
              // dmaWriteWait: hold the request until the fabric acks the write.
              CaseItem(Const(dmaWriteWait, width: 3), [
                If(
                  dmaAck,
                  then: [
                    dmaStbReg < Const(0),
                    dmaWeReg < Const(0),
                    dmaAddr <
                        (dmaAddr + Const(wordBytes, width: dmaAddressWidth)),
                    dmaWord < Const(0, width: busDataWidth),
                    dmaByteIdx < Const(0, width: byteIdxWidth),
                    If(
                      dmaLen.eq(Const(0, width: 32)),
                      then: [
                        dmaBusy < Const(0),
                        dmaDone < Const(1),
                        dmaState < Const(dmaIdle, width: 3),
                      ],
                      orElse: [dmaState < Const(dmaKick, width: 3)],
                    ),
                  ],
                ),
              ]),
            ]),
        ],
      ),
    ]);
  }

  @override
  int get inputClockHz => clockFrequency;

  @override
  void provideInputClockHz(int hz) {
    if (clockFrequency == 0) clockFrequency = hz;
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['harbor,spi', 'opencores,spi-oc'],
    reg: BusAddressRange(baseAddress, 0x1000),
    // `harbor,dma` (boolean) tells firmware the integrated DMA engine is
    // present, so it can use the DMA_ADDR/LEN/CTRL registers for fast block
    // reads instead of the byte-by-byte PIO path.
    properties: {
      'num-cs': csCount,
      '#address-cells': 1,
      '#size-cells': 0,
      if (clockFrequency > 0) 'clock-frequency': clockFrequency,
      if (dma) 'harbor,dma': true,
    },
    // An SD card on CS0: describe it so the in-tree `mmc_spi` driver binds and
    // exposes a block device (root can then live on the card). `voltage-ranges`
    // is a single 3.3 V min-max pair in mV.
    children: sdCard
        ? [
            HarborDeviceTreeChild(
              name: 'mmc@0',
              properties: {
                'compatible': 'mmc-spi-slot',
                'reg': 0,
                'spi-max-frequency': sdMaxFrequency,
                'voltage-ranges': [3300, 3300],
              },
            ),
          ]
        : const [],
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, 0x1000)],
    properties: {
      'compatible': ['harbor,spi', 'opencores,spi-oc'],
      'num-cs': csCount,
      '#address-cells': 1,
      '#size-cells': 0,
      if (clockFrequency > 0) 'clock-frequency': clockFrequency,
      if (dma) 'harbor,dma': true,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'SPI',
    groupName: 'SPI',
    description: 'SPI master and slave controller',
    baseAddress: baseAddress,
    size: 0x1000,
  );
}

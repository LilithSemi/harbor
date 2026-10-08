import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../util/pretty_string.dart';

/// PSRAM SPI operating mode.
enum HarborPsramMode {
  /// Standard single-bit SPI. Command, address, and data shift out on IO0
  /// (MOSI) and data shifts in on IO1 (MISO). Uses 0x03 read / 0x02 write.
  standard,

  /// Quad SPI. The command shifts out single-bit on IO0, then address and data
  /// use all four IO lines. Uses 0xEB fast read (with 6 dummy cycles) / 0x38
  /// write.
  quad,
}

/// PSRAM controller configuration.
class HarborPsramConfig with HarborPrettyString {
  /// PSRAM size in bytes (e.g. 8 MB for an APS6404).
  final int size;

  /// SPI operating mode.
  final HarborPsramMode mode;

  /// SPI clock frequency in Hz. The controller runs SCK at clk/2.
  final int spiFrequency;

  const HarborPsramConfig({
    required this.size,
    this.mode = HarborPsramMode.quad,
    this.spiFrequency = 50000000,
  });

  /// APS6404 / LY68L6400: 8 MB QSPI PSRAM on the Tiny Tapeout QSPI Pmod.
  const HarborPsramConfig.aps6404({this.mode = HarborPsramMode.quad})
    : size = 8 * 1024 * 1024,
      spiFrequency = 50000000;

  @override
  String toString() =>
      'HarborPsramConfig(${size ~/ (1024 * 1024)} MB, ${mode.name}, '
      '${spiFrequency ~/ 1000000} MHz)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborPsramConfig(\n');
    buf.writeln('${c}size: ${size ~/ (1024 * 1024)} MB,');
    buf.writeln('${c}mode: ${mode.name},');
    buf.writeln('${c}frequency: ${spiFrequency ~/ 1000000} MHz,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// QSPI PSRAM controller (APS6404 / LY68L6400 compatible).
///
/// A bus slave that serves as external RAM, talking to a PSRAM over SPI. The
/// [HarborPsramConfig.mode] selects standard single-bit SPI or quad SPI. The
/// FSM is ported from Hirosh Dabui's KianV qqspi (derived from Lone Dynamics'
/// qqspi), reworked for the abstract bus slave port and split IO.
///
/// SPI pins:
/// - `spi_clk` - SPI clock (SCK = clk/2)
/// - `spi_cs_n` - chip select, active low
/// - standard mode: `spi_mosi` (output, IO0), `spi_miso` (input, IO1)
/// - quad mode: `spi_io_out` / `spi_io_oe` / `spi_io_in` (each 4 bits, split
///   tristate so the SoC/pad ring resolves the bidirectional lines)
class HarborPsramController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborSystemMemoryProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// PSRAM configuration.
  final HarborPsramConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port (CPU side).
  late final BusSlavePort bus;

  HarborPsramController({
    required this.config,
    required this.baseAddress,
    BusProtocol protocol = BusProtocol.wishbone,
    int? busAddressWidth,
    int? busDataWidth,
    String? name,
  }) : super('HarborPsramController', name: name ?? 'psram') {
    final quad = config.mode == HarborPsramMode.quad;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    addOutput('spi_clk');
    addOutput('spi_cs_n');
    if (quad) {
      addOutput('spi_io_out', width: 4);
      addOutput('spi_io_oe', width: 4);
      createPort('spi_io_in', PortDirection.input, width: 4);
    } else {
      addOutput('spi_mosi');
      createPort('spi_miso', PortDirection.input);
    }

    final addrWidth = busAddressWidth ?? 32;
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: addrWidth,
      dataWidth: busDataWidth ?? 32,
    );

    final clk = input('clk');
    final reset = input('reset');

    // Standard SPI command/opcode bytes.
    const cmdWrite = 0x02;
    const cmdRead = 0x03;
    // Quad SPI command/opcode bytes.
    const cmdQuadWrite = 0x38;
    const cmdFastReadQuad = 0xEB;

    // FSM state encoding.
    const sIdle = 0;
    const sSelect = 1;
    const sCmd = 2;
    const sAddr = 3;
    const sWait = 4;
    const sXfer = 5;
    const sDone = 6;

    final valid = bus.stb.named('psram_valid');
    final write = bus.we.named('psram_write');
    // Word index into the bank (byte address >> 2), 21 bits for an 8 MB span.
    final wordAddr = bus.addr.getRange(2, 23).named('psram_word_addr');

    // Write-data alignment: pick the selected bytes into the MSBs, the byte
    // offset, and the shift count from the byte-lane selects. Mirrors the
    // source case(bus_SEL) block.
    final sel = bus.sel.getRange(0, 4);
    final dIn = bus.dataIn.getRange(0, 32);
    final byteOffset = Logic(name: 'byte_offset', width: 2);
    final wrCycles = Logic(name: 'wr_cycles', width: 6);
    final wrBuffer = Logic(name: 'wr_buffer', width: 32);
    Logic pack8(Logic byte) =>
        [byte, Const(0, width: 24)].swizzle().getRange(0, 32);
    Logic pack16(Logic half) =>
        [half, Const(0, width: 16)].swizzle().getRange(0, 32);
    Combinational([
      byteOffset < Const(0, width: 2),
      wrCycles < Const(32, width: 6),
      wrBuffer < dIn,
      Case(
        sel,
        [
          CaseItem(Const(0x1, width: 4), [
            byteOffset < Const(3, width: 2),
            wrBuffer < pack8(dIn.getRange(0, 8)),
            wrCycles < Const(8, width: 6),
          ]),
          CaseItem(Const(0x2, width: 4), [
            byteOffset < Const(2, width: 2),
            wrBuffer < pack8(dIn.getRange(8, 16)),
            wrCycles < Const(8, width: 6),
          ]),
          CaseItem(Const(0x4, width: 4), [
            byteOffset < Const(1, width: 2),
            wrBuffer < pack8(dIn.getRange(16, 24)),
            wrCycles < Const(8, width: 6),
          ]),
          CaseItem(Const(0x8, width: 4), [
            byteOffset < Const(0, width: 2),
            wrBuffer < pack8(dIn.getRange(24, 32)),
            wrCycles < Const(8, width: 6),
          ]),
          CaseItem(Const(0x3, width: 4), [
            byteOffset < Const(2, width: 2),
            wrBuffer < pack16(dIn.getRange(0, 16)),
            wrCycles < Const(16, width: 6),
          ]),
          CaseItem(Const(0xC, width: 4), [
            byteOffset < Const(0, width: 2),
            wrBuffer < pack16(dIn.getRange(16, 32)),
            wrCycles < Const(16, width: 6),
          ]),
          CaseItem(Const(0xF, width: 4), [
            byteOffset < Const(0, width: 2),
            wrBuffer < dIn,
            wrCycles < Const(32, width: 6),
          ]),
        ],
        defaultItem: [
          byteOffset < Const(0, width: 2),
          wrBuffer < dIn,
          wrCycles < Const(32, width: 6),
        ],
      ),
    ]);

    // FSM registers.
    final state = Logic(name: 'state', width: 3);
    final spiBuf = Logic(name: 'spi_buf', width: 32);
    final xferCycles = Logic(name: 'xfer_cycles', width: 6);
    final isQuad = Logic(name: 'is_quad');
    final ce = Logic(name: 'ce');
    final sclk = Logic(name: 'sclk');
    final sioOut = Logic(name: 'sio_out', width: 4);
    final sioOe = Logic(name: 'sio_oe', width: 4);
    final busAckReg = Logic(name: 'bus_ack_r');
    final busMisoReg = Logic(name: 'bus_miso_r', width: 32);
    // The request is latched at accept, so an aborted one still runs to its
    // end with what was issued. Its result is then not acked.
    final orphan = Logic(name: 'orphan');
    final weR = Logic(name: 'we_r');
    final wordAddrR = Logic(name: 'word_addr_r', width: 21);
    final byteOffsetR = Logic(name: 'byte_offset_r', width: 2);
    final wrBufferR = Logic(name: 'wr_buffer_r', width: 32);
    final wrCyclesR = Logic(name: 'wr_cycles_r', width: 6);
    final read = (~weR).named('psram_read');

    // Input lines: quad reads all four IO pins, standard reads MISO on IO1.
    final sioIn = quad
        ? input('spi_io_in')
        : [
            Const(0, width: 2),
            input('spi_miso'),
            Const(0),
          ].swizzle().named('sio_in');

    // Command byte selected by mode + direction, placed in the top byte.
    final cmdByte = mux(
      Const(quad),
      mux(weR, Const(cmdQuadWrite, width: 8), Const(cmdFastReadQuad, width: 8)),
      mux(weR, Const(cmdWrite, width: 8), Const(cmdRead, width: 8)),
    );
    // Address word placed in bits [31:8]: {1'b0, wordAddr[20:0], offset[1:0]}.
    final addrField = [
      Const(0),
      wordAddrR,
      mux(weR, byteOffsetR, Const(0, width: 2)),
    ].swizzle().getRange(0, 24);

    final quadC = Const(quad);
    final oeQuadAddr = quad ? Const(0xF, width: 4) : Const(0x1, width: 4);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 3),
          ce < Const(1),
          sclk < Const(0),
          sioOe < Const(0, width: 4),
          sioOut < Const(0, width: 4),
          spiBuf < Const(0, width: 32),
          isQuad < Const(0),
          xferCycles < Const(0, width: 6),
          busAckReg < Const(0),
          busMisoReg < Const(0, width: 32),
          orphan < Const(0),
        ],
        orElse: [
          // ACK is a one-cycle pulse.
          busAckReg < Const(0),
          If(state.neq(Const(sIdle, width: 3)) & ~valid, then: [orphan < 1]),
          If(
            xferCycles.neq(Const(0, width: 6)),
            then: [
              // Bit engine: MSB-first, 1 bit/cycle (single) or 4 bits/cycle (quad).
              sioOut <
                  mux(
                    isQuad,
                    spiBuf.getRange(28, 32),
                    [Const(0, width: 3), spiBuf[31]].swizzle().getRange(0, 4),
                  ),
              If(
                sclk,
                then: [sclk < Const(0)],
                orElse: [
                  sclk < Const(1),
                  spiBuf <
                      mux(
                        isQuad,
                        [
                          spiBuf.getRange(0, 28),
                          sioIn,
                        ].swizzle().getRange(0, 32),
                        [
                          spiBuf.getRange(0, 31),
                          sioIn[1],
                        ].swizzle().getRange(0, 32),
                      ),
                  xferCycles <
                      mux(
                        isQuad,
                        xferCycles - Const(4, width: 6),
                        xferCycles - Const(1, width: 6),
                      ),
                ],
              ),
            ],
            orElse: [
              Case(
                state,
                [
                  CaseItem(Const(sIdle, width: 3), [
                    sioOe < Const(0x1, width: 4),
                    isQuad < Const(0),
                    ce < Const(1),
                    // A classic master still holds its request on the ACK
                    // cycle. Do not take it again.
                    If(
                      valid & ~busAckReg,
                      then: [
                        state < Const(sSelect, width: 3),
                        xferCycles < Const(0, width: 6),
                        orphan < Const(0),
                        weR < write,
                        wordAddrR < wordAddr,
                        byteOffsetR < byteOffset,
                        wrBufferR < wrBuffer,
                        wrCyclesR < wrCycles,
                      ],
                    ),
                  ]),
                  CaseItem(Const(sSelect, width: 3), [
                    ce < Const(0),
                    state < Const(sCmd, width: 3),
                  ]),
                  CaseItem(Const(sCmd, width: 3), [
                    spiBuf <
                        [
                          cmdByte,
                          Const(0, width: 24),
                        ].swizzle().getRange(0, 32),
                    xferCycles < Const(8, width: 6),
                    state < Const(sAddr, width: 3),
                  ]),
                  CaseItem(Const(sAddr, width: 3), [
                    spiBuf <
                        [
                          addrField,
                          Const(0, width: 8),
                        ].swizzle().getRange(0, 32),
                    sioOe < oeQuadAddr,
                    xferCycles < Const(24, width: 6),
                    isQuad < quadC,
                    state <
                        mux(
                          quadC & read,
                          Const(sWait, width: 3),
                          Const(sXfer, width: 3),
                        ),
                  ]),
                  CaseItem(Const(sWait, width: 3), [
                    sioOe < Const(0, width: 4),
                    xferCycles < Const(6, width: 6),
                    isQuad < Const(0),
                    state < Const(sXfer, width: 3),
                  ]),
                  CaseItem(Const(sXfer, width: 3), [
                    isQuad < quadC,
                    If(
                      weR,
                      then: [sioOe < oeQuadAddr, spiBuf < wrBufferR],
                      orElse: [
                        sioOe <
                            (quad ? Const(0, width: 4) : Const(0x1, width: 4)),
                      ],
                    ),
                    xferCycles < mux(weR, wrCyclesR, Const(32, width: 6)),
                    state < Const(sDone, width: 3),
                  ]),
                  CaseItem(Const(sDone, width: 3), [
                    busMisoReg < spiBuf,
                    busAckReg < ~orphan & valid,
                    state < Const(sIdle, width: 3),
                  ]),
                ],
                defaultItem: [state < Const(sIdle, width: 3)],
              ),
            ],
          ),
        ],
      ),
    ]);

    // Drive outputs.
    output('spi_clk') <= sclk;
    output('spi_cs_n') <= ce;
    if (quad) {
      output('spi_io_out') <= sioOut;
      output('spi_io_oe') <= sioOe;
    } else {
      output('spi_mosi') <= sioOut[0];
    }
    bus.ack <= busAckReg & valid;
    bus.dataOut <= busMisoReg;
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: [
      'harbor,psram-controller',
      if (config.mode == HarborPsramMode.quad) 'harbor,qspi-psram',
    ],
    reg: BusAddressRange(baseAddress, config.size),
    properties: {
      'psram-mode': config.mode.name,
      'spi-max-frequency': config.spiFrequency,
    },
  );

  @override
  List<BusAddressRange> get systemMemory => [
    BusAddressRange(baseAddress, config.size),
  ];

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, config.size)],
    properties: {
      'compatible': [
        'harbor,psram-controller',
        if (config.mode == HarborPsramMode.quad) 'harbor,qspi-psram',
      ],
      'psram-mode': config.mode.name,
      'spi-max-frequency': config.spiFrequency,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'PSRAM',
    groupName: 'PSRAM',
    description: 'QSPI PSRAM controller',
    baseAddress: baseAddress,
    size: config.size,
  );
}

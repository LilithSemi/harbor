import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../util/pretty_string.dart';

/// SPI flash operating mode.
enum HarborSpiFlashMode {
  /// Standard SPI (1-bit MOSI/MISO).
  standard,

  /// Dual SPI (2-bit I/O).
  dual,

  /// Quad SPI (4-bit I/O, QSPI).
  quad,
}

/// SPI flash configuration.
/// A flash partition for the device-tree `fixed-partitions` map (also the Linux
/// MTD binding). genip populates these per target: an FPGA target prepends an
/// `fpga-bitstream` partition at offset 0; every target has `river-fsbl` and
/// `river-firmware`.
class HarborFlashPartition {
  /// Partition label (e.g. `fpga-bitstream`, `river-fsbl`, `river-firmware`).
  final String label;

  /// Byte offset within the flash.
  final int offset;

  /// Byte size of the partition.
  final int size;

  const HarborFlashPartition({
    required this.label,
    required this.offset,
    required this.size,
  });

  @override
  String toString() =>
      'HarborFlashPartition($label @ 0x${offset.toRadixString(16)} '
      '(0x${size.toRadixString(16)}))';
}

class HarborSpiFlashConfig with HarborPrettyString {
  /// HarborFlash size in bytes.
  final int size;

  /// SPI clock frequency in Hz.
  final int spiFrequency;

  /// Operating mode (standard/dual/quad).
  final HarborSpiFlashMode mode;

  /// Page size in bytes (typically 256).
  final int pageSize;

  /// Sector size in bytes (typically 4096).
  final int sectorSize;

  /// Read command opcode (0x03 for standard, 0x6B for quad).
  final int readCommand;

  /// Address width in bytes (3 for 24-bit, 4 for 32-bit).
  final int addressBytes;

  /// Number of dummy cycles for fast read.
  final int dummyCycles;

  /// Read-ahead line size in BUS WORDS. 1 (default) = one flash read command per
  /// bus word, the original behaviour. >1 streams this many sequential words in a
  /// single command (one shared cmd+addr+dummy) into a line buffer, and serves
  /// subsequent in-line words from the buffer with no flash access, a big win
  /// for sequential reads since the per-word cmd/addr/dummy overhead dominates.
  final int readAheadWords;

  /// Flash partition map emitted as a DT `fixed-partitions` node (empty = none).
  /// genip computes this from the target (see [HarborFlashPartition]).
  final List<HarborFlashPartition> partitions;

  const HarborSpiFlashConfig({
    required this.size,
    this.spiFrequency = 25000000,
    this.mode = HarborSpiFlashMode.standard,
    this.pageSize = 256,
    this.sectorSize = 4096,
    this.readCommand = 0x03,
    this.addressBytes = 3,
    this.dummyCycles = 0,
    this.readAheadWords = 1,
    this.partitions = const [],
  });

  /// W25Q128: common 16MB SPI flash (e.g., on iCEBreaker, OrangeCrab).
  const HarborSpiFlashConfig.w25q128({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
    this.readAheadWords = 1,
    this.partitions = const [],
  }) : size = 16 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6B, // Quad Output Fast Read
       addressBytes = 3,
       dummyCycles = 8;

  /// IS25LP128: common 16MB SPI flash (e.g., on Arty boards).
  const HarborSpiFlashConfig.is25lp128({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
    this.readAheadWords = 1,
    this.partitions = const [],
  }) : size = 16 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6B,
       addressBytes = 3,
       dummyCycles = 8;

  /// S25FL256: 32MB SPI flash.
  const HarborSpiFlashConfig.s25fl256({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
    this.readAheadWords = 1,
    this.partitions = const [],
  }) : size = 32 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6C, // 4-byte addr quad read
       addressBytes = 4,
       dummyCycles = 8;

  @override
  String toString() =>
      'HarborSpiFlashConfig(${size ~/ (1024 * 1024)} MB, '
      '${mode.name}, ${spiFrequency ~/ 1000000} MHz)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborSpiFlashConfig(\n');
    buf.writeln('${c}size: ${size ~/ (1024 * 1024)} MB,');
    buf.writeln('${c}mode: ${mode.name},');
    buf.writeln('${c}frequency: ${spiFrequency ~/ 1000000} MHz,');
    buf.writeln('${c}readCmd: 0x${readCommand.toRadixString(16)},');
    buf.writeln('${c}addrBytes: $addressBytes,');
    buf.writeln('${c}dummyCycles: $dummyCycles,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// SPI flash controller.
///
/// Provides a Wishbone slave interface for read access to external
/// SPI NOR flash. Supports standard, dual, and quad SPI modes.
///
/// SPI pins (directly exposed for board connection):
/// - `spi_clk`: SPI clock output
/// - `spi_cs_n`: Chip select (active low)
/// - `spi_mosi`: Master Out Slave In (standard mode data out)
/// - `spi_miso`: Master In Slave Out (standard mode data in)
/// - `spi_io_out` / `spi_io_oe` / `spi_io_in`: split Quad/Dual I/O (when mode
///   != standard), the SoC/pad ring resolves the bidirectional lines
///
/// Supports XIP (Execute In Place): the CPU can fetch instructions
/// directly from the SPI flash.
class HarborSpiFlashController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider {
  /// HarborFlash configuration.
  final HarborSpiFlashConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port (CPU side).
  late final BusSlavePort bus;

  HarborSpiFlashController({
    required this.config,
    required this.baseAddress,
    int? busAddressWidth,
    int? busDataWidth,
    // ECP5 only: route the SPI clock through the USRMCLK macro (the config
    // SPI clock has no I/O pad) instead of exposing a spi_clk port, so the
    // controller can drive the on-board config flash for XIP.
    bool useUsrmclk = false,
    // Xilinx 7-series only: drive the config-flash clock through STARTUPE2's
    // USRCCLKO (the CCLK ball has no user pad, like the ECP5 USRMCLK) instead
    // of exposing a spi_clk port. Mutually exclusive with useUsrmclk.
    bool useStartupe2 = false,
    // FPGA standalone builds: own the quad/dual IO pads. Instead of exposing
    // split spi_io_out/oe/in for an external pad ring, create one inout `spi_io`
    // pad driven through a TriStateBuffer (synthesis infers the IOBUF, the
    // constraint file applies the pin + IOSTANDARD). Leave false when a
    // hand-written top or shared-bus mux owns the pads (e.g. Tiny Tapeout).
    bool ownPads = false,
    // I4: WIP-poll watchdog bound (number of RDSR poll iterations before the
    // write engine gives up and raises wr_err). The default (~1M) is many
    // orders beyond any real sector-erase time, lower it for fast simulation.
    int writePollLimit = (1 << 20) - 1,
    BusProtocol protocol = BusProtocol.wishbone,
    String? name,
  }) : super('HarborSpiFlashController', name: name ?? 'spi_flash') {
    if (writePollLimit < 1) {
      throw ArgumentError.value(
        writePollLimit,
        'writePollLimit',
        'must be >= 1',
      );
    }
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // SPI pins. The clock is a pad EXCEPT on ECP5+USRMCLK, where the macro
    // drives the dedicated MCLK ball internally (no spi_clk port).
    if (!useUsrmclk && !useStartupe2) addOutput('spi_clk');
    addOutput('spi_cs_n');

    if (config.mode == HarborSpiFlashMode.standard) {
      addOutput('spi_mosi');
      createPort('spi_miso', PortDirection.input);
    } else {
      // Quad/Dual mode shares its bidirectional IO lines. Either own the pad
      // (one inout `spi_io` with an internal tristate) or expose split tristate
      // (out/oe/in) for an external pad ring / shared-bus mux to resolve.
      final ioWidth = config.mode == HarborSpiFlashMode.quad ? 4 : 2;
      if (ownPads) {
        createPort('spi_io', PortDirection.inOut, width: ioWidth);
      } else {
        addOutput('spi_io_out', width: ioWidth);
        addOutput('spi_io_oe', width: ioWidth);
        createPort('spi_io_in', PortDirection.input, width: ioWidth);
      }
    }

    // The bus address must match the system bus width (the fabric connects
    // same-width interfaces), the byte address is masked to the part's span
    // internally for the SPI read command.
    final addrWidth = busAddressWidth ?? config.size.bitLength;
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: addrWidth,
      dataWidth: busDataWidth ?? 32,
    );

    // WRITE/ERASE command interface (DFU flash-provisioning side, NOT the CPU
    // bus). The DFU flash sink (B5b) drives these to erase a sector or program
    // a page. Program data is pulled byte-by-byte via a read-callback: the
    // engine presents the next index on wr_data_index and the sink presents
    // that byte combinationally on wr_data (same payload-source style as
    // UsbPacketTx). Flash WRITES are always STANDARD single-bit (DQ0/spi_mosi),
    // even when the read mode is quad.
    // I3: the write address width tracks config.addressBytes (3 -> 24-bit,
    // 4 -> 32-bit) so a 4-byte part (e.g. S25FL256, 32MB) lands the program /
    // erase at the RIGHT sector instead of silently dropping the top byte and
    // bricking. Only 3- and 4-byte address parts are supported, anything else
    // fails LOUDLY at construction rather than mis-addressing flash.
    if (config.addressBytes != 3 && config.addressBytes != 4) {
      throw ArgumentError.value(
        config.addressBytes,
        'config.addressBytes',
        'SPI flash write engine supports only 3- or 4-byte addressing',
      );
    }
    final wrAddrWidth = config.addressBytes * 8;

    createPort('wr_req', PortDirection.input);
    createPort('wr_op', PortDirection.input); // 0=sector-erase, 1=page-program
    createPort('wr_addr', PortDirection.input, width: wrAddrWidth);
    createPort('wr_len', PortDirection.input, width: 9); // 1..256 program bytes
    createPort('wr_data', PortDirection.input, width: 8); // sink presents byte
    addOutput('wr_data_index', width: 9); // index the sink should present
    addOutput('wr_busy');
    addOutput('wr_done');
    // I4: sticky error flag. Raised (and held until the next accepted wr_req)
    // when the WIP poll exceeds the watchdog bound. Default-safe: it stays low
    // on every successful erase/program, so existing callers / B5b wiring that
    // ignore it see no behavioural change.
    addOutput('wr_err');

    final clk = input('clk');
    final reset = input('reset');
    // A memory-class slave on the system bus must return the FULL bus word. The
    // RV64 core issues bus-word-aligned reads (the low address bits are 0) and
    // selects the addressed sub-word out of the returned bus.dataOut, exactly
    // like HarborSram (instantiated at the full 64-bit bus width). So on the
    // 64-bit bus we read a WHOLE bus word of flash, busBytes sequential bytes,
    // and drive all of bus.dataOut. The earlier code read a single 32-bit flash
    // word into the LOW 32 bits and left the high lanes 0, so every read whose
    // addressed bytes fell in the high half of the bus word (byte offset 4,12,..
    // on a 64-bit bus) came back ZERO. That made the maskrom's word-by-word lw
    // firmware copy land [instr,0,instr,0..] in SRAM, the core trapped on the
    // first zero word, and the board was dead silent. busWidth bytes is the read
    // size, a 32-bit bus keeps the original 4-byte behaviour.
    final busWidth = bus.dataOut.width;
    final busBytes = busWidth ~/ 8;
    final datOut = Logic(name: 'dat_out_internal', width: busWidth);
    bus.dataOut <= datOut;
    final ack = bus.ack;
    // The read FSM only owns the bus when the write engine is idle: a bus
    // request arriving mid-write is HELD (no ack) until wr_busy drops, so the
    // two engines never interleave on the shared SPI pins (see arbitration mux
    // at the bottom). gated stb keeps the read FSM parked in sIdle while busy.
    final wrBusy = output('wr_busy');
    final stb = (bus.stb & ~wrBusy).named('rd_stb_gated');

    // SPI state machine
    // On ECP5 the clock lives on an internal net feeding USRMCLK, otherwise it
    // is the spi_clk pad. The macro is instantiated after the state machine.
    // These are the READ FSM's private clock/CS, the actual spi_clk/spi_cs_n
    // pads are muxed between the read and write engines below (wr_busy select).
    final spiClk = Logic(name: 'rd_spi_clk');
    final spiCsN = Logic(name: 'rd_spi_cs_n');

    // Bits per clock cycle for data phases
    final bitsPerCycle = switch (config.mode) {
      HarborSpiFlashMode.standard => 1,
      HarborSpiFlashMode.dual => 2,
      HarborSpiFlashMode.quad => 4,
    };

    // Total clocks needed for each phase. The configured reads are all OUTPUT-
    // class (0x03/0x0B/0x3B/0x6B/0x6C): command AND address go out 1-bit on DQ0,
    // only the DATA phase uses the wide (dual/quad) bus. So cmd/addr are always
    // 8 / addressBytes*8 single-bit clocks, data is 32/bitsPerCycle.
    final cmdClocks = 8;
    final addrClocks = config.addressBytes * 8;
    // Read a whole bus word (busBytes bytes) so the wide bus gets all its lanes.
    final dataClocks = busWidth ~/ bitsPerCycle;

    // Shift register for SPI transactions. Widened to the bus word so the data
    // phase can accumulate a full busWidth-bit read and the cmd/addr phases
    // shift out MSB-first from bit busWidth-1.
    final shiftReg = Logic(name: 'shift_reg', width: busWidth);
    final bitCount = Logic(name: 'bit_count', width: 8);
    final spiState = Logic(name: 'spi_state', width: 3);
    final ioDir = Logic(name: 'io_dir'); // 0=output, 1=input

    // States
    const sIdle = 0;
    const sSendCmd = 1;
    const sSendAddr = 2;
    const sDummy = 3;
    const sReadData = 4;
    const sDone = 5;

    // Read-ahead line: a miss streams `lineWords` sequential bus words in ONE
    // flash command (shared cmd+addr+dummy) into `lineBuf`, in-line words are
    // then served from the buffer with no flash access. lineWords==1 is the
    // original one-word-per-command behaviour (default).
    final lineWords = config.readAheadWords;
    final lineBytes = busBytes * lineWords;
    final lineBuf = List.generate(
      lineWords,
      (i) => Logic(name: 'line_buf_$i', width: busWidth),
    );
    final lineValid = Logic(name: 'line_valid');
    final lineTag = Logic(name: 'line_tag', width: 32); // aligned base addr
    final wordIdx = Logic(
      name: 'word_idx',
      width: 8,
    ); // fill index during a miss
    final addr32 =
        (bus.addr.width >= 32
                ? bus.addr.getRange(0, 32)
                : bus.addr.zeroExtend(32))
            .named('addr32');
    // The address is latched when a miss starts, so an aborted read still
    // fills the line it was issued for. Its result is then not acked.
    final reqAddr = Logic(name: 'req_addr', width: 32);
    final orphan = Logic(name: 'orphan');
    // Line-aligned base of an address, and the word's index within the line.
    Logic lineBase(Logic a) =>
        a & Const((config.size - 1) & ~(lineBytes - 1), width: 32);
    final lineWordSelBits = lineWords <= 1 ? 1 : (lineWords - 1).bitLength;
    final busByteShift = busBytes <= 1 ? 0 : (busBytes - 1).bitLength;
    Logic wordSel(Logic a) => (lineWords <= 1)
        ? Const(0, width: 8)
        : a
              .getRange(busByteShift, busByteShift + lineWordSelBits)
              .zeroExtend(8);
    final reqWordSel = wordSel(addr32).named('req_word_sel');
    final lineHit = (lineValid & lineBase(addr32).eq(lineTag)).named(
      'line_hit',
    );

    // The flash command reads from the LINE base (aligned to lineBytes).
    final maskedAddr = lineBase(reqAddr).zeroExtend(busWidth);
    // Left shift that aligns the MSB of the address to bit busWidth-1, so the
    // 1-bit address phase shifts it out MSB-first.
    final addrAlign = Const(
      busWidth - config.addressBytes * 8,
      width: busWidth,
    );

    final isStd = config.mode == HarborSpiFlashMode.standard;
    // Input sampled from the data line(s) during the read phase: MISO (1-bit) in
    // standard mode, the dual/quad bus otherwise. Connected to the pad below.
    final spiIoIn = Logic(
      name: 'spi_io_in',
      width: isStd ? 1 : (config.mode == HarborSpiFlashMode.quad ? 4 : 2),
    );

    // The shift register value AFTER this cycle's data shift, at a word boundary
    // it holds the just-completed word (MSB-first).
    final nextShift =
        ((shiftReg << Const(bitsPerCycle, width: 32)) |
                spiIoIn.zeroExtend(busWidth))
            .named('next_shift');
    // Byte-reverse a busWidth word: the flash streamed bytes MSB-first (lowest
    // address in the high byte), so reverse to the little-endian bus word.
    Logic byteSwap(Logic w) => [
      for (var i = 0; i < busBytes; i++) w.getRange(i * 8, i * 8 + 8),
    ].swizzle();

    Sequential(clk, [
      If(
        reset,
        then: [
          spiCsN < Const(1),
          spiClk < Const(0),
          shiftReg < Const(0, width: busWidth),
          bitCount < Const(0, width: 8),
          spiState < Const(sIdle, width: 3),
          ioDir < Const(0),
          ack < Const(0),
          datOut < Const(0, width: busWidth),
          lineValid < Const(0),
          lineTag < Const(0, width: 32),
          wordIdx < Const(0, width: 8),
          for (final b in lineBuf) b < Const(0, width: busWidth),
          reqAddr < Const(0, width: 32),
          orphan < Const(0),
        ],
        orElse: [
          ack < Const(0),
          If(
            spiState.neq(Const(sIdle, width: 3)) & ~bus.stb,
            then: [orphan < Const(1)],
          ),

          // A flash write/erase can change the cached bytes: invalidate the
          // read-ahead line while the write engine is active.
          If(wrBusy, then: [lineValid < Const(0)]),

          // B2: FREEZE the read FSM while the write engine owns the pins. With
          // the B1 interlock a write only ever starts when spiState == sIdle,
          // so the read FSM is never mid-frame at handoff, even so, gate ALL
          // state/shift progress (and ack) on ~wrBusy as defense in depth. The
          // read FSM holds its state and never advances against MISO nor acks
          // garbage to the CPU during a write (ack is forced 0 above).
          If(
            ~wrBusy,
            then: [
              Case(spiState, [
                // IDLE: wait for bus request. In-line hit -> serve from the buffer,
                // miss -> start a flash command that fills the whole line.
                CaseItem(Const(sIdle, width: 3), [
                  If(
                    stb & ~ack,
                    then: [
                      If(
                        lineHit,
                        then: [
                          for (var i = 0; i < lineWords; i++)
                            If(
                              reqWordSel.eq(Const(i, width: 8)),
                              then: [datOut < lineBuf[i]],
                            ),
                          ack < Const(1),
                        ],
                        orElse: [
                          spiCsN < Const(0),
                          // Command left-aligned to bit busWidth-1 (shifted out MSB-
                          // first, 1-bit on DQ0).
                          shiftReg <
                              Const(
                                config.readCommand << (busWidth - 8),
                                width: busWidth,
                              ),
                          bitCount < Const(0, width: 8),
                          wordIdx < Const(0, width: 8),
                          reqAddr < addr32,
                          orphan < Const(0),
                          ioDir < Const(0), // output (drive DQ0)
                          spiState < Const(sSendCmd, width: 3),
                        ],
                      ),
                    ],
                  ),
                ]),

                // SEND_CMD: 8 bits, always 1-bit SPI on DQ0 (MSB first)
                CaseItem(Const(sSendCmd, width: 3), [
                  spiClk < ~spiClk,
                  If(
                    spiClk,
                    then: [
                      shiftReg < (shiftReg << Const(1, width: 32)),
                      bitCount < (bitCount + Const(1, width: 8)),
                      If(
                        bitCount.eq(Const(cmdClocks - 1, width: 8)),
                        then: [
                          // Load the address, left-aligned so its MSB is at bit 31.
                          shiftReg < (maskedAddr << addrAlign),
                          bitCount < Const(0, width: 8),
                          spiState < Const(sSendAddr, width: 3),
                        ],
                      ),
                    ],
                  ),
                ]),

                // SEND_ADDR: addressBytes*8 bits, 1-bit on DQ0 (MSB first)
                CaseItem(Const(sSendAddr, width: 3), [
                  spiClk < ~spiClk,
                  If(
                    spiClk,
                    then: [
                      shiftReg < (shiftReg << Const(1, width: 32)),
                      bitCount < (bitCount + Const(1, width: 8)),
                      If(
                        bitCount.eq(Const(addrClocks - 1, width: 8)),
                        then: [
                          bitCount < Const(0, width: 8),
                          ioDir < Const(1), // release IO: the flash drives now
                          shiftReg < Const(0, width: busWidth),
                          spiState <
                              Const(
                                config.dummyCycles > 0 ? sDummy : sReadData,
                                width: 3,
                              ),
                        ],
                      ),
                    ],
                  ),
                ]),

                // DUMMY: dummy cycles (IO released, nothing sampled)
                CaseItem(Const(sDummy, width: 3), [
                  spiClk < ~spiClk,
                  If(
                    spiClk,
                    then: [
                      bitCount < (bitCount + Const(1, width: 8)),
                      If(
                        bitCount.eq(Const(config.dummyCycles - 1, width: 8)),
                        then: [
                          bitCount < Const(0, width: 8),
                          shiftReg < Const(0, width: busWidth),
                          spiState < Const(sReadData, width: 3),
                        ],
                      ),
                    ],
                  ),
                ]),

                // READ_DATA: sample the data line(s) and shift in, bitsPerCycle/clk.
                // At each word boundary store the word into the line buffer, keep
                // streaming (CS stays low) until the whole line is read.
                CaseItem(Const(sReadData, width: 3), [
                  spiClk < ~spiClk,
                  If(
                    spiClk,
                    then: [
                      shiftReg < nextShift,
                      bitCount < (bitCount + Const(1, width: 8)),
                      If(
                        bitCount.eq(Const(dataClocks - 1, width: 8)),
                        then: [
                          for (var i = 0; i < lineWords; i++)
                            If(
                              wordIdx.eq(Const(i, width: 8)),
                              then: [lineBuf[i] < byteSwap(nextShift)],
                            ),
                          bitCount < Const(0, width: 8),
                          If(
                            wordIdx.eq(Const(lineWords - 1, width: 8)),
                            then: [spiState < Const(sDone, width: 3)],
                            orElse: [wordIdx < (wordIdx + Const(1, width: 8))],
                          ),
                        ],
                      ),
                    ],
                  ),
                ]),

                // DONE: byte-swap the MSB-first shift register to the little-endian
                // bus word the CPU expects (byte at the lowest flash address ->
                // bits [7:0]). The flash streamed busBytes bytes MSB-first, so the
                // first byte read (lowest address) sits in the HIGH byte of shiftReg
                // and must move to the low byte of datOut: reverse the byte order.
                CaseItem(Const(sDone, width: 3), [
                  // Serve the requested word from the filled line, and validate the
                  // line so subsequent in-line reads hit the buffer.
                  for (var i = 0; i < lineWords; i++)
                    If(
                      wordSel(reqAddr).eq(Const(i, width: 8)),
                      then: [datOut < lineBuf[i]],
                    ),
                  lineValid < Const(1),
                  lineTag < lineBase(reqAddr),
                  ack < ~orphan & bus.stb,
                  spiCsN < Const(1),
                  spiClk < Const(0),
                  ioDir < Const(0),
                  spiState < Const(sIdle, width: 3),
                ]),
              ]),
            ],
          ), // end If(~wrBusy) (B2 read-FSM freeze)
        ],
      ),
    ]);

    // A second, independent FSM that owns the SPI pins while wr_busy is high.
    // It runs WREN, then the erase or page-program command (opcode + 24-bit
    // address [+ data bytes]), then polls Read-Status-Register-1 until WIP
    // (bit0) clears. ALL write traffic is standard single-bit on DQ0
    // (spi_mosi / spi_io[0]), status is read back on spi_miso / spi_io[1].
    //
    // FSM:
    //   wIdle      wait for wr_req, latch op/addr/len
    //   wWrenLow   CS low, load WREN (0x06)
    //   wWren      shift 8 bits of WREN
    //   wWrenHigh  CS high gap after WREN (every erase/program needs WREN first)
    //   wCmdLow    CS low, load command opcode (0x20 erase / 0x02 program)
    //   wCmd       shift 8 bits of opcode, then load address
    //   wAddr      shift 24 bits of address, erase -> poll, program -> data
    //   wData      shift program bytes (pulled via wr_data_index callback)
    //   wEnd       CS high gap after the command frame
    //   wStatLow   CS low, load RDSR (0x05)
    //   wStatCmd   shift 8 bits of RDSR (output)
    //   wStatRead  shift IN 8 status bits, bit0 = WIP
    //   wStatHigh  CS high, if WIP set -> back to wStatLow, else -> wDone
    //   wDone      pulse wr_done, drop wr_busy
    const wIdle = 0;
    const wWren = 2;
    const wWrenHigh = 3;
    const wCmd = 5;
    const wAddr = 6;
    const wData = 7;
    const wDataLoad = 14;
    const wEnd = 8;
    const wStatLow = 9;
    const wStatCmd = 10;
    const wStatRead = 11;
    const wStatHigh = 12;
    const wDone = 13;

    const cmdWren = 0x06;
    const cmdRdsr = 0x05;
    const cmdErase = 0x20; // 4KB sector erase
    const cmdProgram = 0x02; // page program

    final wrState = Logic(name: 'wr_state', width: 4);
    final wrShift = Logic(name: 'wr_shift', width: 32);
    final wrBitCount = Logic(name: 'wr_bit_count', width: 8);
    final wrByteIdx = Logic(name: 'wr_byte_idx', width: 9);
    final wrClk = Logic(name: 'wr_spi_clk');
    final wrCsN = Logic(name: 'wr_spi_cs_n');
    final wrDriveOut = Logic(name: 'wr_drive_out'); // 1=drive DQ0, 0=release
    final wrDoneReg = Logic(name: 'wr_done_reg');
    final wrErrReg = Logic(name: 'wr_err_reg'); // I4: sticky timeout flag
    final wrOpL = Logic(name: 'wr_op_l'); // 0=erase, 1=program
    final wrAddrL = Logic(name: 'wr_addr_l', width: wrAddrWidth);
    final wrLenL = Logic(name: 'wr_len_l', width: 9);
    final wrStatus = Logic(name: 'wr_status', width: 8);
    // I4: count the number of RDSR poll iterations, abort if WIP never clears.
    // The default bound (writePollLimit, ~1M) covers a worst-case slow sector
    // erase (~400ms on typical parts at thousands of system clocks per RDSR)
    // with huge margin, yet stays bounded so a dead part can't hang forever.
    final pollCountWidth = writePollLimit.bitLength + 1;
    final wrPollCount = Logic(name: 'wr_poll_count', width: pollCountWidth);
    final wrPollLimit = Const(writePollLimit, width: pollCountWidth);

    // wr_busy is high in every state except idle.
    wrBusy <= ~wrState.eq(Const(wIdle, width: 4));
    output('wr_done') <= wrDoneReg;
    output('wr_err') <= wrErrReg;
    output('wr_data_index') <= wrByteIdx;

    // Status data-in bit: spi_miso in standard mode, spi_io[1] otherwise.
    // (isStd is declared above for the read path.)
    final statBit = Logic(name: 'wr_stat_bit');

    // Address left-aligned so its MSB sits at bit 31, shifted out MSB-first as
    // an addressBytes*8 address (3-byte -> <<8, 4-byte -> <<0).
    final wrAddrAligned =
        wrAddrL.zeroExtend(32) << Const(32 - wrAddrWidth, width: 32);
    final wrDataLoad = input('wr_data').zeroExtend(32) << Const(24, width: 32);

    Sequential(clk, [
      If(
        reset,
        then: [
          wrState < Const(wIdle, width: 4),
          wrShift < Const(0, width: 32),
          wrBitCount < Const(0, width: 8),
          wrByteIdx < Const(0, width: 9),
          wrClk < Const(0),
          wrCsN < Const(1),
          wrDriveOut < Const(0),
          wrDoneReg < Const(0),
          wrErrReg < Const(0),
          wrOpL < Const(0),
          wrAddrL < Const(0, width: wrAddrWidth),
          wrLenL < Const(0, width: 9),
          wrStatus < Const(0, width: 8),
          wrPollCount < Const(0, width: pollCountWidth),
        ],
        orElse: [
          wrDoneReg < Const(0),
          Case(wrState, [
            // IDLE: wait for wr_req, latch op/addr/len. B1 INTERLOCK: only
            // ACCEPT the request when the READ FSM is idle (spiState == sIdle)
            // so the pin owner-mux never hands the SPI pins to the write engine
            // mid-read-frame (CS low). If wr_req arrives during a read frame it
            // is HELD pending here: the caller must keep wr_req asserted until
            // it is accepted (wr_busy rises). The handoff therefore only ever
            // happens at a clean CS-high boundary (read retired to sIdle).
            //
            // Minor validation: reject a zero-length page-program, and a
            // program that would cross the 256-byte page boundary (real flash
            // wraps within the page, corrupting the page start). Rejected
            // requests raise the sticky wr_err and pulse wr_done WITHOUT
            // touching the pins, so the caller learns instead of corrupting.
            CaseItem(Const(wIdle, width: 4), [
              wrClk < Const(0),
              wrCsN < Const(1),
              If(
                input('wr_req') & spiState.eq(Const(sIdle, width: 3)),
                then: [
                  wrOpL < input('wr_op'),
                  wrAddrL < input('wr_addr'),
                  wrLenL < input('wr_len'),
                  wrByteIdx < Const(0, width: 9),
                  wrErrReg < Const(0), // clear sticky err on a fresh accept
                  wrPollCount < Const(0, width: pollCountWidth),
                  If(
                    // Invalid page-program: len==0, or (addr&0xFF)+len > 256.
                    input('wr_op') &
                        (input('wr_len').eq(Const(0, width: 9)) |
                            (input('wr_addr').getRange(0, 8).zeroExtend(10) +
                                    input('wr_len').zeroExtend(10))
                                .gt(Const(256, width: 10))),
                    then: [
                      // Reject: raise wr_err + pulse wr_done, stay idle, no pins.
                      wrErrReg < Const(1),
                      wrDoneReg < Const(1),
                      wrCsN < Const(1),
                    ],
                    orElse: [
                      // begin WREN
                      wrCsN < Const(0),
                      wrDriveOut < Const(1),
                      wrShift < Const(cmdWren << 24, width: 32),
                      wrBitCount < Const(0, width: 8),
                      wrState < Const(wWren, width: 4),
                    ],
                  ),
                ],
              ),
            ]),

            // WREN: shift 8 bits of 0x06 out on DQ0, MSB first.
            CaseItem(Const(wWren, width: 4), [
              wrClk < ~wrClk,
              If(
                wrClk,
                then: [
                  wrShift < (wrShift << Const(1, width: 32)),
                  wrBitCount < (wrBitCount + Const(1, width: 8)),
                  If(
                    wrBitCount.eq(Const(7, width: 8)),
                    then: [
                      wrCsN < Const(1), // WREN latches on CS rising edge
                      wrClk < Const(0),
                      wrState < Const(wWrenHigh, width: 4),
                    ],
                  ),
                ],
              ),
            ]),

            // WREN_HIGH: one cycle of CS high, then start the command frame.
            CaseItem(Const(wWrenHigh, width: 4), [
              wrCsN < Const(0),
              wrBitCount < Const(0, width: 8),
              wrShift <
                  mux(
                    wrOpL,
                    Const(cmdProgram << 24, width: 32),
                    Const(cmdErase << 24, width: 32),
                  ),
              wrState < Const(wCmd, width: 4),
            ]),

            // CMD: shift 8 bits of the opcode, then load the 24-bit address.
            CaseItem(Const(wCmd, width: 4), [
              wrClk < ~wrClk,
              If(
                wrClk,
                then: [
                  wrShift < (wrShift << Const(1, width: 32)),
                  wrBitCount < (wrBitCount + Const(1, width: 8)),
                  If(
                    wrBitCount.eq(Const(7, width: 8)),
                    then: [
                      wrShift < wrAddrAligned,
                      wrBitCount < Const(0, width: 8),
                      wrState < Const(wAddr, width: 4),
                    ],
                  ),
                ],
              ),
            ]),

            // ADDR: shift 24 address bits. Erase ends the frame here, program
            // continues into the data phase (load the first data byte).
            CaseItem(Const(wAddr, width: 4), [
              wrClk < ~wrClk,
              If(
                wrClk,
                then: [
                  wrShift < (wrShift << Const(1, width: 32)),
                  wrBitCount < (wrBitCount + Const(1, width: 8)),
                  // I3: addressBytes*8-1 (23 for 3-byte, 31 for 4-byte parts).
                  If(
                    wrBitCount.eq(Const(wrAddrWidth - 1, width: 8)),
                    then: [
                      wrBitCount < Const(0, width: 8),
                      If(
                        wrOpL,
                        then: [
                          // page-program: load first data byte (index 0 presented).
                          wrShift < wrDataLoad,
                          wrState < Const(wData, width: 4),
                        ],
                        orElse: [
                          // sector-erase: frame done, raise CS, go poll.
                          wrCsN < Const(1),
                          wrClk < Const(0),
                          wrState < Const(wEnd, width: 4),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),

            // DATA: shift program bytes. After each 8 bits advance the byte
            // index, wr_data_index = wrByteIdx, so the sink already presents the
            // next byte combinationally and we latch it for the next segment.
            CaseItem(Const(wData, width: 4), [
              wrClk < ~wrClk,
              If(
                wrClk,
                then: [
                  wrShift < (wrShift << Const(1, width: 32)),
                  wrBitCount < (wrBitCount + Const(1, width: 8)),
                  If(
                    wrBitCount.eq(Const(7, width: 8)),
                    then: [
                      wrBitCount < Const(0, width: 8),
                      wrByteIdx < (wrByteIdx + Const(1, width: 9)),
                      If(
                        (wrByteIdx + Const(1, width: 9)).gte(wrLenL),
                        then: [
                          // all bytes sent: end the frame.
                          wrCsN < Const(1),
                          wrClk < Const(0),
                          wrState < Const(wEnd, width: 4),
                        ],
                        orElse: [
                          // More bytes: advance the index and take a one-cycle
                          // detour through wDataLoad so the sink (combinational on
                          // wr_data_index = wrByteIdx) presents the NEXT byte before
                          // we latch it. Latching wrDataLoad here would re-load the
                          // current byte (the sink hasn't seen the new index yet).
                          wrState < Const(wDataLoad, width: 4),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),

            // DATA_LOAD: one idle cycle (clk paused, CS held low) to latch the
            // next program byte now that wr_data_index has advanced.
            CaseItem(Const(wDataLoad, width: 4), [
              wrClk < Const(0),
              wrShift < wrDataLoad,
              wrState < Const(wData, width: 4),
            ]),

            // END: CS-high gap after the command frame, then start RDSR poll.
            CaseItem(Const(wEnd, width: 4), [
              wrCsN < Const(1),
              wrState < Const(wStatLow, width: 4),
            ]),

            // STAT_LOW: CS low, load RDSR (0x05). I4: bump the poll watchdog on
            // each poll iteration so a part whose WIP never clears can't pin
            // wr_busy forever.
            CaseItem(Const(wStatLow, width: 4), [
              wrCsN < Const(0),
              wrDriveOut < Const(1),
              wrShift < Const(cmdRdsr << 24, width: 32),
              wrBitCount < Const(0, width: 8),
              wrStatus < Const(0, width: 8),
              wrPollCount < (wrPollCount + Const(1, width: pollCountWidth)),
              wrState < Const(wStatCmd, width: 4),
            ]),

            // STAT_CMD: shift 8 bits of RDSR out, then release DQ0 to read.
            CaseItem(Const(wStatCmd, width: 4), [
              wrClk < ~wrClk,
              If(
                wrClk,
                then: [
                  wrShift < (wrShift << Const(1, width: 32)),
                  wrBitCount < (wrBitCount + Const(1, width: 8)),
                  If(
                    wrBitCount.eq(Const(7, width: 8)),
                    then: [
                      wrBitCount < Const(0, width: 8),
                      wrDriveOut < Const(0), // release: flash drives status now
                      wrState < Const(wStatRead, width: 4),
                    ],
                  ),
                ],
              ),
            ]),

            // STAT_READ: sample 8 status bits MSB-first. Same edge convention
            // as the read FSM: the bit is presented at the spi_clk rising edge
            // and captured here on the falling edge (pre-edge wrClk==1).
            CaseItem(Const(wStatRead, width: 4), [
              wrClk < ~wrClk,
              If(
                wrClk,
                then: [
                  wrStatus <
                      ((wrStatus << Const(1, width: 8)) |
                          statBit.zeroExtend(8)),
                  wrBitCount < (wrBitCount + Const(1, width: 8)),
                  If(
                    wrBitCount.eq(Const(7, width: 8)),
                    then: [
                      wrCsN < Const(1),
                      wrClk < Const(0),
                      wrState < Const(wStatHigh, width: 4),
                    ],
                  ),
                ],
              ),
            ]),

            // STAT_HIGH: inspect WIP (status bit0). Busy -> poll again, UNLESS
            // the watchdog tripped (I4): then abort, raise wr_err, and finish
            // so the caller learns the part is stuck instead of hanging. WIP
            // clear -> done normally.
            CaseItem(Const(wStatHigh, width: 4), [
              wrCsN < Const(1),
              If(
                wrStatus[0], // WIP still set
                then: [
                  If(
                    wrPollCount.gte(wrPollLimit),
                    then: [
                      // Watchdog timeout: give up, flag the error, finish.
                      wrErrReg < Const(1),
                      wrState < Const(wDone, width: 4),
                    ],
                    orElse: [wrState < Const(wStatLow, width: 4)],
                  ),
                ],
                orElse: [wrState < Const(wDone, width: 4)],
              ),
            ]),

            // DONE: pulse wr_done for one cycle, return to idle (drops busy).
            // wr_err (if set by a watchdog timeout) is sticky and survives.
            CaseItem(Const(wDone, width: 4), [
              wrDoneReg < Const(1),
              wrCsN < Const(1),
              wrClk < Const(0),
              wrState < Const(wIdle, width: 4),
            ]),
          ]),
        ],
      ),
    ]);

    // The READ FSM and the WRITE engine share the SPI pins. The write engine
    // owns the bus whenever it is active (wr_busy), otherwise the read FSM
    // does. This is a hard hand-off, never an interleave: a CPU bus request
    // that arrives while wr_busy is high is HELD (stb is gated, the read FSM
    // stays in sIdle and never acks) until the write completes, then it runs
    // normally. In the DFU flash-download use case the maskrom is in download
    // mode so the CPU is not doing XIP, making this simple mux sufficient.
    final pinClk = mux(wrBusy, wrClk, spiClk).named('spi_clk_pin');
    final pinCsN = mux(wrBusy, wrCsN, spiCsN).named('spi_cs_n_pin');
    output('spi_cs_n') <= pinCsN;
    // On ECP5 the clock lives on an internal net feeding USRMCLK (no pad),
    // otherwise it is the spi_clk pad.
    final clkNet = (useUsrmclk || useStartupe2)
        ? Logic(name: 'spi_clk_int')
        : output('spi_clk');
    clkNet <= pinClk;

    // Data-line connection. In the read path the outgoing bit is the MSB of the
    // (bus-wide) shift register shiftReg[busWidth-1] (MSB-first) on DQ0, the
    // write engine drives wrShift[31] on DQ0 only (all writes are standard
    // single-bit). Output-enable / data are muxed by wr_busy. In quad/dual the
    // upper IO bits hold WP#/HOLD# high.
    //
    // Read output-enable is active while ioDir==0 (cmd+addr), write
    // output-enable is wrDriveOut (high for WREN/cmd/addr/data + RDSR opcode,
    // low while the flash drives the status byte back).
    final mosiBit = mux(
      wrBusy,
      wrShift[31],
      shiftReg[busWidth - 1],
    ).named('spi_mosi_bit');
    final driveOut = mux(wrBusy, wrDriveOut, ~ioDir).named('spi_drive_out');
    if (isStd) {
      output('spi_mosi') <= mosiBit;
      // Read samples MISO during read-data, write samples MISO during RDSR.
      spiIoIn <= input('spi_miso');
      statBit <= input('spi_miso');
    } else {
      final ioWidth = config.mode == HarborSpiFlashMode.quad ? 4 : 2;
      final ioOut = config.mode == HarborSpiFlashMode.quad
          ? [Const(1), Const(1), Const(0), mosiBit]
                .swizzle() // {D3,D2,D1,D0}
          : [Const(0), mosiBit].swizzle(); // dual {D1,D0}
      // Drive all lines together (outputs when driveOut, inputs otherwise).
      if (ownPads) {
        // Own the pad: drive the inout `spi_io` through one bus tristate (synth
        // infers the IOBUF) and read it back. driveOut gates the whole bus,
        // matching the split path where oe = driveOut replicated.
        final pad = inOut('spi_io');
        pad <= TriStateBuffer(ioOut, enable: driveOut).out;
        spiIoIn <= pad;
        statBit <= pad[1];
      } else {
        output('spi_io_out') <= ioOut;
        output('spi_io_oe') <= driveOut.replicate(ioWidth);
        spiIoIn <= input('spi_io_in');
        // Status (RDSR) returns on DQ1 in standard-mode framing.
        statBit <= input('spi_io_in')[1];
      }
    }

    // ECP5: drive the config-flash clock through USRMCLK (no I/O pad exists for
    // it). Tristate tied low = always driving.
    if (useUsrmclk) {
      Ecp5Usrmclk(usrmclki: clkNet, usrmclkts: Const(0));
    }

    // Xilinx 7-series: drive the config-flash clock onto the dedicated CCLK
    // ball through STARTUPE2 (no I/O pad exists for it). One per design.
    if (useStartupe2) {
      XilinxStartupe2(usrcclko: clkNet);
    }
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['jedec,spi-nor'],
    reg: BusAddressRange(baseAddress, config.size),
    properties: {
      'spi-max-frequency': config.spiFrequency,
      if (config.mode == HarborSpiFlashMode.quad) 'spi-tx-bus-width': 4,
      if (config.mode == HarborSpiFlashMode.dual) 'spi-tx-bus-width': 2,
    },
    // A `fixed-partitions` map (the standard Linux MTD binding): the FSBL reads
    // it for the firmware offset and Linux exposes each as /dev/mtdN.
    children: config.partitions.isEmpty
        ? const []
        : [
            HarborDeviceTreeChild(
              name: 'partitions',
              properties: const {
                'compatible': 'fixed-partitions',
                '#address-cells': 1,
                '#size-cells': 1,
              },
              children: [
                for (final part in config.partitions)
                  HarborDeviceTreeChild(
                    name: 'partition@${part.offset.toRadixString(16)}',
                    properties: {
                      'reg': [part.offset, part.size],
                      'label': part.label,
                    },
                  ),
              ],
            ),
          ],
  );

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, config.size)],
    properties: {
      'compatible': ['jedec,spi-nor'],
      'spi-max-frequency': config.spiFrequency,
      if (config.mode == HarborSpiFlashMode.quad) 'spi-tx-bus-width': 4,
      if (config.mode == HarborSpiFlashMode.dual) 'spi-tx-bus-width': 2,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'SPIFLASH',
    groupName: 'SPIFLASH',
    description: 'SPI NOR flash controller with XIP',
    baseAddress: baseAddress,
    size: config.size,
  );
}

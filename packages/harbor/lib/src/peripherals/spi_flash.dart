import 'dart:math' show max;

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../arith/fpu_config.dart' show harborStableDefinitionName;
import '../blackbox/ecp5/ecp5.dart';
import '../blackbox/xilinx/xilinx.dart';
import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../memory/mmu_config.dart';
import '../util/pretty_string.dart';
import 'device_register.dart';
import 'spi_flash_cpu_port.dart';

/// SPI flash operating mode.
enum HarborSpiFlashMode {
  /// Standard SPI (1-bit MOSI/MISO).
  standard,

  /// Dual SPI (2-bit I/O).
  dual,

  /// Quad SPI (4-bit I/O, QSPI).
  quad,
}

/// How a flash part sets its quad enable (QE) bit. The bit makes IO2 and IO3
/// work as data pins. A part with the bit clear uses them as WP# and HOLD#,
/// and a quad read returns wrong data.
///
/// The controller reads the JEDEC manufacturer byte (0x9F) before it sends
/// any vendor command, because a command such as 0x35 puts some parts in
/// QPI mode. When the byte is not in the manufacturer list of the config
/// ([HarborSpiFlashConfig.acceptedManufacturers]), it sends nothing else.
enum HarborSpiFlashQuadEnable {
  /// The part needs no QE bit. A quad output read works with the power-up
  /// state. Micron N25Q128 data sheet, section 9.1.6 (Quad Output Fast Read)
  /// in the extended SPI protocol, which has no QE bit.
  none(
    readCommand: 0,
    writeCommand: 0,
    bit: 0,
    writeBytes: 0,
    writeMaxMs: 0,
    keepMask: 0xff,
    defaultManufacturers: [],
    clearsErrors: false,
  ),

  /// QE is bit 6 of status register 1. RDSR 0x05 reads it. WREN then WRSR 0x01
  /// with one data byte writes it. ISSI IS25LP128 data sheet, section 6.1
  /// (Table 6.2) and section 8.16. Macronix parts use the same method. The
  /// BP and SRWD bits keep the value that the read returned. Manufacturer ID
  /// 0x9D is ISSI (data sheet Table 8.3) and 0xC2 is Macronix (JEDEC JEP106).
  sr1Bit6(
    readCommand: 0x05,
    writeCommand: 0x01,
    bit: 6,
    writeBytes: 1,
    writeMaxMs: 15,
    keepMask: 0xff,
    defaultManufacturers: [0x9d, 0xc2],
    clearsErrors: false,
  ),

  /// QE is bit 1 of status register 2. Command 0x35 reads it. WREN then
  /// command 0x31 with one data byte writes it. Winbond W25Q128JV data sheet,
  /// section 7.1.4 (QE is S9), section 8.2.4 and section 8.2.5. The write
  /// sends 0 for the OTP lock bits LB1 to LB3 (bits 3 to 5) and for SRL
  /// (bit 0), so it never locks them. The write time is 30 ms, the GigaDevice
  /// GD25Q128E tW maximum. Winbond W25Q128JV is 15 ms. GigaDevice GD25Q128E
  /// Rev 1.4 uses the same commands and bits (sections 7.3 and 7.4, Table 7).
  sr2Bit1(
    readCommand: 0x35,
    writeCommand: 0x31,
    bit: 1,
    writeBytes: 1,
    writeMaxMs: 30,
    keepMask: 0xc6,
    defaultManufacturers: [0xef],
    clearsErrors: false,
  ),

  /// QE is the QUAD bit, bit 1 of configuration register 1. RDCR 0x35 reads
  /// it. WREN then WRR 0x01 with two data bytes, status register 1 and then
  /// configuration register 1, writes it. Infineon S25FL128S and S25FL256S
  /// data sheet, section 7.5.2 (Table 24), section 9.3.3 and section 9.3.7.
  /// The write sends 0 for the OTP bits TBPARM (bit 2), BPNV (bit 3) and
  /// TBPROT (bit 5). A WRR that fails sets P_ERR and keeps WIP at 1 until a
  /// CLSR (sections 7.5.1 and 9.1.3.1), so a failed sequence sends CLSR 0x30
  /// and then WRDI 0x04. Manufacturer ID 0x01 is Spansion (section 9.2.2).
  cr1Bit1(
    readCommand: 0x35,
    writeCommand: 0x01,
    bit: 1,
    writeBytes: 2,
    writeMaxMs: 500,
    keepMask: 0xd3,
    defaultManufacturers: [0x01],
    clearsErrors: true,
  );

  const HarborSpiFlashQuadEnable({
    required this.readCommand,
    required this.writeCommand,
    required this.bit,
    required this.writeBytes,
    required this.writeMaxMs,
    required this.keepMask,
    required this.defaultManufacturers,
    required this.clearsErrors,
  });

  /// Command that reads the register that holds QE.
  final int readCommand;

  /// Command that writes the register that holds QE.
  final int writeCommand;

  /// Bit of the register that holds QE.
  final int bit;

  /// Data bytes that follow [writeCommand]. Two means status register 1 and
  /// then the register that holds QE.
  final int writeBytes;

  /// Data sheet maximum in ms of the register write (tW). The startup
  /// sequence ends with an error when the part stays busy for longer than
  /// the erase timeout, so that timeout must not be below this value.
  final int writeMaxMs;

  /// Bits of the QE register that the write keeps as read. The other bits
  /// are OTP or lock bits, and the write sends 0 for them.
  final int keepMask;

  /// JEDEC manufacturer bytes that a config accepts when it lists none.
  final List<int> defaultManufacturers;

  /// True when a failed write of the register leaves the part busy until a
  /// CLSR, so the controller sends CLSR and WRDI before it falls back.
  final bool clearsErrors;
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

  /// Marks the partition `read-only` in the node an OS driver binds to, so
  /// the OS refuses to write it. The default is false: Harbor never sets it.
  final bool osReadOnly;

  const HarborFlashPartition({
    required this.label,
    required this.offset,
    required this.size,
    this.osReadOnly = false,
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

  /// Longest time in ms that a 4 KiB sector erase may keep the part busy. The
  /// write engine ends the op with an error after this time. Set it above
  /// the data sheet maximum of the part.
  final int eraseTimeoutMs;

  /// Longest time in ms that a page program may keep the part busy.
  final int programTimeoutMs;

  /// Data sheet maximum in ms of one sector erase, or null when the preset
  /// has none. A timeout below it is rejected at build time.
  final int? eraseMaxMs;

  /// Data sheet maximum in ms of a page program, or null when the preset has
  /// none.
  final int? programMaxMs;

  /// Time in ns that CS# must stay high between two frames (tSHSL). The
  /// controller holds CS# high for this long, rounded up to whole clocks.
  final int tShslNs;

  /// JEDEC manufacturer bytes that the startup sequence accepts. An empty
  /// list means the default of [quadEnable]. A part with another byte gets
  /// no vendor command.
  final List<int> manufacturerIds;

  /// The full JEDEC ID (manufacturer, type and capacity) of the part of a
  /// preset, or null. The controller checks the manufacturer byte only.
  final int? jedecId;

  /// The manufacturer bytes that the startup sequence accepts.
  List<int> get acceptedManufacturers => manufacturerIds.isEmpty
      ? quadEnable.defaultManufacturers
      : manufacturerIds;

  /// How the controller sets the QE bit of the part at startup. It runs in
  /// quad mode only. Dual reads need no QE bit.
  final HarborSpiFlashQuadEnable quadEnable;

  /// Read command that the controller uses when the QE bit cannot be set. It
  /// is fast read, with 8 dummy cycles and the data on one line.
  int get fallbackReadCommand => addressBytes == 4 ? 0x0c : 0x0b;

  /// Dummy cycles of [fallbackReadCommand].
  static const fallbackDummyCycles = 8;

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
    this.eraseTimeoutMs = 3000,
    this.programTimeoutMs = 50,
    this.eraseMaxMs,
    this.programMaxMs,
    this.tShslNs = 50,
    this.quadEnable = HarborSpiFlashQuadEnable.none,
    this.manufacturerIds = const [],
    this.jedecId,
  });

  /// W25Q128: common 16MB SPI flash (e.g., on iCEBreaker, OrangeCrab).
  const HarborSpiFlashConfig.w25q128({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
    this.readAheadWords = 1,
    this.partitions = const [],
    this.eraseTimeoutMs = 3000,
    this.programTimeoutMs = 50,
    this.tShslNs = 50,
  }) : quadEnable = HarborSpiFlashQuadEnable.sr2Bit1,
       manufacturerIds = const [0xef],
       jedecId = 0xef4018,
       eraseMaxMs = 400,
       programMaxMs = 3,
       size = 16 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6B, // Quad Output Fast Read
       addressBytes = 3,
       dummyCycles = 8;

  /// IS25LP128: common 16MB SPI flash (e.g., on Arty boards). The limits are
  /// from the ISSI IS25LP032/064/128 data sheet Rev. D, AC characteristics:
  /// sector erase 300 ms and page program 1 ms. Quad output read 0x6B with 8
  /// dummy cycles is in the IS25LP128/064 data sheet Rev. K1, table of read
  /// dummy cycles.
  const HarborSpiFlashConfig.is25lp128({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
    this.readAheadWords = 1,
    this.partitions = const [],
    this.eraseTimeoutMs = 3000,
    this.programTimeoutMs = 50,
    this.tShslNs = 50,
  }) : quadEnable = HarborSpiFlashQuadEnable.sr1Bit6,
       manufacturerIds = const [0x9d],
       jedecId = 0x9d6018,
       eraseMaxMs = 300,
       programMaxMs = 1,
       size = 16 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6B,
       addressBytes = 3,
       dummyCycles = 8;

  /// N25Q128: 16MB SPI flash (e.g., on KC705 and AX7203). The quad output
  /// fast read takes 8 dummy cycles with the power-up configuration.
  const HarborSpiFlashConfig.n25q128({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
    this.readAheadWords = 1,
    this.partitions = const [],
    this.eraseTimeoutMs = 3000,
    this.programTimeoutMs = 50,
    this.tShslNs = 50,
  }) : quadEnable = HarborSpiFlashQuadEnable.none,
       manufacturerIds = const [],
       jedecId = 0x20ba18,
       eraseMaxMs = 800,
       programMaxMs = 5,
       size = 16 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6B,
       addressBytes = 3,
       dummyCycles = 8;

  /// S25FL256: 32MB SPI flash. The 4 KiB sector erase limit of 650 ms is from
  /// the S25FL128S/S25FL256S data sheet Rev. *Q, Table 49.
  const HarborSpiFlashConfig.s25fl256({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
    this.readAheadWords = 1,
    this.partitions = const [],
    this.eraseTimeoutMs = 3000,
    this.programTimeoutMs = 50,
    this.tShslNs = 50,
  }) : quadEnable = HarborSpiFlashQuadEnable.cr1Bit1,
       manufacturerIds = const [0x01],
       jedecId = 0x010219,
       eraseMaxMs = 650,
       programMaxMs = null,
       size = 32 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6C, // 4-byte addr quad read
       addressBytes = 4,
       dummyCycles = 8;

  /// S25FL128S: 16MB Spansion/Cypress SPI flash (e.g., on Arty S7-50, part
  /// S25FL128SAGMFIR01), JEDEC ID 0x012018. The model digits 01 are uniform
  /// 256 KiB sectors with a 512 byte page buffer, so the 4 KiB erase 0x20 is
  /// not available and the CPU write port cannot be built. The limits are
  /// from the S25FL128S/S25FL256S data sheet Rev. *Q: sector erase 2600 ms
  /// and page program 750 us (Table 49). Quad output read 0x6B has 8 dummy
  /// cycles at the default latency code up to 80 MHz (Table 27).
  const HarborSpiFlashConfig.s25fl128s({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
    this.readAheadWords = 1,
    this.partitions = const [],
    this.eraseTimeoutMs = 3000,
    this.programTimeoutMs = 50,
    this.tShslNs = 50,
  }) : quadEnable = HarborSpiFlashQuadEnable.cr1Bit1,
       manufacturerIds = const [0x01],
       jedecId = 0x012018,
       eraseMaxMs = 2600,
       programMaxMs = 1,
       size = 16 * 1024 * 1024,
       pageSize = 512,
       sectorSize = 256 * 1024,
       readCommand = 0x6B,
       addressBytes = 3,
       dummyCycles = 8;

  /// GD25Q128: 16MB GigaDevice SPI flash (e.g., on OrangeCrab r0.2), JEDEC
  /// ID 0xC84018. The commands and bits come from the GD25Q128E data sheet
  /// Rev 1.4: QE is S9 of status register 2, read with 0x35 and written with
  /// 0x31 (sections 7.3 and 7.4, Table 7), sector erase 300 ms, page program
  /// 2.4 ms and register write 30 ms (AC table), quad output read 0x6B with a
  /// dummy byte (section 7.9). The Winbond W25Q128JV uses the same commands
  /// and bits, and some boards carry it, so manufacturer 0xEF is accepted too.
  const HarborSpiFlashConfig.gd25q128({
    this.spiFrequency = 50000000,
    this.mode = HarborSpiFlashMode.quad,
    this.readAheadWords = 1,
    this.partitions = const [],
    this.eraseTimeoutMs = 3000,
    this.programTimeoutMs = 50,
    this.tShslNs = 50,
  }) : quadEnable = HarborSpiFlashQuadEnable.sr2Bit1,
       manufacturerIds = const [0xc8, 0xef],
       jedecId = 0xc84018,
       eraseMaxMs = 300,
       programMaxMs = 3,
       size = 16 * 1024 * 1024,
       pageSize = 256,
       sectorSize = 4096,
       readCommand = 0x6B,
       addressBytes = 3,
       dummyCycles = 8;

  /// This config with another partition list.
  HarborSpiFlashConfig copyWith({
    required List<HarborFlashPartition> partitions,
  }) => HarborSpiFlashConfig(
    size: size,
    spiFrequency: spiFrequency,
    mode: mode,
    pageSize: pageSize,
    sectorSize: sectorSize,
    readCommand: readCommand,
    addressBytes: addressBytes,
    dummyCycles: dummyCycles,
    readAheadWords: readAheadWords,
    partitions: partitions,
    eraseTimeoutMs: eraseTimeoutMs,
    programTimeoutMs: programTimeoutMs,
    eraseMaxMs: eraseMaxMs,
    programMaxMs: programMaxMs,
    tShslNs: tShslNs,
    quadEnable: quadEnable,
    manufacturerIds: manufacturerIds,
    jedecId: jedecId,
  );

  /// Most partitions a flash can have. The write port lock mask has one bit
  /// for each.
  static const maxPartitions = 32;

  /// Throws an [ArgumentError] when [partitions] cannot describe this flash:
  /// more than [maxPartitions], an empty or repeated label, a partition that
  /// is not sector aligned, empty or outside the flash, or two that overlap.
  void validatePartitions() {
    if (eraseTimeoutMs < 1) {
      throw ArgumentError.value(
        eraseTimeoutMs,
        'eraseTimeoutMs',
        'must be >= 1',
      );
    }
    if (tShslNs < 0) {
      throw ArgumentError.value(tShslNs, 'tShslNs', 'must be >= 0');
    }
    final eraseMax = eraseMaxMs;
    if (eraseMax != null && eraseTimeoutMs < eraseMax) {
      throw ArgumentError.value(
        eraseTimeoutMs,
        'eraseTimeoutMs',
        'is below the data sheet maximum of $eraseMax ms',
      );
    }
    if (mode == HarborSpiFlashMode.quad &&
        quadEnable != HarborSpiFlashQuadEnable.none &&
        eraseTimeoutMs < quadEnable.writeMaxMs) {
      throw ArgumentError.value(
        eraseTimeoutMs,
        'eraseTimeoutMs',
        'is below the ${quadEnable.writeMaxMs} ms register write time of '
            '${quadEnable.name}',
      );
    }
    final programMax = programMaxMs;
    if (programMax != null && programTimeoutMs < programMax) {
      throw ArgumentError.value(
        programTimeoutMs,
        'programTimeoutMs',
        'is below the data sheet maximum of $programMax ms',
      );
    }
    if (programTimeoutMs < 1) {
      throw ArgumentError.value(
        programTimeoutMs,
        'programTimeoutMs',
        'must be >= 1',
      );
    }
    if (partitions.length > maxPartitions) {
      throw ArgumentError.value(
        partitions.length,
        'partitions',
        'at most $maxPartitions partitions',
      );
    }
    final labels = <String>{};
    for (final (i, a) in partitions.indexed) {
      void bad(String why) =>
          throw ArgumentError.value(a, 'partitions[$i]', why);
      if (a.label.isEmpty) bad('label is empty');
      if (!labels.add(a.label)) bad('label is used twice');
      if (a.size <= 0) bad('size must be above 0');
      if (a.offset < 0 || a.offset + a.size > size) bad('outside the flash');
      if (a.offset % sectorSize != 0 || a.size % sectorSize != 0) {
        bad('offset and size must be multiples of $sectorSize');
      }
      for (final b in partitions.take(i)) {
        if (a.offset < b.offset + b.size && b.offset < a.offset + a.size) {
          bad('overlaps ${b.label}');
        }
      }
    }
  }

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
    buf.writeln('${c}quadEnable: ${quadEnable.name},');
    buf.write('$p)');
    return buf.toString();
  }
}

/// Drives the quad or dual SPI pad: IO0 and IO1 follow [driveEnable], IO2
/// and IO3 follow [holdEnable]. A bit with a low enable floats.
///
/// A slice of an inout pad written by a tristate in ROHD emits a parenthesised
/// assign that yosys rejects, so the SystemVerilog is hand-written here.
class HarborQuadPadDriver extends Module with SystemVerilog {
  final int width;

  HarborQuadPadDriver({
    required Logic data,
    required Logic driveEnable,
    required Logic pad,
    Logic? holdEnable,
  }) : width = data.width,
       super(
         name: 'spi_pad_driver',
         definitionName: 'HarborQuadPadDriver_${data.width}',
         reserveDefinitionName: true,
       ) {
    if (width != 2 && width != 4) {
      throw ArgumentError.value(width, 'data', 'must be 2 or 4 bits wide');
    }
    if ((width == 4) != (holdEnable != null)) {
      throw ArgumentError.value(
        holdEnable,
        'holdEnable',
        'is required for 4 bits and not allowed for 2 bits',
      );
    }
    data = addInput('d', data, width: width);
    driveEnable = addInput('oe_lo', driveEnable);
    final hold = holdEnable == null ? null : addInput('oe_hi', holdEnable);
    final padNet = addInOut('pad', pad, width: width);
    padNet.getRange(0, 2) <=
        TriStateBuffer(data.getRange(0, 2), enable: driveEnable).out;
    if (hold != null) {
      padNet.getRange(2, 4) <=
          TriStateBuffer(data.getRange(2, 4), enable: hold).out;
    }
  }

  @override
  String? definitionVerilog(String definitionType) {
    final hi = width == 4 ? '  input logic oe_hi,\n' : '';
    final hiAssign = width == 4
        ? "  assign pad[3:2] = oe_hi ? d[3:2] : 2'bzz;\n"
        : '';
    return '''
module $definitionType (
  input logic [${width - 1}:0] d,
  input logic oe_lo,
$hi  inout wire [${width - 1}:0] pad
);
  assign pad[1:0] = oe_lo ? d[1:0] : 2'bzz;
${hiAssign}endmodule''';
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
///
/// In quad mode with a [HarborSpiFlashConfig.quadEnable] method, the
/// controller first reads the JEDEC manufacturer byte and checks it against
/// the method. Then it reads the register that holds the QE bit twice. When
/// the two reads differ, or the manufacturer does not match, it sends no
/// write. When the bit is clear, it writes the bit and reads it back. It
/// holds bus reads and writes until the sequence ends. When the part does not
/// set the bit, `qe_err` and `qe_fallback` stay high and every read uses one
/// data line with fast read (0x0B, or 0x0C with 4-byte addresses). The
/// status ports are `qe_done`, `qe_set`, `qe_err`, `qe_fallback` and
/// `qe_id_err`, which is high when the manufacturer did not match.
///
/// The controller drives IO2 and IO3 high outside the dummy and data phases of
/// a quad read, and for the whole fallback read. In standard mode, and in
/// dual mode, it does not drive them. The board must pull IO2 and IO3 up for
/// those modes and for the release phase.
///
/// The write command port (`wr_req`, `wr_op`, `wr_addr`, `wr_len`,
/// `wr_data`) belongs to the DFU sink. The caller keeps `wr_req` high until
/// `wr_busy` rises, because the engine takes a request only when the read
/// FSM is idle and CS# has been high long enough.
class HarborSpiFlashController extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborSecondarySlaveProvider {
  /// Clocks that CS# stays high between frames: [tShslNs] rounded up to whole
  /// clocks of [clockHz], at least 1.
  static int csHighClocks(int tShslNs, int clockHz) =>
      max(1, (tShslNs * clockHz + 999999999) ~/ 1000000000);

  /// True when the write engine can program [config]. The engine sends the
  /// 4 KiB erase 0x20 and the 3-byte page program 0x02 only.
  static bool supportsWriteEngine(HarborSpiFlashConfig config) =>
      config.sectorSize == 4096 && config.addressBytes == 3;

  /// Full SCK cycles sent with CS# high after reset. The first STARTUPE2
  /// USRCCLKO edges after configuration do not reach the pin (UG470).
  static const startupClocks = 8;

  /// HarborFlash configuration.
  final HarborSpiFlashConfig config;

  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Bus slave port (CPU side).
  late final BusSlavePort bus;

  /// Width of the bus in bytes.
  final int busBytes;

  /// Base address of the CPU write port window, or null when the build has no
  /// CPU write port. The port is a [HarborSpiFlashCpuPort] on the bus slave
  /// port `cpu_bus`.
  final int? cpuPortBase;

  /// Register slave port of the CPU write port. Only built when
  /// [cpuPortBase] is set.
  BusSlavePort? cpuPortBus;

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
    // Frequency in Hz of the `clk` input. The write engine counts these
    // clocks to time out a busy part, and holds CS# high for tSHSL. The SPI
    // clock is this clock over 2.
    required int clockHz,
    HarborFabricKind fabricKind = HarborFabricKind.wishbone,
    bool crossFabricClock = false,
    this.cpuPortBase,
    String? name,
  }) : busBytes = (busDataWidth ?? 32) ~/ 8,
       super(
         harborStableDefinitionName('HarborSpiFlashController', [
           ...BusSlavePort.definitionNameParts(
             kind: fabricKind,
             addressWidth: busAddressWidth ?? config.size.bitLength,
             dataWidth: busDataWidth ?? 32,
             cross: crossFabricClock,
           ),
           config.mode.name,
           'ab${config.addressBytes}',
           'dc${config.dummyCycles}',
           'rc0x${config.readCommand.toRadixString(16)}',
           'ra${config.readAheadWords}',
           'sz${config.size}',
           'hz$clockHz',
           'te${config.eraseTimeoutMs}',
           'tp${config.programTimeoutMs}',
           if (useUsrmclk) 'usrmclk',
           if (useStartupe2) 'startupe2',
           if (ownPads) 'ownpads',
           'sh${config.tShslNs}',
           if (config.mode == HarborSpiFlashMode.quad &&
               config.quadEnable != HarborSpiFlashQuadEnable.none)
             'qe${config.quadEnable.name}'
                 '_${config.acceptedManufacturers.map((m) => m.toRadixString(16)).join('_')}',
           if (cpuPortBase != null) 'cpuport',
         ]),
         name: name ?? 'spi_flash',
       ) {
    final hz = clockHz;
    if (hz < 1) throw ArgumentError.value(hz, 'clockHz', 'must be >= 1');
    config.validatePartitions();
    final portBase = cpuPortBase;
    if (portBase != null && !supportsWriteEngine(config)) {
      throw ArgumentError.value(
        config,
        'config',
        'the write engine needs 4 KiB sectors and 3-byte addresses',
      );
    }
    if (portBase != null) {
      const window = HarborSpiFlashCpuPort.windowBytes;
      if (portBase % window != 0) {
        throw ArgumentError.value(
          portBase,
          'cpuPortBase',
          'must be aligned to $window bytes',
        );
      }
      if (portBase < baseAddress + config.size &&
          baseAddress < portBase + window) {
        throw ArgumentError.value(
          portBase,
          'cpuPortBase',
          'must be outside the XIP window',
        );
      }
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
    final fabricClock = BusSlavePort.fabricClockInputs(
      this,
      cross: crossFabricClock,
    );
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: fabricKind,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: addrWidth,
      dataWidth: busDataWidth ?? 32,
      fabricClock: fabricClock,
    );
    if (portBase != null) {
      cpuPortBus = BusSlavePort.create(
        module: this,
        name: 'cpu_bus',
        kind: fabricKind,
        clk: input('clk'),
        reset: input('reset'),
        addressWidth: max(addrWidth, 12),
        dataWidth: busDataWidth ?? 32,
        fabricClock: fabricClock,
      );
    }

    // Write and erase command interface for the DFU flash sink, separate
    // from the CPU bus. The engine presents the next index on wr_data_index
    // and the sink returns that byte on wr_data in the same cycle. Writes
    // always use single-bit mode on DQ0, even when reads use quad mode.
    // The write address width follows config.addressBytes, so a 4-byte part
    // programs the correct sector. Other address sizes fail at construction.
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

    // Quad enable startup status. qe_done rises when the startup sequence
    // ends, or at once when the part needs none. qe_set shows that the QE bit
    // of the part was read as set. qe_err stays high after the sequence could
    // not set the bit, and qe_fallback is the same state: reads use one data
    // line. qe_id_err shows that the JEDEC manufacturer byte did not match
    // the method, so the controller sent no vendor command.
    addOutput('qe_done');
    addOutput('qe_set');
    addOutput('qe_err');
    addOutput('qe_fallback');
    addOutput('qe_id_err');

    final clk = input('clk');
    final reset = bus.reset;
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
    final wrBusy = Logic(name: 'wr_busy_int');
    final qe = config.quadEnable;
    final qeActive =
        config.mode == HarborSpiFlashMode.quad &&
        qe != HarborSpiFlashQuadEnable.none;
    final qeDone = Logic(name: 'qe_done_reg');
    final qeSet = Logic(name: 'qe_set_reg');
    final qeErr = Logic(name: 'qe_err_reg');
    final qeIdErr = Logic(name: 'qe_id_err_reg');
    final qeRun = Logic(name: 'qe_run');
    // A bus read waits until the startup sequence ends.
    final stb = (bus.stb & ~wrBusy & qeDone).named('rd_stb_gated');
    // The CPU port request, driven where the port is built below. The read
    // FSM starts no flash command in the cycle the write engine starts, so
    // the engine never takes the pins in the middle of a read frame.
    final cpuBus = cpuPortBus;
    final cpuReq = cpuBus == null ? null : Logic(name: 'cpu_port_req');

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
    final ioRel = Logic(name: 'io_dir'); // 0=output, 1=input
    // IO2 and IO3 are released only in a quad data phase. The fallback read
    // keeps them driven high.
    final ioDir = qeActive ? (ioRel & ~qeErr) : ioRel;

    final wrStart =
        (cpuReq == null ? input('wr_req') : input('wr_req') | cpuReq) &
        spiState.eq(Const(0, width: 3)) &
        qeDone;

    // CS# stays high for at least tSHSL between two frames. csCnt counts the
    // clocks the CS# pin has been high. A frame may start in a cycle where
    // CS# is high and the count is csHigh - 1 or more, so CS# is high for
    // csHigh clocks including that one.
    final csHigh = csHighClocks(config.tShslNs, hz);
    final csWidth = csHigh.bitLength;
    final csCnt = csHigh > 1
        ? Logic(name: 'cs_high_cnt', width: csWidth)
        : null;
    final csOk = csCnt == null
        ? Const(1)
        : csCnt.gte(Const(csHigh - 1, width: csWidth));

    // States
    const sIdle = 0;
    const sSendCmd = 1;
    const sSendAddr = 2;
    const sDummy = 3;
    const sReadData = 4;
    const sDone = 5;
    const sStartup = 6;

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
    final nextShiftWide =
        ((shiftReg << Const(bitsPerCycle, width: 32)) |
        spiIoIn.zeroExtend(busWidth));
    // The fallback read puts the data on IO1 one bit at a time.
    final nextShift =
        (qeActive
                ? mux(
                    qeErr,
                    (shiftReg << Const(1, width: 32)) |
                        spiIoIn.getRange(1, 2).zeroExtend(busWidth),
                    nextShiftWide,
                  )
                : nextShiftWide)
            .named('next_shift');
    final Logic dummyLast = qeActive
        ? mux<Logic>(
            qeErr,
            Const(HarborSpiFlashConfig.fallbackDummyCycles - 1, width: 8),
            Const(config.dummyCycles - 1, width: 8),
          )
        : Const(config.dummyCycles - 1, width: 8);
    final Logic dataLast = qeActive
        ? mux<Logic>(
            qeErr,
            Const(busWidth - 1, width: 8),
            Const(dataClocks - 1, width: 8),
          )
        : Const(dataClocks - 1, width: 8);
    // Byte-reverse a busWidth word: the flash streamed bytes MSB-first (lowest
    // address in the high byte), so reverse to the little-endian bus word.
    Logic byteSwap(Logic w) => [
      for (var i = 0; i < busBytes; i++) w.getRange(i * 8, i * 8 + 8),
    ].concat();

    Sequential(clk, [
      If(
        reset,
        then: [
          spiCsN < Const(1),
          spiClk < Const(0),
          shiftReg < Const(0, width: busWidth),
          bitCount < Const(0, width: 8),
          spiState < Const(startupClocks > 0 ? sStartup : sIdle, width: 3),
          ioRel < Const(0),
          ack < Const(0),
          datOut < Const(0, width: busWidth),
          // The line tag and words are read only with lineValid.
          lineValid < Const(0),
          wordIdx < Const(0, width: 8),
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
                          If(
                            ~wrStart & csOk,
                            then: [
                              spiCsN < Const(0),
                              // Command left-aligned to bit busWidth-1 (shifted
                              // out MSB-first, 1-bit on DQ0).
                              shiftReg <
                                  (qeActive
                                      ? mux<Logic>(
                                          qeErr,
                                          Const(
                                            config.fallbackReadCommand <<
                                                (busWidth - 8),
                                            width: busWidth,
                                          ),
                                          Const(
                                            config.readCommand <<
                                                (busWidth - 8),
                                            width: busWidth,
                                          ),
                                        )
                                      : Const(
                                          config.readCommand << (busWidth - 8),
                                          width: busWidth,
                                        )),
                              bitCount < Const(0, width: 8),
                              wordIdx < Const(0, width: 8),
                              reqAddr < addr32,
                              orphan < Const(0),
                              ioRel < Const(0), // output (drive DQ0)
                              spiState < Const(sSendCmd, width: 3),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ]),

                // STARTUP: clock SCK with CS# high. After configuration, the
                // first USRCCLKO edges of STARTUPE2 do not reach the pin.
                CaseItem(Const(sStartup, width: 3), [
                  spiClk < ~spiClk,
                  If(
                    spiClk,
                    then: [
                      bitCount < (bitCount + Const(1, width: 8)),
                      If(
                        bitCount.eq(Const(startupClocks - 1, width: 8)),
                        then: [
                          bitCount < Const(0, width: 8),
                          spiState < Const(sIdle, width: 3),
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
                          ioRel < Const(1), // release IO: the flash drives now
                          shiftReg < Const(0, width: busWidth),
                          spiState <
                              (qeActive
                                  ? mux<Logic>(
                                      qeErr,
                                      Const(sDummy, width: 3),
                                      Const(
                                        config.dummyCycles > 0
                                            ? sDummy
                                            : sReadData,
                                        width: 3,
                                      ),
                                    )
                                  : Const(
                                      config.dummyCycles > 0
                                          ? sDummy
                                          : sReadData,
                                      width: 3,
                                    )),
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
                        bitCount.eq(dummyLast),
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
                        bitCount.eq(dataLast),
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
                  ioRel < Const(0),
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
    // Startup sequence states: a WREN frame start and the register write.
    const wQWren = 1;
    const wQWrite = 4;

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
    // Count clocks from the start of the RDSR poll phase. A part that is
    // still busy when the count reaches the limit of the op ends the op with
    // an error, so a dead part cannot hold wr_busy for ever.
    int limitOf(int ms) => max(1, ms * hz ~/ 1000);
    final eraseLimit = limitOf(config.eraseTimeoutMs);
    final programLimit = limitOf(config.programTimeoutMs);
    // The count can pass the limit by one poll, which is 34 clocks. The startup
    // sequence counts from its first frame, so the margin also holds the
    // frames before the poll.
    final timerWidth = (max(eraseLimit, programLimit) + 512).bitLength;
    final wrTimer = Logic(name: 'wr_timer', width: timerWidth);
    // Startup quad enable sequence. Each step is one frame on the pins: read
    // the manufacturer byte, read status register 1 twice (two byte write
    // only), read the QE register twice, write (a WREN frame comes first),
    // poll WIP, read back. The last two steps clear a failed write.
    final qeSteps = !qeActive
        ? const <String>[]
        : [
            'id',
            if (qe.writeBytes == 2) ...['rdSr1', 'rdSr1b'],
            'rdQe',
            'rdQe2',
            'write',
            'poll',
            'verify',
            if (qe.clearsErrors) ...['clsr', 'wrdi'],
          ];
    final qeStep = Logic(name: 'qe_step', width: 4);
    int qeIdx(String name) => qeSteps.indexOf(name);
    Logic qeAt(String name) => qeStep.eq(Const(qeIdx(name), width: 4));
    final qeSr1 = Logic(name: 'qe_sr1', width: 8);
    final qePrev = Logic(name: 'qe_prev', width: 8);
    final qeMask = 1 << qe.bit;
    final wrTimeLimit = mux<Logic>(
      wrOpL,
      Const(programLimit, width: timerWidth),
      Const(eraseLimit, width: timerWidth),
    );
    final inPoll = [
      for (final st in [wEnd, wStatLow, wStatCmd, wStatRead, wStatHigh])
        wrState.eq(Const(st, width: 4)),
    ].reduce((a, b) => a | b);

    // wr_busy is high in every state except idle. The sink does not see it
    // while the startup sequence runs, so it does not take it for the end of
    // its own request.
    wrBusy <= ~wrState.eq(Const(wIdle, width: 4));
    output('wr_busy') <= wrBusy & ~qeRun;
    output('qe_done') <= qeDone;
    output('qe_set') <= qeSet;
    output('qe_err') <= qeErr;
    output('qe_fallback') <= qeErr;
    output('qe_id_err') <= qeIdErr;
    if (!qeActive) {
      qeDone <= Const(1);
      qeSet <= Const(0);
      qeErr <= Const(0);
      qeRun <= Const(0);
      qeIdErr <= Const(0);
    }
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
    // The CPU port shares the engine with the DFU sink. A DFU request wins
    // when both wait, and an op that has started always finishes.
    var reqOp = input('wr_op');
    var reqAddr0 = input('wr_addr');
    var reqLen = input('wr_len');
    var engData = input('wr_data');
    if (cpuBus != null && cpuReq != null) {
      final dfuReq = input('wr_req');
      final port = HarborSpiFlashCpuPort.build(
        bus: cpuBus,
        clk: clk,
        flashSize: config.size,
        partitions: [
          for (final part in config.partitions)
            (offset: part.offset, size: part.size),
        ],
        addrWidth: wrAddrWidth,
        take: (wrStart & csOk & ~dfuReq & ~wrBusy).named('take_cpu'),
        engDone: wrDoneReg,
        engErr: wrErrReg,
        engIdx: wrByteIdx,
        qeDone: qeDone,
        qeSet: qeSet,
        qeErr: qeErr,
        qeIdErr: qeIdErr,
      );
      cpuReq <= port.req;
      reqOp = mux(dfuReq, reqOp, port.op);
      reqAddr0 = mux(dfuReq, reqAddr0, port.addr);
      reqLen = mux(dfuReq, reqLen, port.len);
      engData = mux(port.run, port.data, engData);
    }
    final opFrame = mux<Logic>(
      wrOpL,
      Const(cmdProgram << 24, width: 32),
      Const(cmdErase << 24, width: 32),
    );
    // The register write frame. The bits in keepMask keep the value that the
    // read returned, the OTP and lock bits are sent as 0, and QE is 1.
    final qeValue =
        ((wrStatus & Const(qe.keepMask, width: 8)) | Const(qeMask, width: 8))
            .zeroExtend(32);
    final Logic qeFrame = !qeActive
        ? Const(0, width: 32)
        : qe.writeBytes == 2
        ? (Const(qe.writeCommand << 24, width: 32) |
              (qeSr1.zeroExtend(32) << Const(16, width: 32)) |
              (qeValue << Const(8, width: 32)))
        : (Const(qe.writeCommand << 24, width: 32) |
              (qeValue << Const(16, width: 32)));
    // The read command of the current step: 0x9F for the manufacturer, 0x05
    // for status register 1 and the poll, the QE register command for the
    // others.
    Logic qeReadCmd = Const(qe.readCommand, width: 8);
    // The command of the one byte frame that comes before the write: WREN, or
    // CLSR and WRDI after a failed write.
    Logic qeCmd8 = Const(cmdWren, width: 8);
    if (qeActive) {
      for (final st in qeSteps) {
        final cmd = switch (st) {
          'id' => 0x9f,
          'rdSr1' || 'rdSr1b' || 'poll' => cmdRdsr,
          _ => null,
        };
        if (cmd != null && cmd != qe.readCommand) {
          qeReadCmd = mux<Logic>(qeAt(st), Const(cmd, width: 8), qeReadCmd);
        }
      }
      if (qe.clearsErrors) {
        qeCmd8 = mux<Logic>(
          qeAt('clsr'),
          Const(0x30, width: 8),
          mux<Logic>(qeAt('wrdi'), Const(0x04, width: 8), qeCmd8),
        );
      }
    }
    List<Conditional> qeFinish({required bool ok}) => [
      qeDone < Const(1),
      qeRun < Const(0),
      if (ok) qeSet < Const(1) else qeErr < Const(1),
      wrState < Const(wIdle, width: 4),
    ];
    // A failure after the write. A part that stays busy after a failed write
    // gets CLSR and WRDI first, so that it accepts the fallback read.
    List<Conditional> qeFailAfterWrite() => qe.clearsErrors
        ? <Conditional>[
            qeErr < Const(1),
            qeStep < Const(qeIdx('clsr'), width: 4),
            wrState < Const(wQWren, width: 4),
          ]
        : qeFinish(ok: false);
    List<Conditional> qeNext(int i, int state) => [
      qeStep < Const(i + 1, width: 4),
      wrState < Const(state, width: 4),
    ];
    final qeDispatch = !qeActive
        ? const <Conditional>[]
        : [
            Case(qeStep, [
              for (final (i, st) in qeSteps.indexed)
                CaseItem(Const(i, width: 4), [
                  if (st == 'id')
                    If(
                      [
                        for (final m in config.acceptedManufacturers)
                          wrStatus.eq(Const(m, width: 8)),
                      ].reduce((a, b) => a | b),
                      then: qeNext(i, wStatLow),
                      orElse: [qeIdErr < Const(1), ...qeFinish(ok: false)],
                    )
                  else if (st == 'rdSr1') ...[
                    qeSr1 < wrStatus,
                    ...qeNext(i, wStatLow),
                  ] else if (st == 'rdSr1b')
                    If(
                      wrStatus.eq(qeSr1),
                      then: qeNext(i, wStatLow),
                      orElse: qeFinish(ok: false),
                    )
                  else if (st == 'rdQe')
                    If(
                      wrStatus[qe.bit],
                      then: qeFinish(ok: true),
                      orElse: [qePrev < wrStatus, ...qeNext(i, wStatLow)],
                    )
                  else if (st == 'rdQe2')
                    If(
                      wrStatus.eq(qePrev),
                      then: qeNext(i, wQWren),
                      orElse: qeFinish(ok: false),
                    )
                  else if (st == 'poll')
                    If(
                      wrStatus[0],
                      then: [
                        If(
                          wrTimer.gte(wrTimeLimit),
                          then: qeFailAfterWrite(),
                          orElse: [wrState < Const(wStatLow, width: 4)],
                        ),
                      ],
                      orElse: qeNext(i, wStatLow),
                    )
                  else if (st == 'verify')
                    If(
                      wrStatus[qe.bit],
                      then: qeFinish(ok: true),
                      orElse: qeFailAfterWrite(),
                    ),
                ]),
            ], defaultItem: qeFinish(ok: false)),
          ];
    final qeFrameBits = 8 + 8 * qe.writeBytes;
    final List<Conditional> wWrenStart = [
      wrCsN < Const(0),
      wrBitCount < Const(0, width: 8),
      wrShift < (qeActive ? mux<Logic>(qeRun, qeFrame, opFrame) : opFrame),
      wrState <
          (qeActive
              ? mux<Logic>(
                  qeRun,
                  Const(wQWrite, width: 4),
                  Const(wCmd, width: 4),
                )
              : Const(wCmd, width: 4)),
    ];
    // STAT_HIGH for a write or erase: inspect WIP. Busy polls again, unless
    // the timer reached the limit of the op: then the op ends with wr_err.
    final statHighWip = If(
      wrStatus[0],
      then: [
        If(
          wrTimer.gte(wrTimeLimit),
          then: [
            // Watchdog timeout: give up, flag the error, finish.
            wrErrReg < Const(1),
            wrState < Const(wDone, width: 4),
          ],
          orElse: [wrState < Const(wStatLow, width: 4)],
        ),
      ],
      orElse: [wrState < Const(wDone, width: 4)],
    );
    final wrDataLoad = engData.zeroExtend(32) << Const(24, width: 32);

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
          wrTimer < Const(0, width: timerWidth),
          if (qeActive) ...[
            qeDone < Const(0),
            qeSet < Const(0),
            qeErr < Const(0),
            qeRun < Const(0),
            qeStep < Const(0, width: 4),
            qeSr1 < Const(0, width: 8),
            qePrev < Const(0, width: 8),
            qeIdErr < Const(0),
          ],
        ],
        orElse: [
          wrDoneReg < Const(0),
          If(
            qeActive ? (inPoll | qeRun) : inPoll,
            then: [wrTimer < (wrTimer + Const(1, width: timerWidth))],
          ),
          Case(wrState, [
            // IDLE: wait for a request, latch op/addr/len. Accept it only when
            // the read FSM is idle and CS# has been high long enough. While a
            // request waits, the read FSM starts no new flash command (see
            // wrStart), so a read cannot start in the accept cycle. A request
            // that arrives during a read frame is held until the frame ends.
            // The DFU caller keeps wr_req asserted until wr_busy rises. The
            // hand-off therefore happens at a CS-high boundary.
            //
            // Minor validation: reject a zero-length page-program, and a
            // program that would cross the 256-byte page boundary (real flash
            // wraps within the page, corrupting the page start). Rejected
            // requests raise the sticky wr_err and pulse wr_done WITHOUT
            // touching the pins, so the caller learns instead of corrupting.
            CaseItem(Const(wIdle, width: 4), [
              wrClk < Const(0),
              wrCsN < Const(1),
              if (qeActive)
                If(
                  ~qeDone & spiState.eq(Const(sIdle, width: 3)) & csOk,
                  then: [
                    qeRun < Const(1),
                    qeStep < Const(0, width: 4),
                    wrOpL < Const(0),
                    wrTimer < Const(0, width: timerWidth),
                    wrState < Const(wStatLow, width: 4),
                  ],
                ),
              If(
                wrStart & csOk,
                then: [
                  wrOpL < reqOp,
                  wrAddrL < reqAddr0,
                  wrLenL < reqLen,
                  wrByteIdx < Const(0, width: 9),
                  wrErrReg < Const(0), // clear sticky err on a fresh accept
                  wrTimer < Const(0, width: timerWidth),
                  If(
                    // Invalid page-program: len==0, or (addr&0xFF)+len > 256.
                    reqOp &
                        (reqLen.eq(Const(0, width: 9)) |
                            (reqAddr0.getRange(0, 8).zeroExtend(10) +
                                    reqLen.zeroExtend(10))
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
            // In the startup sequence it also ends the CLSR and WRDI frames.
            CaseItem(Const(wWrenHigh, width: 4), [
              If(
                csOk,
                then: [
                  if (qeActive && qe.clearsErrors)
                    If(
                      qeRun & ~qeAt('write'),
                      then: [
                        Case(qeStep, [
                          CaseItem(Const(qeIdx('clsr'), width: 4), [
                            qeStep < Const(qeIdx('wrdi'), width: 4),
                            wrState < Const(wQWren, width: 4),
                          ]),
                        ], defaultItem: qeFinish(ok: false)),
                      ],
                      orElse: wWrenStart,
                    )
                  else
                    ...wWrenStart,
                ],
              ),
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

            // STAT_LOW: CS low, load RDSR (0x05).
            CaseItem(Const(wStatLow, width: 4), [
              If(
                csOk,
                then: [
                  wrCsN < Const(0),
                  wrDriveOut < Const(1),
                  wrShift <
                      (qeActive
                          ? mux<Logic>(
                              qeRun,
                              qeReadCmd.zeroExtend(32) << Const(24, width: 32),
                              Const(cmdRdsr << 24, width: 32),
                            )
                          : Const(cmdRdsr << 24, width: 32)),
                  wrBitCount < Const(0, width: 8),
                  wrStatus < Const(0, width: 8),
                  wrState < Const(wStatCmd, width: 4),
                ],
              ),
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

            // STAT_HIGH: inspect WIP (status bit0). Busy -> poll again, unless
            // the timer reached the limit of the op: then end the op with
            // wr_err. WIP clear -> done.
            CaseItem(Const(wStatHigh, width: 4), [
              wrCsN < Const(1),
              if (qeActive)
                If(qeRun, then: qeDispatch, orElse: [statHighWip])
              else
                statHighWip,
            ]),

            // QE_WREN: start the WREN frame of the startup sequence.
            if (qeActive)
              CaseItem(Const(wQWren, width: 4), [
                If(
                  csOk,
                  then: [
                    wrCsN < Const(0),
                    wrDriveOut < Const(1),
                    wrShift < (qeCmd8.zeroExtend(32) << Const(24, width: 32)),
                    wrBitCount < Const(0, width: 8),
                    wrState < Const(wWren, width: 4),
                  ],
                ),
              ]),

            // QE_WRITE: shift out the register write frame.
            if (qeActive)
              CaseItem(Const(wQWrite, width: 4), [
                wrClk < ~wrClk,
                If(
                  wrClk,
                  then: [
                    wrShift < (wrShift << Const(1, width: 32)),
                    wrBitCount < (wrBitCount + Const(1, width: 8)),
                    If(
                      wrBitCount.eq(Const(qeFrameBits - 1, width: 8)),
                      then: [
                        wrBitCount < Const(0, width: 8),
                        wrCsN < Const(1),
                        wrClk < Const(0),
                        qeStep < (qeStep + Const(1, width: 4)),
                        wrState < Const(wEnd, width: 4),
                      ],
                    ),
                  ],
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
    // normally. A waiting request also keeps the read FSM from starting a new
    // frame, so the pins change owner only while CS# is high.
    final pinClk = mux(wrBusy, wrClk, spiClk).named('spi_clk_pin');
    final pinCsN = mux(wrBusy, wrCsN, spiCsN).named('spi_cs_n_pin');
    output('spi_cs_n') <= pinCsN;
    if (csCnt != null) {
      Sequential(clk, [
        If(
          reset,
          then: [csCnt < Const(0, width: csWidth)],
          orElse: [
            If(
              pinCsN,
              then: [
                If(
                  csCnt.lt(Const(csHigh, width: csWidth)),
                  then: [csCnt < (csCnt + Const(1, width: csWidth))],
                ),
              ],
              orElse: [csCnt < Const(0, width: csWidth)],
            ),
          ],
        ),
      ]);
    }
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
    final driveOut = mux(wrBusy, wrDriveOut, ~ioRel).named('spi_drive_out');
    if (isStd) {
      output('spi_mosi') <= mosiBit;
      // Read samples MISO during read-data, write samples MISO during RDSR.
      spiIoIn <= input('spi_miso');
      statBit <= input('spi_miso');
    } else {
      final ioWidth = config.mode == HarborSpiFlashMode.quad ? 4 : 2;
      final ioOut = config.mode == HarborSpiFlashMode.quad
          ? [Const(1), Const(1), Const(0), mosiBit]
                .concat() // {D3,D2,D1,D0}
          : [Const(0), mosiBit].concat(); // dual {D1,D0}
      // IO0 and IO1 are outputs when driveOut is high and inputs otherwise.
      // IO2 (WP#) and IO3 (HOLD#) are outputs that hold 1 whenever the engine
      // runs and whenever the read FSM is outside its dummy and data phases,
      // so they never float. Only the quad data phase releases them.
      final holdOut = (wrBusy | ~ioDir).named('spi_hold_out');
      if (ownPads) {
        final pad = inOut('spi_io');
        HarborQuadPadDriver(
          data: ioOut,
          driveEnable: driveOut,
          holdEnable: ioWidth == 4 ? holdOut : null,
          pad: pad,
        );
        spiIoIn <= pad;
        statBit <= pad[1];
      } else {
        output('spi_io_out') <= ioOut;
        output('spi_io_oe') <=
            (ioWidth == 4
                ? [holdOut, holdOut, driveOut, driveOut].concat()
                : driveOut.replicate(ioWidth));
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

  /// Physical memory attributes of the XIP window. With a CPU write port the
  /// flash changes under the window, so the region is IO and not cacheable,
  /// read-only and executable. Without the port it is cacheable read-only
  /// memory. A core takes this region in its PMA map.
  HarborPmaRegion get xipPma {
    final widths = [for (var w = 1; w <= busBytes; w *= 2) w];
    return cpuPortBase == null
        ? HarborPmaRegion(
            start: baseAddress,
            size: config.size,
            memoryType: HarborPmaMemoryType.memory,
            ordering: HarborPmaOrdering.relaxed,
            executable: true,
            readable: true,
            writable: false,
            atomicSupport: false,
            misalignedSupport: true,
            accessWidths: widths,
            idempotent: true,
          )
        : HarborPmaRegion(
            start: baseAddress,
            size: config.size,
            memoryType: HarborPmaMemoryType.io,
            ordering: HarborPmaOrdering.channel,
            executable: true,
            readable: true,
            writable: false,
            atomicSupport: false,
            misalignedSupport: false,
            accessWidths: widths,
            idempotent: true,
          );
  }

  /// Physical memory attributes of the 4 KiB CPU port window as plain IO, or
  /// null when the build has no port.
  HarborPmaRegion? get ctrlPma => cpuPortBase == null
      ? null
      : HarborPmaRegion.io(
          start: cpuPortBase!,
          size: HarborSpiFlashCpuPort.windowBytes,
        );

  BusAddressRange get _xipRange => BusAddressRange(baseAddress, config.size);

  BusAddressRange? get _portRange => cpuPortBase == null
      ? null
      : BusAddressRange(cpuPortBase!, HarborSpiFlashCpuPort.windowBytes);

  Map<String, Object> get _speedProperties => {
    'spi-max-frequency': config.spiFrequency,
    if (config.mode == HarborSpiFlashMode.quad) 'spi-tx-bus-width': 4,
    if (config.mode == HarborSpiFlashMode.dual) 'spi-tx-bus-width': 2,
  };

  Map<String, Object> get _geometryProperties => {
    'harbor,flash-size': config.size,
    'harbor,erase-size': 4096,
    'harbor,page-size': config.pageSize,
    'harbor,erase-timeout-ms': config.eraseTimeoutMs,
    'harbor,program-timeout-ms': config.programTimeoutMs,
  };

  // A `fixed-partitions` map (the standard Linux MTD binding): the FSBL reads
  // it for the firmware offset and Linux exposes each as /dev/mtdN. Only the
  // node an OS driver binds to carries `read-only`.
  List<HarborDeviceTreeChild> _partitionChildren({required bool osView}) =>
      config.partitions.isEmpty
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
                    if (osView && part.osReadOnly) 'read-only': true,
                  },
                ),
            ],
          ),
        ];

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['jedec,spi-nor'],
    reg: _xipRange,
    extraReg: [if (_portRange != null) _portRange!],
    properties: {
      ..._speedProperties,
      if (_portRange != null) 'reg-names': ['xip', 'ctrl'],
    },
    children: _partitionChildren(osView: false),
  );

  @override
  List<HarborDeviceTreeNode> get extraDtNodes => _portRange == null
      ? const []
      : [
          HarborDeviceTreeNode(
            compatible: ['harbor,spi-flash-port'],
            reg: _portRange!,
            extraReg: [_xipRange],
            properties: {
              'reg-names': ['ctrl', 'xip'],
              ..._geometryProperties,
            },
            children: _partitionChildren(osView: true),
          ),
        ];

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [_xipRange],
    properties: {
      'compatible': ['jedec,spi-nor'],
      ..._speedProperties,
    },
  );

  @override
  List<HarborAcpiDevice> get extraAcpiDevices => _portRange == null
      ? const []
      : [
          HarborAcpiDevice(
            hid: 'PRP0001',
            uid: 1,
            memory: [_portRange!, _xipRange],
            properties: {
              'compatible': ['harbor,spi-flash-port'],
              ..._geometryProperties,
            },
          ),
        ];

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'SPIFLASH',
    groupName: 'SPIFLASH',
    description: 'SPI NOR flash controller with XIP',
    baseAddress: baseAddress,
    size: config.size,
  );

  @override
  List<HarborSvdPeripheral> get extraSvdPeripherals => _portRange == null
      ? const []
      : [
          HarborSvdPeripheral(
            name: 'SPIFLASH_PORT',
            groupName: 'SPIFLASH_PORT',
            description: 'SPI NOR flash write port with lock range',
            baseAddress: cpuPortBase!,
            size: HarborSpiFlashCpuPort.windowBytes,
            registers: HarborDeviceRegisterMap(
              name: 'spi_flash_port',
              fields: [
                const HarborDeviceField(name: 'ctrl', width: 4, offset: 0x00),
                const HarborDeviceField(name: 'addr', width: 4, offset: 0x04),
                const HarborDeviceField(name: 'len', width: 4, offset: 0x08),
                const HarborDeviceField(name: 'status', width: 4, offset: 0x0c),
                const HarborDeviceField(
                  name: 'lock_mask',
                  width: 4,
                  offset: 0x10,
                ),
                const HarborDeviceField(
                  name: 'qe_status',
                  width: 4,
                  offset: 0x14,
                ),
                const HarborDeviceField(name: 'claim', width: 4, offset: 0x1c),
                for (var i = 0; i < 64; i++)
                  HarborDeviceField(
                    name: 'page$i',
                    width: 4,
                    offset: 0x100 + 4 * i,
                  ),
              ],
            ),
          ),
        ];

  @override
  List<({String busInterfaceName, BusAddressRange range})>
  get secondarySlaves => _portRange == null
      ? const []
      : [(busInterfaceName: 'cpu_bus', range: _portRange!)];
}

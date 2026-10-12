import '../util/pretty_string.dart';
import 'ddr3_timing.dart';

/// SDRAM memory type.
enum HarborDdrType {
  /// DDR SDRAM (double data rate, first generation).
  ddr,

  /// DDR2 SDRAM.
  ddr2,

  /// DDR3 SDRAM (e.g., OrangeCrab).
  ddr3,

  /// DDR3L (low-voltage DDR3, e.g., Arty S7).
  ddr3l,

  /// DDR4 SDRAM.
  ddr4,

  /// DDR5 SDRAM.
  ddr5,

  /// LPDDR4 (low-power).
  lpddr4,

  /// LPDDR5 (low-power).
  lpddr5,
}

/// SDRAM memory configuration.
class HarborDdrConfig with HarborPrettyString {
  /// Memory type.
  final HarborDdrType type;

  /// Total memory size in bytes.
  final int size;

  /// Data bus width in bits (typically 8, 16, or 32).
  final int dataWidth;

  /// Clock frequency in Hz.
  final int frequency;

  /// Number of ranks.
  final int ranks;

  /// Number of bank groups (DDR4/5) or banks (SDR/DDR/DDR2/DDR3).
  final int banks;

  /// Row address width.
  final int rowWidth;

  /// Column address width.
  final int colWidth;

  /// CAS latency.
  final int casLatency;

  /// Device density. It sets tRFC.
  final DdrDensity density;

  /// Board DM wiring: DM pad `l` (in DQS group `l`) carries the mask of byte
  /// lane `dmRemapping[l]`. Null means pad `l` carries lane `l`.
  final List<int>? dmRemapping;

  const HarborDdrConfig({
    required this.type,
    required this.size,
    this.dataWidth = 16,
    required this.frequency,
    this.ranks = 1,
    this.banks = 8,
    this.rowWidth = 15,
    this.colWidth = 10,
    this.casLatency = 6,
    this.density = DdrDensity.gb2,
    this.dmRemapping,
  });

  /// OrangeCrab r0.2 DDR3 config: Micron MT41K64M16, 1 Gb (128MB, 16-bit,
  /// 400 MHz). 8K rows, 1K columns, 8 banks (litedram `MT41K64M16`). The DM
  /// pads are crossed: litex-boards `gsd_orangecrab.py` (commit 8215d8d, line
  /// 181) sets `dm_remapping = {0:1, 1:0}`.
  const HarborDdrConfig.orangeCrab()
    : type = HarborDdrType.ddr3,
      size = 128 * 1024 * 1024,
      dataWidth = 16,
      frequency = 400000000,
      ranks = 1,
      banks = 8,
      rowWidth = 13,
      colWidth = 10,
      casLatency = 6,
      density = DdrDensity.gb1,
      dmRemapping = const [1, 0];

  /// Arty S7 DDR3L config: Micron MT41K128M16, 2 Gb (256MB, 16-bit, 333 MHz).
  /// 16K rows, 1K columns, 8 banks.
  const HarborDdrConfig.artyS7()
    : type = HarborDdrType.ddr3l,
      size = 256 * 1024 * 1024,
      dataWidth = 16,
      frequency = 333333333,
      ranks = 1,
      banks = 8,
      rowWidth = 14,
      colWidth = 10,
      casLatency = 5,
      density = DdrDensity.gb2,
      dmRemapping = null;

  /// Alinx AX7203 DDR3 config: two Micron MT41J256M16HA-125 (4 Gb x16 each)
  /// on a 32-bit bus, 1 GB, 400 MHz (800 MT/s, AX7203 manual p.6 and p.12).
  /// Each part is 8 banks, 32K rows (A[14:0]) and 1K columns. The two parts
  /// share address and command.
  ///
  /// The controller uses CL 6 and CWL 5, the DDR3-800 setting that the -125
  /// part supports at tCK 2.5 ns. Its AC timings in [DdrTiming] are the
  /// DDR3-1600 values, which are the -125 values. tRFC for 4 Gb is 260 ns in
  /// the datasheet, [DdrDensity.gb4] uses 300 ns, which is safe.
  const HarborDdrConfig.ax7203()
    : type = HarborDdrType.ddr3,
      size = 1024 * 1024 * 1024,
      dataWidth = 32,
      frequency = 400000000,
      ranks = 1,
      banks = 8,
      rowWidth = 15,
      colWidth = 10,
      casLatency = 6,
      density = DdrDensity.gb4,
      dmRemapping = null;

  /// Frequency in MHz.
  double get frequencyMhz => frequency / 1e6;

  /// Data rate in MT/s (ddr transfers on both clock edges).
  int get dataRate => frequency * 2;

  /// Bandwidth in MB/s.
  double get bandwidthMBs => dataRate * dataWidth / 8 / 1e6;

  @override
  String toString() =>
      'HarborDdrConfig(${type.name}, ${size ~/ (1024 * 1024)} MB, '
      '${frequencyMhz.toStringAsFixed(0)} MHz)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborDdrConfig(\n');
    buf.writeln('${c}type: ${type.name},');
    buf.writeln('${c}size: ${size ~/ (1024 * 1024)} MB,');
    buf.writeln('${c}dataWidth: $dataWidth bits,');
    buf.writeln(
      '${c}frequency: ${frequencyMhz.toStringAsFixed(0)} MHz (${dataRate ~/ 1000000} MT/s),',
    );
    buf.writeln('${c}bandwidth: ${bandwidthMBs.toStringAsFixed(0)} MB/s,');
    buf.writeln('${c}CL: $casLatency,');
    buf.writeln('${c}banks: $banks, rows: $rowWidth, cols: $colWidth,');
    buf.write('$p)');
    return buf.toString();
  }
}

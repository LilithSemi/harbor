/// Sdr sdram device geometry and mode register encoding.
library;

import '../util/pretty_string.dart';
import 'sdram_timing.dart';

/// How a word address splits into row, bank and column.
enum HarborSdramAddressMap {
  /// Row bits above bank bits above column bits.
  rowBankCol,

  /// Bank bits above row bits above column bits.
  bankRowCol,
}

/// Sdr sdram device and controller configuration.
class HarborSdramConfig with HarborPrettyString {
  /// Part number, e.g. `AS4C16M16SB-6`.
  final String part;

  /// Ac timing for this part.
  final HarborSdramTiming timing;

  /// Data bus width in bits.
  final int dataWidth;

  /// Number of banks.
  final int banks;

  /// Row address width.
  final int rowWidth;

  /// Column address width.
  final int colWidth;

  /// Cas latency to use, or null to pick the lowest one the clock supports.
  final int? casLatency;

  /// Burst length. The v1 engine needs 8.
  final int burstLength;

  /// Single write per burst (mode register A9). The v1 engine needs true.
  final bool singleWrite;

  /// Auto refreshes to run during init, at or above the datasheet minimum.
  final int initRefreshes;

  /// Row, bank, column bit order for a word address.
  final HarborSdramAddressMap addressMap;

  HarborSdramConfig({
    required this.part,
    required this.timing,
    this.dataWidth = 16,
    this.banks = 4,
    required this.rowWidth,
    required this.colWidth,
    this.casLatency,
    this.burstLength = 8,
    this.singleWrite = true,
    this.initRefreshes = 8,
    this.addressMap = HarborSdramAddressMap.rowBankCol,
  }) {
    if (banks < 1 || (banks & (banks - 1)) != 0) {
      throw ArgumentError.value(banks, 'banks', 'must be a power of two');
    }
    if (rowWidth < 11) {
      throw ArgumentError.value(rowWidth, 'rowWidth', 'must be at least 11');
    }
    if (colWidth < 3 || colWidth > 9) {
      throw ArgumentError.value(
        colWidth,
        'colWidth',
        'must be 3 to 9 (10 or more puts a column bit on A10, which means '
            'auto-precharge)',
      );
    }
  }

  /// AS4C16M16SB-6 on the ULX3S: 32 MiB, 16-bit, 13 row bits, 9 column bits,
  /// 4 banks.
  const HarborSdramConfig.as4c16m16sb6({
    this.addressMap = HarborSdramAddressMap.rowBankCol,
    this.casLatency,
    this.timing = const HarborSdramTiming.as4c16m16sb6(),
  }) : part = 'AS4C16M16SB-6',
       dataWidth = 16,
       banks = 4,
       rowWidth = 13,
       colWidth = 9,
       burstLength = 8,
       singleWrite = true,
       initRefreshes = 8;

  /// Bank address bits, e.g. 2 for 4 banks.
  int get bankBits => (banks - 1).bitLength;

  /// Full word address width: row + bank + column bits.
  int get wordAddrWidth => rowWidth + bankBits + colWidth;

  /// Total device capacity in bytes.
  int get sizeBytes => (1 << wordAddrWidth) * (dataWidth ~/ 8);

  /// Bytes in one open row (one page).
  int get pageBytes => (1 << colWidth) * (dataWidth ~/ 8);

  /// Mode register word for the given cas latency. Fields follow table 5
  /// p13, table 6 p14, table 7 p15, table 9 p15 and table 11 p16 of the
  /// as4c16m16sb datasheet rev 2.0: ba/a12/a11/a10/a8/a7 = 0, a9 = single
  /// write, a6:a4 = cas latency, a3 = sequential burst, a2:a0 = burst
  /// length 8.
  int modeRegister(int casLatency) {
    if (burstLength != 8 || !singleWrite) {
      throw ArgumentError(
        'mode register encoding needs burst length 8 and single write',
      );
    }
    return (1 << 9) | (casLatency << 4) | 0x3;
  }

  /// Returns a copy with the given fields replaced.
  HarborSdramConfig copyWith({
    HarborSdramTiming? timing,
    HarborSdramAddressMap? addressMap,
  }) => HarborSdramConfig(
    part: part,
    timing: timing ?? this.timing,
    dataWidth: dataWidth,
    banks: banks,
    rowWidth: rowWidth,
    colWidth: colWidth,
    casLatency: casLatency,
    burstLength: burstLength,
    singleWrite: singleWrite,
    initRefreshes: initRefreshes,
    addressMap: addressMap ?? this.addressMap,
  );

  @override
  String toString() =>
      'HarborSdramConfig($part, ${sizeBytes ~/ (1024 * 1024)} MB, '
      '${dataWidth}b)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborSdramConfig(\n');
    buf.writeln('${c}part: $part,');
    buf.writeln('${c}size: ${sizeBytes ~/ (1024 * 1024)} MB,');
    buf.writeln('${c}dataWidth: $dataWidth bits,');
    buf.writeln('${c}banks: $banks, rows: $rowWidth, cols: $colWidth,');
    buf.writeln('${c}addressMap: ${addressMap.name},');
    buf.write('$p)');
    return buf.toString();
  }
}

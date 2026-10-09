/// Sdr sdram ac timing, sourced from the as4c16m16sb-6 datasheet.
///
/// Every field is a datasheet value in nanoseconds, except the ones whose
/// name ends in `Nck` (device clocks) or `Count` (a plain count).
/// [HarborSdramCycles] turns these into controller clock cycles.
library;

class HarborSdramTiming {
  /// Active to active (same bank). as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tRc;

  /// Refresh to active or refresh. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tRfc;

  /// Active to read or write. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tRcd;

  /// Precharge to active or refresh. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tRp;

  /// Active to precharge, minimum. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tRasMin;

  /// Active to precharge, maximum. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tRasMax;

  /// Active to active, different bank. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tRrd;

  /// Mode register set to a valid command, in ns.
  /// as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tMrd;

  /// Write recovery. as4c16m16sb datasheet rev 2.0, table 16, p21, and
  /// command 6 text, p12.
  final double tWr;

  /// Clock high time. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tCh;

  /// Clock low time. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tCl;

  /// Output data hold time. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tOh;

  /// Output low-Z time. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tLz;

  /// Output high-Z time. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tHz;

  /// Input setup time. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tIs;

  /// Input hold time. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tIh;

  /// Average refresh interval. as4c16m16sb datasheet rev 2.0, table 16, p21.
  final double tRefi;

  /// Power-up clock time with cke low, before the init sequence starts.
  /// as4c16m16sb datasheet rev 2.0, note 11, p22.
  final double powerUpNs;

  /// Refresh window: [refreshCount] refreshes must fit in this time.
  /// as4c16m16sb datasheet rev 2.0, features p2, command 12 p17.
  final double refreshPeriodNs;

  /// Mode register set to a valid command, in device clocks.
  /// as4c16m16sb datasheet rev 2.0, command 8 text, p13.
  final int tMrdNck;

  /// Refreshes required per [refreshPeriodNs].
  /// as4c16m16sb datasheet rev 2.0, features p2, command 12 p17.
  final int refreshCount;

  /// Auto refreshes required during init, minimum.
  /// as4c16m16sb datasheet rev 2.0, note 11, p22.
  final int initRefreshesMin;

  /// Minimum clock period by cas latency, in ns.
  /// as4c16m16sb datasheet rev 2.0, table 16, p21.
  final Map<int, double> tCkMinByCl;

  /// Access time (clock to data valid), by cas latency, in ns.
  /// as4c16m16sb datasheet rev 2.0, table 16, p21.
  final Map<int, double> tAcByCl;

  const HarborSdramTiming({
    required this.tRc,
    required this.tRfc,
    required this.tRcd,
    required this.tRp,
    required this.tRasMin,
    required this.tRasMax,
    required this.tRrd,
    required this.tMrd,
    required this.tWr,
    required this.tCh,
    required this.tCl,
    required this.tOh,
    required this.tLz,
    required this.tHz,
    required this.tIs,
    required this.tIh,
    required this.tRefi,
    required this.powerUpNs,
    required this.refreshPeriodNs,
    required this.tMrdNck,
    required this.refreshCount,
    required this.initRefreshesMin,
    required this.tCkMinByCl,
    required this.tAcByCl,
  });

  /// AS4C16M16SB-6, rev 2.0, June 2021. Values from table 16, p21 unless
  /// noted on the field.
  const HarborSdramTiming.as4c16m16sb6()
    : tRc = 60.0,
      tRfc = 60.0,
      tRcd = 18.0,
      tRp = 18.0,
      tRasMin = 42.0,
      tRasMax = 120000.0,
      tRrd = 12.0,
      tMrd = 12.0,
      tWr = 12.0,
      tCh = 2.0,
      tCl = 2.0,
      tOh = 2.5,
      tLz = 0.0,
      tHz = 5.0,
      tIs = 1.5,
      tIh = 0.8,
      tRefi = 7800.0,
      powerUpNs = 200000.0,
      refreshPeriodNs = 64000000.0,
      tMrdNck = 2,
      refreshCount = 8192,
      initRefreshesMin = 2,
      tCkMinByCl = const {2: 10.0, 3: 6.0},
      tAcByCl = const {2: 6.0, 3: 5.0};

  /// Returns a copy for test speedups. Only [powerUpNs] and [tRasMax] are
  /// exposed, since those are the only values a test shortens.
  HarborSdramTiming copyWith({double? powerUpNs, double? tRasMax}) =>
      HarborSdramTiming(
        tRc: tRc,
        tRfc: tRfc,
        tRcd: tRcd,
        tRp: tRp,
        tRasMin: tRasMin,
        tRasMax: tRasMax ?? this.tRasMax,
        tRrd: tRrd,
        tMrd: tMrd,
        tWr: tWr,
        tCh: tCh,
        tCl: tCl,
        tOh: tOh,
        tLz: tLz,
        tHz: tHz,
        tIs: tIs,
        tIh: tIh,
        tRefi: tRefi,
        powerUpNs: powerUpNs ?? this.powerUpNs,
        refreshPeriodNs: refreshPeriodNs,
        tMrdNck: tMrdNck,
        refreshCount: refreshCount,
        initRefreshesMin: initRefreshesMin,
        tCkMinByCl: tCkMinByCl,
        tAcByCl: tAcByCl,
      );
}

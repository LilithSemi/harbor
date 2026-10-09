/// Turns sdr sdram ac timing (ns) into controller clock cycles.
library;

import 'sdram_config.dart';

/// Picosecond math helpers. All sdram timing values fit in an int number of
/// picoseconds, so this avoids floating point in the cycle counts that the
/// controller compares against.
int _psOf(double ns) => (ns * 1000).round();

/// Smallest cycle count whose real time is at least [ps], at [clockHz].
int _ceilCycles(int ps, int clockHz) =>
    (ps * clockHz + 999999999999) ~/ 1000000000000;

/// Largest cycle count whose real time is at most [ps], at [clockHz].
int _floorCycles(int ps, int clockHz) => (ps * clockHz) ~/ 1000000000000;

/// The only place that turns [HarborSdramConfig] ac timing (ns) into
/// controller clock cycles for a given [clockHz].
class HarborSdramCycles {
  /// The device and controller configuration.
  final HarborSdramConfig config;

  /// Controller clock frequency in Hz (1:1 with sdram_clk).
  final int clockHz;

  /// Controller clock period in picoseconds.
  final int tCkPs;

  /// Cas latency used at this clock: [HarborSdramConfig.casLatency] if set,
  /// otherwise the lowest cas latency the clock supports.
  final int casLatency;

  /// Active to active, same bank, in cycles.
  final int rc;

  /// Refresh to active or refresh, in cycles.
  final int rfc;

  /// Active to read or write, in cycles.
  final int rcd;

  /// Precharge to active or refresh, in cycles.
  final int rp;

  /// Active to precharge, minimum, in cycles.
  final int rasMin;

  /// Active to active, different bank, in cycles.
  final int rrd;

  /// Mode register set to a valid command, in cycles.
  final int mrd;

  /// Write recovery, in cycles.
  final int wr;

  /// Refresh scheduling interval, in cycles.
  final int refi;

  /// Refresh scheduling interval, in picoseconds.
  final int refiEffPs;

  /// Power-up wait before the init sequence starts, in cycles.
  final int powerUp;

  /// Auto refreshes to run during init.
  final int initRefreshes;

  /// Read data high-Z cycles before the bus is free for the next command.
  final int readHiz;

  /// Controller cycles a row may stay open before a forced precharge-all.
  final int rowAgeLimit;

  /// Refreshes the scheduler may postpone before it must catch up.
  final int maxPostponed;

  /// Refreshes the scheduler may pull in ahead of schedule.
  final int maxPulledIn;

  factory HarborSdramCycles(
    HarborSdramConfig config, {
    required int clockHz,
    int maxPostponedRefresh = 8,
    int maxPulledInRefresh = 8,
    int? phyMaxClockHz,
  }) {
    final timing = config.timing;

    if (config.burstLength != 8 || !config.singleWrite) {
      throw ArgumentError(
        'the sdram engine needs burst length 8 and single write',
      );
    }
    if (phyMaxClockHz != null && clockHz > phyMaxClockHz) {
      throw ArgumentError(
        'clockHz $clockHz exceeds the phy limit of $phyMaxClockHz Hz',
      );
    }
    if (maxPostponedRefresh < 1) {
      throw ArgumentError('maxPostponedRefresh must be >= 1');
    }
    if (maxPulledInRefresh < 0) {
      throw ArgumentError('maxPulledInRefresh must be >= 0');
    }
    if (config.initRefreshes < timing.initRefreshesMin) {
      throw ArgumentError(
        'initRefreshes ${config.initRefreshes} is below the datasheet '
        'minimum of ${timing.initRefreshesMin}',
      );
    }

    final casLatency = _resolveCasLatency(config, clockHz);
    final tCkPs = 1000000000000 ~/ clockHz;

    final refreshPeriodPs = _psOf(timing.refreshPeriodNs);
    final refiEffPs =
        refreshPeriodPs ~/
        (timing.refreshCount + maxPostponedRefresh + maxPulledInRefresh);
    if (refiEffPs >= _psOf(timing.tRefi)) {
      throw ArgumentError(
        'the scheduled refresh interval is not tighter than tRefi',
      );
    }
    if ((timing.refreshCount + maxPostponedRefresh + maxPulledInRefresh) *
            refiEffPs >
        refreshPeriodPs) {
      throw ArgumentError('refresh schedule does not fit the refresh window');
    }

    final rowAgeLimit = (_psOf(timing.tRasMax) * 9 * clockHz) ~/ 10000000000000;
    if (rowAgeLimit <= 0) {
      throw ArgumentError('rowAgeLimit must be > 0, check tRasMax and clockHz');
    }

    return HarborSdramCycles._(
      config: config,
      clockHz: clockHz,
      tCkPs: tCkPs,
      casLatency: casLatency,
      rc: _ceilCycles(_psOf(timing.tRc), clockHz),
      rfc: _ceilCycles(_psOf(timing.tRfc), clockHz),
      rcd: _ceilCycles(_psOf(timing.tRcd), clockHz),
      rp: _ceilCycles(_psOf(timing.tRp), clockHz),
      rasMin: _ceilCycles(_psOf(timing.tRasMin), clockHz),
      rrd: _ceilCycles(_psOf(timing.tRrd), clockHz),
      mrd: [
        _ceilCycles(_psOf(timing.tMrd), clockHz),
        timing.tMrdNck,
      ].reduce((a, b) => a > b ? a : b),
      wr: _ceilCycles(_psOf(timing.tWr), clockHz),
      refi: _floorCycles(refiEffPs, clockHz),
      refiEffPs: refiEffPs,
      powerUp: _ceilCycles(_psOf(timing.powerUpNs), clockHz),
      initRefreshes: config.initRefreshes,
      readHiz: _readHiz(_psOf(timing.tHz), clockHz),
      rowAgeLimit: rowAgeLimit,
      maxPostponed: maxPostponedRefresh,
      maxPulledIn: maxPulledInRefresh,
    );
  }

  HarborSdramCycles._({
    required this.config,
    required this.clockHz,
    required this.tCkPs,
    required this.casLatency,
    required this.rc,
    required this.rfc,
    required this.rcd,
    required this.rp,
    required this.rasMin,
    required this.rrd,
    required this.mrd,
    required this.wr,
    required this.refi,
    required this.refiEffPs,
    required this.powerUp,
    required this.initRefreshes,
    required this.readHiz,
    required this.rowAgeLimit,
    required this.maxPostponed,
    required this.maxPulledIn,
  });

  /// The mode register word for [casLatency].
  int get modeRegister => config.modeRegister(casLatency);

  /// Cycles from a read command until a write command may issue, counted
  /// from the read command cycle: cas latency, the [beats] of the burst,
  /// then the read high-Z cycles. as4c16m16sb datasheet rev 2.0, p9 text,
  /// fig 7 and 8 p10.
  int readToWrite(int beats) => casLatency + beats + readHiz;

  /// Picks [config.casLatency] if set, else the lowest cas latency whose
  /// minimum clock period (table 16, p21) the clock period satisfies.
  static int _resolveCasLatency(HarborSdramConfig config, int clockHz) {
    final timing = config.timing;
    final tCkMinByCl = timing.tCkMinByCl;

    if (config.casLatency != null) {
      final cl = config.casLatency!;
      final tCkMinPs = tCkMinByCl[cl];
      if (tCkMinPs == null) {
        throw ArgumentError('CAS latency $cl has no tCkMin entry');
      }
      if (_psOf(tCkMinPs) * clockHz > 1000000000000) {
        throw ArgumentError('CAS latency $cl is too slow for clockHz $clockHz');
      }
      return cl;
    }

    final candidates = tCkMinByCl.keys.toList()..sort();
    for (final cl in candidates) {
      if (_psOf(tCkMinByCl[cl]!) * clockHz <= 1000000000000) {
        return cl;
      }
    }
    throw ArgumentError('no CAS latency fits clockHz $clockHz');
  }

  /// ceil(tHz/tCk + 0.5), computed as ceil((2*tHz*clockHz + 1e12) / 2e12).
  /// as4c16m16sb datasheet rev 2.0, table 16, p21 (tHz), fig 9 p10 (read to
  /// precharge framing the same read-to-next-command gap).
  static int _readHiz(int tHzPs, int clockHz) {
    final a = tHzPs * clockHz;
    const b = 1000000000000;
    final numerator = 2 * a + b;
    const denom = 2 * b;
    return (numerator + denom - 1) ~/ denom;
  }
}

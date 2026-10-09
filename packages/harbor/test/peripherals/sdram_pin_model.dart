import 'package:rohd/rohd.dart';

/// as4c16m16sb datasheet rev 2.0 (june 2021), table 16, p21, -6 grade, with
/// note 11 (power up, p22) and the mode register and command tables (p13-17).
/// [SdramPinModel] keeps its own copy of every value so a wrong number in
/// lib code fails a test instead of agreeing with itself.
class SdramModelRules {
  const SdramModelRules._({
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
    required this.powerUpNs,
    required this.refreshPeriodNs,
    required this.tMrdNck,
    required this.refreshCount,
    required this.initRefreshesMin,
    required this.banks,
    required this.rowWidth,
    required this.colWidth,
    required this.dataWidth,
    required this.tCkMinByCl,
    required this.tAcByCl,
    required this.refreshWindowNs,
  });

  /// table 16, p21 (tRC, tRFC, tRCD, tRP, tRRD, tMRD), tRAS min/max, tWR,
  /// tCH/tCL, tOH/tLZ/tHZ, tIS/tIH and tREFI. note 11, p22 for power up.
  /// Command 8 text p13 for tMRD in clocks. Features p2 and command 12 p17
  /// for the refresh count. Table 9 p15 and table 6 p14 for cas latency and
  /// access time, dimensioned 4 banks x 8192 rows x 512 cols x 16 bits.
  const SdramModelRules.as4c16m16sb6()
    : this._(
        tRc: 60,
        tRfc: 60,
        tRcd: 18,
        tRp: 18,
        tRasMin: 42,
        tRasMax: 120000,
        tRrd: 12,
        tMrd: 12,
        tWr: 12,
        tCh: 2,
        tCl: 2,
        tOh: 2.5,
        tLz: 0,
        tHz: 5,
        tIs: 1.5,
        tIh: 0.8,
        powerUpNs: 200000,
        refreshPeriodNs: 7800,
        tMrdNck: 2,
        refreshCount: 8192,
        initRefreshesMin: 2,
        banks: 4,
        rowWidth: 13,
        colWidth: 9,
        dataWidth: 16,
        tCkMinByCl: const {2: 10.0, 3: 6.0},
        tAcByCl: const {2: 6.0, 3: 5.0},
        refreshWindowNs: 64000000,
      );

  final double tRc,
      tRfc,
      tRcd,
      tRp,
      tRasMin,
      tRasMax,
      tRrd,
      tMrd,
      tWr,
      tCh,
      tCl,
      tOh,
      tLz,
      tHz,
      tIs,
      tIh,
      powerUpNs,
      refreshPeriodNs;
  final int tMrdNck,
      refreshCount,
      initRefreshesMin,
      banks,
      rowWidth,
      colWidth,
      dataWidth;
  final Map<int, double> tCkMinByCl, tAcByCl;

  /// 64ms, features p2 and command 12 p17: the window 8192 refreshes must
  /// land inside.
  final double refreshWindowNs;

  /// A copy with one or more values overridden, for tests that shrink
  /// powerUpNs, shrink tRasMax, or probe the tMRD ns-versus-nCK branches.
  SdramModelRules copyWith({
    double? powerUpNs,
    double? tRasMax,
    double? tMrd,
    int? tMrdNck,
  }) => SdramModelRules._(
    tRc: tRc,
    tRfc: tRfc,
    tRcd: tRcd,
    tRp: tRp,
    tRasMin: tRasMin,
    tRasMax: tRasMax ?? this.tRasMax,
    tRrd: tRrd,
    tMrd: tMrd ?? this.tMrd,
    tWr: tWr,
    tCh: tCh,
    tCl: tCl,
    tOh: tOh,
    tLz: tLz,
    tHz: tHz,
    tIs: tIs,
    tIh: tIh,
    powerUpNs: powerUpNs ?? this.powerUpNs,
    refreshPeriodNs: refreshPeriodNs,
    tMrdNck: tMrdNck ?? this.tMrdNck,
    refreshCount: refreshCount,
    initRefreshesMin: initRefreshesMin,
    banks: banks,
    rowWidth: rowWidth,
    colWidth: colWidth,
    dataWidth: dataWidth,
    tCkMinByCl: tCkMinByCl,
    tAcByCl: tAcByCl,
    refreshWindowNs: refreshWindowNs,
  );
}

/// The refresh-rate check from command 12, p17 ("8192 refresh cycles within
/// 64ms"), restated as a sliding window so a short simulation can prove it.
/// `maxPostponed` (k) and `maxPulledIn` (p) bound how far a real controller
/// may let a refresh slip late or pull one in early.
class SdramRefreshPolicy {
  const SdramRefreshPolicy({
    required this.maxPostponed,
    required this.maxPulledIn,
    required this.periodNs,
    required this.maxLatencyNs,
    required this.initRefreshes,
  });

  final int maxPostponed, maxPulledIn;
  final double periodNs, maxLatencyNs;

  /// How many refreshes the controller issues during init before the
  /// sliding window starts counting. t0 is the time of this one, and the
  /// refresh right after it is n=1, whatever else happens in between.
  final int initRefreshes;
}

/// One command this model saw on the pins, for assertions and debugging.
class SdramModelCommand {
  const SdramModelCommand({
    required this.timePs,
    required this.kind,
    this.bank,
    this.row,
    this.col,
    required this.a,
  });

  final int timePs;
  final String kind;
  final int? bank, row, col;
  final int a;
}

/// Per-bank open/closed bookkeeping.
class _Bank {
  bool active = false;
  int? row;
  int activatedAtPs = _negInf;
  int lastActivateAtPs = _negInf;
  int lastPrechargeAtPs = _negInf;
  int lastWriteAtPs = _negInf;
  bool rasMaxReported = false;
}

/// An in-flight read burst: the 8 (bank, row, col) targets in BL8 sequential
/// order (table 8, p15) and the edge after which no more beats are driven.
class _ReadState {
  _ReadState(this.firstBeatEdgePs, this.order, int periodPs)
    : endEdgeExclusivePs = firstBeatEdgePs + 8 * periodPs;

  final int firstBeatEdgePs;
  final List<(int, int, int)> order;
  int endEdgeExclusivePs;

  /// The next beat index whose drive timeline has not been scheduled yet.
  int nextUndecided = 0;

  /// Whether each decided beat was masked (null until decided).
  final List<bool?> masked = List.filled(8, null);

  /// Set on beat i when beat i+1 is decided, unmasked and still inside the
  /// burst: beat i then leaves its own tHZ release for beat i+1 to carry
  /// the bus into instead of opening a z gap mid-burst.
  final List<bool> skipRelease = List.filled(8, false);
}

const int _negInf = -(1 << 62);

/// Pin-level model of an as4c16m16sb sdr sdram, checking every table 16 (p21)
/// ac timing and every command rule from the command list (p7-17) directly
/// against its own datasheet copy ([SdramModelRules]), in nanoseconds.
///
/// It sees only the sdram pins, the way a real device does: commands are
/// decoded from cs#, ras#, cas#, we#, ba and addr on each clk rising edge,
/// while cke is high on the previous edge. Reads and writes use the mode
/// register's cas latency and burst length, which must already be set.
class SdramPinModel {
  final SdramModelRules rules;
  final SdramRefreshPolicy? refreshPolicy;
  final double fpgaToSdramNs, sdramToFpgaNs;

  /// The fpga's own dq output-enable and data, if the harness gives them,
  /// already in chip time (the harness drives them onto the shared net
  /// directly, with no separate propagation element). With them, handoff,
  /// contention and write setup/hold come straight from these signals
  /// instead of being inferred from the net, which an x-vs-x merge can
  /// hide (see [_onDqChange]). Without them, inference stays deliberately
  /// conservative: it can flag a drive a real phy could never reach that
  /// early or late.
  ///
  /// Wire these to the pad-level signals after the io register, active
  /// high (ecp5's bb primitive's own `t` is active low, so invert it) and
  /// the registered pad data, not an earlier engine-side oe like
  /// `phy_dq_oe`, which does not yet carry the io register's own delay.
  final Logic? fpgaDqOe;
  final Logic? fpgaDqOut;

  bool get _hasFpgaSignals => fpgaDqOe != null;

  /// Every rule broken so far, each starting with `t=<ps>: <rule>:`.
  final List<String> errors = [];

  /// Every command this model decoded, in order.
  final List<SdramModelCommand> log = [];

  final Logic _clk, _cke, _csN, _rasN, _casN, _weN, _ba, _addr, _dqm;
  final LogicNet _dq;

  final Logic _dqDrv;
  final Logic _dqEn;

  final List<_Bank> _banks;
  final Map<int, int> _mem = {};
  final Map<int, int> _dqmAtEdgePs = {};
  final Map<String, int> _lastChangePs = {};

  int? _lastPosedgePs, _lastNegedgePs;
  int? _firstEdgePs, _ckeWentHighAtPs;
  bool _ckePrevEdgeHigh = false;

  bool _prechargedAll = false;
  bool _modeSet = false;
  int _refreshesSoFar = 0;
  bool _anyActivateEver = false;
  bool _anyMrsEver = false;
  bool _initDone = false;
  int? _t0Ps;
  int _policyRefreshCount = 0;
  int _postInitRefreshN = 0;
  final List<int> _refreshTimesPs = [];

  int? _cl;
  int? _periodPs;
  int _lastMrsPs = _negInf;
  int _refreshBusyUntilPs = _negInf;
  int _allIdleSincePs = _negInf;
  int? _lastActivateEdgePs;
  int? _lastActivateBank;

  _ReadState? _activeRead;
  bool _modelDrivingDq = false;
  int _lastDrivenBeatEdgePs = _negInf;

  bool get _fpgaOeAssertedChip =>
      _hasFpgaSignals && fpgaDqOe!.value == LogicValue.one;

  /// True only while `startDrive` puts an x value (and during the
  /// constructor's initial put), never a valid one: only x is always
  /// this model's own value, so only it skips [_onDqChange] outright.
  bool _drivingDqPin = false;

  /// True only during a release's put on [_dqEn], natural or forced, so
  /// [_onDqChange] knows a non-Z reveal there is this release's doing,
  /// not an unrelated later put.
  bool _releasingDqPin = false;

  /// Last change time per dq byte lane (0 = low byte, 1 = high byte), so a
  /// write's dqm can exempt a masked lane from setup and hold.
  final List<int> _lastChangeDqPs = [_negInf, _negInf];

  /// The value each lane last showed when [_lastChangeDqPs] was recorded,
  /// so a release that reveals a *different* value than that still counts
  /// as a new change, even if this same beat already caught one earlier.
  final List<LogicValue?> _lastSeenDqValue = [null, null];

  /// Which (read, index) decided the beat at a given edge, across reads,
  /// so a beat can tell whether the edge before it was an unmasked beat
  /// still holding its data (and so mark that beat to skip its release).
  final Map<int, (_ReadState, int)> _beatByEdge = {};

  SdramPinModel({
    required Logic clk,
    required Logic cke,
    required Logic csN,
    required Logic rasN,
    required Logic casN,
    required Logic weN,
    required Logic ba,
    required Logic addr,
    required Logic dqm,
    required LogicNet dq,
    this.rules = const SdramModelRules.as4c16m16sb6(),
    this.fpgaToSdramNs = 4.6,
    this.sdramToFpgaNs = 0.5,
    this.refreshPolicy,
    this.fpgaDqOe,
    this.fpgaDqOut,
  }) : _clk = clk,
       _cke = cke,
       _csN = csN,
       _rasN = rasN,
       _casN = casN,
       _weN = weN,
       _ba = ba,
       _addr = addr,
       _dqm = dqm,
       _dq = dq,
       _dqDrv = Logic(name: 'sdram_model_dq_drv', width: rules.dataWidth),
       _dqEn = Logic(name: 'sdram_model_dq_en'),
       _banks = List.generate(rules.banks, (_) => _Bank()) {
    // This margin only matters for net inference (see _onDqChange): with
    // fpgaDqOe/fpgaDqOut, a too-early drive is read straight off them,
    // never through the net's own x phase.
    if (!_hasFpgaSignals &&
        fpgaToSdramNs + sdramToFpgaNs < rules.tHz - rules.tOh) {
      throw ArgumentError(
        'fpgaToSdramNs + sdramToFpgaNs must be at least tHz - tOh, or a '
        'too-early fpga drive can land in the x phase and go undetected',
      );
    }

    _dq <= TriStateBuffer(_dqDrv, enable: _dqEn, name: 'sdram_model_dq').out;
    Simulator.injectAction(() {
      _drivingDqPin = true;
      _dqDrv.put(LogicValue.filled(rules.dataWidth, LogicValue.x));
      _dqEn.put(0);
      _drivingDqPin = false;
    });

    if (refreshPolicy != null) _checkRefreshRateFormula();

    for (final (name, l) in [
      ('cke', _cke),
      ('cs_n', _csN),
      ('ras_n', _rasN),
      ('cas_n', _casN),
      ('we_n', _weN),
      ('ba', _ba),
      ('addr', _addr),
      ('dqm', _dqm),
    ]) {
      l.changed.listen((_) => _onPinChange(name));
    }
    if (_hasFpgaSignals) {
      // glitch, not changed: same reasoning as the dq net below, and
      // empirically changed can simply miss a later put altogether.
      fpgaDqOe!.glitch.listen(_onFpgaOeChange);
      fpgaDqOut?.glitch.listen(_onFpgaOutChange);
    } else {
      // glitch (synchronous), not changed (an async Stream): changed can
      // coalesce two rapid transitions into one delivery at the later
      // time, dropping a brief but real contention window (two drivers
      // whose combined value only exists for a moment).
      _dq.glitch.listen(_onDqChange);
    }

    _clk.posedge.listen((_) => _onPosedge());
    _clk.negedge.listen((_) => _onNegedge());
  }

  int get _tIsPs => (rules.tIs * 1000).round();
  int get _tIhPs => (rules.tIh * 1000).round();
  int get _tRcPs => (rules.tRc * 1000).round();
  int get _tRfcPs => (rules.tRfc * 1000).round();
  int get _tRcdPs => (rules.tRcd * 1000).round();
  int get _tRpPs => (rules.tRp * 1000).round();
  int get _tRasMinPs => (rules.tRasMin * 1000).round();
  int get _tRasMaxPs => (rules.tRasMax * 1000).round();
  int get _tRrdPs => (rules.tRrd * 1000).round();
  int get _tMrdPs => (rules.tMrd * 1000).round();
  int get _tWrPs => (rules.tWr * 1000).round();
  int get _tChPs => (rules.tCh * 1000).round();
  int get _tClPs => (rules.tCl * 1000).round();
  int get _tOhPs => (rules.tOh * 1000).round();
  int get _tLzPs => (rules.tLz * 1000).round();
  int get _tHzPs => (rules.tHz * 1000).round();
  int get _powerUpPs => (rules.powerUpNs * 1000).round();
  int get _dPs => ((fpgaToSdramNs + sdramToFpgaNs) * 1000).round();

  /// All post-init refresh edges seen so far, in ps.
  List<int> get refreshTimesPs => List.unmodifiable(_refreshTimesPs);

  /// True once precharge-all, mode register set and the minimum refresh
  /// count have all happened, in any order.
  bool get initDone => _initDone;

  int _key(int bank, int row, int col) =>
      (bank << 22) | (row << 9) | (col & 0x1FF);

  /// Unwritten words return `(bank << 14) ^ (row << 3) ^ col`, 16 bits.
  static int initialWord(int bank, int row, int col) =>
      ((bank << 14) ^ (row << 3) ^ col) & 0xFFFF;

  int peek(int bank, int row, int col) =>
      _mem[_key(bank, row, col)] ?? initialWord(bank, row, col);

  void poke(int bank, int row, int col, int value) =>
      _mem[_key(bank, row, col)] = value & 0xFFFF;

  int? _pin(Logic l) => l.value.isValid ? l.value.toInt() : null;

  void _err(int t, String rule, String what) =>
      errors.add('t=$t: $rule: $what');

  // --- setup and hold, table 16 tIS/tIH, p21 ---

  /// True from `t == lastPosedge` on, so a change landing on the same tick
  /// as the clk edge counts as a hold failure no matter which of the two
  /// listeners (clk's or this pin's) the simulator happens to run first.
  bool _withinHoldOfLastEdge(int t) =>
      _lastPosedgePs != null &&
      t >= _lastPosedgePs! &&
      t - _lastPosedgePs! < _tIhPs;

  void _onPinChange(String name) {
    final t = Simulator.time;
    if (_withinHoldOfLastEdge(t)) {
      _err(t, 'hold', '$name changed within tIH of the last edge');
    }
    _lastChangePs[name] = t;
  }

  /// True only where both values are valid at some bit and disagree there,
  /// so two merges that each carry x on different bits can still compare
  /// equal if neither one actually conflicts with the other's known bits.
  bool _definitelyDiffers(LogicValue a, LogicValue b) {
    for (var i = 0; i < a.width; i++) {
      final ai = a[i];
      final bi = b[i];
      if (ai.isValid && bi.isValid && ai != bi) return true;
    }
    return false;
  }

  /// The handoff bound is the chip's own tHZ after the last driven edge,
  /// no `d`: the fpga's own drive reaches the chip with the same delay as
  /// the clock, so the chip's tHZ is already the fair-game point for it.
  ///
  /// A later beat still due in the same burst extends this past tHZ: its
  /// own edge, not tHZ, is what actually ends the previous beat's hold.
  bool _isPastHandoff(int t) {
    if (t < _lastDrivenBeatEdgePs + _tHzPs) return false;
    final prev = _beatByEdge[_lastDrivenBeatEdgePs];
    if (prev != null) {
      final (ar, i) = prev;
      final period = _periodPs ?? 0;
      if (ar.skipRelease[i] &&
          _lastDrivenBeatEdgePs + period < ar.endEdgeExclusivePs) {
        return false;
      }
    }
    // oe mode only: a beat already decided but not yet actually driven
    // still protects its own low-z lead-in, [previousEdge + tLZ, edge +
    // tHZ) in chip time, which _lastDrivenBeatEdgePs cannot yet reflect.
    if (_hasFpgaSignals && _withinUpcomingBeatWindow(t)) return false;
    return true;
  }

  bool _withinUpcomingBeatWindow(int t) {
    final period = _periodPs ?? 0;
    for (final entry in _beatByEdge.entries) {
      if (entry.key <= _lastDrivenBeatEdgePs) continue;
      final (ar, i) = entry.value;
      if (ar.masked[i] != false) continue;
      if (t >= entry.key - period + _tLzPs && t < entry.key + _tHzPs) {
        return true;
      }
    }
    return false;
  }

  void _onDqChange(LogicValueChanged e) {
    // `glitch` can fire more than once at the same sim time, so `e` may be
    // a zero-time intermediate value on the way to where the net settles.
    //
    // This flag only hides an x put: a valid put or a release can each
    // reveal a value another driver already held underneath.
    if (_drivingDqPin) return;
    final t = Simulator.time;
    final expected = _modelDrivingDq
        ? _dqDrv.value
        : LogicValue.filled(rules.dataWidth, LogicValue.z);
    if (e.newValue == expected) return;
    final pastHandoff = _isPastHandoff(t);
    final contention = _modelDrivingDq && !pastHandoff;
    // dqm at the last posedge is the write's own mask only from its own
    // edge on, so this only gates the hold check, never the recording a
    // later setup check depends on (see the loop below).
    final dqmAtLastEdge = _lastPosedgePs != null
        ? (_dqmAtEdgePs[_lastPosedgePs!] ?? 0)
        : 0;
    for (var lane = 0; lane < 2; lane++) {
      final old = e.previousValue.getRange(lane * 8, lane * 8 + 8);
      final now = e.newValue.getRange(lane * 8, lane * 8 + 8);
      if (old == now) continue;
      // A release's reveal keeps an earlier catch's real time only if the
      // value has not moved since, bit-masked: the catch was itself an x
      // merge, and the model's own later x-again put can shift which bits
      // that is without the fpga's value moving at all.
      final lastSeen = _lastSeenDqValue[lane];
      final seenThisBeat =
          _lastDrivenBeatEdgePs != _negInf &&
          _lastChangeDqPs[lane] >= _lastDrivenBeatEdgePs &&
          lastSeen != null &&
          !_definitelyDiffers(lastSeen, now);
      // Conservative: this can flag tIS where a real, clock-registered
      // phy could never actually land that late.
      if (!(_releasingDqPin && seenThisBeat)) _lastChangeDqPs[lane] = t;
      _lastSeenDqValue[lane] = now;
      final masked = (dqmAtLastEdge >> lane) & 1 == 1;
      if (!contention && !masked && _withinHoldOfLastEdge(t)) {
        _err(t, 'hold', 'dq lane $lane changed within tIH of the last edge');
      }
    }
    if (contention) {
      _err(
        t,
        'dq-contention',
        'the net disagreed with the model while it was driving',
      );
      return;
    }
    if (!pastHandoff) {
      _err(
        t,
        'dq-contention',
        'fpga drove dq before the hiz time after the last beat',
      );
    }
  }

  /// Shared by a fresh fpga oe assert and by this model starting to drive
  /// into one already asserted (see `startDrive`). Past handoff, nothing
  /// is wrong. Before it, the fault is contention if this model is also
  /// driving (no exemption for the two drivers' values happening to
  /// agree: oe mode knows both are really on), otherwise the fpga simply
  /// jumped the gun.
  void _checkFpgaDriveHandoff(int t) {
    final pastHandoff = _isPastHandoff(t);
    if (_modelDrivingDq && !pastHandoff) {
      _err(
        t,
        'dq-contention',
        'the net disagreed with the model while it was driving',
      );
    } else if (!pastHandoff && !_modelDrivingDq) {
      _err(
        t,
        'dq-contention',
        'fpga drove dq before the hiz time after the last beat',
      );
    }
  }

  /// Marks lane [lane]'s setup/hold bookkeeping as changed right now,
  /// used by both an oe edge (the net's value changes whichever way oe
  /// moves, even if out itself does not) and a real out change.
  void _recordFpgaLaneChange(int t, int lane) {
    _lastChangeDqPs[lane] = t;
    final dqmAtLastEdge = _lastPosedgePs != null
        ? (_dqmAtEdgePs[_lastPosedgePs!] ?? 0)
        : 0;
    final masked = (dqmAtLastEdge >> lane) & 1 == 1;
    if (!masked && _withinHoldOfLastEdge(t)) {
      _err(t, 'hold', 'dq lane $lane changed within tIH of the last edge');
    }
  }

  /// oe and out can change in the same instant (one put right after the
  /// other), so a handler reacting to either must wait for both: deferred
  /// to the same sim time, after the pair that triggered it has settled,
  /// reading oe/out live instead of relying on processing order.
  void _onFpgaOeChange(LogicValueChanged e) {
    final t = Simulator.time;
    Simulator.registerAction(t, () {
      for (var lane = 0; lane < 2; lane++) {
        _recordFpgaLaneChange(t, lane);
      }
      if (_fpgaOeAssertedChip) _checkFpgaDriveHandoff(t);
    });
  }

  /// Direct replacement for the net-inferred lane loop in [_onDqChange]:
  /// [fpgaDqOut] is the fpga's own value, so a change here is always real
  /// and never an x/model merge artifact, with no backdating needed.
  void _onFpgaOutChange(LogicValueChanged e) {
    final t = Simulator.time;
    Simulator.registerAction(t, () {
      if (!_fpgaOeAssertedChip) return;
      for (var lane = 0; lane < 2; lane++) {
        final old = e.previousValue.getRange(lane * 8, lane * 8 + 8);
        final now = e.newValue.getRange(lane * 8, lane * 8 + 8);
        if (old == now) continue;
        _recordFpgaLaneChange(t, lane);
      }
    });
  }

  void _checkSetupAll(int t) {
    for (final name in _lastChangePs.keys) {
      final lc = _lastChangePs[name]!;
      if (t - lc < _tIsPs)
        _err(t, 'setup', '$name changed within tIS of this edge');
    }
    // This runs before command dispatch, so _modelDrivingDq can still be
    // true here for a read a write is about to cut on this very edge (the
    // cut itself happens further down in _onPosedge). _lastChangeDqPs is
    // only ever set from a real fpga-driven change (see _onDqChange), so
    // checking it here does not need to wait for the model to let go.
    final dqmNow = _pin(_dqm) ?? 0;
    for (var lane = 0; lane < 2; lane++) {
      if ((dqmNow >> lane) & 1 == 1) continue; // masked lane, don't care.
      final lc = _lastChangeDqPs[lane];
      if (lc != _negInf && t - lc < _tIsPs) {
        _err(t, 'setup', 'dq lane $lane changed within tIS of this edge');
      }
    }
  }

  // --- clock, table 16 tCH/tCL/tCK, p21 ---

  void _onNegedge() {
    final t = Simulator.time;
    if (_lastPosedgePs != null && t - _lastPosedgePs! < _tChPs) {
      _err(t, 'clock', 'tCH shorter than the minimum high time');
    }
    _lastNegedgePs = t;
  }

  void _onPosedge() {
    final t = Simulator.time;
    if (_lastNegedgePs != null && t - _lastNegedgePs! < _tClPs) {
      _err(t, 'clock', 'tCL shorter than the minimum low time');
    }
    if (_lastPosedgePs != null) {
      _periodPs = t - _lastPosedgePs!;
      if (_cl != null &&
          _periodPs! < ((rules.tCkMinByCl[_cl]!) * 1000).round()) {
        _err(
          t,
          'cl-clock',
          'tCK shorter than tCkMin for the active CAS latency',
        );
      }
    }
    _checkRasMaxAll(t);

    _firstEdgePs ??= t;
    final dqmNow = _pin(_dqm) ?? 0;
    _dqmAtEdgePs[t] = dqmNow;
    // Only a handful of past edges are ever looked up again (dqm read
    // latency and the 2-beat masking lookahead, plus a cut's catch-up over a
    // few pending beats), so drop anything older.
    final period = _periodPs ?? 0;
    if (period > 0) {
      _dqmAtEdgePs.removeWhere((key, _) => key < t - 12 * period);
      _beatByEdge.removeWhere((key, _) => key < t - 12 * period);
    }

    final ckeNow = _pin(_cke);
    if (ckeNow == 1 && _ckeWentHighAtPs == null) {
      _ckeWentHighAtPs = t;
      if (t - _firstEdgePs! < _powerUpPs) {
        _err(t, 'power-up', 'cke raised before powerUpNs since the first edge');
      }
    }
    if (ckeNow == 0 && _ckeWentHighAtPs != null && _initDone) {
      // A controller reset after init. A real device's contents are not
      // guaranteed to survive this, but the model keeps its memory map so
      // a test can still check what the controller chooses to preserve.
      _restartPowerUp(t);
    }
    if (ckeNow == 0 && _ckeWentHighAtPs != null) {
      _err(
        t,
        'unsupported',
        _initDone
            ? 'cke low after init (power down and self refresh are not modeled)'
            : 'cke dropped before init finished (power down and self refresh are not modeled)',
      );
    }

    final csN = _pin(_csN);
    if (csN == null) {
      _advanceActiveRead(t);
      _checkSetupAll(t);
      _ckePrevEdgeHigh = ckeNow == 1;
      _lastPosedgePs = t;
      return;
    }
    if (csN == 1) {
      _advanceActiveRead(t);
      _checkSetupAll(t);
      _ckePrevEdgeHigh = ckeNow == 1;
      _lastPosedgePs = t;
      return;
    }

    final ras = _pin(_rasN),
        cas = _pin(_casN),
        we = _pin(_weN),
        ba = _pin(_ba),
        a = _pin(_addr);
    if (ras == null || cas == null || we == null || ba == null || a == null) {
      _err(t, 'setup', 'a command pin was not valid while cs_n was low');
      _advanceActiveRead(t);
      _checkSetupAll(t);
      _ckePrevEdgeHigh = ckeNow == 1;
      _lastPosedgePs = t;
      return;
    }
    final cmd3 = (ras << 2) | (cas << 1) | we;
    if (cmd3 != 7) {
      // not a nop: cke and refresh-busy gate every real command.
      if (!_ckePrevEdgeHigh) {
        _err(t, 'cke', 'a command needs cke high on the previous edge');
      }
      if (t < _refreshBusyUntilPs) {
        if (cmd3 == 1) {
          _err(
            t,
            'refresh-busy',
            'a refresh was issued before tRFC of the previous one elapsed',
          );
        } else {
          _err(
            t,
            'tRFC',
            'a command was issued before tRFC of the last refresh elapsed',
          );
        }
      } else if (_lastMrsPs != _negInf) {
        final nckPs = rules.tMrdNck * (_periodPs ?? 0);
        final thresholdPs = nckPs > _tMrdPs ? nckPs : _tMrdPs;
        if (t - _lastMrsPs < thresholdPs) {
          _err(
            t,
            'tMRD',
            'a command was issued before tMRD of the mode register set elapsed',
          );
        }
      }
      switch (cmd3) {
        case 0:
          _handleMrs(t, ba, a);
        case 1:
          _handleRefresh(t);
        case 2:
          _handlePrecharge(t, ba, a);
        case 3:
          _handleActivate(t, ba, a);
        case 4:
          _handleWrite(t, ba, a);
        case 5:
          _handleRead(t, ba, a);
        case 6:
          _err(t, 'unsupported', 'burst stop is not supported');
      }
      log.add(
        SdramModelCommand(
          timePs: t,
          kind: const [
            'mrs',
            'refresh',
            'precharge',
            'activate',
            'write',
            'read',
            'burst-stop',
            'nop',
          ][cmd3],
          bank: ba,
          a: a,
        ),
      );
    }
    // A command this same edge may have just cut the active read (precharge)
    // or started a new one (read), so beats for this edge are driven last.
    _advanceActiveRead(t);
    // After dispatch, not before: a write's forced release of an overlapping
    // read can reveal the fpga's already-driven dq right on this edge, and
    // the setup check needs to see that, not a stale pre-dispatch value.
    _checkSetupAll(t);
    _ckePrevEdgeHigh = ckeNow == 1;
    _lastPosedgePs = t;
  }

  bool _anyBankActive() => _banks.any((b) => b.active);

  void _updateInitDone() {
    if (!_initDone &&
        _prechargedAll &&
        _modeSet &&
        _refreshesSoFar >= rules.initRefreshesMin) {
      _initDone = true;
    }
  }

  // --- mode register, table 5 p13, tables 6-11 p14-16 ---

  void _handleMrs(int t, int ba, int a) {
    if (_anyBankActive()) {
      _err(t, 'state', 'mode register set while a bank is active');
    } else if (_allIdleSincePs != _negInf && t - _allIdleSincePs < _tRpPs) {
      _err(
        t,
        'tRP',
        'mode register set before tRP since the last precharge elapsed',
      );
    }
    if (!_anyMrsEver && !_prechargedAll) {
      _err(t, 'init-order', 'mode register set before precharge-all');
    }
    _anyMrsEver = true;
    final a7 = (a >> 7) & 1, a8 = (a >> 8) & 1;
    final a10 = (a >> 10) & 1, a11 = (a >> 11) & 1, a12 = (a >> 12) & 1;
    final a3 = (a >> 3) & 1, a9 = (a >> 9) & 1;
    final cl4 = (a >> 4) & 7;
    final bl3 = a & 7;
    var ok = true;
    if (ba != 0) {
      _err(t, 'mode-register', 'BA must be 0 during a mode register set');
      ok = false;
    }
    if (a10 != 0 || a11 != 0 || a12 != 0) {
      _err(
        t,
        'mode-register',
        'A10, A11 and A12 must be 0 during a mode register set',
      );
      ok = false;
    }
    if (a7 != 0 || a8 != 0) {
      _err(t, 'mode-register', 'the test mode field (A8:A7) must be 00');
      ok = false;
    }
    int? cl;
    if (cl4 == 2) {
      cl = 2;
    } else if (cl4 == 3) {
      cl = 3;
    } else {
      _err(t, 'mode-register', 'the CAS latency field is a reserved value');
      ok = false;
    }
    if (![0, 1, 2, 3, 7].contains(bl3)) {
      _err(t, 'mode-register', 'the burst length field is a reserved value');
      ok = false;
    } else if (bl3 != 3) {
      _err(t, 'unsupported', 'only burst length 8 is supported');
      ok = false;
    }
    if (a3 != 0) {
      _err(t, 'unsupported', 'interleave burst order is not supported');
      ok = false;
    }
    if (a9 != 1) {
      _err(t, 'unsupported', 'burst-read-burst-write is not supported');
      ok = false;
    }
    if (ok) {
      _cl = cl;
      _modeSet = true;
    }
    _lastMrsPs = t;
    _updateInitDone();
  }

  // --- refresh, command 12, p17 ---

  void _handleRefresh(int t) {
    if (_anyBankActive()) {
      _err(t, 'state', 'refresh issued while a bank is active');
    } else if (_allIdleSincePs != _negInf && t - _allIdleSincePs < _tRpPs) {
      _err(t, 'tRP', 'refresh before tRP since the last precharge elapsed');
    }
    if (_refreshesSoFar == 0 && !_prechargedAll) {
      _err(t, 'init-order', 'refresh before precharge-all');
    }
    _refreshBusyUntilPs = t + _tRfcPs;
    _refreshesSoFar++;
    final policy = refreshPolicy;
    if (policy != null) {
      _policyRefreshCount++;
      if (_policyRefreshCount == policy.initRefreshes) {
        // t0 is this refresh, fixed: not whichever command happens to
        // come after it.
        _t0Ps = t;
      } else if (_policyRefreshCount > policy.initRefreshes) {
        _postInitRefreshN = _policyRefreshCount - policy.initRefreshes;
        _checkRefreshWindow(t, _postInitRefreshN);
        _refreshTimesPs.add(t);
      }
    }
    _updateInitDone();
  }

  void _checkRefreshWindow(int t, int n) {
    final policy = refreshPolicy;
    if (policy == null) return;
    final periodPs = (policy.periodNs * 1000).round();
    final latencyPs = (policy.maxLatencyNs * 1000).round();
    final lower = _t0Ps! + (n - policy.maxPulledIn) * periodPs;
    final upper = _t0Ps! + (n + policy.maxPostponed) * periodPs + latencyPs;
    if (t < lower || t > upper) {
      _err(
        t,
        'refresh-window',
        'refresh n=$n fell outside [$lower, $upper] ps',
      );
    }
  }

  void _checkRefreshRateFormula() {
    final policy = refreshPolicy!;
    final periodPs = (policy.periodNs * 1000).round();
    final latencyPs = (policy.maxLatencyNs * 1000).round();
    final totalPs =
        (rules.refreshCount + policy.maxPostponed + policy.maxPulledIn) *
            periodPs +
        latencyPs;
    if (totalPs > (rules.refreshWindowNs * 1000).round()) {
      _err(
        0,
        'refresh-window',
        'the refresh policy cannot complete 8192 refreshes within 64ms',
      );
    }
  }

  // --- precharge, commands 2 and 3, p8 ---

  void _handlePrecharge(int t, int ba, int a) {
    final all = ((a >> 10) & 1) == 1;
    for (var i = 0; i < _banks.length; i++) {
      if (!all && i != ba) continue;
      final bank = _banks[i];
      if (bank.active) {
        if (t - bank.activatedAtPs < _tRasMinPs) {
          _err(t, 'tRAS-min', 'precharge before tRAS min elapsed');
        }
        if (bank.lastWriteAtPs != _negInf && t - bank.lastWriteAtPs < _tWrPs) {
          _err(t, 'tWR', 'precharge before tWR since the last write elapsed');
        }
        bank.active = false;
        bank.rasMaxReported = false;
      }
      bank.lastPrechargeAtPs = t;
    }
    if (all) _prechargedAll = true;
    if (_banks.every((b) => !b.active)) _allIdleSincePs = t;

    final ar = _activeRead;
    if (ar != null && _cl != null && (all || ba == _readBank(ar))) {
      final cutAt = t + _cl! * (_periodPs ?? 0);
      if (cutAt < ar.endEdgeExclusivePs) {
        ar.endEdgeExclusivePs = cutAt;
        _advanceReadState(ar, t);
      }
    }
    // Precharging an already-idle bank is legal (table 4, state "Any", p7).
    _updateInitDone();
  }

  int _readBank(_ReadState ar) => ar.order[0].$1;

  // --- activate, command 1, p7 ---

  void _handleActivate(int t, int ba, int a) {
    final bank = _banks[ba];
    if (bank.active) {
      _err(t, 'state', 'activate to a bank that is already active');
    }
    if (bank.lastActivateAtPs != _negInf &&
        t - bank.lastActivateAtPs < _tRcPs) {
      _err(
        t,
        'tRC',
        'activate before tRC since the last activate of this bank elapsed',
      );
    }
    if (_lastActivateBank != null &&
        _lastActivateBank != ba &&
        t - _lastActivateEdgePs! < _tRrdPs) {
      _err(
        t,
        'tRRD',
        'activate before tRRD since the last activate of another bank elapsed',
      );
    }
    if (bank.lastPrechargeAtPs != _negInf &&
        t - bank.lastPrechargeAtPs < _tRpPs) {
      _err(t, 'tRP', 'activate before tRP since the last precharge elapsed');
    }
    bank.active = true;
    bank.row = a & ((1 << rules.rowWidth) - 1);
    bank.activatedAtPs = t;
    bank.lastActivateAtPs = t;
    bank.rasMaxReported = false;
    _lastActivateEdgePs = t;
    _lastActivateBank = ba;

    if (!_anyActivateEver) {
      _anyActivateEver = true;
      if (!_prechargedAll)
        _err(t, 'init-order', 'activate before precharge-all');
      if (!_modeSet)
        _err(t, 'init-order', 'activate before the mode register was set');
      if (_refreshesSoFar < rules.initRefreshesMin) {
        _err(t, 'init-order', 'activate before the minimum init refreshes');
      }
    }
  }

  void _restartPowerUp(int t) {
    _firstEdgePs = t;
    _ckeWentHighAtPs = null;
    _initDone = false;
    _prechargedAll = false;
    _modeSet = false;
    _refreshesSoFar = 0;
    _anyActivateEver = false;
    _anyMrsEver = false;
    _t0Ps = null;
    _policyRefreshCount = 0;
    _postInitRefreshN = 0;
  }

  void _checkRasMaxAll(int t) {
    for (final bank in _banks) {
      if (bank.active &&
          !bank.rasMaxReported &&
          t - bank.activatedAtPs > _tRasMaxPs) {
        _err(t, 'tRAS-max', 'a bank stayed open past tRAS max');
        bank.rasMaxReported = true;
      }
    }
  }

  // --- write, command 6, p11 ---

  void _handleWrite(int t, int ba, int a) {
    final bank = _banks[ba];
    if (!bank.active) {
      _err(t, 'state', 'write to a bank that is not active');
      return;
    }
    if (t - bank.activatedAtPs < _tRcdPs) {
      _err(t, 'tRCD', 'write before tRCD since the activate elapsed');
    }
    if (((a >> 10) & 1) == 1) {
      _err(t, 'unsupported', 'auto precharge on write is not supported');
    }

    final ar = _activeRead;
    if (ar != null && t < ar.endEdgeExclusivePs) {
      final period = _periodPs ?? 0;
      // Both dqm bits, not just one: a single masked byte still leaves the
      // other byte contending with the write (command 4 text, p9).
      final okDqm =
          (_dqmAtEdgePs[t - period] ?? 0) == 3 &&
          (_dqmAtEdgePs[t - 2 * period] ?? 0) == 3;
      if (!okDqm) {
        _err(
          t,
          'dqm-before-write',
          'a write cut a read without both dqm bits high the 2 edges before',
        );
      }
      // The write owns the bus from this edge (fig 7/8, p10): a surviving
      // beat's own tHz release could still be pending past this edge, so
      // release now rather than waiting for it.
      ar.endEdgeExclusivePs = t;
      _advanceReadState(ar, t);
      _activeRead = null;
      _modelDrivingDq = false;
      _releasingDqPin = true;
      _dqEn.put(0);
      _releasingDqPin = false;
    }

    bank.lastWriteAtPs = t;
    final dqVal = _dq.value;
    final dqmVal = _pin(_dqm);
    if (dqmVal == null) {
      _err(t, 'setup', 'dqm was not valid at the write edge');
      return;
    }
    final lowMasked = (dqmVal & 1) == 1;
    final highMasked = (dqmVal & 2) == 2;
    final lowByte = dqVal.getRange(0, 8);
    final highByte = dqVal.getRange(8, 16);
    if ((!lowMasked && !lowByte.isValid) ||
        (!highMasked && !highByte.isValid)) {
      _err(
        t,
        'setup',
        'dq was not valid on an unmasked byte at the write edge',
      );
      return;
    }
    final col = a & ((1 << rules.colWidth) - 1);
    final key = _key(ba, bank.row!, col);
    var merged = _mem[key] ?? initialWord(ba, bank.row!, col);
    if (!lowMasked) merged = (merged & 0xFF00) | lowByte.toInt();
    if (!highMasked) merged = (merged & 0x00FF) | (highByte.toInt() << 8);
    _mem[key] = merged & 0xFFFF;
  }

  // --- read, command 4, p8 ---

  void _handleRead(int t, int ba, int a) {
    final bank = _banks[ba];
    if (!bank.active) {
      _err(t, 'state', 'read from a bank that is not active');
      return;
    }
    if (t - bank.activatedAtPs < _tRcdPs) {
      _err(t, 'tRCD', 'read before tRCD since the activate elapsed');
    }
    if (((a >> 10) & 1) == 1) {
      _err(t, 'unsupported', 'auto precharge on read is not supported');
    }
    if (_cl == null) return;

    // A read interrupting another read keeps the old burst up to this
    // read's own first beat (fig 5, p9), not cut off at this command edge.
    final oldAr = _activeRead;
    if (oldAr != null) {
      final cutAt = t + _cl! * (_periodPs ?? 0);
      if (cutAt < oldAr.endEdgeExclusivePs) {
        oldAr.endEdgeExclusivePs = cutAt;
      }
      _advanceReadState(oldAr, t);
    }

    final colBase = (a & ((1 << rules.colWidth) - 1)) & ~7;
    final start = a & 7;
    final order = [
      for (var k = 0; k < 8; k++) (ba, bank.row!, colBase | ((start + k) & 7)),
    ];
    _activeRead = _ReadState(
      t + _cl! * (_periodPs ?? 0),
      order,
      _periodPs ?? 0,
    );
  }

  /// Schedules (or, if its decision edge has already passed, runs now) the
  /// drive timeline for every beat whose masking is now decidable: dqm
  /// sampled at `edge - 2*tCK` masks the beat at `edge` (command 4 text p9,
  /// command 6 text p11), so a beat can only be decided once that edge has
  /// happened, which may be later than the edge it is processed on here.
  void _advanceReadState(_ReadState ar, int t) {
    final period = _periodPs ?? 0;
    if (period == 0) return;
    while (ar.nextUndecided < 8) {
      final edgeI = ar.firstBeatEdgePs + ar.nextUndecided * period;
      if (edgeI - 2 * period > t) break;
      _decideAndScheduleBeat(ar, ar.nextUndecided);
      ar.nextUndecided++;
    }
  }

  void _advanceActiveRead(int t) {
    final ar = _activeRead;
    if (ar == null) return;
    _advanceReadState(ar, t);
    if (ar.nextUndecided >= 8) _activeRead = null;
  }

  /// Drive timeline for one beat, fig 20 p24: the value commanded at the
  /// edge before this one becomes valid at `previousEdge + d + tAC` and
  /// holds until `edge + d + tOH`, with x everywhere else in the slot.
  /// Released to z (not x) by `edge + d + tHZ`, the same edge tOH is
  /// measured from. A masked beat (dqm sampled 2 edges early) never shows
  /// data: it is z for the whole slot.
  ///
  /// Mid-burst, the beat before this one is still protected: its tOH hold
  /// runs through to `previousEdge + d + tOH`, so this beat's own lead-in
  /// (x, or z if masked) only starts there, not at `previousEdge + d +
  /// tLZ`, unless the bus was already released (the previous edge drove
  /// nothing, or nothing drove at all). Symmetrically, when this beat is
  /// unmasked it marks the beat before it to skip its own tHZ release, so
  /// a continuous burst never opens a z gap between beats. Every action
  /// re-checks the cut boundary at fire time, since a later command may
  /// shorten the burst after this was scheduled.
  void _decideAndScheduleBeat(_ReadState ar, int i) {
    final period = _periodPs ?? 0;
    final edgeI = ar.firstBeatEdgePs + i * period;
    if (edgeI >= ar.endEdgeExclusivePs) return;
    final previousEdge = edgeI - period;
    final masked = (_dqmAtEdgePs[edgeI - 2 * period] ?? 0) != 0;
    final (bank, row, col) = ar.order[i];
    final value = peek(bank, row, col);

    final prev = _beatByEdge[previousEdge];
    final continuing =
        prev != null &&
        prev.$1.masked[prev.$2] == false &&
        previousEdge < prev.$1.endEdgeExclusivePs;
    if (continuing && !masked) prev.$1.skipRelease[prev.$2] = true;
    ar.masked[i] = masked;
    _beatByEdge[edgeI] = (ar, i);

    bool stillSurvives() => edgeI < ar.endEdgeExclusivePs;

    void startDrive(LogicValue v) {
      if (!stillSurvives()) return;
      // Whether the bus was released in time for a fresh beat is W2's own
      // check, at the chip's low-z deadline (previousEdge + tLZ), not
      // here: by the time this runs, in fpga time, an early fpga drive
      // can already be gone again.
      final fpgaAlreadyOn = _hasFpgaSignals
          ? _fpgaOeAssertedChip
          : !_dq.value.isFloating;
      _modelDrivingDq = true;
      _lastDrivenBeatEdgePs = edgeI;
      final isX = !v.isValid;
      if (_hasFpgaSignals) {
        // oe/out give a direct answer: no need to involve _onDqChange, and
        // no exemption for the two values happening to agree either: oe
        // mode knows both drivers are really on, which is the violation.
        _dqDrv.put(v);
        _dqEn.put(1);
        if (!isX && fpgaAlreadyOn) {
          _err(
            Simulator.time,
            'dq-contention',
            'the net disagreed with the model while it was driving',
          );
        }
      } else {
        // Only an x put is unconditionally this model's own value: a
        // valid value can still disagree with the net if another driver
        // is also on it, which must reach _onDqChange like any put would.
        if (isX) _drivingDqPin = true;
        _dqDrv.put(v);
        _dqEn.put(1);
        if (isX) _drivingDqPin = false;
      }
    }

    void release() {
      if (!stillSurvives()) return;
      // The next beat may have been decided unmasked and asked us to skip,
      // but only honor that if it still actually survives right now: a
      // later cut can have excluded it since then, in which case nothing
      // else will release the bus unless this does.
      if (ar.skipRelease[i] && edgeI + period < ar.endEdgeExclusivePs) return;
      // Not _lastDrivenBeatEdgePs here: a masked beat's own release is its
      // only action, and it never drove data, so it must not move that
      // edge away from whichever beat last actually did (startDrive
      // already set it for an unmasked beat's own release).
      _modelDrivingDq = false;
      _releasingDqPin = true;
      _dqEn.put(0);
      _releasingDqPin = false;
    }

    if (masked) {
      // A masked beat never drives: whatever the slot was already showing
      // (the previous beat's own hold, or z) simply continues until this
      // beat's own edge + d + tHZ, not a lead-in borrowed from "continuing"
      // (that borrowed point can coincide with the previous beat's own
      // x-again action and race it).
      _runAt(edgeI + _dPs + _tHzPs, release);
      return;
    }
    if (!continuing) {
      // The chip's own low-z deadline for the first beat after a quiet
      // bus, in chip time (no d): startDrive's own check runs later, in
      // fpga time, so an fpga drive that is already gone again by then
      // would otherwise slip through even though it was on right at the
      // deadline.
      _runAt(previousEdge + _tLzPs, () {
        if (!stillSurvives()) return;
        final fpgaAlreadyOn = _hasFpgaSignals
            ? _fpgaOeAssertedChip
            : !_dq.value.isFloating;
        if (fpgaAlreadyOn) {
          _err(
            Simulator.time,
            'dq-contention',
            'dq was not released when the model started to drive',
          );
        }
      });
    }
    final leadInPs = continuing
        ? previousEdge + _dPs + _tOhPs
        : previousEdge + _dPs + _tLzPs;
    final x = LogicValue.filled(rules.dataWidth, LogicValue.x);
    _runAt(leadInPs, () => startDrive(x));
    _runAt(
      previousEdge + _dPs + ((rules.tAcByCl[_cl] ?? 0) * 1000).round(),
      () => startDrive(LogicValue.ofInt(value, rules.dataWidth)),
    );
    _runAt(edgeI + _dPs + _tOhPs, () => startDrive(x));
    _runAt(edgeI + _dPs + _tHzPs, release);
  }

  /// Runs [body] now if [atPs] has already passed (catching a beat up to a
  /// cut decided after its natural decision edge), otherwise schedules it.
  void _runAt(int atPs, void Function() body) {
    if (atPs <= Simulator.time) {
      body();
    } else {
      Simulator.registerAction(atPs, body);
    }
  }

  /// End-of-run checks: any bank still open past tRAS max, and a refresh
  /// that is now overdue even though none was attempted.
  void finish() {
    final t = Simulator.time;
    _checkRasMaxAll(t);
    final policy = refreshPolicy;
    if (policy != null && _initDone && _t0Ps != null) {
      final periodPs = (policy.periodNs * 1000).round();
      final latencyPs = (policy.maxLatencyNs * 1000).round();
      final n = _postInitRefreshN + 1;
      final upper = _t0Ps! + (n + policy.maxPostponed) * periodPs + latencyPs;
      if (t > upper) {
        _err(
          t,
          'refresh-window',
          'refresh n=$n is overdue at the end of the run',
        );
      }
    }
  }
}

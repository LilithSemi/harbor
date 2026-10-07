import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';

/// Pin-level DDR3 DRAM model for the full-stack [Ddr3PhyEcp5] simulation.
///
/// It sees only the DDR3 pins, the way a real device does:
///  - Commands are decoded from CS#, RAS#, CAS#, WE#, BA, A on each CK rising
///    edge (while CKE is high and RESET# is high).
///  - CL, CWL, AL and the burst length come from the mode registers the
///    controller wrote with MRS.
///  - A WRITE expects DQS driven in the CK before the burst (the preamble),
///    then the first DQS rising edge at CWL after the command, and takes each DQ and DM beat just before its
///    DQS edge (DQ leads DQS by a half beat in the gearbox models). A wrong
///    strobe, DQ, or DM beat makes the write store garbage and logs an error.
///  - A READ drives the DQS preamble, then 8 beats of DQ with DQS edge
///    aligned to them, starting CL after the command. The beats trail CK by
///    T/4 (the IDDRX2DQA model samples on ECLK edges, so that is mid-beat),
///    plus [readSkewBeats] half-CK beats of round-trip delay.
///  - When it is not reading or taking a write, it drives a fixed non-zero
///    pattern on DQ, so a read gate that misses the burst cannot pass.
class Ddr3PinDramModel {
  final DdrParams params;

  /// Extra round-trip delay on reads, in half-CK beats.
  final int readSkewBeats;

  /// DRAM byte lane masked by each DM pin (the board wiring). Identity when
  /// null.
  final List<int>? dmRemapping;

  /// Protocol errors seen so far (write strobe, DQ, DM, or mode problems).
  final List<String> errors = [];

  /// Reads served so far.
  int reads = 0;

  /// Writes taken so far.
  int writes = 0;

  int get _dq => params.dqBits * params.lanes;

  final Logic _ck;
  final Logic _cke;
  final Logic _resetN;
  final Logic _csN;
  final Logic _rasN;
  final Logic _casN;
  final Logic _weN;
  final Logic _ba;
  final Logic _addr;
  final Logic _dm;
  final LogicNet _dqPad;
  final LogicNet _dqsPad;

  final Logic _dqDrv;
  final Logic _dqEn;
  final Logic _dqsDrv;
  final Logic _dqsEn;

  final Map<int, int> _mr = {};
  final Map<int, int> _openRow = {};
  final Map<String, List<int>> _mem = {};

  int? _lastCkRise;
  int? _tck;

  /// End of the last write burst (its last DQS edge).
  int _lastWriteEnd = -1;

  /// Time until which DQ must be released for a write.
  int _dqReleaseUntil = -1;

  /// Time until which DQ is driven by a read burst.
  int _readUntil = -1;

  int get _idle => 0xA5C3 & ((1 << _dq) - 1);

  Ddr3PinDramModel(
    this.params, {
    required Logic ck,
    required Logic cke,
    required Logic resetN,
    required Logic csN,
    required Logic rasN,
    required Logic casN,
    required Logic weN,
    required Logic ba,
    required Logic addr,
    required Logic dm,
    required LogicNet dqPad,
    required LogicNet dqsPad,
    this.readSkewBeats = 0,
    this.dmRemapping,
  }) : _ck = ck,
       _cke = cke,
       _resetN = resetN,
       _csN = csN,
       _rasN = rasN,
       _casN = casN,
       _weN = weN,
       _ba = ba,
       _addr = addr,
       _dm = dm,
       _dqPad = dqPad,
       _dqsPad = dqsPad,
       _dqDrv = Logic(name: 'dram_dq_drv', width: params.dqBits * params.lanes),
       _dqEn = Logic(name: 'dram_dq_en'),
       _dqsDrv = Logic(name: 'dram_dqs_drv', width: params.lanes),
       _dqsEn = Logic(name: 'dram_dqs_en') {
    _dqPad <= TriStateBuffer(_dqDrv, enable: _dqEn, name: 'dram_dq').out;
    _dqsPad <= TriStateBuffer(_dqsDrv, enable: _dqsEn, name: 'dram_dqs').out;
    Simulator.injectAction(() {
      _dqDrv.put(_idle);
      _dqEn.put(1);
      _dqsDrv.put(0);
      _dqsEn.put(0);
    });
    _ck.posedge.listen((_) => _onCkRise());
  }

  int? _pin(Logic l) => l.value.isValid ? l.value.toInt() : null;

  int get _cl => ((((_mr[0] ?? 0) >> 4) & 7) + 4);
  int get _cwl => ((((_mr[2] ?? 0) >> 3) & 7) + 5);

  void _onCkRise() {
    final t = Simulator.time;
    if (_lastCkRise != null) _tck = t - _lastCkRise!;
    _lastCkRise = t;
    if (_pin(_resetN) != 1 || _pin(_cke) != 1 || _pin(_csN) != 0) return;
    final ras = _pin(_rasN);
    final cas = _pin(_casN);
    final we = _pin(_weN);
    final ba = _pin(_ba);
    final a = _pin(_addr);
    if (ras == null || cas == null || we == null || ba == null || a == null) {
      errors.add('t=$t: command pins not valid while CS# is low');
      return;
    }
    final cmd = (ras << 2) | (cas << 1) | we;
    switch (cmd) {
      case 0: // MRS
        _mr[ba] = a;
        if (ba == 0 && (a & 3) != 0) errors.add('t=$t: MR0 is not BL8');
        if (ba == 1 && ((a >> 3) & 3) != 0) errors.add('t=$t: AL is not 0');
      case 3: // ACT
        _openRow[ba] = a;
      case 4: // WRITE
        _write(t, ba, a);
      case 5: // READ
        _read(t, ba, a);
      default: // REF, PRE, ZQ
        break;
    }
  }

  String _key(int ba, int a) => '$ba:${_openRow[ba]}:${a & 0x3FF & ~7}';

  void _write(int t, int ba, int a) {
    final period = _tck;
    if (period == null) return;
    writes++;
    final q = period ~/ 4;
    final e0 = t + _cwl * period;
    final key = _key(ba, a);
    final beats = List<int?>.filled(8, null);
    final masks = List<int?>.filled(8, null);
    final bad = <String>[];

    int? dqs(int at) {
      final v = _dqsPad.value;
      if (!v.isValid) return null;
      return v.toInt();
    }

    final allOne = (1 << params.lanes) - 1;
    void expectDqs(int at, int level, String what) {
      Simulator.registerAction(at, () {
        final v = dqs(at);
        if (v != (level == 1 ? allOne : 0)) {
          bad.add('$what: DQS ${_dqsPad.value} at $at');
        }
      });
    }

    // DQ released from 2 CK before the burst to a CK after it. Not at the
    // command: read data may still be on the bus then.
    final release = e0 + 5 * period;
    if (release > _dqReleaseUntil) _dqReleaseUntil = release;
    Simulator.registerAction(e0 - 2 * period, () => _dqEn.put(0));
    Simulator.registerAction(release, _maybeIdle);

    // A write right behind another one (tCCD) has no preamble: the strobe
    // keeps toggling.
    final seamless = _lastWriteEnd == e0;
    _lastWriteEnd = e0 + 4 * period;
    // Preamble: DQS must be driven in the CK before the first edge. Its
    // level is not checked: litedram's DQS pattern (0101) shows a high
    // quarter in that CK in these models, and TN-02035 gives no cell timing
    // that could say where the silicon puts it.
    if (!seamless) {
      Simulator.registerAction(e0 - 3 * q, () {
        if (!_dqsPad.value.isValid) {
          bad.add('preamble: DQS ${_dqsPad.value} at ${e0 - 3 * q}');
        }
      });
    }
    for (var k = 0; k < 8; k++) {
      final edge = e0 + k * (period ~/ 2);
      expectDqs(edge - q, k.isEven ? 0 : 1, 'beat $k before edge');
      expectDqs(edge + q, k.isEven ? 1 : 0, 'beat $k after edge');
      Simulator.registerAction(edge - q, () {
        final d = _dqPad.value;
        final m = _dm.value;
        if (d.isValid) beats[k] = d.toInt();
        if (m.isValid) masks[k] = m.toInt();
        if (!d.isValid || !m.isValid) bad.add('beat $k: DQ $d DM $m');
      });
    }
    Simulator.registerAction(e0 + 4 * period, () {
      if (bad.isNotEmpty) {
        errors.add('write at $t: ${bad.join('; ')}');
        _mem.remove(key);
        return;
      }
      final old = _mem[key] ?? List<int>.filled(8, _idle);
      final remap = dmRemapping ?? [for (var l = 0; l < params.lanes; l++) l];
      final merged = [
        for (var k = 0; k < 8; k++)
          () {
            var v = old[k];
            for (var pin = 0; pin < params.lanes; pin++) {
              if ((masks[k]! >> pin) & 1 == 1) continue;
              final lane = remap[pin];
              final byte = 0xFF << (8 * lane);
              v = (v & ~byte) | (beats[k]! & byte);
            }
            return v;
          }(),
      ];
      _mem[key] = merged;
    });
  }

  void _read(int t, int ba, int a) {
    final period = _tck;
    if (period == null) return;
    reads++;
    final q = period ~/ 4;
    final half = period ~/ 2;
    final r0 = t + _cl * period + q + readSkewBeats * half;
    final mpr = ((_mr[3] ?? 0) >> 2) & 1 == 1;
    final data = mpr
        ? [for (var k = 0; k < 8; k++) k.isOdd ? (1 << _dq) - 1 : 0]
        : (_mem[_key(ba, a)] ??
              [for (var k = 0; k < 8; k++) (_idle * (k + 3)) & 0xFFFF]);
    final end = r0 + 4 * period;
    if (end > _readUntil) _readUntil = end;
    Simulator.registerAction(r0 - period, () {
      _dqsDrv.put(0);
      _dqsEn.put(1);
    });
    for (var k = 0; k < 8; k++) {
      Simulator.registerAction(r0 + k * half, () {
        _dqDrv.put(data[k]);
        _dqEn.put(1);
        _dqsDrv.put(k.isEven ? (1 << params.lanes) - 1 : 0);
      });
    }
    Simulator.registerAction(end, () {
      _dqsDrv.put(0);
      _dqDrv.put(_idle);
      _maybeIdle();
    });
    Simulator.registerAction(end + half, () {
      if (Simulator.time >= _readUntil + half) _dqsEn.put(0);
    });
  }

  void _maybeIdle() {
    final t = Simulator.time;
    if (t >= _dqReleaseUntil) {
      _dqDrv.put(_idle);
      _dqEn.put(1);
    } else {
      _dqEn.put(0);
    }
  }
}

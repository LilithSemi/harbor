import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/ethernet/eth_frame_fifo.dart';
import 'package:harbor/src/soc/target.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

var _epoch = 0;
var _running = false;

/// A clock that the test can stop. Time is in ps.
class _Clock {
  final Logic clk;
  bool running = true;
  int edges = 0;

  _Clock(String name, int periodPs, int phasePs) : clk = Logic(name: name) {
    final half = periodPs ~/ 2;
    clk.inject(0);
    final epoch = _epoch;
    void step() {
      // An old clock must not run in the next test.
      if (epoch != _epoch || Simulator.simulationHasEnded) return;
      if (running) {
        clk.put(clk.value.toBool() ? 0 : 1);
        edges++;
      }
      Simulator.registerAction(Simulator.time + half, step);
    }

    Simulator.registerAction(phasePs + half, step);
  }
}

int _ps(double mhz) => (1e6 / mhz).round();

/// PHY clock and its strobe period.
class _Phy {
  final double mhz;
  final int strobe;
  const _Phy(this.mhz, this.strobe);
  @override
  String toString() => '$mhz MHz strobe/$strobe';
}

const _phys = [_Phy(2.5, 2), _Phy(25, 2), _Phy(125, 1)];
const _syss = [50.0, 100.0];

List<int> _bytes(Random r, int n) => [
  for (var i = 0; i < n; i++) r.nextInt(256),
];

class _TxFrame {
  final List<int> data;

  /// Word index that carries `w_err`, or null.
  final int? errWord;
  int? startTime;

  /// `w_drop` on the last word.
  bool? dropped;
  _TxFrame(this.data, {this.errWord});
  int get words => (data.length + 3) ~/ 4;
}

class _TxBench {
  final _Clock sys;
  final _Clock phy;
  final _Phy phyKind;
  final HarborEthTxFrameFifo dut;
  final Logic sysReset;
  final Logic txReset;

  /// Frames the consumer got whole.
  final out = <List<int>>[];

  /// Frames where `in_valid` dropped in the frame.
  var underruns = 0;
  var sentAll = false;
  var anyValid = false;

  _TxBench._(
    this.sys,
    this.phy,
    this.phyKind,
    this.dut,
    this.sysReset,
    this.txReset,
  );

  static Future<_TxBench> make(
    double sysMhz,
    _Phy p,
    Random r, {
    int bytes = 2048,
    int? sysPhase,
    int? phyPhase,
  }) async {
    final sys = _Clock(
      'sys_clk',
      _ps(sysMhz),
      sysPhase ?? r.nextInt(_ps(sysMhz)),
    );
    final phy = _Clock('tx_clk', _ps(p.mhz), phyPhase ?? r.nextInt(_ps(p.mhz)));
    final sysReset = Logic();
    final txReset = Logic();
    final wValid = Logic();
    final wData = Logic(width: 32);
    final wBytes = Logic(width: 2);
    final wLast = Logic();
    final wErr = Logic();
    final inReady = Logic();
    final clear = Logic();
    final dut = HarborEthTxFrameFifo(
      sys.clk,
      sysReset,
      phy.clk,
      txReset,
      bytes: bytes,
      wValid: wValid,
      wData: wData,
      wBytes: wBytes,
      wLast: wLast,
      wErr: wErr,
      inReady: inReady,
      clkLostClear: clear,
    );
    await dut.build();
    final b = _TxBench._(sys, phy, p, dut, sysReset, txReset);
    wValid.inject(0);
    wData.inject(0);
    wBytes.inject(0);
    wLast.inject(0);
    wErr.inject(0);
    inReady.inject(0);
    clear.inject(0);
    sysReset.inject(1);
    txReset.inject(1);
    b._wValid = wValid;
    b._wData = wData;
    b._wBytes = wBytes;
    b._wLast = wLast;
    b._wErr = wErr;
    b._inReady = inReady;
    b._clear = clear;
    return b;
  }

  late Logic _wValid, _wData, _wBytes, _wLast, _wErr, _inReady, _clear;

  Future<void> start() async {
    Simulator.setMaxSimTime(1 << 50);
    _running = true;
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await phy.clk.nextPosedge;
    }
    for (var i = 0; i < 4; i++) {
      await sys.clk.nextPosedge;
    }
    txReset.inject(0);
    sysReset.inject(0);
    for (var i = 0; i < 20; i++) {
      await sys.clk.nextPosedge;
    }
    unawaited(_consume());
  }

  /// Writes [frames] in order. [idle] is the chance of no word on a cycle.
  /// [holdLast] delays the last word of frame [holdFrame] by that many
  /// cycles.
  Future<void> write(
    List<_TxFrame> frames,
    Random r, {
    double idle = 0.2,
    int? holdFrame,
    int holdLast = 0,
    bool Function()? hold,
  }) async {
    for (var fi = 0; fi < frames.length; fi++) {
      final f = frames[fi];
      var wi = 0;
      var held = 0;
      while (wi < f.words) {
        await sys.clk.nextNegedge;
        final last = wi == f.words - 1;
        var go = r.nextDouble() >= idle && !(hold?.call() ?? false);
        if (last && fi == holdFrame && held < holdLast) {
          held++;
          go = false;
        }
        _wValid.put(go);
        if (!go) continue;
        var word = 0;
        for (var k = 0; k < 4; k++) {
          final i = wi * 4 + k;
          if (i < f.data.length) word |= f.data[i] << (8 * k);
        }
        _wData.put(word);
        _wBytes.put(last ? f.data.length % 4 : r.nextInt(4));
        _wLast.put(last);
        _wErr.put(f.errWord == wi);
        if (dut.wReady.value.toBool()) {
          if (wi == 0) f.startTime = Simulator.time;
          if (last) f.dropped = dut.wDrop.value.toBool();
          wi++;
        }
      }
    }
    await sys.clk.nextNegedge;
    _wValid.put(0);
    sentAll = true;
  }

  /// A model of the MAC TX input: preamble, then one byte per strobe, then
  /// the gap.
  Future<void> _consume() async {
    var cyc = 0;
    var state = 0;
    var cnt = 0;
    var cur = <int>[];
    while (true) {
      await phy.clk.nextNegedge;
      final s = cyc % phyKind.strobe == 0;
      cyc++;
      final valid = dut.inValid.value.toBool();
      expect(dut.inErr.value.toBool(), isFalse);
      if (valid) anyValid = true;
      var ready = false;
      switch (state) {
        case 0:
          if (s && valid) {
            state = 1;
            cnt = 8;
          }
        case 1:
          if (s && --cnt == 0) state = 2;
        case 2:
          ready = s;
          if (s) {
            if (!valid) {
              underruns++;
              cur = [];
              state = 3;
              cnt = 12;
            } else {
              cur.add(dut.inData.value.toInt());
              if (dut.inLast.value.toBool()) {
                out.add(cur);
                cur = [];
                state = 3;
                cnt = 12;
              }
            }
          }
        default:
          if (s && --cnt == 0) state = 0;
      }
      _inReady.put(ready);
    }
  }

  Future<void> settle(int Function() count, int want, int maxSys) async {
    var n = 0;
    while ((!sentAll || count() < want) && n < maxSys) {
      await sys.clk.nextPosedge;
      n++;
    }
    // Some more time so that an extra frame would show.
    for (var i = 0; i < 400; i++) {
      await sys.clk.nextPosedge;
    }
  }

  /// Waits until all is written and `in_valid` stays low.
  Future<void> drain(int maxSys) async {
    var low = 0;
    for (var n = 0; n < maxSys && (!sentAll || low < 1000); n++) {
      await sys.clk.nextPosedge;
      low = dut.inValid.value.toBool() ? 0 : low + 1;
    }
  }

  Future<void> pulseClear() async {
    await sys.clk.nextNegedge;
    _clear.put(1);
    await sys.clk.nextNegedge;
    _clear.put(0);
  }

  Future<void> end() async {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}

List<_TxFrame> _txFrames(Random r, int n, int maxLen, {double err = 0}) => [
  for (var i = 0; i < n; i++)
    () {
      final len = 1 + r.nextInt(maxLen);
      final data = _bytes(r, len);
      final words = (len + 3) ~/ 4;
      return _TxFrame(
        data,
        errWord: r.nextDouble() < err ? r.nextInt(words) : null,
      );
    }(),
];

class _RxFrame {
  final List<int> data;
  final int status;
  int? startTime;
  _RxFrame(this.data, this.status);
}

class _RxOut {
  final List<int> data;
  final int status;
  _RxOut(this.data, this.status);
}

class _RxBench {
  final _Clock sys;
  final _Clock phy;
  final _Phy phyKind;
  final HarborEthRxFrameFifo dut;
  final Logic sysReset;
  final Logic rxReset;
  final Logic inValid;
  final Logic inData;
  final Logic inLast;
  final Logic inStatus;
  final Logic rReady;
  final Logic clear;
  final out = <_RxOut>[];
  var overflows = 0;
  var sentAll = false;

  /// The producer is in a frame.
  var sending = false;

  /// Bytes the reader has of a frame with no last word yet.
  var partial = 0;

  /// Words the reader can still take, or null for no limit.
  int? budget;

  /// Bytes the producer sent.
  var bytesIn = 0;

  /// Chance that `r_ready` is high on a cycle.
  double readyChance = 0.8;

  /// Set to make the reader drop the part of a frame it has, as a reader
  /// does in a reset.
  var dropPartial = false;

  _RxBench._(
    this.sys,
    this.phy,
    this.phyKind,
    this.dut,
    this.sysReset,
    this.rxReset,
    this.inValid,
    this.inData,
    this.inLast,
    this.inStatus,
    this.rReady,
    this.clear,
  );

  static Future<_RxBench> make(
    double sysMhz,
    _Phy p,
    Random r, {
    int bytes = 2048,
  }) async {
    final sys = _Clock('sys_clk', _ps(sysMhz), r.nextInt(_ps(sysMhz)));
    final phy = _Clock('rx_clk', _ps(p.mhz), r.nextInt(_ps(p.mhz)));
    final sysReset = Logic();
    final rxReset = Logic();
    final inValid = Logic();
    final inData = Logic(width: 8);
    final inLast = Logic();
    final inStatus = Logic(width: 8);
    final rReady = Logic();
    final clear = Logic();
    final dut = HarborEthRxFrameFifo(
      phy.clk,
      rxReset,
      sys.clk,
      sysReset,
      bytes: bytes,
      inValid: inValid,
      inData: inData,
      inLast: inLast,
      inStatus: inStatus,
      rReady: rReady,
      clkLostClear: clear,
    );
    await dut.build();
    for (final l in [inValid, inData, inLast, inStatus, rReady, clear]) {
      l.inject(0);
    }
    sysReset.inject(1);
    rxReset.inject(1);
    return _RxBench._(
      sys,
      phy,
      p,
      dut,
      sysReset,
      rxReset,
      inValid,
      inData,
      inLast,
      inStatus,
      rReady,
      clear,
    );
  }

  Future<void> start(Random r) async {
    Simulator.setMaxSimTime(1 << 50);
    _running = true;
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await phy.clk.nextPosedge;
    }
    for (var i = 0; i < 4; i++) {
      await sys.clk.nextPosedge;
    }
    rxReset.inject(0);
    sysReset.inject(0);
    for (var i = 0; i < 20; i++) {
      await sys.clk.nextPosedge;
    }
    unawaited(_read(r));
  }

  /// A model of the MAC RX output: one byte per strobe, a gap of [gap]
  /// strobes before each frame.
  Future<void> send(List<_RxFrame> frames, {int gap = 20}) async {
    sentAll = false;
    var cyc = 0;
    for (final f in frames) {
      var g = gap;
      var i = 0;
      while (i < f.data.length) {
        await phy.clk.nextNegedge;
        final s = cyc % phyKind.strobe == 0;
        cyc++;
        var v = false;
        if (s) {
          if (g > 0) {
            g--;
          } else {
            if (i == 0) f.startTime = Simulator.time;
            sending = i < f.data.length - 1;
            bytesIn++;
            v = true;
            inData.put(f.data[i]);
            inLast.put(i == f.data.length - 1);
            inStatus.put(i == f.data.length - 1 ? f.status : 0);
            i++;
          }
        }
        inValid.put(v);
      }
    }
    await phy.clk.nextNegedge;
    inValid.put(0);
    sentAll = true;
  }

  Future<void> _read(Random r) async {
    var cur = <int>[];
    while (true) {
      await sys.clk.nextNegedge;
      if (dropPartial) {
        cur = [];
        partial = 0;
        dropPartial = false;
      }
      if (dut.rxOverflow.value.toBool()) overflows++;
      final ready = r.nextDouble() < readyChance && (budget ?? 1) > 0;
      rReady.put(ready);
      if (ready && dut.rValid.value.toBool()) {
        if (budget != null) budget = budget! - 1;
        final w = dut.rData.value.toInt();
        final last = dut.rLast.value.toBool();
        var n = 4;
        if (last) {
          final b = dut.rBytes.value.toInt();
          n = b == 0 ? 4 : b;
        }
        for (var k = 0; k < n; k++) {
          cur.add((w >> (8 * k)) & 0xFF);
        }
        if (last) {
          out.add(_RxOut(cur, dut.rStatus.value.toInt()));
          cur = [];
        }
        partial = cur.length;
      }
    }
  }

  Future<void> settle(int want, int maxSys) async {
    var n = 0;
    while ((!sentAll || out.length < want) && n < maxSys) {
      await sys.clk.nextPosedge;
      n++;
    }
    for (var i = 0; i < 400; i++) {
      await sys.clk.nextPosedge;
    }
  }

  Future<void> pulseClear() async {
    await sys.clk.nextNegedge;
    clear.put(1);
    await sys.clk.nextNegedge;
    clear.put(0);
  }

  Future<void> end() async {
    await Simulator.endSimulation();
    await Simulator.simulationEnded;
  }
}

List<_RxFrame> _rxFrames(Random r, int n, int minLen, int maxLen) => [
  for (var i = 0; i < n; i++)
    _RxFrame(_bytes(r, minLen + r.nextInt(maxLen - minLen + 1)), r.nextInt(64)),
];

/// Checks that [got] is [sent] with some frames left out, each byte exact.
List<int> _subsequence(List<List<int>> got, List<List<int>> sent) {
  final idx = <int>[];
  var j = 0;
  for (final g in got) {
    while (j < sent.length && !_eq(sent[j], g)) {
      j++;
    }
    expect(j, lessThan(sent.length), reason: 'frame not sent or out of order');
    idx.add(j);
    j++;
  }
  return idx;
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _maxLen(_Phy p) => switch (p.mhz) {
  2.5 => 90,
  25.0 => 400,
  _ => 1518,
};

void main() {
  tearDown(() async {
    _epoch++;
    if (_running && !Simulator.simulationHasEnded) {
      await Simulator.endSimulation();
      await Simulator.simulationEnded;
    }
    _running = false;
    await Simulator.reset();
  });

  group('tx', () {
    var seed = 1;
    for (final s in _syss) {
      for (final p in _phys) {
        final sd = seed++;
        test('sys $s MHz, phy $p: frames out equal good frames in', () async {
          final r = Random(sd);
          final b = await _TxBench.make(s, p, r);
          await b.start();
          final frames = _txFrames(
            r,
            p.mhz == 125 ? 10 : 6,
            _maxLen(p),
            err: 0.25,
          );
          if (p.mhz == 125) frames.add(_TxFrame(_bytes(r, 1518)));
          final good = [
            for (final f in frames)
              if (f.errWord == null) f.data,
          ];
          unawaited(b.write(frames, r));
          await b.settle(() => b.out.length, good.length, 4000000);
          expect(b.underruns, 0);
          expect(b.out.length, good.length);
          for (var i = 0; i < good.length; i++) {
            expect(b.out[i], good[i], reason: 'frame $i');
          }
          expect(b.dut.clkLost.value.toBool(), isFalse);
          await b.end();
        });
      }
    }

    test('w_free stays below the size and the real space', () async {
      final r = Random(23);
      final b = await _TxBench.make(100, const _Phy(25, 2), r);
      await b.start();
      const words = 512;
      Logic sig(String n) => b.dut.signals.firstWhere((x) => x.name == n);
      final wPtr = sig('w_ptr');
      final fPtr = sig('f_ptr');
      final bad = <String>[];
      var full = false;
      final sub = b.sys.clk.posedge.listen((_) {
        final free = b.dut.wFree.value.toInt();
        final used = (wPtr.value.toInt() - fPtr.value.toInt()) & 1023;
        if (used == words) full = true;
        if (bad.length < 5 && (free > words - 1 || free > words - used)) {
          bad.add('w_free $free with $used words used');
        }
      });
      final frames = [for (var i = 0; i < 8; i++) _TxFrame(_bytes(r, 1000))];
      unawaited(b.write(frames, r, idle: 0));
      await b.settle(() => b.out.length, frames.length, 4000000);
      await sub.cancel();
      expect(full, isTrue, reason: 'the FIFO got full');
      expect(bad, isEmpty);
      expect(b.out.length, frames.length);
      await b.end();
    });

    test('a frame does not start before its last word', () async {
      final r = Random(20);
      final b = await _TxBench.make(100, const _Phy(125, 1), r);
      await b.start();
      final f = _TxFrame(_bytes(r, 301));
      unawaited(b.write([f], r, idle: 0, holdFrame: 0, holdLast: 3000));
      for (var i = 0; i < 2900; i++) {
        await b.sys.clk.nextPosedge;
      }
      expect(b.anyValid, isFalse, reason: 'in_valid before the last word');
      await b.settle(() => b.out.length, 1, 100000);
      expect(b.out, [f.data]);
      expect(b.underruns, 0);
      await b.end();
    });

    test('a frame with w_err never shows', () async {
      final r = Random(21);
      final b = await _TxBench.make(50, const _Phy(25, 2), r);
      await b.start();
      final frames = [
        _TxFrame(_bytes(r, 70)),
        _TxFrame(_bytes(r, 90), errWord: 0),
        _TxFrame(_bytes(r, 61), errWord: 15),
        _TxFrame(_bytes(r, 3), errWord: 0),
        _TxFrame(_bytes(r, 64)),
      ];
      unawaited(b.write(frames, r));
      await b.settle(() => b.out.length, 2, 400000);
      expect(b.out, [frames[0].data, frames[4].data]);
      await b.end();
    });

    test('a stopped tx clock sets clk_lost and the fifo recovers', () async {
      final r = Random(22);
      final b = await _TxBench.make(100, const _Phy(25, 2), r);
      await b.start();
      final frames = _txFrames(r, 40, 200);
      int? stopAt;
      int? resumeAt;
      unawaited(b.write(frames, r, idle: 0.5, hold: () => !b.phy.running));
      // Let some frames through, then stop the clock.
      while (b.out.length < 5) {
        await b.sys.clk.nextPosedge;
      }
      expect(b.dut.clkLost.value.toBool(), isFalse);
      b.phy.running = false;
      stopAt = Simulator.time;
      for (var i = 0; i < harborEthClkLostCycles + 1000; i++) {
        await b.sys.clk.nextPosedge;
      }
      expect(b.dut.clkLost.value.toBool(), isTrue);
      b.phy.running = true;
      resumeAt = Simulator.time;
      await b.drain(2000000);
      expect(b.dut.clkLost.value.toBool(), isTrue, reason: 'sticky');
      await b.pulseClear();
      await b.sys.clk.nextPosedge;
      expect(b.dut.clkLost.value.toBool(), isFalse);

      final idx = _subsequence(b.out, [for (final f in frames) f.data]);
      // Every frame that started after the recovery arrives.
      final late = [
        for (var i = 0; i < frames.length; i++)
          if (frames[i].startTime! > resumeAt + 2 * _ps(100) * 100) i,
      ];
      expect(late, isNotEmpty);
      for (final i in late) {
        expect(idx, contains(i), reason: 'frame $i after recovery');
      }
      expect(idx.length, lessThan(frames.length), reason: 'loss drops frames');
      expect(stopAt, lessThan(resumeAt));
      // w_drop on the last word tells exactly which frames did not go in.
      final dropped = [
        for (var i = 0; i < frames.length; i++)
          if (frames[i].dropped!) i,
      ];
      expect(dropped, isNotEmpty);
      for (final i in dropped) {
        expect(idx, isNot(contains(i)), reason: 'dropped frame $i came out');
      }
      await b.end();
    });

    for (final side in ['tx', 'sys']) {
      test('$side reset alone in traffic: later frames arrive', () async {
        final r = Random(side == 'tx' ? 24 : 25);
        final b = await _TxBench.make(100, const _Phy(25, 2), r);
        await b.start();
        final before = _txFrames(r, 20, 200);
        final after = _txFrames(r, 10, 200);
        unawaited(b.write(before, r, idle: 0.5));
        while (b.out.length < 3) {
          await b.sys.clk.nextPosedge;
        }
        final reset = side == 'tx' ? b.txReset : b.sysReset;
        await b.sys.clk.nextNegedge;
        reset.inject(1);
        for (var i = 0; i < 200; i++) {
          await b.sys.clk.nextPosedge;
        }
        reset.inject(0);
        while (!b.sentAll) {
          await b.sys.clk.nextPosedge;
        }
        for (var i = 0; i < 100; i++) {
          await b.sys.clk.nextPosedge;
        }
        await b.write(after, r, idle: 0.5);
        await b.drain(2000000);
        expect(b.dut.clkLost.value.toBool(), isFalse);
        final all = [
          for (final f in [...before, ...after]) f.data,
        ];
        final idx = _subsequence(b.out, all);
        expect(idx.length, lessThan(all.length), reason: 'reset drops frames');
        for (var i = before.length; i < all.length; i++) {
          expect(idx, contains(i), reason: 'frame $i after reset');
        }
        await b.end();
      });
    }

    test('frame counter wraps', () async {
      final r = Random(26);
      final b = await _TxBench.make(100, const _Phy(125, 1), r, bytes: 64);
      await b.start();
      final frames = _txFrames(r, 100, 60);
      unawaited(b.write(frames, r, idle: 0.1));
      await b.settle(() => b.out.length, frames.length, 400000);
      expect(b.underruns, 0);
      expect(b.out, [for (final f in frames) f.data]);
      await b.end();
    });

    // A PHY clock at 2x sys from one source must not look stopped.
    for (final (s, p) in [(62.5, 125.0), (25.0, 50.0)]) {
      test('sys $s MHz, phase locked phy $p MHz: no clk_lost', () async {
        final r = Random(23);
        final b = await _TxBench.make(
          s,
          _Phy(p, 1),
          r,
          sysPhase: 0,
          phyPhase: _ps(p) ~/ 4,
        );
        await b.start();
        final frames = _txFrames(r, 4, 200);
        unawaited(b.write(frames, r));
        for (var i = 0; i < 3 * harborEthClkLostCycles; i++) {
          await b.sys.clk.nextPosedge;
          expect(b.dut.clkLost.value.toBool(), isFalse, reason: 'cycle $i');
        }
        expect(b.out, [for (final f in frames) f.data]);
        await b.end();
      });
    }
  });

  group('rx', () {
    var seed = 100;
    for (final s in _syss) {
      for (final p in _phys) {
        final sd = seed++;
        test('sys $s MHz, phy $p: frames out equal frames in', () async {
          final r = Random(sd);
          final b = await _RxBench.make(s, p, r);
          await b.start(r);
          final frames = _rxFrames(r, p.mhz == 125 ? 10 : 6, 6, _maxLen(p));
          if (p.mhz == 125) frames.add(_RxFrame(_bytes(r, 1518), 0x24));
          unawaited(b.send(frames));
          await b.settle(frames.length, 4000000);
          expect(b.overflows, 0);
          expect(b.out.length, frames.length);
          for (var i = 0; i < frames.length; i++) {
            expect(b.out[i].data, frames[i].data, reason: 'frame $i');
            expect(b.out[i].status, frames[i].status, reason: 'status $i');
          }
          await b.end();
        });
      }
    }

    for (final (s, p) in [
      (100.0, const _Phy(125, 1)),
      (50.0, const _Phy(25, 2)),
    ]) {
      test('sys $s MHz, phy $p: overflow drops the whole frame', () async {
        final r = Random(30);
        final b = await _RxBench.make(s, p, r);
        b.readyChance = 0;
        await b.start(r);
        final frames = [
          _RxFrame(_bytes(r, 1000), 1),
          _RxFrame(_bytes(r, 1000), 2),
          _RxFrame(_bytes(r, 1000), 3),
          _RxFrame(_bytes(r, 40), 4),
        ];
        await b.send(frames);
        for (var i = 0; i < 200; i++) {
          await b.sys.clk.nextPosedge;
        }
        expect(b.overflows, 1);
        expect(b.out, isEmpty);
        b.readyChance = 0.7;
        final next = _RxFrame(_bytes(r, 1000), 5);
        await b.send([next]);
        b.sentAll = true;
        await b.settle(4, 1000000);
        expect(b.overflows, 1);
        final want = [frames[0], frames[1], frames[3], next];
        expect(b.out.length, want.length);
        for (var i = 0; i < want.length; i++) {
          expect(b.out[i].data, want[i].data, reason: 'frame $i');
          expect(b.out[i].status, want[i].status, reason: 'status $i');
        }
        await b.end();
      });
    }

    for (final side in ['rx', 'sys']) {
      test('$side reset alone in traffic: no false overflow, later frames '
          'arrive', () async {
        final r = Random(side == 'rx' ? 32 : 33);
        final b = await _RxBench.make(100, const _Phy(125, 1), r);
        b.readyChance = 0;
        await b.start(r);
        // One overflow sets the toggle to 1.
        final first = [
          _RxFrame(_bytes(r, 1000), 1),
          _RxFrame(_bytes(r, 1000), 2),
          _RxFrame(_bytes(r, 1000), 3),
        ];
        await b.send(first);
        for (var i = 0; i < 200; i++) {
          await b.sys.clk.nextPosedge;
        }
        expect(b.overflows, 1);
        b.readyChance = 0.8;
        await b.settle(2, 100000);
        expect(b.out.length, 2);

        final frames = _rxFrames(r, 30, 6, 200);
        unawaited(b.send(frames));
        while (b.out.length < 5) {
          await b.sys.clk.nextPosedge;
        }
        final reset = side == 'rx' ? b.rxReset : b.sysReset;
        await b.sys.clk.nextNegedge;
        reset.inject(1);
        for (var i = 0; i < 200; i++) {
          await b.sys.clk.nextPosedge;
        }
        reset.inject(0);
        final resumeAt = Simulator.time;
        while (!b.sentAll) {
          await b.sys.clk.nextPosedge;
        }
        for (var i = 0; i < 2000; i++) {
          await b.sys.clk.nextPosedge;
        }
        expect(b.overflows, 1, reason: 'reset made an overflow pulse');
        expect(b.dut.clkLost.value.toBool(), isFalse);
        final whole = [
          for (final o in b.out.sublist(2))
            if (o.status != harborEthRxStatusCut) o.data,
        ];
        final idx = _subsequence(whole, [for (final f in frames) f.data]);
        final late = [
          for (var i = 0; i < frames.length; i++)
            if (frames[i].startTime! > resumeAt + _ps(100) * 100) i,
        ];
        expect(late, isNotEmpty);
        for (final i in late) {
          expect(idx, contains(i), reason: 'frame $i after reset');
        }
        await b.end();
      });
    }

    test('frame counter wraps', () async {
      final r = Random(34);
      final b = await _RxBench.make(100, const _Phy(125, 1), r, bytes: 64);
      await b.start(r);
      final frames = _rxFrames(r, 100, 1, 40);
      await b.send(frames);
      await b.settle(frames.length, 100000);
      expect(b.overflows, 0);
      expect(b.out.length, frames.length);
      for (var i = 0; i < frames.length; i++) {
        expect(b.out[i].data, frames[i].data, reason: 'frame $i');
        expect(b.out[i].status, frames[i].status, reason: 'status $i');
      }
      await b.end();
    });

    test('a stopped rx clock sets clk_lost and the fifo recovers', () async {
      final r = Random(31);
      final b = await _RxBench.make(100, const _Phy(25, 2), r);
      await b.start(r);
      final pre = _rxFrames(r, 5, 6, 200);
      await b.send(pre);
      await b.settle(pre.length, 200000);
      expect(b.out.length, pre.length);

      // The reader takes part of frame a, then the clock stops in frame b.
      b.readyChance = 0;
      final a = _RxFrame(_bytes(r, 400), 7);
      final c = _RxFrame(_bytes(r, 400), 8);
      await b.send([a]);
      for (var i = 0; i < 200; i++) {
        await b.sys.clk.nextPosedge;
      }
      b.budget = 10;
      b.readyChance = 1;
      final before = b.bytesIn;
      unawaited(b.send([c]));
      while (b.bytesIn - before < 100) {
        await b.phy.clk.nextPosedge;
      }
      expect(b.partial, 40);
      expect(b.dut.clkLost.value.toBool(), isFalse);
      b.phy.running = false;
      for (var i = 0; i < harborEthClkLostCycles + 1000; i++) {
        await b.sys.clk.nextPosedge;
      }
      expect(b.dut.clkLost.value.toBool(), isTrue);
      b.phy.running = true;
      b.budget = null;
      b.readyChance = 0.8;
      while (!b.sentAll) {
        await b.sys.clk.nextPosedge;
      }
      final post = _rxFrames(r, 10, 6, 200);
      await b.send(post);
      await b.settle(pre.length + 1 + post.length, 400000);
      expect(b.dut.clkLost.value.toBool(), isTrue, reason: 'sticky');
      await b.pulseClear();
      await b.sys.clk.nextPosedge;
      expect(b.dut.clkLost.value.toBool(), isFalse);

      expect(b.out.length, pre.length + 1 + post.length);
      final cut = b.out[pre.length];
      expect(cut.status, harborEthRxStatusCut);
      expect(cut.data.sublist(0, 40), a.data.sublist(0, 40));
      final whole = [...pre, ...post];
      final got = [
        ...b.out.sublist(0, pre.length),
        ...b.out.sublist(pre.length + 1),
      ];
      for (var i = 0; i < whole.length; i++) {
        expect(got[i].data, whole[i].data, reason: 'frame $i');
        expect(got[i].status, whole[i].status, reason: 'status $i');
      }
      await b.end();
    });
  });

  group('rx queue and slice', () {
    for (final words in [9, 10, 11, 12, 13, 14]) {
      test('clock loss after the reader took $words words', () async {
        final r = Random(40 + words);
        final b = await _RxBench.make(100, const _Phy(25, 2), r);
        await b.start(r);
        // The reader takes part of frame a and stops, so the queue and the
        // slice hold words of a when the clock stops in frame c.
        b.readyChance = 0;
        final a = _RxFrame(_bytes(r, 400), 7);
        final c = _RxFrame(_bytes(r, 400), 8);
        await b.send([a]);
        for (var i = 0; i < 200; i++) {
          await b.sys.clk.nextPosedge;
        }
        b.budget = words;
        b.readyChance = 1;
        final before = b.bytesIn;
        unawaited(b.send([c]));
        while (b.bytesIn - before < 100) {
          await b.phy.clk.nextPosedge;
        }
        expect(b.partial, 4 * words);
        b.phy.running = false;
        for (var i = 0; i < harborEthClkLostCycles + 1000; i++) {
          await b.sys.clk.nextPosedge;
        }
        b.phy.running = true;
        b.budget = null;
        b.readyChance = 0.6;
        while (!b.sentAll) {
          await b.sys.clk.nextPosedge;
        }
        final post = _rxFrames(r, 6, 6, 200);
        await b.send(post);
        await b.settle(1 + post.length, 400000);
        expect(b.out.length, 1 + post.length);
        final cut = b.out.first;
        expect(cut.status, harborEthRxStatusCut);
        // The abort word comes last and adds no frame bytes, so the reader
        // model shows it as 4 extra bytes.
        final got = cut.data.sublist(0, cut.data.length - 4);
        expect(got.length, greaterThanOrEqualTo(4 * words));
        expect(got, a.data.sublist(0, got.length));
        for (var i = 0; i < post.length; i++) {
          expect(b.out[1 + i].data, post[i].data, reason: 'frame $i');
          expect(b.out[1 + i].status, post[i].status, reason: 'status $i');
        }
        await b.end();
      });
    }

    test('a sys reset while the slice holds words', () async {
      final r = Random(50);
      final b = await _RxBench.make(100, const _Phy(25, 2), r);
      await b.start(r);
      b.readyChance = 0;
      final a = _RxFrame(_bytes(r, 400), 7);
      await b.send([a]);
      for (var i = 0; i < 200; i++) {
        await b.sys.clk.nextPosedge;
      }
      b.budget = 11;
      b.readyChance = 1;
      for (var i = 0; i < 100; i++) {
        await b.sys.clk.nextPosedge;
      }
      expect(b.partial, 44);
      await b.sys.clk.nextNegedge;
      b.sysReset.put(1);
      b.dropPartial = true;
      for (var i = 0; i < 4; i++) {
        await b.sys.clk.nextNegedge;
      }
      b.sysReset.put(0);
      b.budget = null;
      b.readyChance = 0.6;
      for (var i = 0; i < 200; i++) {
        await b.sys.clk.nextPosedge;
      }
      final post = _rxFrames(r, 6, 6, 200);
      await b.send(post);
      await b.settle(post.length, 400000);
      expect(b.out.length, post.length, reason: 'no word of a after reset');
      for (var i = 0; i < post.length; i++) {
        expect(b.out[i].data, post[i].data, reason: 'frame $i');
        expect(b.out[i].status, post[i].status, reason: 'status $i');
      }
      await b.end();
    });
  });

  // Last, because the block RAM model of a built module makes later
  // simulations slow.
  group('storage', () {
    const ecp5 = HarborFpgaTarget.ecp5(
      device: 'lfe5u-25f',
      package: 'CABGA381',
    );
    for (final target in [null, ecp5]) {
      final kind = target == null ? 'flops' : 'block RAM';
      test('$kind storage emits its memory', () async {
        Logic l([int w = 1]) => Logic(width: w);
        final tx = HarborEthTxFrameFifo(
          l(),
          l(),
          l(),
          l(),
          bytes: 4096,
          wValid: l(),
          wData: l(32),
          wBytes: l(2),
          wLast: l(),
          wErr: l(),
          inReady: l(),
          target: target,
        );
        final rx = HarborEthRxFrameFifo(
          l(),
          l(),
          l(),
          l(),
          bytes: 2048,
          inValid: l(),
          inData: l(8),
          inLast: l(),
          inStatus: l(8),
          rReady: l(),
          target: target,
        );
        await tx.build();
        await rx.build();
        expect(tx.usesBlockRam, target != null);
        final txSv = tx.generateSynth();
        final rxSv = rx.generateSynth();
        if (target == null) {
          expect(tx.definitionName, 'HarborEthTxFrameFifo_4096');
          expect(txSv, contains('HarborEthFrameStore_35x1024'));
          expect(rxSv, contains('HarborEthFrameStore_43x512'));
        } else {
          expect(tx.definitionName, 'HarborEthTxFrameFifo_4096_dp16kd');
          expect(txSv, contains('HarborDualClockBram_35x1024_dp16kd'));
          expect(rxSv, contains('HarborDualClockBram_43x512_dp16kd'));
        }
        expect(txSv, contains('mem [0:1023]'));
        expect(rxSv, contains('mem [0:511]'));
      });
    }
  });
}

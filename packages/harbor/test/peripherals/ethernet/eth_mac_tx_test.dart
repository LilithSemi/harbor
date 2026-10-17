import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/ethernet/eth_config.dart';
import 'package:harbor/src/peripherals/ethernet/eth_mac_tx.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/eth_frames.dart';

class _Frame {
  final List<int> bytes;

  /// Index of the byte that carries `in_err`.
  final int? errAt;

  /// Index of the byte where `in_valid` drops in the frame.
  final int? underrunAt;

  _Frame(this.bytes, {this.errAt, this.underrunAt});

  bool get bad => errAt != null || underrunAt != null;

  /// Bytes the core sends before the pad.
  List<int> get sent =>
      underrunAt == null ? bytes : [...bytes.sublist(0, underrunAt), 0];
}

class _Slot {
  final bool en;
  final int data;
  final bool er;
  _Slot(this.en, this.data, this.er);
}

class _Result {
  final List<_Slot> slots;
  final int done;
  final int errs;
  _Result(this.slots, this.done, this.errs);
}

List<int> _randomBytes(Random rand, int len) => [
  for (var i = 0; i < len; i++) rand.nextInt(256),
];

Future<_Result> _run(List<_Frame> frames, {required int period}) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic();
  final strobe = Logic();
  final inValid = Logic();
  final inData = Logic(width: 8);
  final inLast = Logic();
  final inErr = Logic();
  final dut = HarborEthMacTx(
    clk,
    reset,
    config: HarborEthernetConfig.basic(phy: HarborEthPhy.mii),
    txStrobe: strobe,
    inValid: inValid,
    inData: inData,
    inLast: inLast,
    inErr: inErr,
  );
  await dut.build();

  reset.inject(1);
  strobe.inject(0);
  inValid.inject(0);
  inData.inject(0);
  inLast.inject(0);
  inErr.inject(0);
  Simulator.setMaxSimTime(100000000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);

  final slots = <_Slot>[];
  var done = 0;
  var errs = 0;
  var fi = 0;
  var bi = 0;
  var cycle = 0;
  var idleAfter = 0;
  int? lastData;
  bool? lastEn;
  bool? lastEr;
  var lastStrobe = true;

  while (idleAfter < 40 * period) {
    await clk.nextNegedge;
    if (dut.txFrameDone.value.toBool()) done++;
    if (dut.txFrameErr.value.toBool()) errs++;

    final s = cycle % period == 0;
    cycle++;
    strobe.put(s);

    var valid = false;
    if (fi < frames.length) {
      final f = frames[fi];
      if (f.underrunAt == bi) {
        // Hold in_valid low until the core ends the frame.
        if (dut.txFrameDone.value.toBool()) {
          fi++;
          bi = 0;
        }
      } else {
        valid = true;
        inData.put(f.bytes[bi]);
        inLast.put(bi == f.bytes.length - 1);
        inErr.put(f.errAt == bi);
      }
    }
    inValid.put(valid);

    final en = dut.txEn.value.toBool();
    final data = dut.txData.value.toInt();
    final er = dut.txEr.value.toBool();
    if (!lastStrobe) {
      expect(en, equals(lastEn), reason: 'tx_en moved between strobes');
      expect(data, equals(lastData), reason: 'tx_data moved between strobes');
      expect(er, equals(lastEr), reason: 'tx_er moved between strobes');
    }
    lastEn = en;
    lastData = data;
    lastEr = er;
    lastStrobe = s;

    final ready = dut.inReady.value.toBool();
    expect(ready, s ? anything : isFalse, reason: 'in_ready off a strobe');
    if (s) slots.add(_Slot(en, data, er));
    if (ready && valid) {
      bi++;
      if (bi == frames[fi].bytes.length) {
        fi++;
        bi = 0;
      }
    }

    if (fi >= frames.length && !en) {
      idleAfter++;
    } else {
      idleAfter = 0;
    }
  }

  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  return _Result(slots, done, errs);
}

/// Checks the wire against [frames]. Returns the gaps between frames.
List<int> _check(_Result r, List<_Frame> frames) {
  final runs = <List<_Slot>>[];
  final gaps = <int>[];
  var gap = 0;
  List<_Slot>? cur;
  for (final s in r.slots) {
    if (s.en) {
      if (cur == null) {
        if (runs.isNotEmpty) gaps.add(gap);
        cur = [];
        runs.add(cur);
      }
      cur.add(s);
      gap = 0;
    } else {
      cur = null;
      gap++;
    }
  }
  expect(runs.length, equals(frames.length), reason: 'one tx_en run each');

  for (var i = 0; i < frames.length; i++) {
    final f = frames[i];
    var body = f.sent;
    if (body.length < 60) {
      body = [...body, ...List.filled(60 - body.length, 0)];
    }
    var fcs = ethFcsBytes(body);
    if (f.bad) fcs = [for (final b in fcs) b ^ 0xFF];
    final want = [...List.filled(7, 0x55), 0xD5, ...body, ...fcs];
    final run = runs[i];
    expect(
      run.map((s) => s.data).toList(),
      equals(want),
      reason: 'frame $i of ${f.bytes.length} bytes',
    );
    for (var j = 0; j < run.length; j++) {
      final last = j == run.length - 1;
      expect(
        run[j].er,
        equals(f.bad && last),
        reason: 'tx_er at byte $j of frame $i',
      );
    }
  }
  expect(r.done, equals(frames.length));
  expect(r.errs, equals(frames.where((f) => f.bad).length));
  for (final g in gaps) {
    expect(g, greaterThanOrEqualTo(12));
  }
  return gaps;
}

void main() {
  tearDown(() async => Simulator.reset());

  final rand = Random(11);
  final lengths = [1, 59, 60, 61, 1514, 1518];

  for (final period in [1, 2, 10]) {
    test('lengths $lengths with a strobe every $period cycles', () async {
      final frames = [for (final l in lengths) _Frame(_randomBytes(rand, l))];
      final r = await _run(frames, period: period);
      final gaps = _check(r, frames);
      // The source has the next frame ready, so the gap is the minimum.
      expect(gaps, everyElement(equals(12)));
    });
  }

  test('known ARP frame', () async {
    final frames = [_Frame(ethArpRequest)];
    final r = await _run(frames, period: 1);
    _check(r, frames);
    final tail = r.slots.where((s) => s.en).toList();
    final fcs = tail.sublist(tail.length - 4).map((s) => s.data).toList();
    expect(fcs, equals([0xAD, 0x8D, 0x88, 0x40]));
  });

  test('in_err gives a bad FCS and tx_er on the last byte', () async {
    final frames = [
      _Frame(_randomBytes(rand, 61), errAt: 5),
      _Frame(_randomBytes(rand, 30)),
      _Frame(_randomBytes(rand, 1), errAt: 0),
      _Frame(_randomBytes(rand, 100), errAt: 99),
      _Frame(_randomBytes(rand, 64)),
    ];
    for (final period in [1, 2]) {
      final r = await _run(frames, period: period);
      _check(r, frames);
      await Simulator.reset();
    }
  });

  test('in_valid low in a frame ends it as a bad frame', () async {
    final frames = [
      _Frame(_randomBytes(rand, 40), underrunAt: 10),
      _Frame(_randomBytes(rand, 20)),
      _Frame(_randomBytes(rand, 200), underrunAt: 100),
      _Frame(_randomBytes(rand, 70)),
    ];
    for (final period in [1, 10]) {
      final r = await _run(frames, period: period);
      _check(r, frames);
      await Simulator.reset();
    }
  });
}

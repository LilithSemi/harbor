import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Lines through one [HarborScanoutFetcher] against a port model with a
/// read latency. Each job is a start byte address and a count of 32-bit
/// words. Returns the requests taken for each line.
///
/// [ready] gives `rq_ready` for the next cycle. [tookLastCycle] is true
/// when a take occurred on the cycle before. [firstOffer] is true while the
/// first request of a line is on offer. The default is random and low after
/// a take.
Future<List<List<(int, int)>>> _lines(
  List<(int, int)> jobs, {
  required int seed,
  int latency = 6,
  bool Function(Random rng, bool tookLastCycle, bool firstOffer)? ready,
}) async {
  final readyFn =
      ready ?? (rng, tookLastCycle, _) => !tookLastCycle && rng.nextInt(3) != 0;
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
  final start = Logic()..inject(0);
  final fetchAddr = Logic(width: 32)..inject(0);
  final words = Logic(width: 16)..inject(0);
  final rqReady = Logic()..inject(0);
  final rdValid = Logic()..inject(0);
  final rdData = Logic(width: 16)..inject(0);
  final f = HarborScanoutFetcher(
    clk: clk,
    reset: reset,
    fetchStart: start,
    fetchAddr: fetchAddr,
    words: words,
    fillSel: Const(1),
    rqReady: rqReady,
    rdValid: rdValid,
    rdData: rdData,
    maxWords: 1024,
  );
  await f.build();

  int half(int a) => (a * 0x9E37 + 0x1234) & 0xFFFF;
  final rng = Random(seed);
  var taken = <(int, int)>[];
  final pipe = Queue<(int, int)>();
  var written = <int, int>{};
  var doneSeen = false;
  var took = false;
  var cycle = 0;

  // Everything is driven and sampled on the falling edge, so a value seen
  // here is the one the next rising edge takes.
  clk.negedge.listen((_) {
    cycle++;
    if (f.wrEn.value == LogicValue.one) {
      expect(f.wrSel.value.toInt(), 1);
      written[f.wrIdx.value.toInt()] = f.wrData.value.toInt();
    }
    if (f.done.value == LogicValue.one) doneSeen = true;
    final first = taken.isEmpty && f.rqValid.value == LogicValue.one;
    final readyNow = readyFn(rng, took, first);
    rqReady.put(readyNow ? 1 : 0);
    took = readyNow && f.rqValid.value == LogicValue.one;
    if (took) {
      final a = f.rqAddr.value.toInt();
      final n = f.rqWords.value.toInt();
      taken.add((a, n));
      final t0 = max(cycle, pipe.isEmpty ? 0 : pipe.last.$1) + latency;
      for (var i = 0; i < n; i++) {
        pipe.add((t0 + i, half((a >> 1) + i)));
      }
    }
    final out = pipe.isNotEmpty && pipe.first.$1 <= cycle;
    rdValid.put(out ? 1 : 0);
    rdData.put(out ? pipe.removeFirst().$2 : 0);
  });

  Simulator.setMaxSimTime(1 << 40);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.put(0);
  final all = <List<(int, int)>>[];
  // A failed check ends the run, so the test does not wait on a free
  // running clock.
  try {
    for (final (addr, n) in jobs) {
      taken = [];
      written = {};
      doneSeen = false;
      await clk.nextNegedge;
      fetchAddr.put(addr);
      words.put(n);
      start.put(1);
      await clk.nextNegedge;
      start.put(0);
      final limit = 1000 + 50 * n;
      for (var c = 0; !doneSeen; c++) {
        if (c > limit) {
          fail(
            'line at 0x${addr.toRadixString(16)}, $n words: not done '
            'after $limit cycles, ${taken.length} requests taken',
          );
        }
        await clk.nextPosedge;
      }
      await clk.nextPosedge;

      final base = addr & ~3;
      final where = 'line at 0x${addr.toRadixString(16)}, $n words';
      expect(written.length, n, reason: where);
      for (var i = 0; i < n; i++) {
        final w = (base >> 1) + 2 * i;
        expect(written[i], half(w) | (half(w + 1) << 16), reason: '$where: $i');
      }
      var next = base;
      for (final (a, k) in taken) {
        expect(a, next, reason: '$where: requests run in order with no gap');
        expect(k, inInclusiveRange(1, 8), reason: where);
        // No request crosses an aligned 8-word group, so none crosses a page.
        expect((a >> 4) == ((a + 2 * k - 1) >> 4), isTrue, reason: where);
        next = a + 2 * k;
      }
      expect(next, base + 4 * n, reason: where);
      // Only the first request can be short.
      expect(
        taken.length < 3 ||
            taken.sublist(1, taken.length - 1).every((r) => r.$2 == 8),
        isTrue,
        reason: where,
      );
      all.add(taken);
    }
  } finally {
    await Simulator.endSimulation();
  }
  return all;
}

Future<List<(int, int)>> _line({
  required int addr,
  required int words,
  required int seed,
  int latency = 6,
  bool Function(Random rng, bool tookLastCycle, bool firstOffer)? ready,
}) async => (await _lines(
  [(addr, words)],
  seed: seed,
  latency: latency,
  ready: ready,
)).single;

void main() {
  tearDown(() async => Simulator.reset());

  test('a line that starts 4 bytes before a page splits there', () async {
    const page = 1024;
    final t = await _line(addr: 7 * page - 4, words: 9, seed: 1);
    expect(t.first, (7 * page - 4, 2));
    expect(t[1].$1, 7 * page);
  });

  test('a line that starts mid group splits at the group end', () async {
    final t = await _line(addr: 0x2000 + 8, words: 20, seed: 2);
    expect(t.first, (0x2008, 4));
    expect(t.skip(1).take(4).every((r) => r.$2 == 8), isTrue);
  });

  test('a 640-pixel line with a 3072-byte stride starts on a row', () async {
    final t = await _line(addr: 5 * 3072, words: 640, seed: 3);
    expect(t.length, 160);
    expect(t.every((r) => r.$2 == 8), isTrue);
  });

  test('every start offset in a group and every line length from 1 to '
      '300 words keeps the group rule and the data', () async {
    final jobs = [
      for (final off in [0, 4, 8, 12])
        for (var n = 1; n <= 300; n++) (0x10000 * (1 + n % 7) - 64 + off, n),
    ];
    await _lines(jobs, seed: 9, latency: 3);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('the low 2 bits of the start address are ignored', () async {
    final want = await _line(addr: 0x2008, words: 20, seed: 5);
    for (final low in [1, 2, 3]) {
      await Simulator.reset();
      expect(await _line(addr: 0x2008 + low, words: 20, seed: 5), want);
    }
  });

  test('back to back reads with latency 1', () async {
    await _line(addr: 0x400 - 16, words: 33, seed: 4, latency: 1);
  });

  test('rq_ready held high every cycle still gives correct requests', () async {
    // _lines checks that no request repeats or skips one.
    final jobs = [
      for (final off in [0, 4, 8, 12])
        for (var n = 1; n <= 40; n++) (0x8000 * (1 + n % 5) - 64 + off, n),
    ];
    await _lines(jobs, seed: 20, ready: (rng, took, _) => true);
  });

  test('a random rq_ready with no guaranteed gap after a take still gives '
      'correct requests', () async {
    // Ready is often high on the cycle after a take.
    final jobs = [for (var n = 1; n <= 80; n++) (0x4000 + 16 * n, n)];
    await _lines(jobs, seed: 21, ready: (rng, took, _) => rng.nextBool());
  });

  test('rq_ready high from before the first offer to the end of a line of '
      'one burst or of many bursts', () async {
    // Each line runs in a new simulation, so ready is high before the
    // first offer.
    for (final (addr, n) in [
      (0x1000, 4),
      (0x1008, 2),
      (0x100C, 1),
      (0x2000, 20),
      (0x2004, 37),
      (0x200C, 64),
    ]) {
      await Simulator.reset();
      await _line(
        addr: addr,
        words: n,
        seed: 30,
        ready: (rng, took, _) => true,
      );
    }
  });

  test('rq_ready high on the first offer, then random', () async {
    for (var seed = 0; seed < 8; seed++) {
      await Simulator.reset();
      final jobs = [for (var n = 1; n <= 24; n++) (0x6000 + 12 * n, n)];
      await _lines(
        jobs,
        seed: 40 + seed,
        ready: (rng, took, first) => first || rng.nextBool(),
      );
    }
  });

  test('maxBurst must be a power of two from 2 to 8', () {
    for (final b in [0, 1, 3, 16]) {
      expect(
        () => HarborScanoutFetcher(
          clk: Logic(),
          reset: Logic(),
          fetchStart: Logic(),
          fetchAddr: Logic(width: 32),
          words: Logic(width: 16),
          fillSel: Logic(),
          rqReady: Logic(),
          rdValid: Logic(),
          rdData: Logic(width: 16),
          maxBurst: b,
        ),
        throwsArgumentError,
      );
    }
  });

  test('the display takes one memory port and a valid stride', () {
    const timing = HarborDisplayTiming(
      hActive: 16,
      hFrontPorch: 2,
      hSyncWidth: 2,
      hBackPorch: 2,
      vActive: 2,
      vFrontPorch: 1,
      vSyncWidth: 1,
      vBackPorch: 1,
      pixelClock: 25175000,
    );
    HarborDualClockDisplay make({
      bool wishbone = false,
      bool port = true,
      int? stride,
    }) => HarborDualClockDisplay(
      timing: timing,
      pixelClk: Logic(),
      pixelReset: Logic(),
      shiftClk: Logic(),
      shiftReset: Logic(),
      sysClk: Logic(),
      sysReset: Logic(),
      enable: Logic(),
      fbBase: Logic(width: 32),
      mDataIn: wishbone ? Logic(width: 32) : null,
      mAck: wishbone ? Logic() : null,
      rqReady: port ? Logic() : null,
      rdValid: port ? Logic() : null,
      rdData: port ? Logic(width: 16) : null,
      lineStride: stride,
      target: const HarborSimTarget(),
    );
    expect(make().lineStride, 64);
    expect(make(stride: 1024).rqValid.width, 1);
    expect(() => make(stride: 60), throwsArgumentError);
    expect(() => make(stride: 66), throwsArgumentError);
    expect(() => make(wishbone: true), throwsArgumentError);
    expect(() => make(port: false), throwsArgumentError);
  });
}

import 'dart:async';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests for [HarborFpDivider].
///
/// The normal cases are checked against Dart's own float division, which is
/// round-to-nearest, so the comparison allows the one unit of last place that
/// truncation can differ by. The special cases are checked exactly, because
/// IEEE defines them exactly and this unit claims to follow it there.
void main() {
  var simulated = false;
  tearDown(() async {
    if (simulated) {
      await Simulator.endSimulation();
      simulated = false;
    }
    Simulator.reset();
  });

  /// A double as the FP32 bit pattern nearest to it.
  int bits(double v) {
    final b = ByteData(4)..setFloat32(0, v);
    return b.getUint32(0);
  }

  /// An FP32 bit pattern as the double it stands for.
  double value(int w) {
    final b = ByteData(4)..setUint32(0, w);
    return b.getFloat32(0);
  }

  const nan = 0x7FC00000;
  const posInf = 0x7F800000;
  const negInf = 0xFF800000;
  const posZero = 0x00000000;
  const negZero = 0x80000000;

  ({
    HarborFpDivider unit,
    Logic clk,
    Logic reset,
    Logic start,
    Logic a,
    Logic b,
    Logic take,
  })
  make() {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final a = Logic(name: 'a', width: 32);
    final b = Logic(name: 'b', width: 32);
    final take = Logic(name: 'take');
    final unit = HarborFpDivider(
      clk: clk,
      reset: reset,
      start: start,
      a: a,
      b: b,
      take: take,
    );
    return (
      unit: unit,
      clk: clk,
      reset: reset,
      start: start,
      a: a,
      b: b,
      take: take,
    );
  }

  /// Boots one unit and runs every case on it back to back, which also covers
  /// take-then-restart.
  Future<List<int>> divideAll(List<(int, int)> cases) async {
    final h = make();
    await h.unit.build();
    h.reset.inject(1);
    h.start.inject(0);
    h.take.inject(0);
    h.a.inject(0);
    h.b.inject(0);
    Simulator.setMaxSimTime(20000000);
    simulated = true;
    unawaited(Simulator.run());
    await h.clk.nextPosedge;
    h.reset.inject(0);
    await h.clk.nextNegedge;

    final out = <int>[];
    for (final (x, y) in cases) {
      expect(
        h.unit.ready.value.toInt(),
        1,
        reason: 'the unit must be idle before each case',
      );
      h.a.inject(x);
      h.b.inject(y);
      h.start.inject(1);
      await h.clk.nextPosedge;
      h.start.inject(0);

      var done = false;
      for (var i = 0; i < 4 * HarborFpDivider.mantissaSteps + 16; i++) {
        await h.clk.nextNegedge;
        if (h.unit.resultValid.value.toInt() == 1) {
          done = true;
          break;
        }
        await h.clk.nextPosedge;
      }
      expect(done, isTrue, reason: 'a divide must finish');
      out.add(h.unit.result.value.toInt());

      h.take.inject(1);
      await h.clk.nextPosedge;
      h.take.inject(0);
      await h.clk.nextNegedge;
    }
    return out;
  }

  /// How many units of last place [got] is from the correctly rounded answer.
  int ulpsOff(int got, double want) {
    final ideal = bits(want);
    return (got - ideal).abs();
  }

  test(
    'ordinary divides land within one ulp of the rounded answer',
    () async {
      final pairs = <(double, double)>[
        (1.0, 2.0),
        (2.0, 1.0),
        (1.0, 3.0),
        (10.0, 4.0),
        (-7.5, 2.5),
        (7.5, -2.5),
        (1.0, 1.0),
        (123456.0, 7.0),
        (0.125, 64.0),
        (3.4028235e38, 2.0),
        (1.1754944e-38, 0.5),
        (655.35, 1.37),
        (1e-20, 1e10),
        (1e20, 1e-10),
      ];
      final got = await divideAll([
        for (final (x, y) in pairs) (bits(x), bits(y)),
      ]);
      for (var i = 0; i < pairs.length; i++) {
        final (x, y) = pairs[i];
        final want = value(bits(x)) / value(bits(y));
        expect(
          ulpsOff(got[i], want),
          lessThanOrEqualTo(1),
          reason:
              '$x / $y gave ${value(got[i])}, wanted about $want '
              '(truncation allows one ulp)',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a reciprocal is exact when the answer is a power of two',
    () async {
      // Nothing to truncate, so these must be bit exact rather than close.
      final got = await divideAll([
        (bits(1.0), bits(2.0)),
        (bits(1.0), bits(4.0)),
        (bits(1.0), bits(0.5)),
        (bits(6.0), bits(3.0)),
        (bits(-1.0), bits(8.0)),
      ]);
      expect(got, [bits(0.5), bits(0.25), bits(2.0), bits(2.0), bits(-0.125)]);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'the special cases follow IEEE exactly',
    () async {
      final got = await divideAll([
        (nan, bits(1.0)), // a NaN operand
        (bits(1.0), nan),
        (posZero, posZero), // 0/0
        (posInf, posInf), // inf/inf
        (bits(1.0), posZero), // x/0
        (bits(-1.0), posZero),
        (bits(1.0), negZero),
        (posInf, bits(2.0)), // inf/finite
        (negInf, bits(2.0)),
        (bits(2.0), posInf), // finite/inf
        (bits(-2.0), posInf),
        (posZero, bits(2.0)), // 0/finite
        (negZero, bits(2.0)),
      ]);
      expect(got, [
        nan,
        nan,
        nan,
        nan,
        posInf,
        negInf,
        negInf,
        posInf,
        negInf,
        posZero,
        negZero,
        posZero,
        negZero,
      ]);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('a subnormal input reads as zero', () async {
    // Documented, not IEEE: there is no gradual underflow here.
    const subnormal = 0x00000001;
    final got = await divideAll([
      (subnormal, bits(1.0)), // reads as 0/1
      (bits(1.0), subnormal), // reads as 1/0
      (subnormal, subnormal), // reads as 0/0
    ]);
    expect(got, [posZero, posInf, nan]);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'overflow gives infinity and underflow gives zero',
    () async {
      final got = await divideAll([
        (bits(3.4028235e38), bits(0.25)), // past the largest finite
        (bits(-3.4028235e38), bits(0.25)),
        (bits(1.1754944e-38), bits(3.4028235e38)), // under the smallest normal
      ]);
      expect(got, [posInf, negInf, posZero]);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'the result holds until it is taken',
    () async {
      final h = make();
      await h.unit.build();
      h.reset.inject(1);
      h.start.inject(0);
      h.take.inject(0);
      h.a.inject(bits(1.0));
      h.b.inject(bits(2.0));
      Simulator.setMaxSimTime(2000000);
      simulated = true;
      unawaited(Simulator.run());
      await h.clk.nextPosedge;
      h.reset.inject(0);
      await h.clk.nextNegedge;
      h.start.inject(1);
      await h.clk.nextPosedge;
      h.start.inject(0);

      for (var i = 0; i < 200; i++) {
        await h.clk.nextNegedge;
        if (h.unit.resultValid.value.toInt() == 1) break;
        await h.clk.nextPosedge;
      }
      expect(h.unit.result.value.toInt(), bits(0.5));
      expect(
        h.unit.ready.value.toInt(),
        0,
        reason: 'a held result blocks start',
      );

      for (var i = 0; i < 6; i++) {
        await h.clk.nextPosedge;
        await h.clk.nextNegedge;
        expect(h.unit.resultValid.value.toInt(), 1);
        expect(h.unit.result.value.toInt(), bits(0.5));
      }

      h.take.inject(1);
      await h.clk.nextPosedge;
      h.take.inject(0);
      await h.clk.nextNegedge;
      expect(h.unit.resultValid.value.toInt(), 0);
      expect(h.unit.ready.value.toInt(), 1);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a special case skips the mantissa walk',
    () async {
      // The answer does not depend on the significands, so it should not cost
      // 24 cycles to find out.
      final h = make();
      await h.unit.build();
      h.reset.inject(1);
      h.start.inject(0);
      h.take.inject(0);
      h.a.inject(bits(1.0));
      h.b.inject(posZero);
      Simulator.setMaxSimTime(2000000);
      simulated = true;
      unawaited(Simulator.run());
      await h.clk.nextPosedge;
      h.reset.inject(0);
      await h.clk.nextNegedge;
      h.start.inject(1);
      await h.clk.nextPosedge;
      h.start.inject(0);

      var cycles = 0;
      while (cycles < 100) {
        await h.clk.nextNegedge;
        if (h.unit.resultValid.value.toInt() == 1) break;
        await h.clk.nextPosedge;
        cycles++;
      }
      expect(h.unit.result.value.toInt(), posInf);
      expect(
        cycles,
        lessThan(4),
        reason: 'a special answer is ready at once, not after the walk',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

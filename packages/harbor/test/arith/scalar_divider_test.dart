import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests for [HarborScalarDivider].
///
/// Each answer is checked against the same arithmetic in Dart, including the
/// two cases RISC-V defines rather than leaves open. One simulation runs all
/// the cases of a test back to back, because the Simulator is global and a
/// second run in one test does not give a second machine. Running them back to
/// back also covers take and restart.
void main() {
  var simulated = false;
  tearDown(() async {
    if (simulated) {
      await Simulator.endSimulation();
      simulated = false;
    }
    Simulator.reset();
  });

  const width = 32;
  int u32(int v) => v & 0xFFFFFFFF;
  int s32(int v) => v >= 0x80000000 ? v - 0x100000000 : v;

  /// The RISC-V answer for one divide, special cases included.
  int expected(HarborDivOp op, int a, int b) {
    final signed =
        op == HarborDivOp.quotientSigned || op == HarborDivOp.remainderSigned;
    final quotient =
        op == HarborDivOp.quotientSigned || op == HarborDivOp.quotientUnsigned;
    if (b == 0) {
      return quotient ? 0xFFFFFFFF : a;
    }
    if (signed) {
      final sa = s32(a);
      final sb = s32(b);
      if (sa == -2147483648 && sb == -1) {
        return quotient ? a : 0;
      }
      final q = sa ~/ sb;
      return u32(quotient ? q : sa - q * sb);
    }
    final q = a ~/ b;
    return u32(quotient ? q : a - q * b);
  }

  ({
    HarborScalarDivider unit,
    Logic clk,
    Logic reset,
    Logic start,
    Logic dividend,
    Logic divisor,
    Logic op,
    Logic take,
  })
  make() {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final dividend = Logic(name: 'dividend', width: width);
    final divisor = Logic(name: 'divisor', width: width);
    final op = Logic(name: 'op', width: 2);
    final take = Logic(name: 'take');
    final unit = HarborScalarDivider(
      clk: clk,
      reset: reset,
      start: start,
      dividend: dividend,
      divisor: divisor,
      op: op,
      take: take,
      width: width,
    );
    return (
      unit: unit,
      clk: clk,
      reset: reset,
      start: start,
      dividend: dividend,
      divisor: divisor,
      op: op,
      take: take,
    );
  }

  /// Boots one divider and runs every case on it, taking each result.
  Future<List<int>> divideAll(List<(HarborDivOp, int, int)> cases) async {
    final h = make();
    await h.unit.build();
    h.reset.inject(1);
    h.start.inject(0);
    h.take.inject(0);
    h.dividend.inject(0);
    h.divisor.inject(0);
    h.op.inject(0);
    Simulator.setMaxSimTime(200000000);
    simulated = true;
    unawaited(Simulator.run());
    await h.clk.nextPosedge;
    h.reset.inject(0);
    await h.clk.nextNegedge;

    final out = <int>[];
    for (final (op, a, b) in cases) {
      expect(h.unit.ready.value.toInt(), 1, reason: 'the unit must be idle');
      h.dividend.inject(a);
      h.divisor.inject(b);
      h.op.inject(op.index);
      h.start.inject(1);
      await h.clk.nextPosedge;
      h.start.inject(0);

      var done = false;
      for (var i = 0; i < 4 * width; i++) {
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

  test(
    'every operation matches the same arithmetic in Dart',
    () async {
      // A mix of signs and magnitudes, so the signed and unsigned forms cannot
      // agree by accident.
      final pairs = <(int, int)>[
        (100, 7),
        (0xFFFFFFF6, 3), // minus ten over three
        (7, 0xFFFFFFFF), // seven over minus one
        (0x80000000, 2),
        (1, 1),
        (0, 5),
        (0xFFFFFFFF, 0xFFFFFFFF),
        (123456789, 1000),
      ];
      final cases = <(HarborDivOp, int, int)>[
        for (final op in HarborDivOp.values)
          for (final (a, b) in pairs) (op, a, b),
      ];
      final got = await divideAll(cases);
      for (var i = 0; i < cases.length; i++) {
        final (op, a, b) = cases[i];
        expect(
          got[i],
          expected(op, a, b),
          reason: '$op of 0x${a.toRadixString(16)} by 0x${b.toRadixString(16)}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'divide by zero gives the answers the spec names',
    () async {
      final got = await divideAll([
        (HarborDivOp.quotientUnsigned, 42, 0),
        (HarborDivOp.quotientSigned, 42, 0),
        (HarborDivOp.remainderUnsigned, 42, 0),
        (HarborDivOp.remainderSigned, 42, 0),
      ]);
      expect(
        got.take(2),
        everyElement(0xFFFFFFFF),
        reason: 'an all ones quotient, which reads as minus one signed',
      );
      expect(got.skip(2), everyElement(42), reason: 'the dividend remains');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'the one signed overflow gives the dividend and zero',
    () async {
      // The most negative value over minus one has no representable quotient.
      final got = await divideAll([
        (HarborDivOp.quotientSigned, 0x80000000, 0xFFFFFFFF),
        (HarborDivOp.remainderSigned, 0x80000000, 0xFFFFFFFF),
        // Unsigned reads the same bits as large positives, so it does not
        // overflow and must not take the special path.
        (HarborDivOp.quotientUnsigned, 0x80000000, 0xFFFFFFFF),
      ]);
      expect(got[0], 0x80000000, reason: 'the dividend is the quotient');
      expect(got[1], 0, reason: 'and the remainder is zero');
      expect(
        got[2],
        0,
        reason: 'unsigned, this is a small value over a big one',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('a random sweep matches Dart', () async {
    final rng = Random(20261006);
    final cases = <(HarborDivOp, int, int)>[];
    for (var i = 0; i < 60; i++) {
      final op = HarborDivOp.values[rng.nextInt(4)];
      final a = rng.nextInt(1 << 32);
      // Never zero here, because the zero case has its own test above.
      final b = 1 + rng.nextInt((1 << 32) - 1);
      cases.add((op, a, b));
    }
    final got = await divideAll(cases);
    for (var i = 0; i < cases.length; i++) {
      final (op, a, b) = cases[i];
      expect(
        got[i],
        expected(op, a, b),
        reason: '$op of 0x${a.toRadixString(16)} by 0x${b.toRadixString(16)}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  test(
    'a result is held while take is low, then consumed',
    () async {
      final h = make();
      await h.unit.build();
      h.reset.inject(1);
      h.start.inject(0);
      h.take.inject(0);
      h.dividend.inject(84);
      h.divisor.inject(2);
      h.op.inject(HarborDivOp.quotientUnsigned.index);
      Simulator.setMaxSimTime(20000000);
      simulated = true;
      unawaited(Simulator.run());
      await h.clk.nextPosedge;
      h.reset.inject(0);
      await h.clk.nextNegedge;
      h.start.inject(1);
      await h.clk.nextPosedge;
      h.start.inject(0);

      for (var i = 0; i < 4 * width; i++) {
        await h.clk.nextNegedge;
        if (h.unit.resultValid.value.toInt() == 1) break;
        await h.clk.nextPosedge;
      }
      expect(h.unit.result.value.toInt(), 42);
      expect(
        h.unit.ready.value.toInt(),
        0,
        reason: 'a held result blocks start',
      );

      for (var i = 0; i < 6; i++) {
        await h.clk.nextPosedge;
        await h.clk.nextNegedge;
        expect(h.unit.resultValid.value.toInt(), 1);
        expect(h.unit.result.value.toInt(), 42);
      }

      h.take.inject(1);
      await h.clk.nextPosedge;
      h.take.inject(0);
      await h.clk.nextNegedge;
      expect(h.unit.resultValid.value.toInt(), 0);
      expect(
        h.unit.ready.value.toInt(),
        1,
        reason: 'the unit frees after take',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('a narrower width still divides', () async {
    // The width is a parameter, so a consumer can build a smaller unit.
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final a = Logic(name: 'a', width: 8);
    final b = Logic(name: 'b', width: 8);
    final op = Logic(name: 'op', width: 2);
    final take = Logic(name: 'take');
    final unit = HarborScalarDivider(
      clk: clk,
      reset: reset,
      start: start,
      dividend: a,
      divisor: b,
      op: op,
      take: take,
      width: 8,
    );
    await unit.build();
    reset.inject(1);
    start.inject(0);
    take.inject(0);
    a.inject(100);
    b.inject(7);
    op.inject(HarborDivOp.quotientUnsigned.index);
    Simulator.setMaxSimTime(2000000);
    simulated = true;
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextNegedge;
    start.inject(1);
    await clk.nextPosedge;
    start.inject(0);
    for (var i = 0; i < 40; i++) {
      await clk.nextNegedge;
      if (unit.resultValid.value.toInt() == 1) break;
      await clk.nextPosedge;
    }
    expect(unit.result.value.toInt(), 14, reason: '100 over 7');
  }, timeout: const Timeout(Duration(minutes: 5)));
}

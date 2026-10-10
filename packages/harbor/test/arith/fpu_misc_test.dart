import 'dart:math';

import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fp_misc_path.dart';
import 'package:harbor/src/arith/fp_unpack.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'fp_model.dart';
import 'fp_stall_bench.dart';
import 'testfloat_vectors.dart';

final _opIdxW = (HarborFpOp.values.length - 1).bitLength;

class _Bench {
  final HarborFpuConfig config;
  late final HarborFpMiscPath path;
  final opL = Logic(name: 'op', width: _opIdxW);
  late final Logic fmtL;
  late final Logic aL;
  late final Logic bL;

  final en = Logic(name: 'en');

  _Bench(this.config, {Logic? clk}) {
    fmtL = Logic(name: 'fmt', width: config.fmtWidth);
    aL = Logic(name: 'a', width: config.widest.width);
    bL = Logic(name: 'b', width: config.widest.width);
    path = HarborFpMiscPath(
      config,
      op: opL,
      fmt: fmtL,
      a: aL,
      b: bL,
      clk: clk,
      enables: clk == null ? const {} : {for (final k in config.cuts) k: en},
    );
  }

  Future<void> build() => path.build();

  ({BigInt bits, int flags}) run(
    HarborFpOp op,
    int fmtIndex,
    BigInt a,
    BigInt b,
  ) {
    opL.put(op.index);
    fmtL.put(fmtIndex);
    aL.put(a);
    bL.put(b);
    return (
      bits: path.result.value.toBigInt(),
      flags: path.flags.value.toInt(),
    );
  }
}

HarborFpuConfig _cfg(
  List<HarborFpFormat> formats,
  Set<HarborFpOp> ops, {
  bool ftz = false,
}) => HarborFpuConfig(formats: formats, ops: ops, stages: 0, ftz: ftz);

/// The model result of a misc op. Bits above the format are ignored.
FpResult _model(
  HarborFpOp op,
  HarborFpFormat f,
  BigInt a,
  BigInt b, {
  bool ftz = false,
}) {
  final mask = (BigInt.one << f.width) - BigInt.one;
  a &= mask;
  b &= mask;
  return switch (op) {
    HarborFpOp.eq => fpCompare(f, a, b, FpCompareKind.eq, ftz: ftz),
    HarborFpOp.lt => fpCompare(f, a, b, FpCompareKind.lt, ftz: ftz),
    HarborFpOp.le => fpCompare(f, a, b, FpCompareKind.le, ftz: ftz),
    HarborFpOp.ltq => fpCompare(f, a, b, FpCompareKind.ltq, ftz: ftz),
    HarborFpOp.leq => fpCompare(f, a, b, FpCompareKind.leq, ftz: ftz),
    HarborFpOp.min => fpMin(f, a, b, ftz: ftz),
    HarborFpOp.max => fpMax(f, a, b, ftz: ftz),
    HarborFpOp.minm => fpMinM(f, a, b, ftz: ftz),
    HarborFpOp.maxm => fpMaxM(f, a, b, ftz: ftz),
    HarborFpOp.classify => fpClass(f, a),
    HarborFpOp.sgnj => fpSgnj(f, a, b, FpSgnjKind.inject),
    HarborFpOp.sgnjn => fpSgnj(f, a, b, FpSgnjKind.negate),
    HarborFpOp.sgnjx => fpSgnj(f, a, b, FpSgnjKind.xor),
    _ => throw ArgumentError.value(op),
  };
}

/// An operand of [f] with random bits above the format, weighted to zeros,
/// subnormals, Inf and NaN.
BigInt _operand(Random r, HarborFpFormat f, int width) {
  final ones = (BigInt.one << f.exponentWidth) - BigInt.one;
  var v = _randBits(r, f.width);
  final exp = switch (r.nextInt(6)) {
    0 => BigInt.zero,
    1 => ones,
    _ => null,
  };
  if (exp != null) {
    v &= ~(ones << f.mantissaWidth);
    v |= exp << f.mantissaWidth;
    if (r.nextInt(3) == 0) {
      v &= ~((BigInt.one << f.mantissaWidth) - BigInt.one);
    }
  }
  final upper = _randBits(r, width) >> f.width << f.width;
  return v | (r.nextBool() ? upper : BigInt.zero);
}

BigInt _randBits(Random r, int width) {
  var v = BigInt.zero;
  for (var i = 0; i < width; i += 16) {
    v = (v << 16) | BigInt.from(r.nextInt(1 << 16));
  }
  return v & ((BigInt.one << width) - BigInt.one);
}

void main() {
  tearDown(Simulator.reset);

  final f16 = HarborFpFormat.fp16;
  final f32 = HarborFpFormat.fp32;
  final f64 = HarborFpFormat.fp64;
  final mixed = [f16, f32, f64];

  final skipReason = testFloatAvailable()
      ? null
      : 'testfloat_gen not found; set HARBOR_TESTFLOAT_GEN or run inside '
            '`nix develop`';

  group('compare, TestFloat level 1', () {
    final specs = [
      ('eq', HarborFpOp.eq),
      ('lt', HarborFpOp.lt),
      ('le', HarborFpOp.le),
      ('lt_quiet', HarborFpOp.ltq),
      ('le_quiet', HarborFpOp.leq),
    ];
    final fmts = [('f16', 0, f16), ('f32', 1, f32), ('f64', 2, f64)];

    for (final (tfSuffix, hop) in specs) {
      for (final (prefix, idx, fmt) in fmts) {
        test('$prefix $tfSuffix', () async {
          final b = _Bench(_cfg(mixed, {hop}));
          await b.build();
          var n = 0;
          await for (final c in testFloatCases(
            '${prefix}_$tfSuffix',
            rm: 'near_even',
          )) {
            final got = b.run(hop, idx, c.operands[0], c.operands[1]);
            expect(
              got.bits,
              c.result,
              reason:
                  '$fmt $tfSuffix ${c.operands[0].toRadixString(16)} '
                  '${c.operands[1].toRadixString(16)}',
            );
            expect(got.flags, c.flags & 0x10);
            n++;
          }
          expect(n, greaterThan(0));
        }, skip: skipReason);
      }
    }
  });

  group('compare vs model, random and ftz', () {
    for (final ftz in [false, true]) {
      test('ftz $ftz', () async {
        final b = _Bench(
          _cfg(mixed, {
            HarborFpOp.eq,
            HarborFpOp.lt,
            HarborFpOp.le,
            HarborFpOp.ltq,
            HarborFpOp.leq,
          }, ftz: ftz),
        );
        await b.build();
        final r = Random(ftz ? 101 : 100);
        final kinds = {
          HarborFpOp.eq: FpCompareKind.eq,
          HarborFpOp.lt: FpCompareKind.lt,
          HarborFpOp.le: FpCompareKind.le,
          HarborFpOp.ltq: FpCompareKind.ltq,
          HarborFpOp.leq: FpCompareKind.leq,
        };
        for (final (i, f) in [(0, f16), (1, f32), (2, f64)]) {
          for (var n = 0; n < 3000; n++) {
            final a = _randBits(r, f.width);
            final bb = _randBits(r, f.width);
            for (final hop in kinds.keys) {
              final got = b.run(hop, i, a, bb);
              final want = fpCompare(f, a, bb, kinds[hop]!, ftz: ftz);
              expect(
                got.bits,
                want.bits,
                reason:
                    '$f $hop ${a.toRadixString(16)} ${bb.toRadixString(16)}',
              );
              expect(got.flags, want.flags);
            }
          }
        }
      });
    }
  });

  group('min/max vs model', () {
    for (final ftz in [false, true]) {
      test('random and specials, ftz $ftz', () async {
        final b = _Bench(
          _cfg(mixed, {
            HarborFpOp.min,
            HarborFpOp.max,
            HarborFpOp.minm,
            HarborFpOp.maxm,
          }, ftz: ftz),
        );
        await b.build();
        final r = Random(ftz ? 201 : 200);
        final specials = <BigInt Function(HarborFpFormat)>[
          (f) => BigInt.zero,
          (f) => BigInt.one << (f.width - 1),
          (f) =>
              (((BigInt.one << f.exponentWidth) - BigInt.one) <<
                  f.mantissaWidth) |
              (BigInt.one << (f.mantissaWidth - 1)),
          (f) =>
              ((BigInt.one << f.exponentWidth) - BigInt.one) << f.mantissaWidth,
          (f) =>
              (((BigInt.one << f.exponentWidth) - BigInt.one) <<
                  f.mantissaWidth) |
              BigInt.one,
        ];
        for (final (i, f) in [(0, f16), (1, f32), (2, f64)]) {
          final cases = <(BigInt, BigInt)>[];
          for (final sa in specials) {
            for (final sb in specials) {
              cases.add((sa(f), sb(f)));
            }
          }
          for (var n = 0; n < 4000; n++) {
            cases.add((_randBits(r, f.width), _randBits(r, f.width)));
          }
          for (final (a, bb) in cases) {
            for (final (hop, fn) in [
              (HarborFpOp.min, fpMin),
              (HarborFpOp.max, fpMax),
              (HarborFpOp.minm, fpMinM),
              (HarborFpOp.maxm, fpMaxM),
            ]) {
              final got = b.run(hop, i, a, bb);
              final want = fn(f, a, bb, ftz: ftz);
              expect(
                got.bits,
                want.bits,
                reason:
                    '$f $hop ${a.toRadixString(16)} ${bb.toRadixString(16)}',
              );
              expect(got.flags, want.flags);
            }
          }
        }
      });
    }
  });

  test('classify, every class, unaffected by ftz', () async {
    for (final ftz in [false, true]) {
      final b = _Bench(_cfg(mixed, {HarborFpOp.classify}, ftz: ftz));
      await b.build();
      for (final (i, f) in [(0, f16), (1, f32), (2, f64)]) {
        final patterns = <BigInt>[
          BigInt.zero,
          BigInt.one << (f.width - 1),
          BigInt.one, // smallest subnormal, positive
          (BigInt.one << (f.width - 1)) |
              BigInt.one, // smallest subnormal, negative
          BigInt.one << f.mantissaWidth, // smallest normal, positive
          (BigInt.one << (f.width - 1)) | (BigInt.one << f.mantissaWidth),
          ((BigInt.one << f.exponentWidth) - BigInt.one) <<
              f.mantissaWidth, // +inf
          (BigInt.one << (f.width - 1)) |
              (((BigInt.one << f.exponentWidth) - BigInt.one) <<
                  f.mantissaWidth), // -inf
          (((BigInt.one << f.exponentWidth) - BigInt.one) << f.mantissaWidth) |
              (BigInt.one << (f.mantissaWidth - 1)), // qNaN
          (((BigInt.one << f.exponentWidth) - BigInt.one) << f.mantissaWidth) |
              BigInt.one, // sNaN
        ];
        final seen = <int>{};
        for (final bits in patterns) {
          final got = b.run(HarborFpOp.classify, i, bits, BigInt.zero);
          final want = fpClass(f, bits);
          expect(got.bits, want.bits, reason: '$f ${bits.toRadixString(16)}');
          expect(got.flags, 0);
          seen.add(got.bits.bitLength - 1);
        }
        expect(seen.length, 10, reason: '$f missed a class');
      }
    }
  });

  test('sign injection vs model, unaffected by ftz', () async {
    for (final ftz in [false, true]) {
      final b = _Bench(
        _cfg(mixed, {
          HarborFpOp.sgnj,
          HarborFpOp.sgnjn,
          HarborFpOp.sgnjx,
        }, ftz: ftz),
      );
      await b.build();
      final r = Random(300);
      final kinds = {
        HarborFpOp.sgnj: FpSgnjKind.inject,
        HarborFpOp.sgnjn: FpSgnjKind.negate,
        HarborFpOp.sgnjx: FpSgnjKind.xor,
      };
      for (final (i, f) in [(0, f16), (1, f32), (2, f64)]) {
        for (var n = 0; n < 2000; n++) {
          final a = _randBits(r, f.width);
          final bb = _randBits(r, f.width);
          for (final hop in kinds.keys) {
            final got = b.run(hop, i, a, bb);
            final want = fpSgnj(f, a, bb, kinds[hop]!);
            expect(got.bits, want.bits, reason: '$f $hop');
            expect(got.flags, 0);
          }
        }
        // A subnormal operand keeps its exact mantissa through sgnj even
        // with ftz on.
        final sub = BigInt.one | (BigInt.one << (f.width - 1));
        for (final hop in kinds.keys) {
          final got = b.run(hop, i, sub, BigInt.zero);
          final want = fpSgnj(f, sub, BigInt.zero, kinds[hop]!);
          expect(got.bits, want.bits);
        }
      }
    }
  });

  test('min and max give zeros above the format for boxed inputs', () async {
    final b = _Bench(
      _cfg(mixed, {
        HarborFpOp.min,
        HarborFpOp.max,
        HarborFpOp.minm,
        HarborFpOp.maxm,
      }),
    );
    await b.build();
    final boxed = BigInt.parse('FFFFFFFFFFFF3C00', radix: 16);
    final other = BigInt.parse('FFFFFFFFFFFFBC00', radix: 16);
    for (final op in [
      HarborFpOp.min,
      HarborFpOp.max,
      HarborFpOp.minm,
      HarborFpOp.maxm,
    ]) {
      expect(
        b.run(op, 0, boxed, other).bits,
        _model(op, f16, boxed, other).bits,
      );
      expect(b.run(op, 0, boxed, other).bits >> 16, BigInt.zero);
    }
    expect(b.run(HarborFpOp.max, 0, boxed, other).bits, BigInt.from(0x3c00));
    expect(b.run(HarborFpOp.min, 0, boxed, other).bits, BigInt.from(0xbc00));
    final r = Random(400);
    for (var n = 0; n < 3000; n++) {
      final i = r.nextInt(3);
      final f = mixed[i];
      final x = _operand(r, f, 64);
      final y = _operand(r, f, 64);
      for (final op in [
        HarborFpOp.min,
        HarborFpOp.max,
        HarborFpOp.minm,
        HarborFpOp.maxm,
      ]) {
        final got = b.run(op, i, x, y);
        final want = _model(op, f, x, y);
        expect(got.bits, want.bits, reason: '$f $op $x $y');
        expect(got.flags, want.flags);
      }
    }
  });

  for (final (stages, ftz) in [(2, false), (6, true)]) {
    test(
      'registers at the cuts of $stages stages, mixed ops, stalls',
      () async {
        final config = HarborFpuConfig(
          formats: mixed,
          ops: harborFpMiscOps,
          stages: stages,
          ftz: ftz,
        );
        final clk = SimpleClockGenerator(10).clk;
        final b = _Bench(config, clk: clk);
        await b.build();
        final r = Random(stages);
        final ops = harborFpMiscOps.toList();
        final cases = [
          for (var n = 0; n < 400; n++)
            () {
              final i = r.nextInt(3);
              // Op pairs with different result kinds come back to back.
              final op = n < 8
                  ? [HarborFpOp.lt, HarborFpOp.classify][n % 2]
                  : ops[r.nextInt(ops.length)];
              return (
                op,
                i,
                _operand(r, mixed[i], 64),
                _operand(r, mixed[i], 64),
              );
            }(),
        ];
        void put((HarborFpOp, int, BigInt, BigInt) k) {
          b.opL.put(k.$1.index);
          b.fmtL.put(k.$2);
          b.aL.put(k.$3);
          b.bL.put(k.$4);
        }

        final seen = await runWithStalls(
          clk: clk,
          en: b.en,
          latency: config.latency,
          count: cases.length,
          put: (i) => put(cases[i]),
          putJunk: () => put(cases[r.nextInt(cases.length)]),
          read: () => (
            bits: b.path.result.value.toBigInt(),
            flags: b.path.flags.value.toInt(),
          ),
          random: r,
        );
        final stalls = checkStallRun(seen, cases.length, (i, got) {
          final (op, fi, x, y) = cases[i];
          final want = _model(op, mixed[fi], x, y, ftz: ftz);
          expect(got.bits, want.bits, reason: 'case $i $op ${mixed[fi]} $x $y');
          expect(got.flags, want.flags, reason: 'case $i $op');
        });
        expect(stalls, greaterThan(50));
      },
    );
  }

  test('bits that cross each cut', () {
    final b = _Bench(_cfg(mixed, harborFpMiscOps));
    expect([
      for (final k in HarborFpCut.values)
        b.path.cuts[k]!.fold(0, (s, l) => s + l.width),
    ], List.filled(7, 69));
  });

  test('classify shares the value unpack unless ftz is set', () async {
    for (final ftz in [false, true]) {
      final b = _Bench(
        _cfg(mixed, {HarborFpOp.eq, HarborFpOp.classify}, ftz: ftz),
      );
      await b.build();
      final names = [
        for (final m in b.path.subModules)
          if (m is HarborFpUnpack) m.definitionName,
      ];
      const base = 'HarborFpUnpack_E5M10_E8M23_E11M52';
      expect(names, [base, base, if (ftz) '${base}_NoFtz']);
    }
  });

  test('each op alone builds and is correct', () async {
    final r = Random(500);
    for (final op in harborFpMiscOps) {
      Simulator.reset();
      final b = _Bench(_cfg(mixed, {op}));
      await b.build();
      for (var n = 0; n < 200; n++) {
        final i = r.nextInt(3);
        final x = _operand(r, mixed[i], 64);
        final y = _operand(r, mixed[i], 64);
        final got = b.run(op, i, x, y);
        final want = _model(op, mixed[i], x, y);
        expect(got.bits, want.bits, reason: '$op ${mixed[i]} $x $y');
        expect(got.flags, want.flags, reason: '$op');
      }
    }
  });
}

import 'dart:math';

import 'package:harbor/src/arith/fp_estimate.dart';
import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'fp_model.dart';
import 'fp_stall_bench.dart';

final _opIdxW = (HarborFpOp.values.length - 1).bitLength;

class _Bench {
  final HarborFpuConfig config;
  late final HarborFpEstimate path;
  final opL = Logic(name: 'op', width: _opIdxW);
  late final Logic fmtL;
  final rmL = Logic(name: 'rm', width: 3);
  late final Logic aL;

  final en = Logic(name: 'en');

  _Bench(this.config, {Logic? clk}) {
    fmtL = Logic(name: 'fmt', width: config.fmtWidth);
    aL = Logic(name: 'a', width: config.widest.width);
    path = HarborFpEstimate(
      config,
      op: opL,
      fmt: fmtL,
      rm: rmL,
      a: aL,
      clk: clk,
      enables: clk == null ? const {} : {for (final k in config.cuts) k: en},
    );
  }

  Future<void> build() => path.build();

  ({BigInt bits, int flags}) run(
    HarborFpOp op,
    int fmtIndex,
    BigInt a, {
    int rm = 0,
  }) {
    opL.put(op.index);
    fmtL.put(fmtIndex);
    rmL.put(rm);
    aL.put(a);
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

  group('rec7 vs model', () {
    for (final ftz in [false, true]) {
      test('random and specials, ftz $ftz', () async {
        final b = _Bench(_cfg(mixed, {HarborFpOp.rec7}, ftz: ftz));
        await b.build();
        final r = Random(ftz ? 901 : 900);
        for (final (i, f) in [(0, f16), (1, f32), (2, f64)]) {
          final specials = <BigInt>[
            BigInt.zero,
            BigInt.one << (f.width - 1),
            ((BigInt.one << f.exponentWidth) - BigInt.one) << f.mantissaWidth,
            (((BigInt.one << f.exponentWidth) - BigInt.one) <<
                    f.mantissaWidth) |
                (BigInt.one << (f.width - 1)),
            (((BigInt.one << f.exponentWidth) - BigInt.one) <<
                    f.mantissaWidth) |
                (BigInt.one << (f.mantissaWidth - 1)),
            (((BigInt.one << f.exponentWidth) - BigInt.one) <<
                    f.mantissaWidth) |
                BigInt.one,
            BigInt.one,
            BigInt.one << (f.mantissaWidth - 1),
            BigInt.one << f.mantissaWidth,
          ];
          for (final rm in [0, 1, 2, 3, 4]) {
            for (final bits in specials) {
              final got = b.run(HarborFpOp.rec7, i, bits, rm: rm);
              final want = fpRec7(f, bits, rm, ftz: ftz);
              expect(
                got.bits,
                want.bits,
                reason: '$f rm $rm ${bits.toRadixString(16)}',
              );
              expect(got.flags, want.flags);
            }
            for (var n = 0; n < 3000; n++) {
              final bits = _randBits(r, f.width);
              final got = b.run(HarborFpOp.rec7, i, bits, rm: rm);
              final want = fpRec7(f, bits, rm, ftz: ftz);
              if (got.bits != want.bits || got.flags != want.flags) {
                fail(
                  '$f rm $rm ${bits.toRadixString(16)}: got '
                  '${got.bits.toRadixString(16)}/${got.flags}, want '
                  '${want.bits.toRadixString(16)}/${want.flags}',
                );
              }
            }
          }
        }
      });
    }
  });

  group('rsqrt7 vs model', () {
    for (final ftz in [false, true]) {
      test('random and specials, ftz $ftz', () async {
        final b = _Bench(_cfg(mixed, {HarborFpOp.rsqrt7}, ftz: ftz));
        await b.build();
        final r = Random(ftz ? 1001 : 1000);
        for (final (i, f) in [(0, f16), (1, f32), (2, f64)]) {
          final specials = <BigInt>[
            BigInt.zero,
            BigInt.one << (f.width - 1),
            ((BigInt.one << f.exponentWidth) - BigInt.one) << f.mantissaWidth,
            (((BigInt.one << f.exponentWidth) - BigInt.one) <<
                    f.mantissaWidth) |
                (BigInt.one << (f.width - 1)),
            (((BigInt.one << f.exponentWidth) - BigInt.one) <<
                    f.mantissaWidth) |
                (BigInt.one << (f.mantissaWidth - 1)),
            BigInt.one,
            BigInt.one << (f.mantissaWidth - 1),
            BigInt.one << f.mantissaWidth,
            (BigInt.one << f.mantissaWidth) | (BigInt.one << (f.width - 1)),
          ];
          for (final bits in specials) {
            final got = b.run(HarborFpOp.rsqrt7, i, bits);
            final want = fpRsqrt7(f, bits, ftz: ftz);
            expect(got.bits, want.bits, reason: '$f ${bits.toRadixString(16)}');
            expect(got.flags, want.flags);
          }
          for (var n = 0; n < 5000; n++) {
            final bits = _randBits(r, f.width);
            final got = b.run(HarborFpOp.rsqrt7, i, bits);
            final want = fpRsqrt7(f, bits, ftz: ftz);
            if (got.bits != want.bits || got.flags != want.flags) {
              fail(
                '$f ${bits.toRadixString(16)}: got '
                '${got.bits.toRadixString(16)}/${got.flags}, want '
                '${want.bits.toRadixString(16)}/${want.flags}',
              );
            }
          }
        }
      });
    }
  });

  for (final (stages, ftz) in [(2, false), (6, true)]) {
    test(
      'registers at the cuts of $stages stages, mixed ops, stalls',
      () async {
        final config = HarborFpuConfig(
          formats: mixed,
          ops: harborFpEstimateOps,
          stages: stages,
          ftz: ftz,
        );
        final clk = SimpleClockGenerator(10).clk;
        final b = _Bench(config, clk: clk);
        await b.build();
        final r = Random(stages + 10);
        BigInt operand(HarborFpFormat f) {
          var v = _randBits(r, f.width);
          // Tiny and huge values, where the results overflow or are subnormal.
          if (r.nextBool()) {
            final e = [0, 0, 1, (1 << f.exponentWidth) - 2][r.nextInt(4)];
            v &=
                ~(((BigInt.one << f.exponentWidth) - BigInt.one) <<
                    f.mantissaWidth);
            v |= BigInt.from(e) << f.mantissaWidth;
          }
          return v | (_randBits(r, 64) >> f.width << f.width);
        }

        final cases = [
          for (var n = 0; n < 400; n++)
            () {
              final i = r.nextInt(3);
              final op = r.nextBool() ? HarborFpOp.rec7 : HarborFpOp.rsqrt7;
              return (op, i, r.nextInt(5), operand(mixed[i]));
            }(),
        ];
        void put((HarborFpOp, int, int, BigInt) k) {
          b.opL.put(k.$1.index);
          b.fmtL.put(k.$2);
          b.rmL.put(k.$3);
          b.aL.put(k.$4);
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
          final (op, fi, rm, x) = cases[i];
          final f = mixed[fi];
          final bits = x & ((BigInt.one << f.width) - BigInt.one);
          final want = op == HarborFpOp.rec7
              ? fpRec7(f, bits, rm, ftz: ftz)
              : fpRsqrt7(f, bits, ftz: ftz);
          expect(got.bits, want.bits, reason: 'case $i $op $f rm $rm $x');
          expect(got.flags, want.flags, reason: 'case $i $op');
        });
        expect(stalls, greaterThan(50));
      },
    );
  }

  test('bits that cross each cut', () {
    final b = _Bench(_cfg(mixed, harborFpEstimateOps));
    expect(
      [
        for (final k in HarborFpCut.values)
          b.path.cuts[k]!.fold(0, (s, l) => s + l.width),
      ],
      [81, 35, 35, 35, 35, 69, 69],
    );
  });

  test('each op alone builds and is correct', () async {
    final r = Random(501);
    for (final op in harborFpEstimateOps) {
      Simulator.reset();
      final b = _Bench(_cfg(mixed, {op}));
      await b.build();
      for (var n = 0; n < 300; n++) {
        final i = r.nextInt(3);
        final f = mixed[i];
        final x = _randBits(r, f.width);
        final rm = r.nextInt(5);
        final got = b.run(op, i, x, rm: rm);
        final want = op == HarborFpOp.rec7 ? fpRec7(f, x, rm) : fpRsqrt7(f, x);
        expect(got.bits, want.bits, reason: '$op $f $x');
        expect(got.flags, want.flags, reason: '$op');
      }
    }
  });
}

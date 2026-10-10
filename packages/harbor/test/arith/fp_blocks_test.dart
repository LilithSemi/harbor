import 'dart:math';

import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fp_round_pack.dart';
import 'package:harbor/src/arith/fp_unpack.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'fp_model.dart';

/// Unpack and round pack, wired back to back or driven alone.
class _Bench {
  final HarborFpuConfig config;
  final fmt = Logic(name: 'fmt', width: 2);
  final operand = Logic(name: 'operand', width: 64);
  final rm = Logic(name: 'rm', width: 3);
  final sign = Logic(name: 'sign');
  final exponent = Logic(name: 'exponent', width: 13);
  final significand = Logic(name: 'significand', width: 55);
  final sticky = Logic(name: 'sticky');
  final forceNan = Logic(name: 'force_nan');
  final forceInf = Logic(name: 'force_inf');
  final forceZero = Logic(name: 'force_zero');
  final passThrough = Logic(name: 'pass_through');
  late final HarborFpUnpack unpack;
  late final HarborFpRoundPack pack;

  _Bench(this.config) {
    final fmtW = config.fmtWidth;
    final opW = config.widest.width;
    final f = fmt.getRange(0, fmtW);
    unpack = HarborFpUnpack(config, fmt: f, operand: operand.getRange(0, opW));
    final ew = unpack.exponentWidth;
    final sigW = unpack.significandWidth + 2;
    Logic pick(Logic a, Logic b) => mux(passThrough, a, b);
    pack = HarborFpRoundPack(
      config,
      fmt: f,
      rm: rm,
      sign: pick(unpack.sign, sign),
      exponent: pick(unpack.exponent, exponent.getRange(0, ew)),
      significand: pick(
        [unpack.significand, Const(0, width: 2)].swizzle(),
        significand.getRange(0, sigW),
      ),
      sticky: pick(Const(0), sticky),
      forceNan: pick(unpack.isNan, forceNan),
      forceInf: pick(unpack.isInf, forceInf),
      forceZero: pick(unpack.isZero, forceZero),
    );
  }

  int get ew => unpack.exponentWidth;
  int get sigW => pack.significandWidth;

  Future<void> build() async {
    await unpack.build();
    await pack.build();
  }

  void put(Logic l, Object v) {
    l.put(v is BigInt ? LogicValue.ofBigInt(v, l.width) : v);
  }

  ({BigInt bits, int flags}) passOne(int fmtIndex, BigInt bits) {
    put(passThrough, 1);
    put(fmt, fmtIndex);
    put(rm, 0);
    put(operand, bits);
    return (
      bits: pack.result.value.toBigInt(),
      flags: pack.flags.value.toInt(),
    );
  }

  ({BigInt bits, int flags}) roundOne({
    required int fmtIndex,
    required int rmode,
    required int s,
    required int e,
    required BigInt sig,
    required bool st,
    bool nan = false,
    bool inf = false,
    bool zero = false,
  }) {
    put(passThrough, 0);
    put(fmt, fmtIndex);
    put(rm, rmode);
    put(sign, s);
    put(exponent, BigInt.from(e) & ((BigInt.one << 13) - BigInt.one));
    put(significand, sig);
    put(sticky, st ? 1 : 0);
    put(forceNan, nan ? 1 : 0);
    put(forceInf, inf ? 1 : 0);
    put(forceZero, zero ? 1 : 0);
    return (
      bits: pack.result.value.toBigInt(),
      flags: pack.flags.value.toInt(),
    );
  }
}

BigInt _canonicalNan(HarborFpFormat f) =>
    (((BigInt.one << f.exponentWidth) - BigInt.one) << f.mantissaWidth) |
    (BigInt.one << (f.mantissaWidth - 1));

bool _isNan(HarborFpFormat f, BigInt bits) {
  final exp =
      (bits >> f.mantissaWidth) &
      ((BigInt.one << f.exponentWidth) - BigInt.one);
  final mant = bits & ((BigInt.one << f.mantissaWidth) - BigInt.one);
  return exp == (BigInt.one << f.exponentWidth) - BigInt.one &&
      mant != BigInt.zero;
}

bool _isSub(HarborFpFormat f, BigInt bits) {
  final exp =
      (bits >> f.mantissaWidth) &
      ((BigInt.one << f.exponentWidth) - BigInt.one);
  final mant = bits & ((BigInt.one << f.mantissaWidth) - BigInt.one);
  return exp == BigInt.zero && mant != BigInt.zero;
}

BigInt _randBits(Random r, int width) {
  var v = BigInt.zero;
  for (var i = 0; i < width; i += 16) {
    v = (v << 16) | BigInt.from(r.nextInt(1 << 16));
  }
  return v & ((BigInt.one << width) - BigInt.one);
}

/// Expected pass through result: the operand itself, NaN made canonical.
/// An input flushed through force_zero sets no flags.
({BigInt bits, int flags}) _passExpected(
  HarborFpFormat f,
  BigInt bits,
  bool ftz,
) {
  if (_isNan(f, bits)) return (bits: _canonicalNan(f), flags: 0);
  if (ftz && _isSub(f, bits)) {
    return (bits: bits & (BigInt.one << (f.width - 1)), flags: 0);
  }
  return (bits: bits, flags: 0);
}

/// The exact value `sig * 2^(e - sigW + 1)`, plus a bit below when [st], as
/// an operand of a wide format the model can round from.
const _src = HarborFpFormat(16, 64);

BigInt _encodeExact(int s, int e, BigInt sig, bool st, int sigW) {
  final m = (sig << 1) | (st ? BigInt.one : BigInt.zero);
  final l = m.bitLength - 1;
  final te = e - (sigW - 1) - 1 + l;
  final mant = (m - (BigInt.one << l)) << (_src.mantissaWidth - l);
  return (BigInt.from(s) << (_src.width - 1)) |
      (BigInt.from(te + _src.bias) << _src.mantissaWidth) |
      mant;
}

/// Model oracle for round and pack.
FpResult _roundExpected(
  HarborFpFormat f,
  int s,
  int e,
  BigInt sig,
  bool st,
  int sigW,
  int rmode,
  bool ftz,
) {
  if (sig == BigInt.zero && !st) {
    return FpResult(BigInt.from(s) << (f.width - 1), 0);
  }
  final a = _encodeExact(s, e, sig, st, sigW);
  return fpToFp(_src, f, a, rmode, ftz: ftz);
}

void main() {
  tearDown(Simulator.reset);

  final f16 = HarborFpFormat.fp16;
  final f32 = HarborFpFormat.fp32;
  final f64 = HarborFpFormat.fp64;
  final mixed = [f16, f32, f64];

  HarborFpuConfig cfg(List<HarborFpFormat> formats, {bool ftz = false}) =>
      HarborFpuConfig(
        formats: formats,
        ops: {HarborFpOp.add},
        stages: 0,
        ftz: ftz,
      );

  for (final ftz in [false, true]) {
    group('pass through, ftz $ftz', () {
      test('every fp16 pattern', () async {
        final b = _Bench(cfg(mixed, ftz: ftz));
        await b.build();
        for (var v = 0; v < 1 << 16; v++) {
          final bits = BigInt.from(v);
          final got = b.passOne(0, bits);
          final want = _passExpected(f16, bits, ftz);
          if (got.bits != want.bits || got.flags != want.flags) {
            fail(
              'fp16 ${v.toRadixString(16)}: got '
              '${got.bits.toRadixString(16)}/${got.flags}, want '
              '${want.bits.toRadixString(16)}/${want.flags}',
            );
          }
        }
      });

      test('random fp32 and fp64', () async {
        final b = _Bench(cfg(mixed, ftz: ftz));
        await b.build();
        final r = Random(ftz ? 11 : 10);
        for (final (i, f) in [(1, f32), (2, f64)]) {
          for (var n = 0; n < 50000; n++) {
            var bits = _randBits(r, f.width);
            // Bias toward zero and all ones exponents.
            final pick = r.nextInt(8);
            if (pick == 0) {
              bits &=
                  ~(((BigInt.one << f.exponentWidth) - BigInt.one) <<
                      f.mantissaWidth);
            }
            if (pick == 1) {
              bits |=
                  ((BigInt.one << f.exponentWidth) - BigInt.one) <<
                  f.mantissaWidth;
            }
            final got = b.passOne(i, bits);
            final want = _passExpected(f, bits, ftz);
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
    });
  }

  test('unpack ftz override', () async {
    for (final cfgFtz in [false, true]) {
      for (final ftz in [null, false, true]) {
        final config = cfg(mixed, ftz: cfgFtz);
        final fmt = Logic(name: 'fmt', width: config.fmtWidth);
        final operand = Logic(name: 'operand', width: 64);
        final u = HarborFpUnpack(config, fmt: fmt, operand: operand, ftz: ftz);
        await u.build();
        final flush = ftz ?? cfgFtz;
        expect(u.ftz, flush);
        const base = 'HarborFpUnpack_E5M10_E8M23_E11M52';
        expect(
          u.definitionName,
          ftz == null || ftz == cfgFtz
              ? base
              : (ftz ? '${base}_Ftz' : '${base}_NoFtz'),
        );
        for (final (i, f) in [(0, f16), (1, f32), (2, f64)]) {
          for (final sign in [0, 1]) {
            final bits =
                (BigInt.from(sign) << (f.width - 1)) |
                (BigInt.one << (f.mantissaWidth - 1)) |
                BigInt.one;
            fmt.put(i);
            operand.put(bits);
            expect(u.sign.value.toInt(), sign);
            expect(u.isZero.value.toBool(), flush, reason: '$f');
            expect(u.isSub.value.toBool(), !flush, reason: '$f');
            final mant =
                (bits & ((BigInt.one << f.mantissaWidth) - BigInt.one)) <<
                (52 - f.mantissaWidth);
            expect(
              u.significand.value.toBigInt(),
              flush ? BigInt.zero : mant,
              reason: '$f',
            );
          }
        }
      }
    }
  });

  test('unpack fields and classes', () async {
    final b = _Bench(cfg(mixed));
    await b.build();
    final u = b.unpack;
    final r = Random(3);
    for (final (i, f) in [(0, f16), (1, f32), (2, f64)]) {
      for (var n = 0; n < 5000; n++) {
        var bits = _randBits(r, f.width);
        if (n % 4 == 0) {
          bits &=
              ~(((BigInt.one << f.exponentWidth) - BigInt.one) <<
                  f.mantissaWidth);
        }
        if (n % 4 == 1) {
          bits |=
              ((BigInt.one << f.exponentWidth) - BigInt.one) << f.mantissaWidth;
        }
        if (n % 16 == 2) bits &= BigInt.one << (f.width - 1);
        b.passOne(i, bits);
        final expF =
            ((bits >> f.mantissaWidth) &
                    ((BigInt.one << f.exponentWidth) - BigInt.one))
                .toInt();
        final mant = bits & ((BigInt.one << f.mantissaWidth) - BigInt.one);
        final allOnes = (1 << f.exponentWidth) - 1;
        expect(u.sign.value.toInt(), (bits >> (f.width - 1)).toInt());
        expect(u.isZero.value.toBool(), expF == 0 && mant == BigInt.zero);
        expect(u.isSub.value.toBool(), expF == 0 && mant != BigInt.zero);
        expect(u.isInf.value.toBool(), expF == allOnes && mant == BigInt.zero);
        expect(u.isNan.value.toBool(), expF == allOnes && mant != BigInt.zero);
        expect(
          u.isSnan.value.toBool(),
          expF == allOnes &&
              mant != BigInt.zero &&
              (mant >> (f.mantissaWidth - 1)) == BigInt.zero,
        );
        final exp = u.exponent.value.toBigInt().toSigned(u.exponentWidth);
        expect(exp.toInt(), (expF == 0 ? 1 : expF) - f.bias);
        final hidden = expF == 0 ? BigInt.zero : BigInt.one;
        expect(
          u.significand.value.toBigInt(),
          ((hidden << f.mantissaWidth) | mant) << (52 - f.mantissaWidth),
        );
      }
    }
  });

  /// Random round pack inputs aimed at overflow, the subnormal boundary,
  /// carries, deep underflow and plain normals.
  Future<void> roundSweep(
    List<HarborFpFormat> formats,
    bool ftz,
    int perCase,
    int seed,
  ) async {
    final b = _Bench(cfg(formats, ftz: ftz));
    await b.build();
    final sigW = b.sigW;
    final maxE = (1 << (b.ew - 1)) - 1;
    final r = Random(seed);
    var checked = 0;
    for (var i = 0; i < formats.length; i++) {
      final f = formats[i];
      final minN = 1 - f.bias;
      final maxN = f.bias;
      for (var rmode = 0; rmode < 5; rmode++) {
        for (var n = 0; n < perCase; n++) {
          final region = r.nextInt(7);
          final e = switch (region) {
            0 => maxN - 2 + r.nextInt(5),
            1 => minN - f.mantissaWidth - 4 + r.nextInt(f.mantissaWidth + 8),
            2 => minN - 2 + r.nextInt(4),
            3 => -maxE + r.nextInt(2 * maxE + 1),
            _ => minN + r.nextInt(maxN - minN + 1),
          };
          var sig = _randBits(r, sigW) | (BigInt.one << (sigW - 1));
          // Long runs of ones below the format LSB make rounding carry.
          if (r.nextInt(3) == 0) {
            final lo = r.nextInt(sigW - f.mantissaWidth);
            sig |= (BigInt.one << sigW) - (BigInt.one << lo);
          }
          // Exact values: clear everything below the format LSB.
          if (r.nextInt(5) == 0) {
            sig &=
                (BigInt.one << sigW) -
                (BigInt.one << (sigW - 1 - f.mantissaWidth));
          }
          var ee = e;
          // At or below the minimum normal, leading zeros are allowed.
          if (region == 2 && r.nextBool()) {
            ee = minN;
            sig >>= 1 + r.nextInt(3);
          }
          final st = r.nextInt(3) == 0;
          final s = r.nextInt(2);
          final got = b.roundOne(
            fmtIndex: i,
            rmode: rmode,
            s: s,
            e: ee,
            sig: sig,
            st: st,
          );
          final want = _roundExpected(f, s, ee, sig, st, sigW, rmode, ftz);
          if (got.bits != want.bits || got.flags != want.flags) {
            fail(
              '$f rm $rmode s $s e $ee sig ${sig.toRadixString(16)} st $st: '
              'got ${got.bits.toRadixString(16)}/${got.flags}, want '
              '${want.bits.toRadixString(16)}/${want.flags}',
            );
          }
          checked++;
        }
        // Exact zeros of both signs.
        for (final s in [0, 1]) {
          final got = b.roundOne(
            fmtIndex: i,
            rmode: rmode,
            s: s,
            e: r.nextInt(100) - 50,
            sig: BigInt.zero,
            st: false,
          );
          expect(got.bits, BigInt.from(s) << (f.width - 1));
          expect(got.flags, 0);
        }
      }
    }
    expect(checked, formats.length * 5 * perCase);
  }

  for (final ftz in [false, true]) {
    test('round pack vs model, fp16 fp32 fp64, ftz $ftz', () async {
      await roundSweep(mixed, ftz, 2000, ftz ? 21 : 20);
    });
  }

  test('round pack vs model, fp16 bf16', () async {
    await roundSweep([f16, HarborFpFormat.bf16], false, 1000, 30);
  });

  test('round pack vs model, fp32 alone', () async {
    await roundSweep([f32], false, 1000, 31);
  });

  for (final ftz in [false, true]) {
    test('round pack vs model, fp16 bf16 fp32 fp64, ftz $ftz', () async {
      final bf16 = HarborFpFormat.bf16;
      await roundSweep([f16, bf16, f32, f64], ftz, 30000 ~/ 4, ftz ? 41 : 40);
    });
  }

  test('round pack exact zeros full exponent range', () async {
    final b = _Bench(cfg(mixed));
    await b.build();
    final f = f16;
    for (var rmode = 0; rmode < 5; rmode++) {
      for (var s = 0; s < 2; s++) {
        for (var e = -126; e <= 127; e++) {
          final got = b.roundOne(
            fmtIndex: 0,
            rmode: rmode,
            s: s,
            e: e,
            sig: BigInt.zero,
            st: false,
          );
          expect(got.bits, BigInt.from(s) << (f.width - 1));
          expect(got.flags, 0);
        }
      }
    }
  });

  test('force overrides', () async {
    final b = _Bench(cfg(mixed));
    await b.build();
    final one = BigInt.one << (b.sigW - 1);
    for (final (i, f) in [(0, f16), (1, f32), (2, f64)]) {
      for (final s in [0, 1]) {
        final nan = b.roundOne(
          fmtIndex: i,
          rmode: 0,
          s: s,
          e: 0,
          sig: one,
          st: true,
          nan: true,
          inf: true,
          zero: true,
        );
        expect(nan.bits, _canonicalNan(f));
        expect(nan.flags, 0);
        final inf = b.roundOne(
          fmtIndex: i,
          rmode: 1,
          s: s,
          e: 0,
          sig: one,
          st: true,
          inf: true,
          zero: true,
        );
        expect(
          inf.bits,
          (BigInt.from(s) << (f.width - 1)) |
              (((BigInt.one << f.exponentWidth) - BigInt.one) <<
                  f.mantissaWidth),
        );
        expect(inf.flags, 0);
        final zero = b.roundOne(
          fmtIndex: i,
          rmode: 0,
          s: s,
          e: 2000,
          sig: one,
          st: true,
          zero: true,
        );
        expect(zero.bits, BigInt.from(s) << (f.width - 1));
        expect(zero.flags, 0);
      }
    }
  });
}

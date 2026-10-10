import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/src/arith/fp_format.dart';
import 'package:test/test.dart';

import 'fp_model.dart';
import 'testfloat_vectors.dart';

const _formats = {
  'f16': HarborFpFormat.fp16,
  'f32': HarborFpFormat.fp32,
  'f64': HarborFpFormat.fp64,
};

const _rmNames = ['near_even', 'minMag', 'min', 'max', 'near_maxMag'];

String? get _skip => testFloatAvailable()
    ? null
    : 'testfloat_gen not found; set HARBOR_TESTFLOAT_GEN or run inside `nix develop`';

Future<void> _sweep(
  String tfOp,
  String rmName,
  FpResult Function(List<BigInt> operands) model, {
  int stride = 1,
  bool exact = false,
}) async {
  final cases = await testFloatCases(
    tfOp,
    rm: rmName,
    stride: stride,
    exact: exact,
  ).toList();
  expect(cases, isNotEmpty, reason: '$tfOp produced no cases');
  for (final c in cases) {
    final r = model(c.operands);
    final where =
        '$tfOp rm=$rmName ${c.operands.map((o) => o.toRadixString(16)).join(' ')}';
    expect(
      r.bits.toRadixString(16),
      c.result.toRadixString(16),
      reason: '$where bits',
    );
    expect(
      r.flags.toRadixString(16),
      c.flags.toRadixString(16),
      reason: '$where flags',
    );
  }
}

void main() {
  final skip = _skip;

  group('arithmetic', () {
    for (final entry in _formats.entries) {
      final prefix = entry.key;
      final f = entry.value;
      for (var rm = 0; rm < 5; rm++) {
        final rmName = _rmNames[rm];

        test('${prefix}_add rm=$rmName', () {
          return _sweep(
            '${prefix}_add',
            rmName,
            (ops) => fpAdd(f, ops[0], ops[1], rm),
          );
        }, skip: skip);

        test('${prefix}_sub rm=$rmName', () {
          return _sweep(
            '${prefix}_sub',
            rmName,
            (ops) => fpSub(f, ops[0], ops[1], rm),
          );
        }, skip: skip);

        test('${prefix}_mul rm=$rmName', () {
          return _sweep(
            '${prefix}_mul',
            rmName,
            (ops) => fpMul(f, ops[0], ops[1], rm),
          );
        }, skip: skip);

        test('${prefix}_div rm=$rmName', () {
          return _sweep(
            '${prefix}_div',
            rmName,
            (ops) => fpDiv(f, ops[0], ops[1], rm),
          );
        }, skip: skip);

        test('${prefix}_sqrt rm=$rmName', () {
          return _sweep(
            '${prefix}_sqrt',
            rmName,
            (ops) => fpSqrt(f, ops[0], rm),
          );
        }, skip: skip);

        test('${prefix}_mulAdd rm=$rmName', () {
          return _sweep(
            '${prefix}_mulAdd',
            rmName,
            (ops) => fpFma(f, f, ops[0], ops[1], ops[2], rm),
            stride: 61,
          );
        }, skip: skip);

        test('${prefix}_roundToInt rm=$rmName', () {
          return _sweep(
            '${prefix}_roundToInt',
            rmName,
            (ops) => fpRound(f, ops[0], rm, exact: true),
            exact: true,
          );
        }, skip: skip);

        // fround (exact: false) never sets NX, matching testfloat_gen's
        // default -notexact vectors for the same op.
        test('${prefix}_roundToInt rm=$rmName (fround, no NX)', () {
          return _sweep(
            '${prefix}_roundToInt',
            rmName,
            (ops) => fpRound(f, ops[0], rm, exact: false),
          );
        }, skip: skip);
      }
    }
  });

  group('compare', () {
    for (final entry in _formats.entries) {
      final prefix = entry.key;
      final f = entry.value;
      const rmName = 'near_even'; // compares are rm independent.

      test('${prefix}_eq', () {
        return _sweep(
          '${prefix}_eq',
          rmName,
          (ops) => fpCompare(f, ops[0], ops[1], FpCompareKind.eq),
        );
      }, skip: skip);

      test('${prefix}_lt', () {
        return _sweep(
          '${prefix}_lt',
          rmName,
          (ops) => fpCompare(f, ops[0], ops[1], FpCompareKind.lt),
        );
      }, skip: skip);

      test('${prefix}_le', () {
        return _sweep(
          '${prefix}_le',
          rmName,
          (ops) => fpCompare(f, ops[0], ops[1], FpCompareKind.le),
        );
      }, skip: skip);

      test('${prefix}_lt_quiet', () {
        return _sweep(
          '${prefix}_lt_quiet',
          rmName,
          (ops) => fpCompare(f, ops[0], ops[1], FpCompareKind.ltq),
        );
      }, skip: skip);

      test('${prefix}_le_quiet', () {
        return _sweep(
          '${prefix}_le_quiet',
          rmName,
          (ops) => fpCompare(f, ops[0], ops[1], FpCompareKind.leq),
        );
      }, skip: skip);
    }
  });

  group('integer conversions', () {
    const widths = {'32': 32, '64': 64};
    for (final entry in _formats.entries) {
      final prefix = entry.key;
      final f = entry.value;
      for (var rm = 0; rm < 5; rm++) {
        final rmName = _rmNames[rm];
        for (final w in widths.entries) {
          test('${prefix}_to_i${w.key} rm=$rmName', () {
            return _sweep(
              '${prefix}_to_i${w.key}',
              rmName,
              (ops) => fpToInt(f, ops[0], w.value, true, rm),
              exact: true,
            );
          }, skip: skip);

          test('${prefix}_to_ui${w.key} rm=$rmName', () {
            return _sweep(
              '${prefix}_to_ui${w.key}',
              rmName,
              (ops) => fpToInt(f, ops[0], w.value, false, rm),
              exact: true,
            );
          }, skip: skip);

          test('i${w.key}_to_$prefix rm=$rmName', () {
            return _sweep(
              'i${w.key}_to_$prefix',
              rmName,
              (ops) => intToFp(f, ops[0], w.value, true, rm),
            );
          }, skip: skip);

          test('ui${w.key}_to_$prefix rm=$rmName', () {
            return _sweep(
              'ui${w.key}_to_$prefix',
              rmName,
              (ops) => intToFp(f, ops[0], w.value, false, rm),
            );
          }, skip: skip);
        }
      }
    }
  });

  group('format conversions', () {
    const pairs = [
      ('f16', 'f32'),
      ('f16', 'f64'),
      ('f32', 'f16'),
      ('f32', 'f64'),
      ('f64', 'f16'),
      ('f64', 'f32'),
    ];
    for (final (fromPrefix, toPrefix) in pairs) {
      final from = _formats[fromPrefix]!;
      final to = _formats[toPrefix]!;
      for (var rm = 0; rm < 5; rm++) {
        final rmName = _rmNames[rm];
        test('${fromPrefix}_to_$toPrefix rm=$rmName', () {
          return _sweep(
            '${fromPrefix}_to_$toPrefix',
            rmName,
            (ops) => fpToFp(from, to, ops[0], rm),
          );
        }, skip: skip);
      }
    }
  });

  group('directed: fcvtmod.w.d', () {
    FpResult cvt(String hex) => fpCvtModWD(BigInt.parse(hex, radix: 16));

    test('NaN converts to zero with NV', () {
      final r = cvt('7ff8000000000000');
      expect(r.bits, BigInt.zero);
      expect(r.flags, nvFlag);
    });

    test('signaling NaN converts to zero with NV', () {
      final r = cvt('7ff0000000000001');
      expect(r.bits, BigInt.zero);
      expect(r.flags, nvFlag);
    });

    test('+infinity converts to zero with NV', () {
      final r = cvt('7ff0000000000000');
      expect(r.bits, BigInt.zero);
      expect(r.flags, nvFlag);
    });

    test('-infinity converts to zero with NV', () {
      final r = cvt('fff0000000000000');
      expect(r.bits, BigInt.zero);
      expect(r.flags, nvFlag);
    });

    test('exactly 2^31 wraps to -2^31 (0x80000000) with NV', () {
      final bits = intToFp(
        HarborFpFormat.fp64,
        BigInt.from(1) << 31,
        64,
        true,
        rmRne,
      ).bits;
      final r = fpCvtModWD(bits);
      expect(r.bits, BigInt.parse('80000000', radix: 16));
      expect(r.flags, nvFlag);
    });

    test('-2^31 - 1 wraps to 0x7FFFFFFF with NV', () {
      final value = -((BigInt.one << 31) + BigInt.one);
      final bits = intToFp(HarborFpFormat.fp64, value, 64, true, rmRne).bits;
      final r = fpCvtModWD(bits);
      expect(r.bits, BigInt.parse('7FFFFFFF', radix: 16));
      expect(r.flags, nvFlag);
    });

    test('2^63 truncates to 0 (low 32 bits are zero) with NV', () {
      final bits = intToFp(
        HarborFpFormat.fp64,
        BigInt.one << 63,
        64,
        false,
        rmRne,
      ).bits;
      final r = fpCvtModWD(bits);
      expect(r.bits, BigInt.zero);
      expect(r.flags, nvFlag);
    });

    test('an in-range value within int32 round-trips with no flags', () {
      final bits = intToFp(
        HarborFpFormat.fp64,
        BigInt.from(42),
        64,
        true,
        rmRne,
      ).bits;
      final r = fpCvtModWD(bits);
      expect(r.bits, BigInt.from(42));
      expect(r.flags, 0);
    });

    test('an in-range inexact value sets NX only', () {
      // 1.5 truncates to 1 under RTZ.
      final bits = BigInt.parse('3FF8000000000000', radix: 16);
      final r = fpCvtModWD(bits);
      expect(r.bits, BigInt.one);
      expect(r.flags, nxFlag);
    });

    test('zero converts to zero with no flags', () {
      final r = cvt('0000000000000000');
      expect(r.bits, BigInt.zero);
      expect(r.flags, 0);
    });

    // When NV fires for an out-of-range result, NX must stay clear even if
    // the exact value also had a fraction (spike fcvt.w.d behavior).
    test('out of range with a fractional part sets NV only, not NX', () {
      expect(cvt('41E0000000100000').flags, nvFlag); // 2^31 + 0.5
      expect(cvt('4270000000000800').flags, nvFlag); // 2^40 + 0.5
    });

    test('a subnormal input truncates to zero with NX only', () {
      final r = cvt('0000000000000001');
      expect(r.bits, BigInt.zero);
      expect(r.flags, nxFlag);
    });

    test('exactly -2^31 is in range with no flags', () {
      final bits = intToFp(
        HarborFpFormat.fp64,
        -(BigInt.one << 31),
        64,
        true,
        rmRne,
      ).bits;
      final r = fpCvtModWD(bits);
      expect(r.bits, BigInt.parse('80000000', radix: 16));
      expect(r.flags, 0);
    });

    test('2^31 - 0.5 truncates in range to 2^31 - 1 with NX only', () {
      final bytes = ByteData(8)
        ..setFloat64(0, (BigInt.one << 31).toDouble() - 0.5);
      final bits = BigInt.from(bytes.getUint64(0));
      final r = fpCvtModWD(bits);
      expect(r.bits, BigInt.parse('7FFFFFFF', radix: 16));
      expect(r.flags, nxFlag);
    });
  });

  group('directed: fli.* (all 32 entries, fp32)', () {
    const f = HarborFpFormat.fp32;

    // Transcribed from the RISC-V ISA manual, Zfa extension, table `flis`
    // (src/unpriv/zfa.adoc): (sign, exponent field, mantissa field), with
    // the mantissa field given by its top 2 bits (the rest are always 0).
    const table = [
      (1, 0x7F, 0), // -1.0
      (0, 0x01, 0), // min positive normal
      (0, 0x6F, 0), // 2^-16
      (0, 0x70, 0), // 2^-15
      (0, 0x77, 0), // 2^-8
      (0, 0x78, 0), // 2^-7
      (0, 0x7B, 0), // 0.0625
      (0, 0x7C, 0), // 0.125
      (0, 0x7D, 0), // 0.25
      (0, 0x7D, 1), // 0.3125
      (0, 0x7D, 2), // 0.375
      (0, 0x7D, 3), // 0.4375
      (0, 0x7E, 0), // 0.5
      (0, 0x7E, 1), // 0.625
      (0, 0x7E, 2), // 0.75
      (0, 0x7E, 3), // 0.875
      (0, 0x7F, 0), // 1.0
      (0, 0x7F, 1), // 1.25
      (0, 0x7F, 2), // 1.5
      (0, 0x7F, 3), // 1.75
      (0, 0x80, 0), // 2.0
      (0, 0x80, 1), // 2.5
      (0, 0x80, 2), // 3
      (0, 0x81, 0), // 4
      (0, 0x82, 0), // 8
      (0, 0x83, 0), // 16
      (0, 0x86, 0), // 128
      (0, 0x87, 0), // 256
      (0, 0x8E, 0), // 2^15
      (0, 0x8F, 0), // 2^16
      (0, 0xFF, 0), // +inf
      (0, 0xFF, 2), // canonical NaN
    ];

    for (var i = 0; i < 32; i++) {
      test('index $i', () {
        final (sign, expField, mantTop2) = table[i];
        final expected =
            (BigInt.from(sign) << 31) |
            (BigInt.from(expField) << 23) |
            (BigInt.from(mantTop2) << 21);
        final r = fpLi(f, i);
        expect(r.bits.toRadixString(16), expected.toRadixString(16));
        expect(r.flags, 0);
      });
    }

    test('index 29 (2^16) overflows to +infinity in half precision', () {
      final r = fpLi(HarborFpFormat.fp16, 29);
      expect(r.bits, BigInt.parse('7C00', radix: 16));
      expect(r.flags, 0);
    });
  });

  group('directed: fli.* (all entries, every format)', () {
    // Table entries 2..29, transcribed from the Zfa manual's own fraction
    // names (entry: value) as (mantissa, exp2), value = mantissa * 2^exp2.
    // Packed below by a format-generic formula, not by the model's own
    // packing code, so a format/entry pair exercises an independent check.
    const spec = <int, (int, int)>{
      0: (1, 0), // -1.0
      2: (1, -16),
      3: (1, -15),
      4: (1, -8),
      5: (1, -7),
      6: (1, -4),
      7: (1, -3),
      8: (1, -2),
      9: (5, -4),
      10: (3, -3),
      11: (7, -4),
      12: (1, -1),
      13: (5, -3),
      14: (3, -2),
      15: (7, -3),
      16: (1, 0),
      17: (5, -2),
      18: (3, -1),
      19: (7, -2),
      20: (1, 1),
      21: (5, -1),
      22: (3, 0),
      23: (1, 2),
      24: (1, 3),
      25: (1, 4),
      26: (1, 7),
      27: (1, 8),
      28: (1, 15),
      29: (1, 16),
    };

    BigInt pack(HarborFpFormat f, int sign, int mantissaInt, int exp2) {
      final mantissa = BigInt.from(mantissaInt);
      final bits = mantissa.bitLength;
      final te = exp2 + bits - 1;
      final minNormalTe = 1 - f.bias;
      final signBit = BigInt.from(sign) << (f.exponentWidth + f.mantissaWidth);
      if (te >= minNormalTe) {
        final expBits = te + f.bias;
        final shift = f.mantissaWidth - (bits - 1);
        final mantField =
            (mantissa << shift) &
            ((BigInt.one << f.mantissaWidth) - BigInt.one);
        return signBit | (BigInt.from(expBits) << f.mantissaWidth) | mantField;
      }
      // Subnormal: the field's LSB is worth 2^(minNormalTe - mantissaWidth).
      final subnormalExp = minNormalTe - f.mantissaWidth;
      return signBit | (mantissa << (exp2 - subnormalExp));
    }

    const formats = {
      'f16': HarborFpFormat.fp16,
      'bf16': HarborFpFormat.bf16,
      'f32': HarborFpFormat.fp32,
      'f64': HarborFpFormat.fp64,
    };

    for (final entry in formats.entries) {
      group(entry.key, () {
        final f = entry.value;
        final maxNormalTe = (1 << f.exponentWidth) - 2 - f.bias;

        for (final idx in spec.keys) {
          test('index $idx', () {
            final (m, e) = spec[idx]!;
            final sign = idx == 0 ? 1 : 0;
            final te = e + BigInt.from(m).bitLength - 1;
            final expected = te > maxNormalTe
                ? (BigInt.from(sign) << (f.exponentWidth + f.mantissaWidth)) |
                      (BigInt.from((1 << f.exponentWidth) - 1) <<
                          f.mantissaWidth)
                : pack(f, sign, m, e);
            final r = fpLi(f, idx);
            expect(r.bits.toRadixString(16), expected.toRadixString(16));
            expect(r.flags, 0);
          });
        }

        test('index 1 (min positive normal)', () {
          final expected = pack(f, 0, 1, 1 - f.bias);
          expect(fpLi(f, 1).bits.toRadixString(16), expected.toRadixString(16));
        });

        test('index 30 (+infinity)', () {
          final expected =
              BigInt.from((1 << f.exponentWidth) - 1) << f.mantissaWidth;
          expect(
            fpLi(f, 30).bits.toRadixString(16),
            expected.toRadixString(16),
          );
        });

        test('index 31 (canonical NaN)', () {
          final expected =
              (BigInt.from((1 << f.exponentWidth) - 1) << f.mantissaWidth) |
              (BigInt.one << (f.mantissaWidth - 1));
          expect(
            fpLi(f, 31).bits.toRadixString(16),
            expected.toRadixString(16),
          );
        });
      });
    }
  });

  group('directed: vfrec7.v / vfrsqrt7.v spot values', () {
    // Worked examples from the RISC-V "V" vector extension 1.0 spec text
    // (v-spec.adoc), SEW=32.
    const f = HarborFpFormat.fp32;

    test('vfrsqrt7(0x00718abc) == 0x5f080000', () {
      final r = fpRsqrt7(f, BigInt.parse('00718abc', radix: 16));
      expect(r.bits, BigInt.parse('5f080000', radix: 16));
    });

    test('vfrsqrt7(0x7f765432) == 0x1f820000', () {
      final r = fpRsqrt7(f, BigInt.parse('7f765432', radix: 16));
      expect(r.bits, BigInt.parse('1f820000', radix: 16));
    });

    test('vfrec7(0x00718abc) == 0x7e900000, rm independent', () {
      for (final rm in [rmRne, rmRtz, rmRdn, rmRup, rmRmm]) {
        final r = fpRec7(f, BigInt.parse('00718abc', radix: 16), rm);
        expect(r.bits, BigInt.parse('7e900000', radix: 16));
      }
    });

    test('vfrec7(0x7f765432) == 0x00214000, rm independent', () {
      for (final rm in [rmRne, rmRtz, rmRdn, rmRup, rmRmm]) {
        final r = fpRec7(f, BigInt.parse('7f765432', radix: 16), rm);
        expect(r.bits, BigInt.parse('00214000', radix: 16));
      }
    });

    test('vfrec7 of +0.0 is +infinity with DZ', () {
      final r = fpRec7(f, BigInt.zero, rmRne);
      expect(r.bits.toRadixString(16), '7f800000');
      expect(r.flags, dzFlag);
    });

    test('vfrsqrt7 of a negative finite value is canonical NaN with NV', () {
      final r = fpRsqrt7(f, BigInt.parse('bf800000', radix: 16)); // -1.0
      expect(r.bits.toRadixString(16), '7fc00000');
      expect(r.flags, nvFlag);
    });

    test('vfrec7 overflow for a subnormal input is rm-dependent', () {
      // The reciprocal of this subnormal overflows fp32; RTZ clamps to the
      // largest finite value, RNE rounds the overflow up to infinity.
      final a = BigInt.parse('00100000', radix: 16);
      final rtz = fpRec7(f, a, rmRtz);
      expect(rtz.bits.toRadixString(16), '7f7fffff');
      expect(rtz.flags, ofFlag | nxFlag);

      final rne = fpRec7(f, a, rmRne);
      expect(rne.bits.toRadixString(16), '7f800000');
      expect(rne.flags, ofFlag | nxFlag);
    });
  });

  group('directed: widening FMA fp16 x fp16 + fp32 (regression anchor)', () {
    // Each line is "a16 b16 c32 expected32", RNE, from an independent
    // Python/Fraction oracle. The exact-product oracle sweep below is now
    // the main coverage for widening FMA; this is a small kept sample.
    for (final (i, line) in _wideningFmaCases.indexed) {
      final parts = line.split(' ');
      test('case $i: ${line.trim()}', () {
        final a = BigInt.parse(parts[0], radix: 16);
        final b = BigInt.parse(parts[1], radix: 16);
        final c = BigInt.parse(parts[2], radix: 16);
        final expected = BigInt.parse(parts[3], radix: 16);
        final r = fpFma(
          HarborFpFormat.fp16,
          HarborFpFormat.fp32,
          a,
          b,
          c,
          rmRne,
        );
        expect(r.bits.toRadixString(16), expected.toRadixString(16));
      });
    }
  });

  group('directed: classify', () {
    const f = HarborFpFormat.fp32;
    BigInt bits(String hex) => BigInt.parse(hex, radix: 16);

    const cases = [
      ('-inf', 'ff800000', 1 << 0),
      ('-normal', 'bf800000', 1 << 1),
      ('-subnormal', '80000001', 1 << 2),
      ('-0', '80000000', 1 << 3),
      ('+0', '00000000', 1 << 4),
      ('+subnormal', '00000001', 1 << 5),
      ('+normal', '3f800000', 1 << 6),
      ('+inf', '7f800000', 1 << 7),
      ('sNaN', '7f800001', 1 << 8),
      ('qNaN', '7fc00000', 1 << 9),
    ];

    for (final (name, hex, expectedBit) in cases) {
      test(name, () {
        final r = fpClass(f, bits(hex));
        expect(r.bits, BigInt.from(expectedBit));
      });
    }
  });

  group('directed: sign injection', () {
    const f = HarborFpFormat.fp32;
    final pos = BigInt.parse('3f800000', radix: 16); // 1.0
    final neg = BigInt.parse('bf800000', radix: 16); // -1.0
    final nan = BigInt.parse('7fc00001', radix: 16); // qNaN, nonzero payload

    test('sgnj copies the sign of b', () {
      expect(fpSgnj(f, pos, neg, FpSgnjKind.inject).bits, neg);
      expect(fpSgnj(f, neg, pos, FpSgnjKind.inject).bits, pos);
    });

    test('sgnjn copies the negated sign of b', () {
      expect(fpSgnj(f, pos, pos, FpSgnjKind.negate).bits, neg);
    });

    test('sgnjx xors the signs', () {
      expect(fpSgnj(f, pos, neg, FpSgnjKind.xor).bits, neg);
      expect(fpSgnj(f, neg, neg, FpSgnjKind.xor).bits, pos);
    });

    test('sign injection never touches a NaN payload', () {
      final r = fpSgnj(f, nan, neg, FpSgnjKind.inject);
      expect(r.bits, nan | (BigInt.one << 31));
      expect(r.flags, 0);
    });
  });

  group('directed: min / max / minm / maxm', () {
    const f = HarborFpFormat.fp32;
    final posZero = BigInt.zero;
    final negZero = BigInt.parse('80000000', radix: 16);
    final one = BigInt.parse('3f800000', radix: 16);
    final negOne = BigInt.parse('bf800000', radix: 16);
    final two = BigInt.parse('40000000', radix: 16);
    final qnan = BigInt.parse('7fc00000', radix: 16);
    final snan = BigInt.parse('7f800001', radix: 16);
    final canonicalNan = BigInt.parse('7fc00000', radix: 16);

    test('fmin/fmax: -0 is below +0', () {
      expect(fpMin(f, posZero, negZero).bits, negZero);
      expect(fpMax(f, posZero, negZero).bits, posZero);
    });

    test('fmin/fmax: ordinary ordering', () {
      expect(fpMin(f, one, two).bits, one);
      expect(fpMax(f, one, two).bits, two);
    });

    test('fmin/fmax: mixed signs', () {
      expect(fpMin(f, negOne, two).bits, negOne);
      expect(fpMax(f, negOne, two).bits, two);
      expect(fpMin(f, one, negOne).bits, negOne);
      expect(fpMax(f, one, negOne).bits, one);
    });

    test(
      'fmin/fmax: a single quiet NaN returns the other operand, no flag',
      () {
        final r = fpMin(f, one, qnan);
        expect(r.bits, one);
        expect(r.flags, 0);
      },
    );

    test(
      'fmin/fmax: a single signaling NaN returns the other operand but raises NV',
      () {
        final r = fpMax(f, one, snan);
        expect(r.bits, one);
        expect(r.flags, nvFlag);
      },
    );

    test('fmin/fmax: both NaN gives canonical NaN', () {
      final r = fpMin(f, qnan, snan);
      expect(r.bits, canonicalNan);
      expect(r.flags, nvFlag);
    });

    test('fminm/fmaxm: a single NaN still gives canonical NaN', () {
      final r = fpMinM(f, one, qnan);
      expect(r.bits, canonicalNan);
      expect(r.flags, 0);

      final rSignaling = fpMaxM(f, one, snan);
      expect(rSignaling.bits, canonicalNan);
      expect(rSignaling.flags, nvFlag);
    });

    test('fminm/fmaxm: ordinary ordering matches fmin/fmax', () {
      expect(fpMinM(f, one, two).bits, one);
      expect(fpMaxM(f, one, two).bits, two);
    });

    test('fminm/fmaxm: -0 is below +0, same as fmin/fmax', () {
      expect(fpMinM(f, posZero, negZero).bits, negZero);
      expect(fpMaxM(f, posZero, negZero).bits, posZero);
    });
  });

  group('directed: negProduct/negAddend exact-zero sign', () {
    const f = HarborFpFormat.fp32;
    final one = BigInt.parse('3f800000', radix: 16);
    final negOne = BigInt.parse('bf800000', radix: 16);
    const rms = [rmRne, rmRtz, rmRdn, rmRup, rmRmm];

    void expectZeroSign(FpResult r, int wantSign) {
      expect(
        r.bits,
        wantSign == 1 ? BigInt.parse('80000000', radix: 16) : BigInt.zero,
      );
      expect(r.flags, 0);
    }

    test('fmsub (negAddend): 1*1 - 1 = 0, negative only under RDN', () {
      for (final rm in rms) {
        final r = fpFma(f, f, one, one, one, rm, negAddend: true);
        expectZeroSign(r, rm == rmRdn ? 1 : 0);
      }
    });

    test('fnmsub (negProduct): -(1*1) + 1 = 0, negative only under RDN', () {
      for (final rm in rms) {
        final r = fpFma(f, f, one, one, one, rm, negProduct: true);
        expectZeroSign(r, rm == rmRdn ? 1 : 0);
      }
    });

    test('fnmadd (negProduct, negAddend): -(1*1) - (-1) = 0, negative only '
        'under RDN', () {
      for (final rm in rms) {
        final r = fpFma(
          f,
          f,
          one,
          one,
          negOne,
          rm,
          negProduct: true,
          negAddend: true,
        );
        expectZeroSign(r, rm == rmRdn ? 1 : 0);
      }
    });
  });

  group('directed: ftz', () {
    const f = HarborFpFormat.fp32;
    BigInt bits(String hex) => BigInt.parse(hex, radix: 16);
    const rms = [rmRne, rmRtz, rmRdn, rmRup, rmRmm];

    test('an exact subnormal result flushes to +0 with UF and NX', () {
      // 0x00800001 + (-0x80800000) is exactly 2^-149, the smallest
      // subnormal, with no rounding error.
      final r = fpAdd(f, bits('00800001'), bits('80800000'), rmRne, ftz: true);
      expect(r.bits, BigInt.zero);
      expect(r.flags, ufFlag | nxFlag);
    });

    test('flushing an exact result is rm-independent', () {
      for (final rm in rms) {
        final r = fpAdd(f, bits('00800001'), bits('80800000'), rm, ftz: true);
        expect(r.bits, BigInt.zero, reason: 'rm=$rm');
        expect(r.flags, ufFlag | nxFlag, reason: 'rm=$rm');
      }
    });

    test('a flushed zero keeps the sign of the discarded result', () {
      final pos = fpMul(
        f,
        bits('00800001'),
        bits('3f000000'),
        rmRup,
        ftz: true,
      );
      expect(pos.bits, BigInt.zero);
      expect(pos.flags, ufFlag | nxFlag);

      final neg = fpMul(
        f,
        bits('00800001'),
        bits('bf000000'),
        rmRup,
        ftz: true,
      );
      expect(neg.bits, bits('80000000'));
      expect(neg.flags, ufFlag | nxFlag);
    });

    test('an inexact subnormal result still flushes with UF and NX', () {
      final r = fpMul(f, bits('00800001'), bits('3f000000'), rmRup, ftz: true);
      expect(r.bits, BigInt.zero);
      expect(r.flags, ufFlag | nxFlag);
    });

    test('a subnormal input flushes to zero before the op, silently', () {
      final withFtz = fpAdd(
        f,
        bits('00000001'),
        bits('3f800000'),
        rmRne,
        ftz: true,
      );
      expect(withFtz.bits, bits('3f800000'));
      expect(withFtz.flags, 0);

      // Without ftz the same tiny input still nudges the exact sum,
      // raising NX even though the rounded bits land on the same value.
      final withoutFtz = fpAdd(f, bits('00000001'), bits('3f800000'), rmRne);
      expect(withoutFtz.bits, bits('3f800000'));
      expect(withoutFtz.flags, nxFlag);
    });
  });

  group('directed: ftz scope (compare, min/max, fcvtmod, rec7/rsqrt7)', () {
    const f = HarborFpFormat.fp32;
    BigInt bits(String hex) => BigInt.parse(hex, radix: 16);
    final subnormal = bits('00000001');
    final negSubnormal = bits('80000001');
    final one = bits('3f800000');

    test('fpCompare flushes a subnormal input to zero', () {
      expect(
        fpCompare(f, subnormal, BigInt.zero, FpCompareKind.eq, ftz: true).bits,
        BigInt.one,
      );
      expect(
        fpCompare(f, subnormal, BigInt.zero, FpCompareKind.eq).bits,
        BigInt.zero,
      );
    });

    test('fpMin/fpMax return the flushed zero, not the subnormal bits', () {
      final min = fpMin(f, subnormal, BigInt.zero, ftz: true);
      expect(min.bits, BigInt.zero);
      final max = fpMax(f, negSubnormal, BigInt.zero, ftz: true);
      expect(max.bits, BigInt.zero);
    });

    test('fpMinM/fpMaxM also flush subnormal inputs', () {
      expect(fpMinM(f, subnormal, one, ftz: true).bits, BigInt.zero);
      expect(fpMaxM(f, negSubnormal, one, ftz: true).bits, one);
    });

    test('fpCvtModWD flushes a subnormal fp64 input to zero', () {
      final r = fpCvtModWD(bits('0000000000000001'), ftz: true);
      expect(r.bits, BigInt.zero);
      expect(r.flags, 0);
    });

    test('fpRec7 flushes a subnormal input to the DZ reciprocal of zero', () {
      final r = fpRec7(f, subnormal, rmRne, ftz: true);
      expect(r.bits.toRadixString(16), '7f800000');
      expect(r.flags, dzFlag);
    });

    test('fpRec7 flushes a subnormal output to zero with UF and NX', () {
      // The reciprocal of the largest finite value lands just below the
      // smallest normal, a nonzero subnormal that ftz flushes on the way
      // out (unflushed, this is 0x00200000, per the vfrec7.v spot checks).
      final r = fpRec7(f, bits('7f7fffff'), rmRne, ftz: true);
      expect(r.bits, BigInt.zero);
      expect(r.flags, ufFlag | nxFlag);

      final noFtz = fpRec7(f, bits('7f7fffff'), rmRne);
      expect(noFtz.bits.toRadixString(16), '200000');
      expect(noFtz.flags, 0);
    });

    test('fpRsqrt7 flushes a subnormal input the same way', () {
      final r = fpRsqrt7(f, subnormal, ftz: true);
      expect(r.bits.toRadixString(16), '7f800000');
      expect(r.flags, dzFlag);
    });
  });

  group('directed: widening FMA exact-product oracle', () {
    // A widening FMA's product is always exact in the wide format, so
    // fpFma(narrow, wide, a, b, c, rm) must equal fpAdd(wide, fpMul(wide,
    // cvt(a), cvt(b)), c, rm); a signaling NaN's NV is ORed in separately.
    for (final (narrow, wide, label) in [
      (HarborFpFormat.fp16, HarborFpFormat.fp32, 'f16 -> f32'),
      (HarborFpFormat.fp32, HarborFpFormat.fp64, 'f32 -> f64'),
    ]) {
      group(label, () {
        void check(BigInt a, BigInt b, BigInt c, int rm) {
          final aSnan = _isSignalingNaN(narrow, a);
          final bSnan = _isSignalingNaN(narrow, b);
          final aw = fpToFp(narrow, wide, a, rm).bits;
          final bw = fpToFp(narrow, wide, b, rm).bits;
          final prod = fpMul(wide, aw, bw, rm);
          final sum = fpAdd(wide, prod.bits, c, rm);
          final expectedFlags =
              sum.flags | prod.flags | ((aSnan || bSnan) ? nvFlag : 0);
          final r = fpFma(narrow, wide, a, b, c, rm);
          final where =
              '${a.toRadixString(16)} ${b.toRadixString(16)} '
              '${c.toRadixString(16)} rm=$rm';
          expect(
            r.bits.toRadixString(16),
            sum.bits.toRadixString(16),
            reason: '$where bits',
          );
          expect(
            r.flags.toRadixString(16),
            expectedFlags.toRadixString(16),
            reason: '$where flags',
          );
        }

        final edgeNarrow = _fpEdgeBits(narrow);
        final edgeWide = _fpEdgeBits(wide);

        test('edge operands x rm', () {
          for (final a in edgeNarrow) {
            for (final b in edgeNarrow) {
              final aw = fpToFp(narrow, wide, a, rmRne).bits;
              final bw = fpToFp(narrow, wide, b, rmRne).bits;
              final prod = fpMul(wide, aw, bw, rmRne);
              final cCandidates = [...edgeWide, _negateBits(wide, prod.bits)];
              for (final c in cCandidates) {
                for (final rm in [rmRne, rmRtz, rmRdn, rmRup, rmRmm]) {
                  check(a, b, c, rm);
                }
              }
            }
          }
        });

        test('random finite operands x rm', () {
          final rnd = Random(42);
          for (var i = 0; i < 300; i++) {
            final a = _randomFiniteBits(narrow, rnd);
            final b = _randomFiniteBits(narrow, rnd);
            final c = _randomFiniteBits(wide, rnd);
            for (final rm in [rmRne, rmRtz, rmRdn, rmRup, rmRmm]) {
              check(a, b, c, rm);
            }
          }
        });
      });
    }
  });
}

/// True when [bits] is a signaling NaN in [f]: exponent all ones, nonzero
/// mantissa, and the mantissa's MSB (the "is quiet" bit) clear.
bool _isSignalingNaN(HarborFpFormat f, BigInt bits) {
  final expMask = (BigInt.one << f.exponentWidth) - BigInt.one;
  final mantMask = (BigInt.one << f.mantissaWidth) - BigInt.one;
  final expBits = (bits >> f.mantissaWidth) & expMask;
  final mantBits = bits & mantMask;
  if (expBits != expMask || mantBits == BigInt.zero) return false;
  return ((mantBits >> (f.mantissaWidth - 1)) & BigInt.one) == BigInt.zero;
}

BigInt _negateBits(HarborFpFormat f, BigInt bits) =>
    bits ^ (BigInt.one << (f.exponentWidth + f.mantissaWidth));

/// Zero (both signs), min/max subnormal, min/max normal, infinity (both
/// signs), a quiet NaN and a signaling NaN: the edge values for [f].
List<BigInt> _fpEdgeBits(HarborFpFormat f) {
  final maxExp = (1 << f.exponentWidth) - 1;
  final mantMask = (BigInt.one << f.mantissaWidth) - BigInt.one;
  BigInt enc(int sign, int exp, BigInt mant) =>
      (BigInt.from(sign) << (f.exponentWidth + f.mantissaWidth)) |
      (BigInt.from(exp) << f.mantissaWidth) |
      mant;
  return [
    enc(0, 0, BigInt.zero),
    enc(1, 0, BigInt.zero),
    enc(0, 0, BigInt.one),
    enc(0, 0, mantMask),
    enc(0, 1, BigInt.zero),
    enc(0, maxExp - 1, mantMask),
    enc(0, maxExp, BigInt.zero),
    enc(1, maxExp, BigInt.zero),
    enc(0, maxExp, BigInt.one << (f.mantissaWidth - 1)),
    enc(0, maxExp, BigInt.one),
  ];
}

/// A pseudo-random finite (non-NaN, non-infinite) bit pattern for [f],
/// covering both normal and subnormal exponents.
BigInt _randomFiniteBits(HarborFpFormat f, Random rnd) {
  final maxExp = (1 << f.exponentWidth) - 1;
  final sign = rnd.nextInt(2);
  final exp = rnd.nextInt(maxExp); // excludes maxExp: no inf/NaN.
  var mant = BigInt.zero;
  for (var i = 0; i < f.mantissaWidth; i++) {
    mant = (mant << 1) | (rnd.nextBool() ? BigInt.one : BigInt.zero);
  }
  return (BigInt.from(sign) << (f.exponentWidth + f.mantissaWidth)) |
      (BigInt.from(exp) << f.mantissaWidth) |
      mant;
}

// A handful of rows from an independent Python/Fraction oracle, kept as a
// regression anchor alongside the exact-product oracle sweep above.
final List<String> _wideningFmaCases = _wideningFmaDataRaw.trim().split('\n');

const String _wideningFmaDataRaw = '''
0001 0001 00000001 27800000
0001 0001 7f7fffff 7f7fffff
0001 8001 00000001 a7800000
0001 8001 7f7fffff 7f7fffff
0001 03ff 00000001 2c7fc000
0001 03ff 7f7fffff 7f7fffff
0001 83ff 00000001 ac7fc000
0001 83ff 7f7fffff 7f7fffff
0001 0400 00000001 2c800000
d54f 0534 cd8778e7 cd8778e7
bca0 6327 6facaa50 6facaa50
bf02 3f9f dfc9e3b1 dfc9e3b1
85ad 5943 2fd2b7a4 bc6eea38
''';

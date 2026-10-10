import 'package:harbor/src/arith/fp_format.dart';
import 'package:harbor/src/arith/fpu_config.dart';
import 'package:harbor/src/riscv/micro_op.dart';
import 'package:test/test.dart';

/// Tests for [HarborFpuConfig], [HarborFpFormat] and [harborFpOpFor].
void main() {
  HarborFpuConfig config({
    List<HarborFpFormat>? formats,
    List<(HarborFpFormat, HarborFpFormat)> widening = const [],
    Set<HarborFpOp> ops = const {},
    int stages = 0,
    int divRadix = 2,
    List<int> intWidths = const [],
  }) => HarborFpuConfig(
    formats: formats ?? [HarborFpFormat.fp32],
    widening: widening,
    ops: ops,
    stages: stages,
    divRadix: divRadix,
    intWidths: intWidths,
  );

  group('HarborFpFormat', () {
    test('presets have the documented widths', () {
      expect(HarborFpFormat.fp16.exponentWidth, 5);
      expect(HarborFpFormat.fp16.mantissaWidth, 10);
      expect(HarborFpFormat.bf16.exponentWidth, 8);
      expect(HarborFpFormat.bf16.mantissaWidth, 7);
      expect(HarborFpFormat.fp32.exponentWidth, 8);
      expect(HarborFpFormat.fp32.mantissaWidth, 23);
      expect(HarborFpFormat.fp64.exponentWidth, 11);
      expect(HarborFpFormat.fp64.mantissaWidth, 52);
    });

    test('width is 1 + exponent + mantissa', () {
      expect(HarborFpFormat.fp16.width, 16);
      expect(HarborFpFormat.bf16.width, 16);
      expect(HarborFpFormat.fp32.width, 32);
      expect(HarborFpFormat.fp64.width, 64);
    });

    test('bias follows the exponent width', () {
      expect(HarborFpFormat.fp16.bias, 15);
      expect(HarborFpFormat.fp32.bias, 127);
      expect(HarborFpFormat.fp64.bias, 1023);
    });

    test('equal geometry compares equal', () {
      expect(const HarborFpFormat(8, 23), HarborFpFormat.fp32);
      expect(
        const HarborFpFormat(8, 23).hashCode,
        HarborFpFormat.fp32.hashCode,
      );
      expect(HarborFpFormat.fp32, isNot(HarborFpFormat.bf16));
    });
  });

  group('stage table', () {
    const expectedCuts = {
      0: <HarborFpCut>{},
      1: {HarborFpCut.c4},
      2: {HarborFpCut.c3, HarborFpCut.c5},
      3: {HarborFpCut.c2, HarborFpCut.c4, HarborFpCut.c5},
      4: {HarborFpCut.c2, HarborFpCut.c4, HarborFpCut.c5, HarborFpCut.c6},
      5: {
        HarborFpCut.c1,
        HarborFpCut.c2,
        HarborFpCut.c4,
        HarborFpCut.c5,
        HarborFpCut.c6,
      },
      6: {
        HarborFpCut.c1,
        HarborFpCut.c2,
        HarborFpCut.c3,
        HarborFpCut.c4,
        HarborFpCut.c5,
        HarborFpCut.c6,
      },
      7: {
        HarborFpCut.c1,
        HarborFpCut.c2,
        HarborFpCut.c3,
        HarborFpCut.c4,
        HarborFpCut.c5,
        HarborFpCut.c6,
        HarborFpCut.c7,
      },
    };

    for (final entry in expectedCuts.entries) {
      test('N=${entry.key} gives the listed cut set', () {
        final cfg = config(stages: entry.key);
        expect(cfg.cuts, entry.value);
      });

      test('N=${entry.key} latency equals the cut count', () {
        final cfg = config(stages: entry.key);
        expect(cfg.latency, entry.key);
      });
    }
  });

  group('HarborFpuConfig validation', () {
    test('rejects empty formats', () {
      expect(
        () => HarborFpuConfig(formats: [], ops: const {}, stages: 0),
        throwsArgumentError,
      );
    });

    test('rejects stages below 0', () {
      expect(() => config(stages: -1), throwsArgumentError);
    });

    test('rejects stages above 7', () {
      expect(() => config(stages: 8), throwsArgumentError);
    });

    test('rejects a divRadix other than 2 or 4', () {
      expect(() => config(divRadix: 3), throwsArgumentError);
    });

    test('accepts divRadix 4', () {
      expect(() => config(divRadix: 4), returnsNormally);
    });

    test('rejects a widening pair whose formats are not configured', () {
      expect(
        () => config(
          formats: [HarborFpFormat.fp32],
          widening: const [(HarborFpFormat.fp16, HarborFpFormat.fp32)],
        ),
        throwsArgumentError,
      );
    });

    test('rejects a widening pair where narrow is not smaller than wide', () {
      expect(
        () => config(
          formats: [HarborFpFormat.fp32, HarborFpFormat.fp16],
          widening: const [(HarborFpFormat.fp32, HarborFpFormat.fp16)],
        ),
        throwsArgumentError,
      );
    });

    test('accepts a valid widening pair', () {
      expect(
        () => config(
          formats: [HarborFpFormat.fp16, HarborFpFormat.fp32],
          widening: const [(HarborFpFormat.fp16, HarborFpFormat.fp32)],
        ),
        returnsNormally,
      );
    });

    test('rejects cvtModWD without fp64 in formats', () {
      expect(
        () => config(
          formats: [HarborFpFormat.fp32],
          ops: {HarborFpOp.cvtModWD},
          intWidths: const [32],
        ),
        throwsArgumentError,
      );
    });

    test('rejects cvtModWD without 32 in intWidths', () {
      expect(
        () => config(
          formats: [HarborFpFormat.fp64],
          ops: {HarborFpOp.cvtModWD},
          intWidths: const [64],
        ),
        throwsArgumentError,
      );
    });

    test('accepts cvtModWD with fp64 and 32 present', () {
      expect(
        () => config(
          formats: [HarborFpFormat.fp64],
          ops: {HarborFpOp.cvtModWD},
          intWidths: const [32],
        ),
        returnsNormally,
      );
    });

    test('widest returns the configured format with the largest width', () {
      final cfg = config(
        formats: [
          HarborFpFormat.fp16,
          HarborFpFormat.fp64,
          HarborFpFormat.fp32,
        ],
      );
      expect(cfg.widest, HarborFpFormat.fp64);
    });
  });

  group('harborFpOpFor', () {
    test('covers every RiscVFpuFunct except fmv and fmvXH', () {
      for (final f in RiscVFpuFunct.values) {
        final op = harborFpOpFor(f);
        if (f == RiscVFpuFunct.fmv || f == RiscVFpuFunct.fmvXH) {
          expect(op, isNull, reason: '$f should map to null');
        } else {
          expect(op, isNotNull, reason: '$f should map to a HarborFpOp');
        }
      }
    });

    test('maps the fcvt family onto fpToFp, fpToInt or intToFp', () {
      const fpToInt = {
        RiscVFpuFunct.fcvtWS,
        RiscVFpuFunct.fcvtLS,
        RiscVFpuFunct.fcvtWD,
        RiscVFpuFunct.fcvtLD,
      };
      const intToFp = {
        RiscVFpuFunct.fcvtSW,
        RiscVFpuFunct.fcvtSL,
        RiscVFpuFunct.fcvtDW,
        RiscVFpuFunct.fcvtDL,
      };
      const fpToFp = {
        RiscVFpuFunct.fcvtSD,
        RiscVFpuFunct.fcvtDS,
        RiscVFpuFunct.fcvtSH,
        RiscVFpuFunct.fcvtHS,
        RiscVFpuFunct.fcvtDH,
        RiscVFpuFunct.fcvtHD,
      };
      for (final f in fpToInt) {
        expect(harborFpOpFor(f), HarborFpOp.fpToInt);
      }
      for (final f in intToFp) {
        expect(harborFpOpFor(f), HarborFpOp.intToFp);
      }
      for (final f in fpToFp) {
        expect(harborFpOpFor(f), HarborFpOp.fpToFp);
      }
      expect(harborFpOpFor(RiscVFpuFunct.fcvtmodWD), HarborFpOp.cvtModWD);
    });
  });
}

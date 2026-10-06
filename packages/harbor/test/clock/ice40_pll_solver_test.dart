// Regression tests for the iCE40 SB_PLL40_CORE/PAD divider solver
// (`HarborClockGenerator.calculateDividers`).
//
// A review found that an earlier fix (closed-form DIVF per (DIVR, DIVQ))
// could falsely reject an input that icepll.cc's own exhaustive DIVF loop
// solves: the closed-form picks the single DIVF whose VCO is closest to the
// target ratio and checks only THAT DIVF's VCO against the band, instead of
// trying every DIVF like icepll.cc does. At a 12 MHz input this happened for
// 133 MHz and 266 MHz targets. This file locks in the fix: a literal,
// independent port of icepll.cc's `analyze()` loops, and a sweep at 12 MHz
// that must agree with it everywhere, including those two targets.
import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

const _pfdMin = 10e6;
const _pfdMax = 133e6;
const _vcoMin = 533e6;
const _vcoMax = 1066e6;

/// Direct, independent port of icepll.cc's `analyze()` (SIMPLE feedback):
/// DIVR outer, DIVF middle, DIVQ inner, strict `<` (first candidate at the
/// best error wins a tie, matching icepll.cc exactly -- it has no secondary
/// tie-break). Returns null when nothing is in band.
(int, int, int, double)? _refAnalyze(int fin, int fout) {
  int? bestDivr, bestDivf, bestDivq;
  var bestError = double.infinity;
  var bestActual = 0.0;
  for (var divr = 0; divr <= 15; divr++) {
    final fpfd = fin / (divr + 1);
    if (fpfd < _pfdMin || fpfd > _pfdMax) continue;
    for (var divf = 0; divf <= 127; divf++) {
      final fvco = fpfd * (divf + 1);
      if (fvco < _vcoMin || fvco > _vcoMax) continue;
      for (var divq = 1; divq <= 6; divq++) {
        final actual = fvco / (1 << divq);
        final error = (actual - fout).abs();
        if (error < bestError) {
          bestError = error;
          bestActual = actual;
          bestDivr = divr;
          bestDivf = divf;
          bestDivq = divq;
        }
      }
    }
  }
  if (bestDivr == null) return null;
  return (bestDivr, bestDivf!, bestDivq!, bestActual);
}

void main() {
  group('calculateDividers (regression: closed-form DIVF false rejection)', () {
    test('12 MHz -> 133 MHz gives DIVR 0, DIVF 87, DIVQ 3 (132 MHz), '
        'matching icepll', () {
      final (divr, divf, divq) = HarborClockGenerator.calculateDividers(
        12000000,
        133000000,
      );
      expect(divr, equals(0));
      expect(divf, equals(87));
      expect(divq, equals(3));
      final actual = 12000000 * (divf + 1) / ((divr + 1) * (1 << divq));
      expect(actual, equals(132000000));
    });

    test('12 MHz -> 266 MHz gives DIVR 0, DIVF 87, DIVQ 2 (264 MHz), '
        'matching icepll', () {
      final (divr, divf, divq) = HarborClockGenerator.calculateDividers(
        12000000,
        266000000,
      );
      expect(divr, equals(0));
      expect(divf, equals(87));
      expect(divq, equals(2));
      final actual = 12000000 * (divf + 1) / ((divr + 1) * (1 << divq));
      expect(actual, equals(264000000));
    });

    test('sweep at 12 MHz input matches a literal icepll.cc port for every '
        'integer MHz target 16-275, including 133 and 266', () {
      for (var mhz = 16; mhz <= 275; mhz++) {
        final fout = mhz * 1000000;
        final ref = _refAnalyze(12000000, fout);
        expect(ref, isNotNull, reason: '$mhz MHz: reference found nothing');
        final (refDivr, refDivf, refDivq, refActual) = ref!;

        final (divr, divf, divq) = HarborClockGenerator.calculateDividers(
          12000000,
          fout,
        );
        expect(
          divr,
          equals(refDivr),
          reason: '12 -> $mhz MHz: DIVR mismatch vs icepll reference',
        );
        expect(
          divf,
          equals(refDivf),
          reason: '12 -> $mhz MHz: DIVF mismatch vs icepll reference',
        );
        expect(
          divq,
          equals(refDivq),
          reason: '12 -> $mhz MHz: DIVQ mismatch vs icepll reference',
        );
        final actual = 12000000 * (divf + 1) / ((divr + 1) * (1 << divq));
        expect(
          actual,
          equals(refActual),
          reason: '12 -> $mhz MHz: achieved frequency mismatch',
        );
      }
    });

    test('throws ArgumentError when no in-band solution exists', () {
      expect(
        () => HarborClockGenerator.calculateDividers(1, 1),
        throwsArgumentError,
      );
    });

    test('input/output band checks reject out-of-range requests', () {
      expect(
        () => HarborClockGenerator.calculateDividers(5000000, 48000000),
        throwsArgumentError,
      );
      expect(
        () => HarborClockGenerator.calculateDividers(12000000, 300000000),
        throwsArgumentError,
      );
    });
  });
}

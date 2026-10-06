// Regression tests for the ECP5 EHXPLLL divider solver
// (`HarborClockGenerator.ecp5PllDividers` / `ecp5PllSolve`).
//
// The old solver reduced target:source by GCD with no band checks, so
// 25 MHz -> 48 MHz picked CLKI_DIV 25, a 1 MHz phase detector (PFD). On a
// real ULX3S (ECP5 LFE5U-85F) that PLL never asserts LOCK: the setting looks
// plausible (it IS exactly 48 MHz / 25 = ratio 25:48 reduced) but the PFD is
// far below the EHXPLLL's 3.125 MHz minimum, so it never locks.
//
// The reference loops below are an independent port of prjtrellis
// ecppll.cpp's `calc_pll_params` / `calc_pll_params_highres`, written
// straight from the source (not by calling the solver under test), including
// the literal CLKOS_DIV loop over 1..128 (a `round(vco / target)` shortcut
// was tried first and dropped: fout = vco / div is a reciprocal, not linear,
// function of div, so nearest-integer rounding of the real-valued ratio does
// not always land on the brute-force optimum -- see the standalone
// regression below for a concrete case).
import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

const _pfdMin = 3.125e6;
const _pfdMax = 400e6;
const _vcoMin = 400e6;
const _vcoMax = 800e6;
const _outMin = 10e6;
const _outMax = 400e6;

/// Direct port of ecppll.cpp's `calc_pll_params` (CLKOP is the real output).
/// Returns null when no (CLKI_DIV, CLKFB_DIV, CLKOP_DIV) keeps the PFD and
/// VCO in band.
({
  int clkiDiv,
  int clkfbDiv,
  int clkopDiv,
  double pfd,
  double vco,
  double fout,
})?
_refSimple(int sourceFreq, int targetFreq) {
  var bestErr = double.infinity;
  var bestVco = 0.0;
  int? ci, cf, co;
  var pfdOut = 0.0, foutOut = 0.0;
  for (var clkiDiv = 1; clkiDiv <= 128; clkiDiv++) {
    final pfd = sourceFreq / clkiDiv;
    if (pfd < _pfdMin || pfd > _pfdMax) continue;
    for (var clkfbDiv = 1; clkfbDiv <= 80; clkfbDiv++) {
      for (var clkopDiv = 1; clkopDiv <= 128; clkopDiv++) {
        final vco = pfd * clkfbDiv * clkopDiv;
        if (vco < _vcoMin || vco > _vcoMax) continue;
        final fout = pfd * clkfbDiv;
        final err = (fout - targetFreq).abs();
        if (err < bestErr ||
            (err == bestErr && (vco - 600e6).abs() < (bestVco - 600e6).abs())) {
          bestErr = err;
          bestVco = vco;
          pfdOut = pfd;
          foutOut = fout;
          ci = clkiDiv;
          cf = clkfbDiv;
          co = clkopDiv;
        }
      }
    }
  }
  if (ci == null) return null;
  return (
    clkiDiv: ci,
    clkfbDiv: cf!,
    clkopDiv: co!,
    pfd: pfdOut,
    vco: bestVco,
    fout: foutOut,
  );
}

/// Direct port of ecppll.cpp's `calc_pll_params_highres` (CLKOP is feedback
/// only, CLKOS is the real output). Returns null when no in-band solution
/// exists, checking the CLKOP feedback frequency against the OUTPUT band too
/// (ecppll.cpp around line 326): a solver that checks only the VCO would
/// accept the broken 1 MHz PFD instance.
({
  int clkiDiv,
  int clkfbDiv,
  int clkopDiv,
  int clkosDiv,
  double pfd,
  double vco,
  double feedback,
  double fout,
})?
_refHighres(int sourceFreq, int targetFreq) {
  var bestErr = double.infinity;
  var bestVco = 0.0;
  int? ci, cf, co, cs;
  var pfdOut = 0.0, fbOut = 0.0, foutOut = 0.0;
  for (var clkiDiv = 1; clkiDiv <= 128; clkiDiv++) {
    final pfd = sourceFreq / clkiDiv;
    if (pfd < _pfdMin || pfd > _pfdMax) continue;
    for (var clkfbDiv = 1; clkfbDiv <= 80; clkfbDiv++) {
      for (var clkopDiv = 1; clkopDiv <= 128; clkopDiv++) {
        final vco = pfd * clkfbDiv * clkopDiv;
        if (vco < _vcoMin || vco > _vcoMax) continue;
        final feedback = vco / clkopDiv;
        if (feedback < _outMin || feedback > _outMax) continue;
        // Literal brute-force loop, matching ecppll.cpp exactly (no
        // round(vco / target) shortcut: see the file header comment).
        for (var clkosDiv = 1; clkosDiv <= 128; clkosDiv++) {
          final fout = vco / clkosDiv;
          final err = (fout - targetFreq).abs();
          if (err < bestErr ||
              (err == bestErr &&
                  (vco - 600e6).abs() < (bestVco - 600e6).abs())) {
            bestErr = err;
            bestVco = vco;
            pfdOut = pfd;
            fbOut = feedback;
            foutOut = fout;
            ci = clkiDiv;
            cf = clkfbDiv;
            co = clkopDiv;
            cs = clkosDiv;
          }
        }
      }
    }
  }
  if (ci == null) return null;
  return (
    clkiDiv: ci,
    clkfbDiv: cf!,
    clkopDiv: co!,
    clkosDiv: cs!,
    pfd: pfdOut,
    vco: bestVco,
    feedback: fbOut,
    fout: foutOut,
  );
}

/// Harbor's decision between the two reference modes: whichever lands closer
/// to the requested frequency wins, ties going to the simpler CLKOP-direct
/// mode. An exact highres match beats an inexact simple match even when the
/// simple PFD/VCO are individually "nicer" (e.g. 25 -> 48: simple's best is
/// 46.875 MHz, highres hits 48 MHz exactly).
({int clkiDiv, int clkfbDiv, int clkopDiv, int? clkosDiv, double fout})
_refSolve(int sourceFreq, int targetFreq) {
  final simple = _refSimple(sourceFreq, targetFreq);
  final highres = _refHighres(sourceFreq, targetFreq);
  final simpleErr = simple == null
      ? double.infinity
      : (simple.fout - targetFreq).abs();
  final highresErr = highres == null
      ? double.infinity
      : (highres.fout - targetFreq).abs();
  if (highres != null && highresErr < simpleErr) {
    return (
      clkiDiv: highres.clkiDiv,
      clkfbDiv: highres.clkfbDiv,
      clkopDiv: highres.clkopDiv,
      clkosDiv: highres.clkosDiv,
      fout: highres.fout,
    );
  }
  final s = simple!;
  return (
    clkiDiv: s.clkiDiv,
    clkfbDiv: s.clkfbDiv,
    clkopDiv: s.clkopDiv,
    clkosDiv: null,
    fout: s.fout,
  );
}

/// Minimal harness that builds one ECP5 clock domain through
/// [HarborClockGenerator.createDomain], used to inspect the generated SV.
class _SingleClkHarness extends BridgeModule {
  late final HarborClockDomain domain;

  _SingleClkHarness(int sourceFreq, int targetFreq)
    : super('SingleClkHarness') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('tick');

    final gen = HarborClockGenerator(
      parent: this,
      inputClk: input('clk'),
      inputReset: input('reset'),
      target: const HarborFpgaTarget.ecp5(
        device: 'lfe5u-85f',
        package: 'CABGA381',
      ),
    );
    domain = gen.createDomain(
      HarborClockConfig.fixed(
        name: 'dom',
        frequency: targetFreq,
        sourceFrequency: sourceFreq,
      ),
    );
    Sequential(domain.clk, reset: domain.reset, [
      output('tick') < ~output('tick'),
    ]);
  }
}

void main() {
  group('CLKOS_DIV must be a literal brute-force pick, not round()', () {
    test('a vco=480 MHz, target~=195.918 MHz case where round(vco/target) '
        'picks the wrong divisor', () {
      // Reviewer-found case: ratio = vco/target = 2.45. round() picks the
      // nearest integer to the ratio (2), but fout = vco/div is a
      // reciprocal of div, so the divisor with the least frequency error
      // is not always the one nearest the ratio. The true best, found by
      // scanning every divisor 1-128 (what ecppll.cpp and both
      // [_refHighres] and the production highres search now do), is 3.
      const vco = 480000000.0;
      const target = vco / 2.45;

      var roundDiv = (vco / target).round();
      if (roundDiv < 1) roundDiv = 1;
      if (roundDiv > 128) roundDiv = 128;
      final roundErr = (vco / roundDiv - target).abs();

      var literalBestDiv = 1;
      var literalBestErr = double.infinity;
      for (var div = 1; div <= 128; div++) {
        final err = (vco / div - target).abs();
        if (err < literalBestErr) {
          literalBestErr = err;
          literalBestDiv = div;
        }
      }

      expect(roundDiv, equals(2));
      expect(literalBestDiv, equals(3));
      expect(
        literalBestErr,
        lessThan(roundErr),
        reason:
            'round(vco/target) (div $roundDiv, err $roundErr Hz) must '
            'not beat the literal brute-force optimum (div '
            '$literalBestDiv, err $literalBestErr Hz)',
      );
    });
  });

  group('ecp5PllDividers (regression: 1 MHz PFD never locks)', () {
    test('25 MHz -> 48 MHz is exact, in band, and PFD is not 1 MHz', () {
      final sol = HarborClockGenerator.ecp5PllSolve(25000000, 48000000);
      final outFreq = sol.clkosDiv != null
          ? sol.vco / sol.clkosDiv!
          : sol.pfd * sol.clkfbDiv;
      expect(outFreq, equals(48000000));
      expect(sol.pfd, inInclusiveRange(_pfdMin, _pfdMax));
      expect(sol.vco, inInclusiveRange(_vcoMin, _vcoMax));
      expect(sol.pfd, isNot(equals(1000000)));
    });

    test('25 MHz -> 48 MHz hardware-proven parameter set '
        '(ecppll -i 25 -o 48 --highres, confirmed locking on a ULX3S)', () {
      final sol = HarborClockGenerator.ecp5PllSolve(25000000, 48000000);
      expect(sol.clkiDiv, equals(5));
      expect(sol.clkfbDiv, equals(2));
      expect(sol.clkopDiv, equals(48));
      expect(sol.clkosDiv, equals(10));
      expect(sol.clkopCphase, equals(9));
      // ecppll.cpp's highres mode never computes CLKOS_CPHASE/CLKOS_FPHASE
      // (it would be uninitialized memory in the real tool); Harbor applies
      // generate_secondary_output's own zero-phase rule instead: CPHASE =
      // CLKOP_CPHASE, FPHASE = 0.
      expect(sol.clkosCphase, equals(9));
      expect(sol.clkosFphase, equals(0));
      expect(sol.pfd, equals(5000000));
      expect(sol.vco, equals(480000000));
      expect(sol.vco / sol.clkopDiv, equals(10000000)); // feedback freq
      expect(sol.vco / sol.clkosDiv!, equals(48000000));
    });

    test('48 MHz -> 24 MHz is exact and in band', () {
      final d = HarborClockGenerator.ecp5PllDividers(48000000, 24000000);
      expect(48000000 * d.clkfbDiv / d.clkiDiv, equals(24000000));
      final vco = 24000000 * d.clkopDiv;
      expect(vco, inInclusiveRange(400000000, 800000000));
    });

    test('25 MHz -> 125 MHz is exact and in band', () {
      final d = HarborClockGenerator.ecp5PllDividers(25000000, 125000000);
      expect(25000000 * d.clkfbDiv / d.clkiDiv, equals(125000000));
      final vco = 125000000 * d.clkopDiv;
      expect(vco, inInclusiveRange(400000000, 800000000));
    });

    test('25 MHz -> 40 MHz (800x600 pixel clock) is exact at a 5 MHz PFD, '
        '600 MHz VCO', () {
      final sol = HarborClockGenerator.ecp5PllSolve(25000000, 40000000);
      expect(sol.pfd, equals(5000000));
      expect(sol.vco, equals(600000000));
      final outFreq = sol.clkosDiv != null
          ? sol.vco / sol.clkosDiv!
          : sol.pfd * sol.clkfbDiv;
      expect(outFreq, equals(40000000));
    });

    test('25 MHz -> 200 MHz (5x TMDS shift clock) is exact and in band', () {
      final sol = HarborClockGenerator.ecp5PllSolve(25000000, 200000000);
      expect(sol.pfd, inInclusiveRange(_pfdMin, _pfdMax));
      expect(sol.vco, inInclusiveRange(_vcoMin, _vcoMax));
      final outFreq = sol.clkosDiv != null
          ? sol.vco / sol.clkosDiv!
          : sol.pfd * sol.clkfbDiv;
      expect(outFreq, equals(200000000));
    });

    test('25 MHz -> 200 MHz primary + 40 MHz CLKOS secondary (800x600 HDMI: '
        'shift clock + pixel clock) share an exact 600 MHz VCO', () {
      // createDomainWithSecondary's two-output path: CLKOP is the real
      // primary output (ecp5PllDividers, simple mode), CLKOS is a second
      // tap off the SAME VCO (ecp5ClkosDiv). Both land on the shared
      // 600 MHz VCO exactly: 600/200 = 3, 600/40 = 15.
      final d = HarborClockGenerator.ecp5PllDividers(25000000, 200000000);
      final vco = 200000000 * d.clkopDiv;
      expect(vco, equals(600000000));
      final clkosDiv = HarborClockGenerator.ecp5ClkosDiv(
        25000000,
        200000000,
        40000000,
      );
      expect(vco / clkosDiv, equals(40000000));
    });

    test('throws ArgumentError when no in-band solution exists', () {
      // 1 Hz in, 1 Hz out: no CLKI_DIV gives a PFD anywhere near 3.125 MHz.
      expect(
        () => HarborClockGenerator.ecp5PllSolve(1, 1),
        throwsArgumentError,
      );
      expect(
        () => HarborClockGenerator.ecp5PllDividers(1, 1),
        throwsArgumentError,
      );
    });

    test('sweep: every result is in band and matches the independent '
        'ecppll-loop reference exactly (not just "in band")', () {
      const sources = [12000000, 25000000, 48000000, 100000000];
      const targets = [
        24000000,
        25000000,
        40000000,
        48000000,
        50000000,
        60000000,
        75000000,
        100000000,
        125000000,
        200000000,
      ];
      for (final src in sources) {
        for (final tgt in targets) {
          final ref = _refSolve(src, tgt);
          final got = HarborClockGenerator.ecp5PllSolve(src, tgt);

          expect(
            got.pfd,
            inInclusiveRange(_pfdMin, _pfdMax),
            reason: '$src -> $tgt PFD out of band',
          );
          expect(
            got.vco,
            inInclusiveRange(_vcoMin, _vcoMax),
            reason: '$src -> $tgt VCO out of band',
          );

          expect(
            got.clkiDiv,
            equals(ref.clkiDiv),
            reason: '$src -> $tgt CLKI_DIV mismatch vs ecppll reference',
          );
          expect(
            got.clkfbDiv,
            equals(ref.clkfbDiv),
            reason: '$src -> $tgt CLKFB_DIV mismatch vs ecppll reference',
          );
          expect(
            got.clkopDiv,
            equals(ref.clkopDiv),
            reason: '$src -> $tgt CLKOP_DIV mismatch vs ecppll reference',
          );
          expect(
            got.clkosDiv,
            equals(ref.clkosDiv),
            reason: '$src -> $tgt CLKOS_DIV mismatch vs ecppll reference',
          );

          // Harbor's error must never be worse than the independent
          // reference's best achievable error.
          final gotErr = (got.fout - tgt).abs();
          final refErr = (ref.fout - tgt).abs();
          expect(
            gotErr,
            lessThanOrEqualTo(refErr + 1e-6),
            reason: '$src -> $tgt Harbor error worse than ecppll reference',
          );
        }
      }
    });
  });

  group('CLKOS wiring for a single-target ECP5 domain', () {
    test('a domain needing the CLKOS path is actually clocked from CLKOS '
        '(checked by connection, not by text match)', () async {
      final h = _SingleClkHarness(25000000, 48000000);
      // domain.clk is the exact Logic `_createEcp5Pll` chose as `outClk`
      // (pll.output('CLKOS') or pll.output('CLKOP')), so its name proves
      // which EHXPLLL output the domain is actually wired from -- a
      // `contains('.CLKOS(')` text match alone does not: `Ecp5Ehxplll`
      // always declares and connects the CLKOS port regardless of whether
      // clkosDiv is set, so that text is present in both cases.
      expect(h.domain.clk.name, equals('CLKOS'));
      await h.build();
      final sv = h.generateSynth();
      expect(sv, contains('CLKOS_ENABLE'));
      expect(sv, contains('CLKOS_DIV(10)'));
      expect(sv, contains('CLKOS_CPHASE(9)'));
      expect(sv, contains('CLKOS_FPHASE(0)'));
    });

    test('a domain NOT needing CLKOS is actually clocked from CLKOP, and stays '
        'on the plain CLKOP path', () async {
      final h = _SingleClkHarness(48000000, 24000000);
      expect(h.domain.clk.name, equals('CLKOP'));
      await h.build();
      final sv = h.generateSynth();
      expect(sv, isNot(contains('CLKOS_ENABLE')));
    });
  });
}

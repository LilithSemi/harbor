import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// A minimal SoC-like harness that builds a primary + secondary clock from one
/// ECP5 PLL and consumes both so neither is optimized away.
class _ClkHarness extends BridgeModule {
  late final HarborClockDomain shift;
  late final HarborClockDomain pixel;

  _ClkHarness(HarborDeviceTarget? target) : super('ClkHarness') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addOutput('shift_tick');
    addOutput('pixel_tick');

    final gen = HarborClockGenerator(
      parent: this,
      inputClk: input('clk'),
      inputReset: input('reset'),
      target: target,
    );
    final pair = gen.createDomainWithSecondary(
      HarborClockConfig.fixed(
        name: 'shift',
        frequency: 125000000,
        sourceFrequency: 25000000,
      ),
      secondaryFrequency: 25000000,
      secondaryName: 'pixel',
    );
    shift = pair.primary;
    pixel = pair.secondary;

    Sequential(shift.clk, reset: shift.reset, [
      output('shift_tick') < ~output('shift_tick'),
    ]);
    Sequential(pixel.clk, reset: pixel.reset, [
      output('pixel_tick') < ~output('pixel_tick'),
    ]);
  }
}

void main() {
  group('ecp5ClkosDiv', () {
    test('25MHz -> 125MHz primary + 25MHz secondary needs CLKOS_DIV 25', () {
      // ecp5PllDividers now runs ecppll.cpp's real search/tie-break: for
      // 25 -> 125, CLKOP_DIV 5 (VCO 625 MHz) beats CLKOP_DIV 4 (VCO 500 MHz)
      // because 625 MHz is closer to ecppll.cpp's 600 MHz tie-break target
      // (both give an exact 125 MHz CLKOP; the achieved frequency doesn't
      // depend on CLKOP_DIV at all in this mode, so the VCO tie-break is the
      // only thing that ever decides it). CLKOS_DIV = 625/25 = 25.
      expect(
        HarborClockGenerator.ecp5ClkosDiv(25000000, 125000000, 25000000),
        equals(25),
      );
    });
  });

  group('ecp5CoSecondaryDividers', () {
    test('125 MHz primary + 50 MHz secondary from 25 MHz: even CLKOP_DIV, '
        'exact secondary', () {
      final sol = HarborClockGenerator.ecp5CoSecondaryDividers(
        25000000,
        125000000,
        50000000,
      );
      final vco = 125000000 * sol.clkopDiv;
      expect(25000000 * sol.clkfbDiv / sol.clkiDiv, equals(125000000));
      expect(vco % 50000000, equals(0));
      expect(vco / sol.clkosDiv, equals(50000000));
      expect(sol.clkopDiv % 2, equals(0));
    });

    test('100 MHz primary + 50 MHz secondary from 25 MHz: any CLKOP_DIV '
        'is exact, picks the VCO closest to 600 MHz', () {
      final sol = HarborClockGenerator.ecp5CoSecondaryDividers(
        25000000,
        100000000,
        50000000,
      );
      final vco = 100000000 * sol.clkopDiv;
      expect(vco, equals(600000000));
      expect(vco / sol.clkosDiv, equals(50000000));
    });

    test('impossible pair throws naming both frequencies', () {
      // Every in-band VCO for a 125 MHz primary (500/625/750 MHz) is unable
      // to divide evenly by 33 MHz, so no CLKOP_DIV shares the VCO exactly.
      expect(
        () => HarborClockGenerator.ecp5CoSecondaryDividers(
          25000000,
          125000000,
          33000000,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('125000000'), contains('33000000')),
          ),
        ),
      );
    });

    test('125 MHz primary + 48 MHz secondary at 0 ppm tolerance still '
        'throws, naming the best error found', () {
      // The old solver rounded this to 48.08 MHz without an error.
      expect(
        () => HarborClockGenerator.ecp5CoSecondaryDividers(
          25000000,
          125000000,
          48000000,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('125000000'),
              contains('48000000'),
              contains('0 ppm'),
              contains('The best is'),
            ),
          ),
        ),
      );
    });

    test('125.875 MHz CLKOP (TMDS shift) + 25.175 MHz CLKOS (pixel) from 25 '
        'MHz: no exact solution, but 7000 ppm on both solves', () {
      // CLKOP can only be a multiple of 3.125 MHz here, so 125 MHz is the
      // closest to 125.875 MHz, 6951 ppm low.
      final sol = HarborClockGenerator.ecp5CoSecondaryDividers(
        25000000,
        125875000,
        25175000,
        primaryTolPpm: 7000,
        secondaryTolPpm: 7000,
      );
      expect(sol.achievedPrimaryHz, 125000000);
      expect(sol.achievedSecondaryHz, 25000000);
      expect(sol.clkiDiv * 125000000, 25000000 * sol.clkfbDiv);
    });

    test('125.875 MHz + 25.175 MHz at 0 ppm tolerance still throws, naming '
        'the best error found', () {
      expect(
        () => HarborClockGenerator.ecp5CoSecondaryDividers(
          25000000,
          125875000,
          25175000,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('125875000'),
              contains('25175000'),
              contains('0 ppm'),
              contains('The best is 6951.3 ppm primary'),
            ),
          ),
        ),
      );
    });
  });

  group('createDomainWithSecondary (ECP5)', () {
    test('returns primary and secondary domains at the right rates', () async {
      final h = _ClkHarness(
        const HarborFpgaTarget.ecp5(device: 'lfe5u-85f', package: 'CABGA381'),
      );
      await h.build();
      expect(h.shift.config.frequency, equals(125000000));
      expect(h.pixel.config.frequency, equals(25000000));
      expect(h.pixel.config.name, equals('pixel'));
    });

    test('wires one EHXPLLL with the CLKOS output enabled', () async {
      final h = _ClkHarness(
        const HarborFpgaTarget.ecp5(device: 'lfe5u-85f', package: 'CABGA381'),
      );
      await h.build();
      final sv = h.generateSynth();
      expect('EHXPLLL'.allMatches(sv).length, equals(1));
      expect(sv, contains('CLKOS_ENABLE'));
      expect(sv, contains('CLKOS_DIV'));
    });
  });
}

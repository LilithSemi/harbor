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

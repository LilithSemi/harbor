import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Wrapper so the ECP5 EHXPLLL DDR3 clock tree shows up in generateSynth().
class _ClockTreeWrap extends BridgeModule {
  late final Ecp5Ddr3Clocks clocks;

  _ClockTreeWrap({
    required Logic source,
    required int sourceHz,
    int ddrCkHz = 96000000,
  }) : super('ClockTreeWrap') {
    source = addInput('source', source);
    clocks = buildEcp5Ddr3ClockTree(
      this,
      source: source,
      sourceHz: sourceHz,
      ddrCkHz: ddrCkHz,
    );
    // Pull the clocks + LOCK up to ports so nothing is pruned.
    addOutput('ddr_ck') <= clocks.ddrCk;
    addOutput('controller_clk') <= clocks.controllerClk;
    addOutput('ddr_ck90') <= clocks.ddrCk90;
    addOutput('ddr_ck_dqs') <= clocks.ddrCkDqs;
    addOutput('idelay_ref') <= clocks.idelayRef;
    addOutput('locked') <= clocks.locked;
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  test('elaborates with exactly one EHXPLLL and no Xilinx primitive', () async {
    final wrap = _ClockTreeWrap(
      source: Logic(name: 'clk48'),
      sourceHz: 48000000,
    );
    await wrap.build();
    final sv = wrap.generateSynth();

    expect('EHXPLLL'.allMatches(sv).length, equals(1));
    expect(sv, contains('CLKOS_ENABLE'));
    expect(sv, isNot(contains('MMCME2')));
    expect(sv, isNot(contains('PLLE2')));
    expect(sv, isNot(contains('BUFG')));
  });

  test('default 48 MHz -> 96 MHz CK matches HarborClockGenerator.ecp5PllSolve '
      'exactly', () async {
    final sol = HarborClockGenerator.ecp5PllSolve(48000000, 96000000);
    // 96 MHz is reached through the CLKOP-direct ("simple") search: no
    // highres CLKOS companion, so CLKOP stays a real, usable clock.
    expect(sol.clkosDiv, isNull);
    // The same CLKOP-direct search HarborClockGenerator.ecp5PllDividers
    // uses, so this is the identical validated pair either entry point
    // would hand back.
    final dividers = HarborClockGenerator.ecp5PllDividers(48000000, 96000000);
    expect(sol.clkiDiv, equals(dividers.clkiDiv));
    expect(sol.clkfbDiv, equals(dividers.clkfbDiv));
    expect(sol.clkopDiv, equals(dividers.clkopDiv));

    final clkosDiv = HarborClockGenerator.ecp5ClkosDiv(
      48000000,
      96000000,
      24000000,
    );

    final wrap = _ClockTreeWrap(
      source: Logic(name: 'clk48'),
      sourceHz: 48000000,
    );
    await wrap.build();
    final sv = wrap.generateSynth();

    expect(sv, contains('.CLKI_DIV(${sol.clkiDiv})'));
    expect(sv, contains('.CLKFB_DIV(${sol.clkfbDiv})'));
    expect(sv, contains('.CLKOP_DIV(${sol.clkopDiv})'));
    expect(sv, contains('.CLKOS_DIV($clkosDiv)'));

    // The 48 MHz OrangeCrab oscillator reaches 96 MHz with no rounding
    // error at all (CLKI_DIV 1, CLKFB_DIV 2 -> CLKOP exactly 96 MHz).
    expect(wrap.clocks.ddrCkMhz, equals(96.0));
    expect(wrap.clocks.controllerClkMhz, equals(24.0));
  });

  test('controllerClk and ddrCk share one VCO at an exact 1:4 ratio', () async {
    final wrap = _ClockTreeWrap(
      source: Logic(name: 'clk48'),
      sourceHz: 48000000,
    );
    await wrap.build();

    expect(wrap.clocks.ddrCkMhz, equals(wrap.clocks.controllerClkMhz * 4));
    final vcoOverCk = wrap.clocks.vcoMhz / wrap.clocks.ddrCkMhz;
    final vcoOverCtrl = wrap.clocks.vcoMhz / wrap.clocks.controllerClkMhz;
    expect(vcoOverCk, closeTo(vcoOverCk.round().toDouble(), 1e-9));
    expect(vcoOverCtrl, closeTo(vcoOverCtrl.round().toDouble(), 1e-9));
    expect(vcoOverCtrl.round(), equals(4 * vcoOverCk.round()));
  });

  test(
    'CLKOP and CLKOS rising edges land together (independent phase model)',
    () async {
      final wrap = _ClockTreeWrap(
        source: Logic(name: 'clk48'),
        sourceHz: 48000000,
      );
      await wrap.build();
      final sv = wrap.generateSynth();

      // Read back the emitted PLL parameters: what the hardware actually
      // sees, independent of the formula that set them.
      int param(String name) {
        final m = RegExp(r'\.' + name + r'\((-?\d+)\)').firstMatch(sv);
        if (m == null) throw StateError('missing PLL parameter $name');
        return int.parse(m.group(1)!);
      }

      final clkopDiv = param('CLKOP_DIV');
      final clkosDiv = param('CLKOS_DIV');
      final clkopCphase = param('CLKOP_CPHASE');
      final clkopFphase = param('CLKOP_FPHASE');
      final clkosCphase = param('CLKOS_CPHASE');
      final clkosFphase = param('CLKOS_FPHASE');

      // Both outputs must land on an exact VCO cycle (no sub-cycle shift),
      // so a plain CPHASE-mod-DIV model is enough to place their edges.
      expect(clkopFphase, equals(0));
      expect(clkosFphase, equals(0));
      // CLKOS must repeat on a whole number of CLKOP periods for its edge
      // to ever land on a CLKOP edge at all.
      expect(clkosDiv % clkopDiv, equals(0));

      final opEdge = clkopCphase % clkopDiv;
      final osEdgeAtOpPeriod = clkosCphase % clkopDiv;
      expect(
        osEdgeAtOpPeriod,
        equals(opEdge),
        reason:
            'CLKOS edge (CPHASE=$clkosCphase) must coincide with a CLKOP '
            'edge (CPHASE=$clkopCphase) every CLKOP period, or CK/4 rises '
            'off CK by a fraction of a CK',
      );
    },
  );

  test('a CK with no in-band EHXPLLL solution throws', () {
    expect(
      () => _ClockTreeWrap(
        source: Logic(name: 'clk48'),
        sourceHz: 48000000,
        // Outside the ECP5 EHXPLLL 10-400 MHz output band.
        ddrCkHz: 4000000000,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a CK not divisible by 4 throws', () {
    expect(
      () => _ClockTreeWrap(
        source: Logic(name: 'clk48'),
        sourceHz: 48000000,
        ddrCkHz: 96000001,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('a CK reachable only through the highres CLKOS path throws '
      '(CLKOP would be feedback-only)', () {
    // 25 MHz -> 48 MHz has no in-band CLKOP-direct solution (nearest simple
    // result is 46.875 MHz). ecp5PllSolve only reaches 48 MHz exactly
    // through the highres path (see HarborClockGenerator.ecp5PllSolve's
    // doc comment), which this tree must reject.
    final sol = HarborClockGenerator.ecp5PllSolve(25000000, 48000000);
    expect(sol.clkosDiv, isNotNull);
    expect(
      () => _ClockTreeWrap(
        source: Logic(name: 'clk25'),
        sourceHz: 25000000,
        ddrCkHz: 48000000,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}

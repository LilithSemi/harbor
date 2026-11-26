import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Wrapper so the MMCM + 4 BUFG DDR3 clock tree shows up in generateSynth().
class _ClockTreeWrap extends BridgeModule {
  late final XilinxDdr3Clocks clocks;

  _ClockTreeWrap({
    required Logic source,
    required int sourceHz,
    int ddrCkHz = 333333333,
    double dqsPhaseDeg = 180.0,
    int ddrGearRatio = 1,
  }) : super('ClockTreeWrap') {
    source = addInput('source', source);
    clocks = buildXilinxDdr3ClockTree(
      this,
      source: source,
      sourceHz: sourceHz,
      ddrCkHz: ddrCkHz,
      dqsPhaseDeg: dqsPhaseDeg,
      ddrGearRatio: ddrGearRatio,
    );
    // Pull the clocks + LOCKED up to ports so nothing is pruned.
    addOutput('ddr_ck') <= clocks.ddrCk;
    addOutput('controller') <= clocks.controller;
    addOutput('controller_clk') <= clocks.controllerClk;
    addOutput('idelay_ref') <= clocks.idelayRef;
    addOutput('ddr_ck90') <= clocks.ddrCk90;
    addOutput('ddr_ck_dqs') <= clocks.ddrCkDqs;
    addOutput('locked') <= clocks.locked;
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  group('DDR3 clock-tree VCO solver', () {
    test('12 MHz Arty S7 CLK12 (F14) reaches DDR3-667 in-band', () {
      final sol = solveDdr3ClockTree(12000000, 333333333, 200000000);
      expect(sol, isNotNull);
      expect(sol!.vco, inInclusiveRange(600e6, 1200e6));
      final ck = sol.vco / sol.ckDivide;
      final ctrl = sol.vco / sol.ctrlDivide;
      final ref = sol.vco / sol.refDivide;
      // From a 12 MHz source the fractional-divide granularity forces a
      // ~3% CK error to keep the IDELAYCTRL ref in band (the 100 MHz R2
      // input lands exact: the reason it is the preferred DDR3 clock source).
      expect((ck - 333333333).abs() / 333333333, lessThan(0.03));
      expect((ctrl - 333333333 / 4).abs() / (333333333 / 4), lessThan(0.05));
      // IDELAYCTRL ref must be inside the 190-210 MHz calibration band.
      expect(ref, inInclusiveRange(190e6, 210e6));
    });

    test(
      '100 MHz Arty S7 clock (R2) reaches DDR3-667 with exact 200 MHz ref',
      () {
        final sol = solveDdr3ClockTree(100000000, 333333333, 200000000);
        expect(sol, isNotNull);
        expect(sol!.vco, inInclusiveRange(600e6, 1200e6));
        final ref = sol.vco / sol.refDivide;
        // 100 MHz in -> VCO 1000 (mult 10) -> /5 = 200 MHz exact.
        expect(ref, inInclusiveRange(190e6, 210e6));
        final ck = sol.vco / sol.ckDivide;
        expect((ck - 333333333).abs() / 333333333, lessThan(0.02));
      },
    );

    test('a sub-10 MHz source has no in-band solution (VCO floor)', () {
      // 5 MHz * 512/8 = 320 MHz max VCO < 600 -> unreachable.
      expect(solveDdr3ClockTree(5000000, 333333333, 200000000), isNull);
    });
  });

  test('DDR3 clock tree elaborates and emits MMCM + 4 dedicated BUFGs', () async {
    final wrap = _ClockTreeWrap(
      source: Logic(name: 'clk100'),
      sourceHz: 100000000,
    );
    await wrap.build();
    final sv = wrap.dumpSystemVerilog();

    // One PLLE2, UberDDR3-proven openXC7 form (INTERNAL compensation, feedback
    // wired directly with no BUFG).
    expect(sv, contains('PLLE2_ADV'));
    expect(sv, contains('.COMPENSATION("INTERNAL")'));
    // All four CLKOUTs configured, CLKOUT3 carries the 90-degree write phase.
    expect(sv, contains('.CLKOUT1_DIVIDE('));
    expect(sv, contains('.CLKOUT2_DIVIDE('));
    expect(sv, contains('.CLKOUT3_DIVIDE('));
    expect(sv, contains('.CLKOUT3_PHASE(90.0)'));
    // CLKOUT4 = the DQS launch clock at the default 180-degree oracle phase
    // (the UberDDR3 Arty HR-bank !i_ddr3_clk DQS launch, sub-CK DQS-vs-CK).
    expect(sv, contains('.CLKOUT4_DIVIDE('));
    expect(sv, contains('.CLKOUT4_PHASE(180.0)'));
    // A dedicated BUFG per output (5). INTERNAL compensation wires the feedback
    // directly so there is no feedback BUFG.
    final bufgCount =
        'BUFG '.allMatches(sv).length +
        RegExp(r'\bBUFG\b\s+\w+_bufg').allMatches(sv).length;
    expect(
      bufgCount,
      greaterThanOrEqualTo(5),
      reason: '5 output BUFGs (CK/ctrl/idelayref/ck90/ckdqs)',
    );
    // The realised frequencies are the DDR3-667 arrangement.
    expect(wrap.clocks.ddrCkMhz, closeTo(333.3, 5));
    expect(wrap.clocks.controllerMhz, closeTo(83.3, 5));
    expect(wrap.clocks.idelayRefMhz, inInclusiveRange(190, 210));
  });

  test('DQS launch phase (CLKOUT4) is build-sweepable', () async {
    final wrap = _ClockTreeWrap(
      source: Logic(name: 'clk100'),
      sourceHz: 100000000,
      dqsPhaseDeg: 135.0,
    );
    await wrap.build();
    final sv = wrap.dumpSystemVerilog();
    expect(sv, contains('.CLKOUT4_PHASE(135.0)'));
  });

  group('DDR gearRatio 2 (CK/8 controller on CLKOUT5)', () {
    test(
      'gearRatio 1 emits NO CLKOUT5, controllerClk == controller (CK/4)',
      () async {
        final wrap = _ClockTreeWrap(
          source: Logic(name: 'clk100'),
          sourceHz: 100000000,
        );
        await wrap.build();
        final sv = wrap.dumpSystemVerilog();
        // No spare CLKOUT5 is configured -> byte-identical to the pre-gearbox tree.
        expect(sv, isNot(contains('.CLKOUT5_DIVIDE(')));
        // The sequencer clock IS CK/4 at gearRatio 1.
        expect(wrap.clocks.controllerClkMhz, wrap.clocks.controllerMhz);
      },
    );

    test(
      'gearRatio 2 emits CK/8 on CLKOUT5, valid integer divides in band',
      () async {
        final wrap = _ClockTreeWrap(
          source: Logic(name: 'clk100'),
          sourceHz: 100000000,
          ddrGearRatio: 2,
        );
        await wrap.build();
        final sv = wrap.dumpSystemVerilog();
        final c = wrap.clocks;
        // ignore: avoid_print
        print(
          'gearRatio 2 PLL: VCO=${c.vcoMhz} CK=${c.ddrCkMhz} '
          'CK/4=${c.controllerMhz} CK/8(controllerClk)=${c.controllerClkMhz}',
        );

        // CLKOUT5 is now the CK/8 controller clock (integer 2x the CK/4 divide).
        expect(sv, contains('.CLKOUT5_DIVIDE('));
        // CK/8 = exactly half the CK/4 rate (same VCO, integer 2:1).
        expect(c.controllerClkMhz, closeTo(c.controllerMhz / 2, 0.01));
        // The DDR CK + SERDES CK/4 are unchanged by the gearing.
        expect(c.ddrCkMhz, closeTo(333.3, 5));
        expect(c.controllerMhz, closeTo(83.3, 5));
        // VCO in band and both ctrl divides integer (2:1 phase-locked).
        expect(c.vcoMhz, inInclusiveRange(600, 1200));
        final ctrlDiv = c.vcoMhz / c.controllerMhz;
        final gearDiv = c.vcoMhz / c.controllerClkMhz;
        expect(ctrlDiv, closeTo(ctrlDiv.round().toDouble(), 0.01));
        expect(gearDiv, closeTo(gearDiv.round().toDouble(), 0.01));
        expect(gearDiv.round(), 2 * ctrlDiv.round());
      },
    );

    test('gearRatio 2 with a core clock on CLKOUT5 is rejected (conflict)', () {
      expect(
        () => buildXilinxDdr3ClockTree(
          _ClockTreeWrap(source: Logic(), sourceHz: 100000000),
          source: Logic(name: 's'),
          sourceHz: 100000000,
          coreClkHz: 50000000,
          ddrGearRatio: 2,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

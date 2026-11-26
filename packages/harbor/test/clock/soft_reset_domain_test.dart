// A domain made from a provided clock, such as the Xilinx DDR3 core clock,
// sees the soft reset request. The raw reset source stays out of it.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

class _Harness extends BridgeModule {
  late final HarborClockDomain domain;
  late final HarborClockGenerator gen;

  _Harness({required bool soft}) : super('SoftResetHarness_$soft') {
    createPort('clk', PortDirection.input);
    createPort('pclk', PortDirection.input);
    createPort('hard', PortDirection.input);
    createPort('soft', PortDirection.input);
    addOutput('domain_reset');
    addOutput('hard_reset');
    gen = HarborClockGenerator(
      parent: this,
      inputClk: input('clk'),
      inputReset: input('hard'),
      softReset: soft ? input('soft') : null,
    );
    domain = gen.createDomainFromClock(
      HarborClockConfig.fixed(
        name: 'core',
        frequency: 100000000,
        sourceFrequency: 100000000,
      ),
      input('pclk'),
      locked: Const(1),
    );
    output('domain_reset') <= domain.reset;
    output('hard_reset') <= gen.hardResetOf(domain);
  }
}

/// An ASIC target domain, which has no PLL primitive and shares the input
/// clock.
class _AsicHarness extends BridgeModule {
  late final HarborClockDomain domain;
  late final HarborClockGenerator gen;

  _AsicHarness({required bool soft}) : super('SoftResetAsic_$soft') {
    createPort('clk', PortDirection.input);
    createPort('hard', PortDirection.input);
    createPort('soft', PortDirection.input);
    addOutput('domain_reset');
    addOutput('hard_reset');
    gen = HarborClockGenerator(
      parent: this,
      inputClk: input('clk'),
      inputReset: input('hard'),
      softReset: soft ? input('soft') : null,
      target: HarborAsicTarget(
        provider: Sky130Provider(pdkRoot: '/pdk/sky130A'),
        topCell: 'top',
      ),
    );
    domain = gen.createDomain(
      HarborClockConfig.fixed(
        name: 'core',
        frequency: 50000000,
        sourceFrequency: 100000000,
      ),
    );
    output('domain_reset') <= domain.reset;
    output('hard_reset') <= gen.hardResetOf(domain);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('the soft reset request resets a provided clock domain and the raw '
      'reset source does not', () async {
    final h = _Harness(soft: true);
    final clk = SimpleClockGenerator(10).clk;
    final pclk = SimpleClockGenerator(14).clk;
    final hard = Logic(name: 'hard')..inject(0);
    final soft = Logic(name: 'soft')..inject(1);
    h.input('clk').srcConnection! <= clk;
    h.input('pclk').srcConnection! <= pclk;
    h.input('hard').srcConnection! <= hard;
    h.input('soft').srcConnection! <= soft;
    await h.build();
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    bool v(String o) => h.output(o).value.toInt() == 1;

    for (var i = 0; i < 4; i++) {
      await pclk.nextPosedge;
    }
    expect(v('domain_reset'), isTrue);
    soft.inject(0);
    for (var i = 0; i < 4; i++) {
      await pclk.nextPosedge;
    }
    expect(v('domain_reset'), isFalse);
    expect(v('hard_reset'), isFalse);

    // The raw reset source does not reach the domain.
    hard.inject(1);
    for (var i = 0; i < 4; i++) {
      await pclk.nextPosedge;
    }
    expect(v('domain_reset'), isFalse);
    hard.inject(0);

    // The soft reset request asserts the domain reset, and releases it in
    // the domain clock. The hard reset of the domain never sees it.
    await pclk.nextNegedge;
    soft.inject(1);
    await pclk.nextNegedge;
    expect(v('domain_reset'), isTrue);
    expect(v('hard_reset'), isFalse);
    soft.inject(0);
    await pclk.nextPosedge;
    expect(v('domain_reset'), isTrue);
    for (var i = 0; i < 4; i++) {
      await pclk.nextPosedge;
    }
    expect(v('domain_reset'), isFalse);
    await Simulator.endSimulation();
  });

  test('without a soft reset request the domain reset is the hard reset', () {
    final h = _Harness(soft: false);
    expect(h.gen.hardResetOf(h.domain), same(h.domain.reset));
  });

  test('an ASIC target domain sees the soft reset request', () async {
    final h = _AsicHarness(soft: true);
    final clk = SimpleClockGenerator(10).clk;
    final hard = Logic(name: 'hard')..inject(0);
    final soft = Logic(name: 'soft')..inject(0);
    h.input('clk').srcConnection! <= clk;
    h.input('hard').srcConnection! <= hard;
    h.input('soft').srcConnection! <= soft;
    await h.build();
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    bool v(String o) => h.output(o).value.toInt() == 1;
    await clk.nextPosedge;
    expect(v('domain_reset'), isFalse);
    soft.inject(1);
    await clk.nextNegedge;
    expect(v('domain_reset'), isTrue);
    expect(v('hard_reset'), isFalse);
    soft.inject(0);
    await clk.nextNegedge;
    expect(v('domain_reset'), isFalse);
    hard.inject(1);
    await clk.nextNegedge;
    expect(v('hard_reset'), isTrue);
    await Simulator.endSimulation();
  });

  test('an ASIC domain without a soft request keeps its reset', () {
    final h = _AsicHarness(soft: false);
    expect(h.domain.reset, same(h.gen.inputReset));
  });
}

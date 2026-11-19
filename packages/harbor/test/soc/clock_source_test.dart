import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

HarborSoC _kc705({required List<HarborClockConfig> clocks, bool tree = true}) {
  final board = HarborBoard.get('kc705');
  return HarborSoC(
    name: 'ClockSourceSoc',
    compatible: 'test,clock-source',
    target: board.fpgaTarget(pins: ['clk', 'clk_n', 'uart_tx', 'uart_rx']),
    clocks: clocks,
    xilinxDdr3Tree: tree
        ? const XilinxDdr3TreeSpec.kc705(coreClkHz: 50000000)
        : null,
  );
}

HarborClockConfig _core() => const HarborClockConfig(
  name: 'core',
  rate: HarborFixedClockRate(50000000),
  sourceFrequency: 200000000,
  source: HarborClockSource.ddr3Core,
);

HarborClockConfig _bus(int hz) => HarborClockConfig(
  name: 'bus',
  rate: HarborFixedClockRate(hz),
  sourceFrequency: 200000000,
  source: HarborClockSource.ddr3Controller,
);

void main() {
  tearDown(() async => Simulator.reset());

  test('the default source is pll', () {
    final c = HarborClockConfig.fixed(name: 'sys', frequency: 50000000);
    expect(c.source, HarborClockSource.pll);
  });

  test('a pll clock builds with its own PLL', () {
    final soc = _kc705(
      tree: false,
      clocks: [
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 50000000,
          sourceFrequency: 200000000,
        ),
      ],
    );
    expect(soc.clockDomain('sys')!.config.source, HarborClockSource.pll);
    expect(soc.xilinxDdr3Clocks, isNull);
  });

  test('ddr3Core binds the core clock of the tree', () {
    final soc = _kc705(clocks: [_core()]);
    final d = soc.clockDomain('core')!;
    expect(d.config.source, HarborClockSource.ddr3Core);
    expect(d.clk.name, 'core_clk');
  });

  test('ddr3Controller binds the controller clock of the tree', () {
    final soc = _kc705(clocks: [_core(), _bus(83333333)]);
    final d = soc.clockDomain('bus')!;
    expect(identical(d.clk, soc.xilinxDdr3Clocks!.controllerClk), isTrue);
    expect(d.config.frequency, 83333333);
    expect(soc.xilinxDdr3Clocks!.controllerClkMhz, closeTo(83.333, 0.01));
  });

  test('ddr3Controller with no tree throws and names the domain', () {
    expect(
      () => _kc705(tree: false, clocks: [_bus(83333333)]),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('bus')),
      ),
    );
  });

  test('ddr3Controller with a wrong frequency throws and names both', () {
    expect(
      () => _kc705(clocks: [_core(), _bus(75000000)]),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('75'), contains('83.3')),
        ),
      ),
    );
  });

  group('addClockDomainFromNet', () {
    HarborSoC sim() => HarborSoC(
      name: 'NetClockSoc',
      compatible: 'test,net-clock',
      target: const HarborSimTarget(frequency: 50000000),
    );

    test('reset stays high until locked rises', () async {
      final soc = sim();
      final ext = soc.addInput('ext_clk', Logic());
      final lock = soc.addInput('ext_locked', Logic());
      final d = soc.addClockDomainFromNet(
        HarborClockConfig.fixed(name: 'ext', frequency: 25000000),
        ext,
        locked: lock,
      );
      expect(soc.clockDomain('ext'), same(d));
      final clk = SimpleClockGenerator(10).clk;
      final extClk = SimpleClockGenerator(8).clk;
      final locked = Logic(name: 'lockDrv')..inject(0);
      final reset = Logic(name: 'reset')..inject(1);
      soc.input('clk').srcConnection! <= clk;
      soc.input('reset').srcConnection! <= reset;
      soc.input('ext_clk').srcConnection! <= extClk;
      soc.input('ext_locked').srcConnection! <= locked;
      await soc.build();
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      for (var i = 0; i < 100; i++) {
        await clk.nextPosedge;
      }
      expect(d.reset.value, isNot(LogicValue.zero));
      locked.inject(1);
      for (var i = 0; i < 10; i++) {
        await clk.nextPosedge;
      }
      expect(d.reset.value, LogicValue.zero);
      await Simulator.endSimulation();
    });

    test('a taken name throws', () {
      final soc = sim();
      final cfg = HarborClockConfig.fixed(name: 'ext', frequency: 25000000);
      soc.addClockDomainFromNet(cfg, soc.addInput('c0', Logic()));
      expect(
        () => soc.addClockDomainFromNet(cfg, soc.addInput('c1', Logic())),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a call after build throws', () async {
      final soc = sim();
      final ext = soc.addInput('ext_clk', Logic());
      soc.input('clk').srcConnection! <= Logic();
      soc.input('reset').srcConnection! <= Logic();
      soc.input('ext_clk').srcConnection! <= Logic();
      await soc.build();
      expect(
        () => soc.addClockDomainFromNet(
          HarborClockConfig.fixed(name: 'late', frequency: 25000000),
          ext,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

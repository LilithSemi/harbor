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

  test('ddr3Controller rate is exact to the realised Hz', () {
    final ck300 = HarborSoC(
      name: 'Ck300Soc',
      compatible: 'test,ck300',
      target: HarborBoard.get(
        'kc705',
      ).fpgaTarget(pins: ['clk', 'clk_n', 'uart_tx', 'uart_rx']),
      clocks: [_core(), _bus(75000000)],
      xilinxDdr3Tree: const XilinxDdr3TreeSpec.kc705(
        coreClkHz: 50000000,
        ddrCkHz: 300000000,
      ),
    );
    expect(ck300.clockDomain('bus')!.config.frequency, 75000000);
    expect(
      () => _kc705(clocks: [_core(), _bus(83333433)]),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'ddr3Controller reset is high before the DDR lock and low after',
    () async {
      final soc = _kc705(clocks: [_core(), _bus(83333333)]);
      final d = soc.clockDomain('bus')!;
      final tree = soc.xilinxDdr3Clocks!;
      final clk = SimpleClockGenerator(10).clk;
      soc.input('clk').srcConnection! <= clk;
      soc.input('clk_n').srcConnection! <= Logic();
      await soc.build();
      // The tree is a black box in sim, so the test drives its outputs.
      // The lock timer starts at 0 on an FPGA (INIT=0).
      soc.signals.firstWhere((s) => s.name == 'bus_provLockCnt').put(0);
      tree.locked.put(0);
      final seen = <String, LogicValue>{};
      for (var t = 0; t < 200; t++) {
        Simulator.registerAction(t * 6, () {
          tree.controllerClk.put(t.isEven ? 1 : 0);
          if (t == 100) tree.locked.put(1);
          if (t == 90) seen['before'] = d.reset.value;
          if (t == 150) seen['after'] = d.reset.value;
        });
      }
      Simulator.setMaxSimTime(2000);
      await Simulator.run();
      expect(seen['before'], LogicValue.one);
      expect(seen['after'], LogicValue.zero);
    },
  );

  group('addClockDomainFromNet', () {
    HarborSoC sim() => HarborSoC(
      name: 'NetClockSoc',
      compatible: 'test,net-clock',
      target: const HarborSimTarget(frequency: 50000000),
    );

    /// Builds a SoC with one net domain, runs it, and calls [check] with the
    /// SoC reset and lock inputs. The domain reset is read once the clocks run.
    Future<void> run(
      Future<void> Function(
        HarborClockDomain d,
        Logic clk,
        Logic reset,
        Logic locked,
      )
      check,
    ) async {
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
      for (var i = 0; i < 20; i++) {
        await clk.nextPosedge;
      }
      await check(d, clk, reset, locked);
      await Simulator.endSimulation();
    }

    test('reset is high before lock and low after', () async {
      await run((d, clk, reset, locked) async {
        reset.inject(0);
        for (var i = 0; i < 20; i++) {
          await clk.nextPosedge;
        }
        expect(d.reset.value, LogicValue.one);
        locked.inject(1);
        for (var i = 0; i < 10; i++) {
          await clk.nextPosedge;
        }
        expect(d.reset.value, LogicValue.zero);
      });
    });

    test('the SoC reset holds the domain with lock high', () async {
      await run((d, clk, reset, locked) async {
        reset.inject(0);
        locked.inject(1);
        for (var i = 0; i < 20; i++) {
          await clk.nextPosedge;
        }
        expect(d.reset.value, LogicValue.zero);
        reset.inject(1);
        for (var i = 0; i < 5; i++) {
          await clk.nextPosedge;
        }
        expect(d.reset.value, LogicValue.one);
      });
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

    test('a call after buildFabric throws', () {
      final soc = sim();
      final ext = soc.addInput('ext_clk', Logic());
      soc.buildFabric();
      expect(
        () => soc.addClockDomainFromNet(
          HarborClockConfig.fixed(name: 'late', frequency: 25000000),
          ext,
        ),
        throwsA(isA<StateError>()),
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

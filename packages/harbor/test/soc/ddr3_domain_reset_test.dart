import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _core = HarborClockConfig(
  name: 'core',
  rate: HarborFixedClockRate(50000000),
  sourceFrequency: 200000000,
  source: HarborClockSource.ddr3Core,
);

const _bus = HarborClockConfig(
  name: 'bus',
  rate: HarborFixedClockRate(83333333),
  sourceFrequency: 200000000,
  source: HarborClockSource.ddr3Controller,
);

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'the reset pin holds the core and bus domains of the DDR3 tree',
    () async {
      final soc = HarborSoC(
        name: 'Ddr3DomainReset',
        compatible: 'test,ddr3-domain-reset',
        target: HarborBoard.get(
          'kc705',
        ).fpgaTarget(pins: ['clk', 'clk_n', 'uart_tx', 'uart_rx']),
        clocks: const [_core, _bus],
        xilinxDdr3Tree: const XilinxDdr3TreeSpec.kc705(coreClkHz: 50000000),
        externalReset: true,
      );
      final core = soc.clockDomain('core')!;
      final bus = soc.clockDomain('bus')!;
      final tree = soc.xilinxDdr3Clocks!;
      final resetN = Logic(name: 'reset_n_drv')..inject(1);
      soc.input('clk').srcConnection! <= Logic();
      soc.input('clk_n').srcConnection! <= Logic();
      soc.input('reset_n').srcConnection! <= resetN;
      await soc.build();

      final corePll = soc.subModules.firstWhere((m) => m.name == 'coreclk_pll');
      final pad = soc.subModules
          .firstWhere((m) => m.name == 'sysclk_ibufds')
          .output('O');
      final coreOut = corePll.output('CLKOUT0');
      final seen = <String, List<LogicValue>>{};
      void sample(String key) =>
          seen[key] = [core.reset.value, bus.reset.value];

      // The PLL outputs and the board clock pad are black boxes in
      // simulation, so the test drives them.
      const edge = 6;
      // Flops without a reset start at X in simulation, and FPGA flops start
      // at 0. The test sets them after the first tick.
      final powerUp = [
        for (final m in [soc, ...soc.subModules])
          ...m.signals.where(
            (s) =>
                s.name == 'porCount' ||
                s.name == 'core_provLockCnt' ||
                s.name == 'bus_provLockCnt',
          ),
      ];
      for (var t = 0; t < 800; t++) {
        Simulator.registerAction(t * edge, () {
          if (t == 2) {
            for (final s in powerUp) {
              s.put(0);
            }
          }
          pad.put(t > 4 && t.isOdd ? 1 : 0);
          coreOut.put(t.isEven ? 1 : 0);
          tree.controllerClk.put(t.isEven ? 1 : 0);
          corePll.output('LOCKED').put(1);
          tree.locked.put(1);
          if (t == 500) sample('released');
          if (t == 520) resetN.put(0);
          if (t == 560) sample('asserted');
          if (t == 580) resetN.put(1);
          if (t == 700) sample('after');
        });
      }
      Simulator.setMaxSimTime(800 * edge + 10);
      await Simulator.run();

      expect(seen['released'], everyElement(LogicValue.zero));
      expect(seen['asserted'], everyElement(LogicValue.one));
      expect(seen['after'], everyElement(LogicValue.zero));
    },
  );
}

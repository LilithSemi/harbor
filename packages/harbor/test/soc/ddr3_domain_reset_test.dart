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

/// Builds a KC705 SoC with a DDR3 tree, runs it, and returns the resets of the
/// core and bus domains at the ticks that [at] names. [act] runs at tick t
/// with the reset pin and the reset request.
Future<Map<int, List<LogicValue>>> _run({
  required int ticks,
  required List<int> at,
  required void Function(int t, Logic resetN, Logic request) act,
}) async {
  final request = Logic(name: 'request_drv')..inject(0);
  final soc = HarborSoC(
    name: 'Ddr3DomainReset',
    compatible: 'test,ddr3-domain-reset',
    target: HarborBoard.get(
      'kc705',
    ).fpgaTarget(pins: ['clk', 'clk_n', 'uart_tx', 'uart_rx']),
    clocks: const [_core, _bus],
    xilinxDdr3Tree: const XilinxDdr3TreeSpec.kc705(coreClkHz: 50000000),
    externalReset: true,
    resetRequest: request,
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
  final seen = <int, List<LogicValue>>{};
  // Flops without a reset start at X in simulation, and FPGA flops start at
  // 0. The test sets them after the first tick.
  final powerUp = [
    for (final m in [soc, ...soc.subModules])
      ...m.signals.where(
        (s) =>
            s.name == 'porCount' ||
            s.name == 'core_provLockCnt' ||
            s.name == 'bus_provLockCnt',
      ),
  ];
  // The PLL outputs and the board clock pad are black boxes in simulation,
  // so the test drives them.
  const edge = 6;
  for (var t = 0; t < ticks; t++) {
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
      act(t, resetN, request);
      if (at.contains(t)) seen[t] = [core.reset.value, bus.reset.value];
    });
  }
  Simulator.setMaxSimTime(ticks * edge + 10);
  await Simulator.run();
  return seen;
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'the reset pin holds the core and bus domains of the DDR3 tree',
    () async {
      final seen = await _run(
        ticks: 800,
        at: [500, 560, 700],
        act: (t, resetN, request) {
          if (t == 520) resetN.put(0);
          if (t == 580) resetN.put(1);
        },
      );
      expect(seen[500], everyElement(LogicValue.zero));
      expect(seen[560], everyElement(LogicValue.one));
      expect(seen[700], everyElement(LogicValue.zero));
    },
  );

  test('a reset request holds both domains for the stretch', () async {
    final hold = 2 * HarborSoC.resetRequestHoldCycles;
    final seen = await _run(
      ticks: 700 + hold + 700,
      at: [500, 800, 700 + hold - 300, 700 + hold + 600],
      act: (t, resetN, request) {
        if (t == 700) request.put(1);
        if (t == 704) request.put(0);
      },
    );
    expect(seen[500], everyElement(LogicValue.zero));
    expect(seen[800], everyElement(LogicValue.one));
    expect(seen[700 + hold - 300], everyElement(LogicValue.one));
    expect(seen[700 + hold + 600], everyElement(LogicValue.zero));
  });
}

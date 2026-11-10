import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _pllClock = HarborClockConfig(
  name: 'sys',
  rate: HarborFixedClockRate(100000000),
  sourceFrequency: 200000000,
);

Future<Directory> _generate({
  required bool useHimbaechel,
  List<HarborClockConfig> clocks = const [_pllClock],
  XilinxDdr3TreeSpec? tree,
}) async {
  final board = HarborBoard.get('kc705');
  final noPll = clocks.isEmpty;
  final target = board.fpgaTarget(
    pins: ['clk', 'clk_n', 'uart_tx', 'uart_rx', if (noPll) 'reset'],
    useHimbaechel: useHimbaechel,
  );
  final soc = HarborSoC(
    name: 'PllSoc',
    compatible: 'test,pll-soc',
    target: target,
    clocks: clocks,
    xilinxDdr3Tree: tree,
  );
  final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
  soc.exposePin(uart, 'tx', externalName: 'uart_tx');
  soc.exposePin(uart, 'rx', externalName: 'uart_rx');
  final dir = Directory.systemTemp.createTempSync('harbor_pll_clock_');
  await soc.generateAll(dir);
  return dir;
}

String _read(Directory dir, String file) =>
    File('${dir.path}/$file').readAsStringSync();

/// The XDC clock lines on a net, other than the differential input net.
List<String> _netClocks(Directory dir) => _read(dir, 'PllSoc.xdc')
    .split('\n')
    .where((l) => l.contains('[get_nets') && !l.contains('sysclk_diff'))
    .toList();

bool _exists(Directory dir, String file) =>
    File('${dir.path}/$file').existsSync();

void main() {
  tearDown(() async => Simulator.reset());

  test('legacy flow gets a strict clock script for the PLL clock', () async {
    final dir = await _generate(useHimbaechel: false);
    addTearDown(() => dir.deleteSync(recursive: true));
    final py = _read(dir, 'support/nextpnr/pll_clocks.py');
    expect(py, contains("('sys_clk', 100.00)"));
    expect(py, contains('ctx.addClock(net, mhz)'));
    expect(py, isNot(contains('except')));
    expect(_exists(dir, 'support/nextpnr/clocks.py'), isFalse);
    expect(_read(dir, 'PllSoc.xdc'), isNot(contains('[get_nets sys_clk]')));
    expect(
      _read(dir, 'rtl/PllSoc.sv'),
      contains('(* keep = 1 *) logic sys_clk;'),
    );
    final mk = _read(dir, 'Makefile');
    expect(
      mk,
      contains(
        r'PREPACK := $(if $(wildcard support/nextpnr/pll_clocks.py),'
        r'--pre-pack support/nextpnr/pll_clocks.py,)',
      ),
    );
    expect(mk, isNot(contains('--timing-allow-fail,')));
  });

  test('himbaechel flow gets the PLL clock in the XDC', () async {
    final dir = await _generate(useHimbaechel: true);
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(
      _read(dir, 'PllSoc.xdc'),
      contains('create_clock -period 10.000 [get_nets sys_clk]'),
    );
    expect(_exists(dir, 'support/nextpnr/clocks.py'), isFalse);
    expect(_exists(dir, 'support/nextpnr/pll_clocks.py'), isFalse);
    expect(
      _read(dir, 'rtl/PllSoc.sv'),
      contains('(* keep = 1 *) logic sys_clk;'),
    );
  });

  for (final himb in [false, true]) {
    test(
      'a design without a PLL has no clock net or script, himb=$himb',
      () async {
        final dir = await _generate(useHimbaechel: himb, clocks: const []);
        addTearDown(() => dir.deleteSync(recursive: true));
        expect(_exists(dir, 'support/nextpnr/pll_clocks.py'), isFalse);
        expect(_exists(dir, 'support/nextpnr/clocks.py'), isFalse);
        expect(_netClocks(dir), isEmpty);
        expect(_read(dir, 'rtl/PllSoc.sv'), isNot(contains('keep')));
      },
    );

    test('a DDR3 clock tree build keeps its output, himb=$himb', () async {
      final dir = await _generate(
        useHimbaechel: himb,
        clocks: const [
          HarborClockConfig(
            name: 'sys',
            rate: HarborFixedClockRate(100000000),
            sourceFrequency: 200000000,
            providedByDdr3Tree: true,
          ),
          HarborClockConfig(
            name: 'aux',
            rate: HarborFixedClockRate(50000000),
            sourceFrequency: 200000000,
          ),
        ],
        tree: const XilinxDdr3TreeSpec(
          sourceHz: 200000000,
          ddrCkHz: 400000000,
          coreClkHz: 100000000,
        ),
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      expect(_exists(dir, 'support/nextpnr/pll_clocks.py'), isFalse);
      expect(_read(dir, 'Makefile'), isNot(contains('pll_clocks')));
      expect(_netClocks(dir), isEmpty);
      final sv = _read(dir, 'rtl/PllSoc.sv');
      expect(sv, isNot(contains('aux_clk')));
      expect(sv, isNot(contains('keep = 1 *) logic aux')));
    });
  }
}

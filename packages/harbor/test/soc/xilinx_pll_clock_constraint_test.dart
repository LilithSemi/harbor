import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

Future<Directory> _generate({
  required bool useHimbaechel,
  required bool withPll,
}) async {
  final board = HarborBoard.get('kc705');
  final target = board.fpgaTarget(
    pins: ['clk', 'clk_n', 'uart_tx', 'uart_rx', if (!withPll) 'reset'],
    useHimbaechel: useHimbaechel,
  );
  final soc = HarborSoC(
    name: 'PllSoc',
    compatible: 'test,pll-soc',
    target: target,
    clocks: [
      if (withPll)
        const HarborClockConfig(
          name: 'sys',
          rate: HarborFixedClockRate(100000000),
          sourceFrequency: 200000000,
        ),
    ],
  );
  final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
  soc.exposePin(uart, 'tx', externalName: 'uart_tx');
  soc.exposePin(uart, 'rx', externalName: 'uart_rx');
  final dir = Directory.systemTemp.createTempSync('harbor_pll_clock_');
  await soc.generateAll(dir);
  return dir;
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final himb in [false, true]) {
    test('PLL clock without DDR3 is constrained, himbaechel=$himb', () async {
      final dir = await _generate(useHimbaechel: himb, withPll: true);
      addTearDown(() => dir.deleteSync(recursive: true));
      if (himb) {
        expect(
          File('${dir.path}/support/nextpnr/clocks.py').existsSync(),
          isFalse,
        );
        expect(
          File('${dir.path}/PllSoc.xdc').readAsStringSync(),
          contains('create_clock -period 10.000 [get_nets sys_clk]'),
        );
      } else {
        expect(
          File('${dir.path}/support/nextpnr/clocks.py').readAsStringSync(),
          contains("('sys_clk', 100.00)"),
        );
      }
      final rtl = File('${dir.path}/rtl/PllSoc.sv').readAsStringSync();
      expect(rtl, contains('(* keep = 1 *) logic sys_clk;'));
    });
  }

  test('a design without a PLL has no clock script', () async {
    final dir = await _generate(useHimbaechel: true, withPll: false);
    addTearDown(() => dir.deleteSync(recursive: true));
    expect(File('${dir.path}/support/nextpnr/clocks.py').existsSync(), isFalse);
  });
}

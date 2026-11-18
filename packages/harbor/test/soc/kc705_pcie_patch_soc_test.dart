import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

Future<String> _makefile({required bool pcie}) async {
  final board = HarborBoard.get('kc705');
  final target = board.fpgaTarget(
    pins: ['clk', 'clk_n', 'uart_rx', if (pcie) 'pcie_refclk_p' else 'uart_tx'],
  );
  final soc = HarborSoC(
    name: 'PatchSoc',
    compatible: 'test,patch-soc',
    target: target,
    clocks: const [
      HarborClockConfig(
        name: 'sys',
        rate: HarborFixedClockRate(100000000),
        sourceFrequency: 200000000,
      ),
    ],
  );
  final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
  soc.exposePin(uart, 'tx', externalName: pcie ? 'pcie_refclk_p' : 'uart_tx');
  soc.exposePin(uart, 'rx', externalName: 'uart_rx');
  final dir = Directory.systemTemp.createTempSync('harbor_patch_soc_');
  addTearDown(() => dir.deleteSync(recursive: true));
  await soc.generateAll(dir);
  return File('${dir.path}/Makefile').readAsStringSync();
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'a KC705 SoC with the PCIe reference clock port gets the patch',
    () async {
      final mk = await _makefile(pcie: true);
      expect(mk, contains('GTXE2_CHANNEL.GTREFCLK1_USED'));
      expect(mk, contains('0x00002C9F'));
    },
  );

  test('a KC705 SoC without the PCIe ports has no patch', () async {
    final mk = await _makefile(pcie: false);
    expect(mk, isNot(contains('GTXE2')));
    expect(mk, isNot(contains('0x00002C9F')));
  });
}

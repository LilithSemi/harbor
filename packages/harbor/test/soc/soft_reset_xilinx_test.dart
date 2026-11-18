// On a single-oscillator Xilinx board the core clock comes from a separate
// PLL, and its domain reset is made from the PLL lock and a timer. The soft
// reset request must reach that reset too.

import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('the core domain reset of an Arty S7 DDR3-fast SoC depends on the '
      'soft reset request, and the raw reset does not', () async {
    final board = HarborBoard.get('arty-s7-50');
    final soc = HarborSoC(
      name: 'ArtySoft',
      compatible: 'test,arty-soft',
      softReset: true,
      target: board.fpgaTarget(pins: ['clk', 'uart_tx', 'uart_rx']),
      clocks: [
        const HarborClockConfig(
          name: 'sys',
          rate: HarborFixedClockRate(100000000),
          sourceFrequency: 100000000,
          providedByDdr3Tree: true,
        ),
      ],
      xilinxDdr3Tree: const XilinxDdr3TreeSpec(
        sourceHz: 100000000,
        ddrCkHz: 400000000,
        coreClkHz: 100000000,
      ),
    );
    final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
    soc.exposePin(uart, 'tx', externalName: 'uart_tx');
    soc.exposePin(uart, 'rx', externalName: 'uart_rx');
    soc.addResetController(HarborResetController(baseAddress: 0x10005000));
    final dir = Directory.systemTemp.createTempSync('harbor_soft_xilinx_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await soc.generateAll(dir);
    final sv = File('${dir.path}/rtl/ArtySoft.sv').readAsStringSync();

    // The core reset has the soft request in its asserting source.
    expect(sv, contains('softResetRequest'));
    final soft = RegExp(
      r'assign (\w+) = sys_provResetHold \| softResetRequest;',
    ).firstMatch(sv);
    expect(soft, isNotNull);
    expect(
      sv,
      contains('assign sysReset = ${soft!.group(1)} | (~(sysRstSync[1]));'),
    );
    // The raw power-on reset is not in it.
    expect(sv, isNot(contains('sys_provResetHold | porReset')));
    // The controller runs on the hard variant, which has no soft request.
    final hard = RegExp(r'assign sysHardReset = ([^;]*);').firstMatch(sv)!;
    expect(hard.group(1), isNot(contains('softResetRequest')));
    expect(sv, contains('.por(sysHardReset)'));
  });
}

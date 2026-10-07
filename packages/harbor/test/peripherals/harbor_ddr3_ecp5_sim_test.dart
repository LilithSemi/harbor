import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_config.dart';
import 'package:harbor/src/peripherals/harbor_ddr3.dart';
import 'package:harbor/src/soc/target.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Separate file: the 4096-cycle power-on reset makes this slow, so it runs in
// parallel with the other ECP5 simulations.
void main() {
  tearDown(() async => Simulator.reset());

  test('HarborDdr3 on ECP5 holds the controller in reset until the PHY is '
      'ready, and drives cal_failed low', () async {
    final ddr = HarborDdr3(
      config: const HarborDdrConfig.orangeCrab(),
      baseAddress: 0x40000000,
      clockHz: 48000000,
      busAddressWidth: 27,
      busDataWidth: 32,
      ckPeriodPs: 2500,
      target: const HarborFpgaTarget.ecp5(
        device: 'LFE5U-25F',
        package: 'CSFBGA285',
      ),
    );
    final ck = SimpleClockGenerator(2).clk;
    final divInit = Logic(name: 'div_init')..inject(1);
    Simulator.registerAction(2, () => divInit.put(0));
    final div = Logic(name: 'div', width: 2);
    Sequential(ck, reset: divInit, [div < div + 1]);
    final ddrReset = Logic(name: 'ddr_reset')..inject(1);
    // Both clocks come from the same CK source.
    ddr.input('ddr_ck_fast').srcConnection! <= ck;
    ddr.input('ddr_clk').srcConnection! <= div[1];
    ddr.input('ddr_reset').srcConnection! <= ddrReset;
    for (final n in [
      'clk',
      'reset',
      'ddr_ck90_fast',
      'ddr_ck_dqs_fast',
      'ddr_idelay_ref',
    ]) {
      ddr.input(n).srcConnection! <= Const(0);
    }
    await ddr.build();
    final ctrl = ddr.controller!;
    final phyRdy = ddr.signals.firstWhere(
      (s) => s.name == 'phy_idelayctrl_rdy',
    );
    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    for (var i = 0; i < 20; i++) {
      await ck.nextPosedge;
    }
    ddrReset.inject(0);
    var heldWhileNotReady = 0;
    var resetWhileNotReady = 0;
    var readyAt = -1;
    for (var i = 0; i < 24000; i++) {
      await ck.nextPosedge;
      if (phyRdy.value == LogicValue.one) {
        readyAt = i;
        break;
      }
      heldWhileNotReady++;
      if (ctrl.phyReset.value == LogicValue.one) resetWhileNotReady++;
    }
    for (var i = 0; i < 40; i++) {
      await ck.nextPosedge;
    }
    final phyResetAfter = ctrl.phyReset.value;
    final calFailed = ddr.output('cal_failed').value;
    await Simulator.endSimulation();
    expect(readyAt, greaterThan(0));
    expect(resetWhileNotReady, heldWhileNotReady);
    expect(phyResetAfter, LogicValue.zero);
    expect(calFailed, LogicValue.zero);
  });
}

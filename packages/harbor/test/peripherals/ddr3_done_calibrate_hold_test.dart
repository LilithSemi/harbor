import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_dram_model.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('the Xilinx calibration case holds state_calibrate at DONE_CALIBRATE, '
      'it does not go X', () async {
    // Tiny CK period so the power-up reset walk reaches instruction 13 fast.
    final p = DdrParams(controllerClkPeriodPs: 800000, ddr3ClkPeriodPs: 200000);
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rstn');

    final phyData = Logic(name: 'phy_data', width: p.dqBits * p.lanes * 8);
    final phyDqs = Logic(name: 'phy_dqs', width: p.lanes * 8);
    final phyBitslipRef = Logic(name: 'phy_bsref', width: p.lanes * 8);
    final phyRdy = Logic(name: 'phy_rdy');

    // train=hw: runtimeTrainable is false, so this is the plain Xilinx
    // calibration path with no self-training PHY and no runtime override.
    final ctrl = Ddr3Controller(
      p,
      controllerClk: clk,
      rstN: rstN,
      wbCyc: Logic()..inject(0),
      wbStb: Logic()..inject(0),
      wbWe: Logic()..inject(0),
      wbAddr: Logic(width: p.wbAddrBits)..inject(0),
      wbData: Logic(width: p.wbDataBits)..inject(0),
      wbSel: Logic(width: p.wbSelBits)..inject(0),
      aux: Logic(width: Ddr3Controller.auxWidth)..inject(0),
      wb2Cyc: Logic()..inject(0),
      wb2Stb: Logic()..inject(0),
      wb2We: Logic()..inject(0),
      wb2Addr: Logic(width: Ddr3Controller.wb2AddrBits)..inject(0),
      wb2Sel: Logic(width: Ddr3Controller.wb2SelBits)..inject(0),
      wb2Data: Logic(width: Ddr3Controller.wb2DataBits)..inject(0),
      phyIserdesData: phyData,
      phyIserdesDqs: phyDqs,
      phyIserdesBitslipReference: phyBitslipRef,
      phyIdelayctrlRdy: phyRdy,
    );

    final model = Ddr3DramModel(
      p,
      controllerClk: clk,
      phyReset: ctrl.phyReset,
      cmd: ctrl.phyCmd,
      writeData: ctrl.output('o_phy_data'),
      bitslip: ctrl.output('o_phy_bitslip'),
      idelayDqsLd: ctrl.output('o_phy_idelay_dqs_ld'),
    );

    phyData <= model.iserdesData;
    phyDqs <= model.iserdesDqs;
    phyBitslipRef <= model.iserdesBitslipReference;
    phyRdy <= model.idelayctrlRdy;

    await ctrl.build();
    await model.build();

    rstN.inject(0);
    Simulator.setMaxSimTime(3000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    rstN.inject(1);

    var reachedDone = false;
    for (var i = 0; i < 100000 && !reachedDone; i++) {
      await clk.nextPosedge;
      final st = ctrl.debug1.value;
      if (st.isValid && (st.toInt() & 0x3F) == 23) reachedDone = true;
    }
    expect(
      reachedDone,
      isTrue,
      reason: 'calibration never reached DONE_CALIBRATE (state 23)',
    );

    // The unique case has no item for state 23 unless the fix adds one, so
    // the state register (and everything else the case drives) is left
    // undriven the cycle after DONE and goes X in simulation.
    for (var i = 0; i < 200; i++) {
      await clk.nextPosedge;
      final st = ctrl.debug1.value;
      expect(
        st.isValid,
        isTrue,
        reason: 'state_calibrate went X $i cycle(s) after DONE_CALIBRATE',
      );
      expect(st.toInt() & 0x3F, 23, reason: 'state_calibrate left DONE');
    }

    await Simulator.endSimulation();
  });
}

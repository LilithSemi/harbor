import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_dram_model.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('a lane with a nonzero added_read_pipe reaches DONE_CALIBRATE and '
      'added_read_pipe_max tracks it', () async {
    // Same tiny-CK harness as ddr3_readcal_test.dart. With this timing the
    // DQS eye lands past the added_read_pipe threshold for every lane, so
    // every lane needs the extra read-pipe cycle: a lane with a nonzero
    // added_read_pipe never captures read data unless added_read_pipe_max
    // tracks it, so calibration never reaches DONE_CALIBRATE without the
    // fix.
    final p = DdrParams(controllerClkPeriodPs: 800000, ddr3ClkPeriodPs: 200000);
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rstn');

    final phyData = Logic(name: 'phy_data', width: p.dqBits * p.lanes * 8);
    final phyDqs = Logic(name: 'phy_dqs', width: p.lanes * 8);
    final phyBitslipRef = Logic(name: 'phy_bsref', width: p.lanes * 8);
    final phyRdy = Logic(name: 'phy_rdy');

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
      // Gate the BIST read data to its own burst window (cycles 3-6 after
      // the read command, found by sweeping against this harness) and an
      // inverted pattern outside it. A capture at the wrong cycle then
      // reads wrong data instead of the same held value, so this proves
      // the extra-cycle lane captures on the right cycle, not just that
      // it eventually captures something.
      gateReadWindow: true,
      readWindowStart: 3,
      readWindowCycles: 4,
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
    for (var i = 0; i < 20000 && !reachedDone; i++) {
      await clk.nextPosedge;
      final st = ctrl.debug1.value;
      if (st.isValid && (st.toInt() & 0x3F) == 23) reachedDone = true;
    }

    expect(
      reachedDone,
      isTrue,
      reason:
          'calibration never reached DONE_CALIBRATE: a lane with a '
          'nonzero added_read_pipe never captures read data unless '
          'added_read_pipe_max tracks it, so the write/read BIST never '
          'matches and calibration keeps restarting',
    );

    // At least one lane needed the extra read-pipe cycle, and the
    // tracked max must reflect it (not the reset default of 0).
    final lane0 = ctrl.addedReadPipeLaneRegs[0].value.toInt();
    final lane1 = ctrl.addedReadPipeLaneRegs[1].value.toInt();
    expect(
      lane0 == 1 || lane1 == 1,
      isTrue,
      reason: 'this timing should need the extra read-pipe cycle',
    );
    expect(
      ctrl.addedReadPipeMaxReg.value.toInt(),
      1,
      reason: 'added_read_pipe_max must track the lane that needs it',
    );

    await Simulator.endSimulation();
  });
}

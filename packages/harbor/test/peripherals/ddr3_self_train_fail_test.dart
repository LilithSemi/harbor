import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_dram_model.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Tiny CK period so the power-up reset walk is short in simulation.
DdrParams _params() =>
    const DdrParams(controllerClkPeriodPs: 800000, ddr3ClkPeriodPs: 200000);

class _Wb2 {
  final Logic cyc = Logic()..inject(0);
  final Logic stb = Logic()..inject(0);
  final Logic we = Logic()..inject(0);
  final Logic addr = Logic(width: Ddr3Controller.wb2AddrBits)..inject(0);
  final Logic sel = Logic(width: Ddr3Controller.wb2SelBits)..inject(0);
  final Logic data = Logic(width: Ddr3Controller.wb2DataBits)..inject(0);
}

Ddr3Controller _controller(
  DdrParams p, {
  required Logic clk,
  required Logic rstN,
  required Logic phyData,
  required Logic phyRdy,
  required Logic levelDone,
  bool runtimeTrainable = false,
  _Wb2? wb2,
}) {
  final w = wb2 ?? _Wb2();
  return Ddr3Controller(
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
    wb2Cyc: w.cyc,
    wb2Stb: w.stb,
    wb2We: w.we,
    wb2Addr: w.addr,
    wb2Sel: w.sel,
    wb2Data: w.data,
    phyIserdesData: phyData,
    // A self-training PHY returns no DQS samples.
    phyIserdesDqs: Logic(width: p.lanes * 8)..inject(0),
    phyIserdesBitslipReference: Logic(width: p.lanes * 8)..inject(0),
    phyIdelayctrlRdy: phyRdy,
    phySelfTrainsRead: true,
    phyReadPipeTicks: Ddr3PhyEcp5.readPipeTicks,
    phyReadLevelDone: levelDone,
    runtimeTrainable: runtimeTrainable,
  );
}

int _state(Ddr3Controller c) {
  final v = c.debug1.value.getRange(0, 6);
  return v.isValid ? v.toInt() : -1;
}

void main() {
  tearDown(() async => Simulator.reset());

  test('a read path that never passes ends in a visible calibration '
      'failure after maxCalAttempts runs, with the bus open', () async {
    final p = _params();
    final dq = p.dqBits * p.lanes;
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rstn');
    final phyData = Logic(name: 'phy_data', width: dq * 8);
    final phyRdy = Logic(name: 'phy_rdy');
    final levelDone = Logic(name: 'level_done');
    final ctrl = _controller(
      p,
      clk: clk,
      rstN: rstN,
      phyData: phyData,
      phyRdy: phyRdy,
      levelDone: levelDone,
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
    final lev = Ddr3Ecp5ReadLeveler(
      lanes: p.lanes,
      clk: clk,
      reset: ctrl.phyReset,
      start: ctrl.output('o_phy_read_level_start'),
      check: ctrl.output('o_phy_read_level_check'),
      pass: ctrl.output('o_phy_read_level_pass'),
      burstSeen: Const(3, width: 2),
      useBurstDet: false,
    );
    // Every read comes back corrupted.
    phyData <= ~model.iserdesData;
    phyRdy <= model.idelayctrlRdy;
    levelDone <= lev.done;

    await ctrl.build();
    await model.build();
    await lev.build();
    rstN.inject(0);
    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    rstN.inject(1);

    var restarts = 0;
    var lastReset = 0;
    for (var i = 0; i < 300000 && _state(ctrl) != 26; i++) {
      await clk.nextPosedge;
      final r = ctrl.phyReset.value;
      if (r.isValid) {
        if (r.toInt() == 1 && lastReset == 0) restarts++;
        lastReset = r.toInt();
      }
    }
    // The bus stalls only for refresh now, not forever (refresh is frequent
    // at this tiny simulation CK period).
    var openCycles = 0;
    for (var i = 0; i < 500; i++) {
      await clk.nextPosedge;
      if (ctrl.output('o_wb_stall').value.toInt() == 0) openCycles++;
    }
    final state = _state(ctrl);
    final failed = ctrl.calFailed!.value.toInt();
    final debugState = ctrl.debug1.value.getRange(0, 6).toInt();
    await Simulator.endSimulation();

    expect(state, 26, reason: 'calibration did not give up');
    expect(debugState, 26);
    expect(failed, 1);
    expect(restarts, Ddr3Controller.defaultMaxCalAttempts - 1);
    expect(openCycles, greaterThan(100), reason: 'the bus stays stalled');
  });
}

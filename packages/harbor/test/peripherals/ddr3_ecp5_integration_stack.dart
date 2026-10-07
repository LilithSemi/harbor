import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_phy_ecp5.dart';
import 'package:rohd/rohd.dart';

import 'ddr3_ecp5_pad_dram_model.dart';

/// Full-stack test rig: `Ddr3Controller` + the real `Ddr3PhyEcp5`
/// (every ECP5 DQ/DQS/command primitive built from its sim model, see
/// lib/src/blackbox/ecp5/ecp5.dart) + [Ddr3PinDramModel] on the DDR3 pins.
/// The DRAM model sees only the pins, so a PHY timing error fails the run.
///
/// Tiny CK period (the ddr3_self_train_test.dart trick): a slow controller
/// clock makes the reset ROM's nanosecond timers finish in few cycles.
DdrParams ddr3Ecp5TestParams() => DdrParams.orangeCrab(ckPeriodPs: 200000);

const ddr3Ecp5TestDmRemapping = [1, 0];

/// What the leveler should pick with no added read skew. The read gate
/// passes at READCLKSEL 1..3 (the model takes the middle of the preamble),
/// so the centre is 2. The bitslip that lines the burst up with the
/// controller's capture tick is 5 (litedram's bitslip 1, plus the 4 extra
/// positions this PHY keeps for early data).
const int ddr3Ecp5BaseSlip = 5;
const int ddr3Ecp5BaseReadClkSel = 2;

class Ddr3Ecp5IntegrationStack {
  final DdrParams p;
  late final Logic ck;
  late final Logic ctrlClk;
  final Logic rstN = Logic(name: 'rst_n')..inject(0);
  final Logic wbCyc = Logic(name: 'wb_cyc')..inject(0);
  final Logic wbStb = Logic(name: 'wb_stb')..inject(0);
  final Logic wbWe = Logic(name: 'wb_we')..inject(0);
  late final Logic wbAddr;
  late final Logic wbData;
  late final Logic wbSel;
  late final Ddr3Controller ctrl;
  late final Ddr3PhyEcp5 phy;
  late final Ddr3PinDramModel dram;
  final LogicNet _dqPad;
  final LogicNet _dqsPad;

  Ddr3Ecp5IntegrationStack(
    this.p, {
    int readSkewBeats = 0,
    int maxCalAttempts = Ddr3Controller.defaultMaxCalAttempts,
  }) : _dqPad = LogicNet(name: 'dq_pad', width: p.dqBits * p.lanes),
       _dqsPad = LogicNet(name: 'dqs_pad', width: p.lanes) {
    // CK period 4: the clock tree model raises sclk one time unit after a CK
    // rising edge, which must land before the falling edge (as CLKDIVF's
    // output follows ECLK's rising edge) for the x2 gearbox models.
    ck = SimpleClockGenerator(4).clk;
    final divInit = Logic(name: 'div_init')..inject(1);
    Simulator.registerAction(4, () => divInit.put(0));
    final div = Logic(name: 'div', width: 2);
    Sequential(ck, reset: divInit, [div < div + 1]);
    ctrlClk = div[1];

    wbAddr = Logic(name: 'wb_addr', width: p.wbAddrBits)..inject(0);
    wbData = Logic(name: 'wb_data', width: p.wbDataBits)..inject(0);
    wbSel = Logic(name: 'wb_sel', width: p.wbSelBits)..inject(0);

    // Placeholder PHY-return nets: the controller<->PHY construction cycle
    // (same idiom as tool_ddr3_cal_harness.dart).
    final dq = p.dqBits * p.lanes;
    final phyDataNet = Logic(name: 'phy_data', width: dq * 8);
    final phyDqsNet = Logic(name: 'phy_dqs', width: p.lanes * 8);
    final phyBsRefNet = Logic(name: 'phy_bsref', width: p.lanes * 8);
    final phyRdyNet = Logic(name: 'phy_rdy');
    final phyLevelDoneNet = Logic(name: 'phy_level_done');

    ctrl = Ddr3Controller(
      p,
      controllerClk: ctrlClk,
      rstN: rstN,
      wbCyc: wbCyc,
      wbStb: wbStb,
      wbWe: wbWe,
      wbAddr: wbAddr,
      wbData: wbData,
      wbSel: wbSel,
      aux: Logic(width: Ddr3Controller.auxWidth)..inject(0),
      wb2Cyc: Logic()..inject(0),
      wb2Stb: Logic()..inject(0),
      wb2We: Logic()..inject(0),
      wb2Addr: Logic(width: Ddr3Controller.wb2AddrBits)..inject(0),
      wb2Sel: Logic(width: Ddr3Controller.wb2SelBits)..inject(0),
      wb2Data: Logic(width: Ddr3Controller.wb2DataBits)..inject(0),
      phyIserdesData: phyDataNet,
      phyIserdesDqs: phyDqsNet,
      phyIserdesBitslipReference: phyBsRefNet,
      phyIdelayctrlRdy: phyRdyNet,
      phySelfTrainsRead: true,
      maxCalAttempts: maxCalAttempts,
      phyReadPipeTicks: Ddr3PhyEcp5.readPipeTicks,
      phyReadLevelDone: phyLevelDoneNet,
    );

    final dqsNPad = LogicNet(name: 'dqs_n_pad', width: p.lanes);

    phy = Ddr3PhyEcp5(
      p,
      controllerClk: ctrlClk,
      ddr3Clk: ck,
      refClk: Const(0),
      ddr3Clk90: Const(0),
      rstN: rstN,
      controllerReset: ctrl.phyReset,
      cmd: ctrl.phyCmd,
      dqsTriControl: Const(0),
      dqTriControl: Const(0),
      toggleDqs: Const(0),
      data: ctrl.output('o_phy_data'),
      dm: ctrl.output('o_phy_dm'),
      odelayDataCntValueIn: Const(0, width: 5),
      odelayDqsCntValueIn: Const(0, width: 5),
      idelayDataCntValueIn: ctrl.output('o_phy_idelay_data_cntvaluein'),
      idelayDqsCntValueIn: Const(0, width: 5),
      odelayDataLd: Const(0, width: p.lanes),
      odelayDqsLd: Const(0, width: p.lanes),
      idelayDataLd: ctrl.output('o_phy_idelay_data_ld'),
      idelayDqsLd: Const(0, width: p.lanes),
      bitslip: ctrl.output('o_phy_bitslip'),
      writeLevelingCalib: Const(0),
      readLevelStart: ctrl.output('o_phy_read_level_start'),
      readLevelCheck: ctrl.output('o_phy_read_level_check'),
      readLevelPass: ctrl.output('o_phy_read_level_pass'),
      dqPad: _dqPad,
      dqsPad: _dqsPad,
      dqsNPad: dqsNPad,
      dmRemapping: ddr3Ecp5TestDmRemapping,
    );

    phyDataNet <= phy.iserdesData;
    phyDqsNet <= phy.iserdesDqs;
    phyBsRefNet <= phy.iserdesBitslipReference;
    phyRdyNet <= phy.idelayctrlRdy;
    phyLevelDoneNet <= phy.readLevelDone;

    dram = Ddr3PinDramModel(
      p,
      ck: phy.oDdr3ClkP,
      cke: phy.oDdr3Cke,
      resetN: phy.oDdr3ResetN,
      csN: phy.oDdr3CsN,
      rasN: phy.oDdr3RasN,
      casN: phy.oDdr3CasN,
      weN: phy.oDdr3WeN,
      ba: phy.oDdr3BaAddr,
      addr: phy.oDdr3Addr,
      dm: phy.oDdr3Dm,
      dqPad: _dqPad,
      dqsPad: _dqsPad,
      readSkewBeats: readSkewBeats,
      dmRemapping: ddr3Ecp5TestDmRemapping,
    );
  }

  Future<void> build() async {
    await ctrl.build();
    await phy.build();
  }

  Module get leveler =>
      phy.subModules.firstWhere((m) => m.name == 'ecp5_read_leveler');

  /// Leveling pass bits of [lane] at [slip], bit d = READCLKSEL d passed.
  int passRow(int lane, int slip) => leveler.signals
      .firstWhere((x) => x.name == 'pass_vec_$lane')
      .value
      .getRange(slip * 8, slip * 8 + 8)
      .toInt();

  int slipOf(int lane) =>
      (leveler.output('o_slip').value.toInt() >> (4 * lane)) & 0xF;
  int readClkSelOf(int lane) =>
      (leveler.output('o_read_clk_sel').value.toInt() >> (3 * lane)) & 0x7;

  int get state {
    final v = ctrl.debug1.value.getRange(0, 6);
    return v.isValid ? v.toInt() : -1;
  }

  Future<void> run() async {
    rstN.inject(0);
    Simulator.setMaxSimTime(80000000);
    unawaited(Simulator.run());
    // Hold reset across several full controllerClk (CK/4) edges, not just a
    // couple of ck edges: ctrlClk-domain registers (Ddr3Ecp5Init) and the
    // slower sclk-domain ones (the DDRDLLA lock shift register) only apply
    // their reset value on a clock edge of their own domain, and both are
    // several ck periods slower than ck. Two ck edges is not even one full
    // ctrlClk period, so those registers never see a reset edge and stay X
    // forever once released. Ten ctrlClk edges covers every domain here.
    for (var i = 0; i < 10; i++) {
      await ctrlClk.nextPosedge;
    }
    rstN.inject(1);
  }

  /// Runs until DONE_CALIBRATE (23) or CAL_FAILED (26), or [maxTicks]
  /// controllerClk ticks elapse (never hangs).
  Future<int> waitDone({int maxTicks = 12000}) async {
    for (var i = 0; i < maxTicks; i++) {
      await ctrlClk.nextPosedge;
      if (state == 23 || state == 26) return state;
    }
    return state;
  }

  /// Non-pipelined Wishbone write: blocks for acceptance, then for the ack.
  /// CYC stays high until the ack, since the controller drops a pending
  /// request when CYC falls (UberDDR3 OPT_BUS_ABORT).
  Future<void> wbWrite(int addr, LogicValue data, {LogicValue? sel}) async {
    wbAddr.inject(addr);
    wbData.put(data);
    wbSel.put(sel ?? LogicValue.filled(p.wbSelBits, LogicValue.one));
    wbCyc.inject(1);
    wbStb.inject(1);
    wbWe.inject(1);
    while (ctrl.output('o_wb_stall').value.toInt() == 1) {
      await ctrlClk.nextPosedge;
    }
    await ctrlClk.nextPosedge;
    wbStb.inject(0);
    while (ctrl.output('o_wb_ack').value.toInt() == 0) {
      await ctrlClk.nextPosedge;
    }
    await ctrlClk.nextPosedge;
    wbCyc.inject(0);
    wbWe.inject(0);
  }

  /// Non-pipelined Wishbone read: blocks for acceptance, then for ack.
  Future<LogicValue> wbRead(int addr) async {
    wbAddr.inject(addr);
    wbWe.inject(0);
    wbCyc.inject(1);
    wbStb.inject(1);
    while (ctrl.output('o_wb_stall').value.toInt() == 1) {
      await ctrlClk.nextPosedge;
    }
    await ctrlClk.nextPosedge;
    wbStb.inject(0);
    while (ctrl.output('o_wb_ack').value.toInt() == 0) {
      await ctrlClk.nextPosedge;
    }
    final data = ctrl.output('o_wb_data').value;
    await ctrlClk.nextPosedge;
    wbCyc.inject(0);
    return data;
  }
}

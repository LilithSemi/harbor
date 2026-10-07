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

  test(
    'with a self-training PHY the controller skips the DQS states, runs '
    'the PHY read leveling to the window centre, then passes its BIST',
    () async {
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
      // Fake ECP5 read path: a lane returns good data only inside its window.
      Logic window(int l) {
        final s = lev.slip.getRange(4 * l, 4 * l + 4);
        final d = lev.readClkSel.getRange(3 * l, 3 * l + 3);
        return l == 0
            ? s.eq(7) & d.gte(1) & d.lte(5)
            : (s.eq(8) & d.gte(2)) | (s.eq(7) & d.eq(0));
      }

      final good = model.iserdesData;
      phyData <=
          [
            for (var b = 7; b >= 0; b--)
              for (var l = p.lanes - 1; l >= 0; l--)
                mux(
                  window(l),
                  good.getRange(dq * b + 8 * l, dq * b + 8 * l + 8),
                  ~good.getRange(dq * b + 8 * l, dq * b + 8 * l + 8),
                ),
          ].swizzle();
      phyRdy <= model.idelayctrlRdy;
      levelDone <= lev.done;

      await ctrl.build();
      await model.build();
      await lev.build();
      rstN.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      rstN.inject(1);

      final seen = <int>{};
      var checks = 0;
      // A read or write command opens a trafficLeft that lasts until its data is
      // back (read capture at +12 ticks). PAUSE must stay low in it.
      final cmdLen = 4 + 3 + p.baBits + p.rowBits;
      var trafficLeft = 0;
      var commands = 0;
      var pauseInWindow = 0;
      for (var i = 0; i < 200000 && _state(ctrl) != 23; i++) {
        await clk.nextPosedge;
        seen.add(_state(ctrl));
        if (ctrl.output('o_phy_read_level_check').value.toInt() == 1) checks++;
        final cmd = ctrl.phyCmd.value;
        for (var slot = 0; slot < 4; slot++) {
          final w = cmd.getRange(cmdLen * slot, cmdLen * (slot + 1));
          final c3 = w.getRange(cmdLen - 4, cmdLen - 1);
          if (w[cmdLen - 1].toInt() == 0 &&
              (c3.toInt() == 0x4 || c3.toInt() == 0x5)) {
            trafficLeft = 6 + Ddr3PhyEcp5.readPipeTicks + 1;
            commands++;
          }
        }
        if (trafficLeft > 0) {
          if (lev.pause.value.toInt() == 1) pauseInWindow++;
          trafficLeft--;
        }
      }
      final slip = lev.slip.value.toInt();
      final sel = lev.readClkSel.value.toInt();
      await Simulator.endSimulation();

      expect(_state(ctrl), 23, reason: 'never reached DONE_CALIBRATE');
      for (final s in [1, 2, 3, 4, 5, 6]) {
        expect(seen, isNot(contains(s)), reason: 'ran sampled-DQS state $s');
      }
      expect(seen, containsAll([9, 10, 11, 12, 13]));
      expect(checks, 8 * Ddr3Ecp5ReadLeveler.bitslips);
      expect(commands, greaterThan(checks));
      expect(pauseInWindow, 0, reason: 'PAUSE high during DRAM traffic');
      // Lane 0: slip 7, delays 1..5 -> 3. Lane 1: slip 8, delays 2..7 -> 4.
      expect(slip & 0xF, 7);
      expect(slip >> 4, 8);
      expect(sel & 0x7, 3);
      expect(sel >> 3, 4);
    },
  );

  test(
    'the read capture waits phyReadPipeTicks more controller ticks',
    () async {
      final p = _params();
      final dq = p.dqBits * p.lanes;
      final cmdLen = 4 + 3 + p.baBits + p.rowBits;
      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: 'rstn');
      final phyData = Logic(name: 'phy_data', width: dq * 8);
      final ctrl = _controller(
        p,
        clk: clk,
        rstN: rstN,
        phyData: phyData,
        phyRdy: Const(1),
        levelDone: Const(1),
      );
      // Every byte of the read data is the tick count.
      final tick = Logic(name: 'tick', width: 8);
      Sequential(clk, reset: ~rstN, [tick < tick + 1]);
      phyData <= [for (var i = 0; i < dq; i++) tick].swizzle();
      await ctrl.build();
      rstN.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      rstN.inject(1);

      int? readTick;
      for (var i = 0; i < 50000 && readTick == null; i++) {
        await clk.nextPosedge;
        final cmd = ctrl.phyCmd.value;
        final w = cmd.getRange(cmdLen * 2, cmdLen * 3);
        if (w[cmdLen - 1].toInt() == 0 &&
            w.getRange(cmdLen - 4, cmdLen - 1).toInt() == 0x5 &&
            _state(ctrl) >= 9) {
          readTick = tick.value.toInt();
        }
      }
      for (var i = 0; i < 100 && _state(ctrl) != 23; i++) {
        await clk.nextPosedge;
      }
      final captured = ctrl.debug2.value.toInt() & 0xFF;
      await Simulator.endSimulation();
      expect(readTick, isNotNull);
      // The controller's own capture is 6 ticks after the read command. The
      // ECP5 PHY adds readPipeTicks.
      expect(captured, (readTick! + 6 + Ddr3PhyEcp5.readPipeTicks) & 0xFF);
    },
  );

  test('train=runtime with a self-training PHY: no PHY sweep, no BIST check, '
      'and the READCLKSEL and bitslip knobs reach the PHY', () async {
    final p = _params();
    final dq = p.dqBits * p.lanes;
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rstn');
    final wb2 = _Wb2();
    final ctrl = _controller(
      p,
      clk: clk,
      rstN: rstN,
      phyData: Const(0, width: dq * 8),
      phyRdy: Const(1),
      levelDone: Const(1),
      runtimeTrainable: true,
      wb2: wb2,
    );
    await ctrl.build();
    rstN.inject(0);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    rstN.inject(1);

    Future<void> write(int addr, int data) async {
      wb2.cyc.inject(1);
      wb2.stb.inject(1);
      wb2.we.inject(1);
      wb2.addr.inject(addr);
      wb2.data.inject(data);
      await clk.nextPosedge;
      wb2.cyc.inject(0);
      wb2.stb.inject(0);
      wb2.we.inject(0);
    }

    final seen = <int>{};
    var checks = 0;
    for (var i = 0; i < 50000 && _state(ctrl) != 23; i++) {
      await clk.nextPosedge;
      seen.add(_state(ctrl));
      if (ctrl.output('o_phy_read_level_check').value.toInt() == 1) checks++;
    }
    expect(_state(ctrl), 23);
    expect(seen, isNot(contains(13)), reason: 'firmware owns read training');
    expect(checks, 0);

    // READCLKSEL (index 7) = 5 on lane 1.
    await write(7, 5);
    await write(4, 0x101); // CTL SET, lane 1
    await write(4, 0x102); // CTL APPLY, lane 1
    await clk.nextPosedge;
    expect(ctrl.output('o_phy_read_clk_sel').value.toInt(), 5 << 3);

    // Each BITSLIP APPLY steps the PHY bitslip by one: a one-cycle pulse.
    var pulses = 0;
    final sub = clk.posedge.listen((_) {
      if (ctrl.output('o_phy_bitslip').value.toInt() == 1) pulses++;
    });
    for (var n = 0; n < 3; n++) {
      await write(3, 1);
      await write(4, 0x001);
      await write(4, 0x002);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
    }
    await sub.cancel();
    expect(pulses, 3);

    // CAP: slipMax reports the 16 fabric bitslip positions.
    wb2.cyc.inject(1);
    wb2.stb.inject(1);
    wb2.addr.inject(6);
    await clk.nextPosedge;
    wb2.cyc.inject(0);
    wb2.stb.inject(0);
    await clk.nextPosedge;
    expect((ctrl.output('o_wb2_data').value.toInt() >> 16) & 0xF, 15);
    await Simulator.endSimulation();
  });
}

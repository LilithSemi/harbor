import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'ddr3_scheduled_clock.dart';

/// Golden-model differential verification of [Ddr3ControllerGearbox].
///
/// The gearbox is a synchronous 2:1 mux/demux between the CK/8 controller-logic
/// clock and the CK/4 SERDES/PHY clock. This test drives the controller side
/// with per-tick fingerprinted commands + BL8 write payloads, models the PHY as
/// a sink, and checks every PHY-facing beat against a plain-Dart golden model of
/// the phase schedule (command verbatim on the active tick, DESELECT bubble on
/// the other, sideband straight through, DQ high-Z on the bubble). A read
/// loopback feeds known captures on the PHY side and checks the controller side
/// reconstructs the selected-phase capture. gearRatio == 1 is asserted to be a
/// byte-identical pass-through.
void main() {
  tearDown(() async => Simulator.reset());

  // --- geometry helpers (match Ddr3Controller) ---
  const ckPs = 3000;
  DdrParams geared() =>
      const DdrParams(controllerClkPeriodPs: ckPs * 8, ddr3ClkPeriodPs: ckPs);
  DdrParams transparent() =>
      const DdrParams(controllerClkPeriodPs: ckPs * 4, ddr3ClkPeriodPs: ckPs);

  int cmdLenOf(DdrParams p) => 4 + 3 + p.baBits + p.rowBits;

  BigInt mask(int width) => (BigInt.one << width) - BigInt.one;

  /// cs_n is the MSB of each cmdLen-wide SERDES slot; the DESELECT bubble ORs
  /// these bits high across all [serdes] slots.
  BigInt csDeselectMask(int cmdLen, int serdes) {
    var m = BigInt.zero;
    for (var j = 0; j < serdes; j++) {
      m |= BigInt.one << (j * cmdLen + cmdLen - 1);
    }
    return m;
  }

  /// Reproducible per-tick fingerprint of [width] bits.
  BigInt fingerprint(int seed, int salt, int width) {
    var v = BigInt.zero;
    var x = BigInt.from(((seed + 1) * 2654435761 + (salt + 1) * 40503 + 12345));
    x &= mask(64);
    var bits = 0;
    while (bits < width) {
      x = (x * BigInt.from(6364136223846793005) + BigInt.one) & mask(64);
      v = (v << 64) | x;
      bits += 64;
    }
    return v & mask(width);
  }

  void injBig(Logic s, BigInt v) => s.inject(LogicValue.ofBigInt(v, s.width));
  BigInt rdBig(Logic s) => s.value.toBigInt();

  test('gearRatio == 2 geometry engages the gearbox', () {
    final p = geared();
    expect(p.gearRatio, 2);
    expect(p.serdesRatio, 4);
    expect(p.controllerClkRatio, 8);
    expect(p.wbDataBits, 128); // unchanged by the slower controller clock
  });

  test(
    'write path: command on active tick, DESELECT bubble on the other',
    () async {
      await Simulator.reset();
      final p = geared();
      final cmdLen = cmdLenOf(p);
      final serdes = p.serdesRatio;
      final cmdW = cmdLen * serdes;
      final csMask = csDeselectMask(cmdLen, serdes);

      final serdesClk = SimpleClockGenerator(4).clk;
      final rstN = Logic(name: 'rst_n')..inject(0);
      // Divide-by-2 controller clock and a mirror of the gearbox phase flop.
      // The controller clock runs free. It lines up with the phase flop
      // because rst_n releases at t=4 and the first rise is at t=6.
      final controllerClk = scheduledClock(firstRise: 6, halfPeriod: 4);
      final tbPhase = Logic(name: 'tb_phase');
      Sequential(serdesClk, reset: ~rstN, [tbPhase < ~tbPhase]);

      // Controller-side stimulus signals.
      final cCmd = Logic(width: cmdW);
      final cDqsTri = Logic();
      final cDqTri = Logic();
      final cToggle = Logic();
      final cData = Logic(width: p.wbDataBits);
      final cDm = Logic(width: p.wbSelBits);
      final cReset = Logic();
      final cOdDataCnt = Logic(width: 5);
      final cOdDqsCnt = Logic(width: 5);
      final cIdDataCnt = Logic(width: 5);
      final cIdDqsCnt = Logic(width: 5);
      final cOdDataLd = Logic(width: p.lanes);
      final cOdDqsLd = Logic(width: p.lanes);
      final cIdDataLd = Logic(width: p.lanes);
      final cIdDqsLd = Logic(width: p.lanes);
      final cBitslip = Logic(width: p.lanes);
      final cWlCalib = Logic();
      final pIData = Logic(width: p.dqBits * p.lanes * 8);
      final pIDqs = Logic(width: p.lanes * 8);
      final pIBs = Logic(width: p.lanes * 8);
      for (final s in [
        cDqsTri, cDqTri, cToggle, cReset, cWlCalib, //
      ]) {
        s.inject(0);
      }
      for (final s in [
        cCmd, cData, cDm, cOdDataCnt, cOdDqsCnt, cIdDataCnt, cIdDqsCnt, //
        cOdDataLd, cOdDqsLd, cIdDataLd, cIdDqsLd, cBitslip, //
        pIData, pIDqs, pIBs,
      ]) {
        s.inject(0);
      }

      const writeDataPhase = 0;
      final dut = Ddr3ControllerGearbox(
        p,
        controllerClk: controllerClk,
        serdesClk: serdesClk,
        rstN: rstN,
        cPhyCmd: cCmd,
        cPhyDqsTriControl: cDqsTri,
        cPhyDqTriControl: cDqTri,
        cPhyToggleDqs: cToggle,
        cPhyData: cData,
        cPhyDm: cDm,
        cPhyReset: cReset,
        cPhyOdelayDataCntvaluein: cOdDataCnt,
        cPhyOdelayDqsCntvaluein: cOdDqsCnt,
        cPhyIdelayDataCntvaluein: cIdDataCnt,
        cPhyIdelayDqsCntvaluein: cIdDqsCnt,
        cPhyOdelayDataLd: cOdDataLd,
        cPhyOdelayDqsLd: cOdDqsLd,
        cPhyIdelayDataLd: cIdDataLd,
        cPhyIdelayDqsLd: cIdDqsLd,
        cPhyBitslip: cBitslip,
        cPhyWriteLevelingCalib: cWlCalib,
        pIserdesData: pIData,
        pIserdesDqs: pIDqs,
        pIserdesBitslipReference: pIBs,
        writeDataPhase: writeDataPhase,
        readCapturePhase: 1,
      );
      await dut.build();
      Simulator.setMaxSimTime(20000);
      unawaited(Simulator.run());

      // Release reset on a clean edge.
      await serdesClk.nextNegedge;
      rstN.inject(1);

      const nTicks = 40;
      for (var i = 0; i < nTicks; i++) {
        await serdesClk.nextPosedge; // phase + controller clock settle
        // Drive a fresh fingerprinted controller word this tick. cs_n bits are
        // cleared so the DESELECT bubble forcing them high is observable.
        final cmdI = fingerprint(i, 1, cmdW) & (mask(cmdW) ^ csMask);
        final dataI = fingerprint(i, 2, p.wbDataBits);
        final dmI = fingerprint(i, 3, p.wbSelBits);
        final dqTriI = i & 1;
        final dqsTriI = (i >> 1) & 1;
        final toggleI = (i + 1) & 1;
        final odDataCntI = fingerprint(i, 4, 5);
        final bitslipI = fingerprint(i, 5, p.lanes);
        final wlI = i % 3 == 0 ? 1 : 0;

        injBig(cCmd, cmdI);
        injBig(cData, dataI);
        injBig(cDm, dmI);
        cDqTri.inject(dqTriI);
        cDqsTri.inject(dqsTriI);
        cToggle.inject(toggleI);
        injBig(cOdDataCnt, odDataCntI);
        injBig(cBitslip, bitslipI);
        cWlCalib.inject(wlI);

        await serdesClk.nextNegedge; // mid-tick: phase + inputs stable
        final phase = tbPhase.value.toInt();
        final active = phase == writeDataPhase;

        // --- golden model of the PHY-facing beat ---
        expect(
          rdBig(dut.output('o_p_phy_cmd')),
          active ? cmdI : (cmdI | csMask),
          reason: 'cmd tick $i phase $phase',
        );
        expect(
          dut.output('o_p_phy_dq_tri_control').value.toInt(),
          active ? dqTriI : 1,
          reason: 'dq_tri tick $i phase $phase',
        );
        expect(
          dut.output('o_p_phy_dqs_tri_control').value.toInt(),
          active ? dqsTriI : 1,
          reason: 'dqs_tri tick $i phase $phase',
        );
        expect(
          dut.output('o_p_phy_toggle_dqs').value.toInt(),
          active ? toggleI : 0,
          reason: 'toggle tick $i phase $phase',
        );
        // Data + mask ride through both ticks (DQ is tri-stated on the bubble).
        expect(
          rdBig(dut.output('o_p_phy_data')),
          dataI,
          reason: 'data tick $i phase $phase',
        );
        expect(
          rdBig(dut.output('o_p_phy_dm')),
          dmI,
          reason: 'dm tick $i phase $phase',
        );
        // Sideband is quasi-static: straight through on every tick.
        expect(
          rdBig(dut.output('o_p_phy_odelay_data_cntvaluein')),
          odDataCntI,
          reason: 'odelay tick $i',
        );
        expect(
          rdBig(dut.output('o_p_phy_bitslip')),
          bitslipI,
          reason: 'bitslip tick $i',
        );
        expect(
          dut.output('o_p_phy_write_leveling_calib').value.toInt(),
          wlI,
          reason: 'wlcalib tick $i',
        );
      }
      // Both phases must have been exercised.
      await Simulator.endSimulation();
    },
  );

  test('read path: controller reconstructs the selected-phase capture', () async {
    await Simulator.reset();
    final p = geared();
    final cmdLen = cmdLenOf(p);
    final serdes = p.serdesRatio;
    final cmdW = cmdLen * serdes;

    final serdesClk = SimpleClockGenerator(4).clk;
    final rstN = Logic(name: 'rst_n')..inject(0);
    final controllerClk = scheduledClock(firstRise: 6, halfPeriod: 4);
    final tbPhase = Logic(name: 'tb_phase');
    Sequential(serdesClk, reset: ~rstN, [tbPhase < ~tbPhase]);

    Logic z(int w) => Logic(width: w)..inject(0);
    final pIData = Logic(width: p.dqBits * p.lanes * 8);
    final pIDqs = Logic(width: p.lanes * 8);
    final pIBs = Logic(width: p.lanes * 8);
    pIData.inject(0);
    pIDqs.inject(0);
    pIBs.inject(0);

    const readCapturePhase = 1;
    final dut = Ddr3ControllerGearbox(
      p,
      controllerClk: controllerClk,
      serdesClk: serdesClk,
      rstN: rstN,
      cPhyCmd: z(cmdW),
      cPhyDqsTriControl: z(1),
      cPhyDqTriControl: z(1),
      cPhyToggleDqs: z(1),
      cPhyData: z(p.wbDataBits),
      cPhyDm: z(p.wbSelBits),
      cPhyReset: z(1),
      cPhyOdelayDataCntvaluein: z(5),
      cPhyOdelayDqsCntvaluein: z(5),
      cPhyIdelayDataCntvaluein: z(5),
      cPhyIdelayDqsCntvaluein: z(5),
      cPhyOdelayDataLd: z(p.lanes),
      cPhyOdelayDqsLd: z(p.lanes),
      cPhyIdelayDataLd: z(p.lanes),
      cPhyIdelayDqsLd: z(p.lanes),
      cPhyBitslip: z(p.lanes),
      cPhyWriteLevelingCalib: z(1),
      pIserdesData: pIData,
      pIserdesDqs: pIDqs,
      pIserdesBitslipReference: pIBs,
      writeDataPhase: 0,
      readCapturePhase: readCapturePhase,
    );
    await dut.build();
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());

    await serdesClk.nextNegedge;
    rstN.inject(1);

    // Golden model: capData holds the pIserdesData present during the last tick
    // whose phase == readCapturePhase (latched at that tick's trailing posedge).
    BigInt? goldenHeld;
    const nTicks = 40;
    for (var i = 0; i < nTicks; i++) {
      await serdesClk.nextPosedge;
      final dataI = fingerprint(i, 7, p.dqBits * p.lanes * 8);
      final dqsI = fingerprint(i, 8, p.lanes * 8);
      final bsI = fingerprint(i, 9, p.lanes * 8);
      injBig(pIData, dataI);
      injBig(pIDqs, dqsI);
      injBig(pIBs, bsI);

      await serdesClk.nextNegedge;
      final phase = tbPhase.value.toInt();
      // A capture-phase tick latches at its trailing posedge, so the controller
      // sees THIS tick's value only from the next tick on. Check the value the
      // controller currently sees against the last completed capture.
      if (goldenHeld != null) {
        expect(
          rdBig(dut.output('o_c_iserdes_data')),
          goldenHeld,
          reason: 'read data tick $i phase $phase',
        );
      }
      if (phase == readCapturePhase) {
        goldenHeld = dataI; // becomes visible next tick
      }
    }
    await Simulator.endSimulation();
  });

  test(
    'gearRatio == 1 is a byte-identical combinational pass-through',
    () async {
      await Simulator.reset();
      final p = transparent();
      expect(p.gearRatio, 1);
      final cmdLen = cmdLenOf(p);
      final cmdW = cmdLen * p.serdesRatio;

      final clk = SimpleClockGenerator(4).clk; // single domain at gearRatio 1
      final rstN = Logic(name: 'rst_n')..inject(1);

      final cCmd = Logic(width: cmdW);
      final cData = Logic(width: p.wbDataBits);
      final cDm = Logic(width: p.wbSelBits);
      final cDqTri = Logic();
      final cDqsTri = Logic();
      final cToggle = Logic();
      final cOd = Logic(width: 5);
      final cBitslip = Logic(width: p.lanes);
      final pIData = Logic(width: p.dqBits * p.lanes * 8);
      final pIDqs = Logic(width: p.lanes * 8);
      final pIBs = Logic(width: p.lanes * 8);
      Logic z(int w) => Logic(width: w)..inject(0);

      final dut = Ddr3ControllerGearbox(
        p,
        controllerClk: clk,
        serdesClk: clk,
        rstN: rstN,
        cPhyCmd: cCmd,
        cPhyDqsTriControl: cDqsTri,
        cPhyDqTriControl: cDqTri,
        cPhyToggleDqs: cToggle,
        cPhyData: cData,
        cPhyDm: cDm,
        cPhyReset: z(1),
        cPhyOdelayDataCntvaluein: cOd,
        cPhyOdelayDqsCntvaluein: z(5),
        cPhyIdelayDataCntvaluein: z(5),
        cPhyIdelayDqsCntvaluein: z(5),
        cPhyOdelayDataLd: z(p.lanes),
        cPhyOdelayDqsLd: z(p.lanes),
        cPhyIdelayDataLd: z(p.lanes),
        cPhyIdelayDqsLd: z(p.lanes),
        cPhyBitslip: cBitslip,
        cPhyWriteLevelingCalib: z(1),
        pIserdesData: pIData,
        pIserdesDqs: pIDqs,
        pIserdesBitslipReference: pIBs,
      );
      await dut.build();
      Simulator.setMaxSimTime(5000);
      unawaited(Simulator.run());

      for (var i = 0; i < 8; i++) {
        final cmdI = fingerprint(i, 11, cmdW);
        final dataI = fingerprint(i, 12, p.wbDataBits);
        final dmI = fingerprint(i, 13, p.wbSelBits);
        final odI = fingerprint(i, 14, 5);
        final bsI = fingerprint(i, 15, p.lanes);
        final rdI = fingerprint(i, 16, p.dqBits * p.lanes * 8);
        injBig(cCmd, cmdI);
        injBig(cData, dataI);
        injBig(cDm, dmI);
        cDqTri.inject(i & 1);
        cDqsTri.inject((i >> 1) & 1);
        cToggle.inject((i + 1) & 1);
        injBig(cOd, odI);
        injBig(cBitslip, bsI);
        injBig(pIData, rdI);
        await serdesClk_settle(clk);

        // Every output equals its input, no phase, no register.
        expect(rdBig(dut.output('o_p_phy_cmd')), cmdI);
        expect(rdBig(dut.output('o_p_phy_data')), dataI);
        expect(rdBig(dut.output('o_p_phy_dm')), dmI);
        expect(dut.output('o_p_phy_dq_tri_control').value.toInt(), i & 1);
        expect(
          dut.output('o_p_phy_dqs_tri_control').value.toInt(),
          (i >> 1) & 1,
        );
        expect(dut.output('o_p_phy_toggle_dqs').value.toInt(), (i + 1) & 1);
        expect(rdBig(dut.output('o_p_phy_odelay_data_cntvaluein')), odI);
        expect(rdBig(dut.output('o_p_phy_bitslip')), bsI);
        expect(rdBig(dut.output('o_c_iserdes_data')), rdI);
      }
      await Simulator.endSimulation();
    },
  );
}

/// Settle combinational logic by advancing to the next clock edge.
Future<void> serdesClk_settle(Logic clk) async => clk.nextNegedge;

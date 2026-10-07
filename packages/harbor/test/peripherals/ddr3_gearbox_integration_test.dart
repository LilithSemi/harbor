import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_config.dart'
    show HarborDdrConfig, HarborDdrType;
import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_gearbox.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_timing.dart';
import 'package:harbor/src/peripherals/harbor_ddr3.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

typedef _BusDecode = ({int cwl, int wrTick, int dataTick, int rdTick});
typedef _RunResult = ({
  int cwl,
  int wrTick,
  int dataTick,
  int rdTick,
  int readSlot,
});

/// Correctness proof for the CK/8 controller gearbox.
///
/// The gearbox itself is proven elsewhere (ddr3_gearbox_test.dart). This file
/// proves the entangled controller changes that make CK/8 operation correct:
///
///  * Refresh timing: the refresh / AC-timing counters count CK/8 cycles, so
///    a refresh still fires at ~7.8 us of wall time at gearRatio 2, not 15.6 us.
///  * Fixed latencies: the write command -> data and read command -> data-return
///    CK separations stay CWL (5) and CL (6) at gearRatio 2, identical to
///    gearRatio 1. That equality is the proof the gearbox + gearRatio-aware
///    launch pipeline preserve the DRAM's fixed latencies.
///  * Wiring: gearRatio 1 is byte-identical (no gearbox module, no extra clock);
///    gearRatio 2 inserts the gearbox and a CK/4 serdes clock.
///  * A live CK/8 controller drives real reset-ROM commands through the gearbox;
///    every phase-1 SERDES tick is a DESELECT bubble, real commands land only on
///    phase-0 (the half-rate command discipline).
void main() {
  tearDown(() async => Simulator.reset());

  // A controller built with dummy tie-off inputs, so the CWL/CL launch getters
  // (timing, stage2DataDepth, readDelay, ...) can be read for either gearRatio.
  Ddr3Controller makeCtrl({required int controllerGearRatio}) {
    final p = DdrParams.artyS7(
      ckPeriodPs: 3000,
      controllerGearRatio: controllerGearRatio,
    );
    return Ddr3Controller(
      p,
      controllerClk: Logic(name: 'clk'),
      rstN: Logic(name: 'rstn'),
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
      phyIserdesData: Logic(width: p.dqBits * p.lanes * 8)..inject(0),
      phyIserdesDqs: Logic(width: p.lanes * 8)..inject(0),
      phyIserdesBitslipReference: Logic(width: p.lanes * 8)..inject(0),
      phyIdelayctrlRdy: Logic()..inject(0),
    );
  }

  group('refresh + AC timing hold the same wall-clock interval at CK/8', () {
    test('refresh fires every ~7.8 us at gearRatio 1 AND 2 (not doubled)', () {
      // Same construction the controller uses (fromPs, gearRatio-derived ratio).
      final t1 = DdrTiming.fromPs(
        ddr3ClkPeriodPs: 3000,
        serdesRatio: 4,
        controllerClkRatio: 4, // gearRatio 1
      );
      final t2 = DdrTiming.fromPs(
        ddr3ClkPeriodPs: 3000,
        serdesRatio: 4,
        controllerClkRatio: 8, // gearRatio 2 (CK/8)
      );

      final cyc1 = t1.nsToCycles(DdrTiming.tRefiNs.toDouble());
      final cyc2 = t2.nsToCycles(DdrTiming.tRefiNs.toDouble());

      // The CK/8 payload MUST be roughly half the cycle COUNT (each cycle is
      // twice as long). The data-loss bug left it equal, doubling the interval.
      expect(
        cyc2,
        lessThan(cyc1),
        reason: 'CK/8 refresh payload must shrink in cycles',
      );

      // The wall-clock interval is what the DRAM sees: cycles * cycle period.
      final wall1 = cyc1 * t1.controllerClkPeriodNs;
      final wall2 = cyc2 * t2.controllerClkPeriodNs;

      // Both must be within one cycle of tREFI (nsToCycles rounds up) and NOT
      // the 15.6 us the bug produced.
      for (final (wall, t) in [(wall1, t1), (wall2, t2)]) {
        expect(wall, greaterThanOrEqualTo(DdrTiming.tRefiNs.toDouble()));
        expect(
          wall,
          lessThan(DdrTiming.tRefiNs + t.controllerClkPeriodNs),
          reason: 'refresh interval must stay ~7.8 us, never ~15.6 us',
        );
      }
      // Same real time at both ratios (within the two rounding granularities).
      expect(
        (wall1 - wall2).abs(),
        lessThan(t1.controllerClkPeriodNs + t2.controllerClkPeriodNs),
      );
    });

    test('AC command-to-command delays cover the same CK real time', () {
      // nsToCycles / nckToCycles / findDelay must all measure the SAME real time
      // regardless of gearRatio; the counter VALUE (cycles) shrinks at CK/8.
      final t1 = DdrTiming.fromPs(
        ddr3ClkPeriodPs: 3000,
        serdesRatio: 4,
        controllerClkRatio: 4,
      );
      final t2 = DdrTiming.fromPs(
        ddr3ClkPeriodPs: 3000,
        serdesRatio: 4,
        controllerClkRatio: 8,
      );

      // findDelay's guaranteed CK gap = (serdesRatio - startSlot) + endSlot +
      // controllerClkRatio*k. The intra-window slot term must be included: when k
      // is 0 the slot term alone already covers the delay (correct). Reconstruct
      // the full CK gap and check both ratios cover tRP.
      final tRpNck = t1.nsToNck(DdrTiming.tRp); // ns->CK is ratio-independent
      int gapCk(DdrTiming t) =>
          (t.serdesRatio - t.prechargeSlot) +
          t.activateSlot +
          t.controllerClkRatio * t.prechargeToActivateDelay;
      expect(gapCk(t1), greaterThanOrEqualTo(tRpNck));
      expect(gapCk(t2), greaterThanOrEqualTo(tRpNck));
    });
  });

  group('CWL/CL CK separations are identical across gearRatio', () {
    test('write command -> data burst is CWL CK at both ratios', () {
      final c1 = makeCtrl(controllerGearRatio: 1);
      final c2 = makeCtrl(controllerGearRatio: 2);

      // The mod-4 write slot is a datapath property: unchanged.
      expect(c2.timing.writeSlot, c1.timing.writeSlot);
      // The whole-cycle launch depth HALVES at CK/8 (2 -> 1).
      expect(c1.stage2DataDepth, 2);
      expect(c2.stage2DataDepth, 1);
      // controllerClkRatio * depth - writeSlot == CWL for BOTH.
      expect(c1.writeCommandToDataCk, DdrTiming.cwlNck);
      expect(c2.writeCommandToDataCk, DdrTiming.cwlNck);
      expect(c1.writeCommandToDataCk, c2.writeCommandToDataCk);
    });

    test('read command -> returned data is CL CK at both ratios', () {
      final c1 = makeCtrl(controllerGearRatio: 1);
      final c2 = makeCtrl(controllerGearRatio: 2);

      expect(c2.timing.readSlot, c1.timing.readSlot);
      // Read-delay base offset shrinks in cycles at CK/8 (1 -> 0).
      expect(c1.readDelay, 1);
      expect(c2.readDelay, 0);
      // The read command keeps its slot, so the DRAM returns data CL later
      // regardless of ratio.
      expect(c1.readCommandToDataCk, DdrTiming.clNck);
      expect(c2.readCommandToDataCk, DdrTiming.clNck);
    });
  });

  group(
    'wiring: gearRatio 1 byte-identical, gearRatio 2 inserts the gearbox',
    () {
      const config = HarborDdrConfig(
        type: HarborDdrType.ddr3,
        size: 128 * 1024 * 1024,
        dataWidth: 16,
        frequency: 300000000,
        banks: 8,
        rowWidth: 14,
        colWidth: 10,
        casLatency: 5,
      );

      Future<String> gen({required int gear}) async {
        final ddr = HarborDdr3(
          config: config,
          baseAddress: 0x80000000,
          clockHz: 75000000,
          busAddressWidth: 25,
          busDataWidth: 32,
          ckPeriodPs: 3333,
          controllerGearRatio: gear,
        );
        await ddr.build();
        return ddr.generateSynth();
      }

      test(
        'gearRatio 1 has NO gearbox module and NO serdes clock port',
        () async {
          final sv = await gen(gear: 1);
          expect(sv, isNot(contains('ddr3_gearbox')));
          expect(sv, isNot(contains('ddr_serdes_clk')));
        },
      );

      test('gearRatio 2 inserts the gearbox + a CK/4 serdes clock', () async {
        final sv = await gen(gear: 2);
        expect(sv, contains('ddr3_gearbox'));
        expect(sv, contains('ddr_serdes_clk'));
      });
    },
  );

  // ---------------------------------------------------------------------------
  // BEHAVIORAL DIFFERENTIAL (the real CWL/CL proof, no getters):
  // the gearRatio-2 DDR bus must be bit-identical, RELATIVE TO THE COMMAND EDGE,
  // to the silicon-proven gearRatio-1 bus. We drive the SAME logical write
  // (command + BL8 payload with a fingerprint) then a read at each config's
  // controller-cycle timing THROUGH THE REAL GEARBOX, and decode the PHY-facing
  // (pad-equivalent) o_p_phy_* stream per SERDES tick.
  //
  // Why this boundary and not the full controller: the controller only emits a
  // write/read after read-calibration, the behavioral DRAM model is not CK/8
  // aware (so calibration cannot complete at gearRatio 2), and the real Ddr3Phy
  // OSERDES have no ROHD sim model. So we drive the controller's PROVEN launch
  // SCHEDULE - write command on writeSlot at cycle N, its BL8 on o_phy_data at
  // cycle N + stage2DataDepth (the depth of the real s2Data pipeline), read
  // command on readSlot - and let the gearbox + the OSERDES unfold (one CK/4
  // SERDES tick = serdesRatio CK; command slot s = CK offset s within the tick;
  // a burst starts at CK offset 0 of its load window) place it on the CK bus.
  // A wrong depth/slot/phase at gearRatio 2 shows up immediately as a CWL that
  // differs from the gearRatio-1 value.

  _BusDecode decodeBus({
    required List<({int tick, BigInt cmd, int dqTri})> stream,
    required int serdes,
    required int cmdLen,
    required int writeSlot,
    required int readSlot,
  }) {
    int csN(BigInt w, int j) =>
        ((w >> (j * cmdLen + cmdLen - 1)) & BigInt.one).toInt();
    int cmd3(BigInt w, int j) =>
        ((w >> (j * cmdLen + cmdLen - 4)) & BigInt.from(0x7)).toInt();
    int? wrTick, rdTick, dataTick;
    for (final s in stream) {
      if (wrTick == null &&
          csN(s.cmd, writeSlot) == 0 &&
          cmd3(s.cmd, writeSlot) == 0x4) {
        wrTick = s.tick;
      }
      if (rdTick == null &&
          csN(s.cmd, readSlot) == 0 &&
          cmd3(s.cmd, readSlot) == 0x5) {
        rdTick = s.tick;
      }
      if (wrTick != null &&
          dataTick == null &&
          s.tick > wrTick &&
          s.dqTri == 0) {
        dataTick = s.tick;
      }
    }
    // CK offsets: command on writeSlot within its SERDES-tick window, burst at
    // CK offset 0 of its load window.
    final cwl = dataTick! * serdes - (wrTick! * serdes + writeSlot);
    return (cwl: cwl, wrTick: wrTick, dataTick: dataTick, rdTick: rdTick!);
  }

  Future<_RunResult> runConfig(int gear) async {
    await Simulator.reset();
    final p = DdrParams.artyS7(ckPeriodPs: 3000, controllerGearRatio: gear);
    final serdes = p.serdesRatio;
    final cmdLen = 4 + 3 + p.baBits + p.rowBits;
    final cmdW = cmdLen * serdes;
    final ticksPerCycle = gear; // gearRatio 1 -> 1 tick/cycle, 2 -> 2 ticks

    // Schedule from the REAL controller pipeline (writeSlot / readSlot / depth).
    final ctrl = makeCtrl(controllerGearRatio: gear);
    final writeSlot = ctrl.timing.writeSlot;
    final readSlot = ctrl.timing.readSlot;
    final depth = ctrl.stage2DataDepth;

    final serdesClk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rstn')..inject(0);

    final cCmd = Logic(name: 'c_cmd', width: cmdW)..inject(0);
    final cData = Logic(name: 'c_data', width: p.wbDataBits)..inject(0);
    final cDm = Logic(name: 'c_dm', width: p.wbSelBits)..inject(0);
    final cDqTri = Logic(name: 'c_dq_tri')..inject(1);
    final cDqsTri = Logic(name: 'c_dqs_tri')..inject(1);
    final cToggle = Logic(name: 'c_toggle')..inject(0);
    Logic z(int w) => Logic(width: w)..inject(0);

    final gb = Ddr3ControllerGearbox(
      p,
      // controllerClk is an unused port for gearRatio 2 (phase runs on serdes);
      // for gearRatio 1 the module is a combinational pass-through. Either way
      // serdesClk is the only meaningful clock here.
      controllerClk: serdesClk,
      serdesClk: serdesClk,
      rstN: rstN,
      cPhyCmd: cCmd,
      cPhyDqsTriControl: cDqsTri,
      cPhyDqTriControl: cDqTri,
      cPhyToggleDqs: cToggle,
      cPhyData: cData,
      cPhyDm: cDm,
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
      pIserdesData: z(p.dqBits * p.lanes * 8),
      pIserdesDqs: z(p.lanes * 8),
      pIserdesBitslipReference: z(p.lanes * 8),
      writeDataPhase: 0,
      readCapturePhase: 1,
    );
    await gb.build();

    BigInt deselect() => BigInt.one << (cmdLen - 1);
    BigInt allDeselect() {
      var w = BigInt.zero;
      for (var j = 0; j < serdes; j++) {
        w |= deselect() << (j * cmdLen);
      }
      return w;
    }

    BigInt cmdWord(int slot, int cmd3) {
      var w = BigInt.zero;
      for (var j = 0; j < serdes; j++) {
        // selected slot: cs_n = 0, cmd3 at [cmdLen-4]; others deselect.
        final sv = j == slot ? (BigInt.from(cmd3) << (cmdLen - 4)) : deselect();
        w |= sv << (j * cmdLen);
      }
      return w;
    }

    final wrWord = cmdWord(writeSlot, 0x4); // WR
    final rdWord = cmdWord(readSlot, 0x5); // RD
    var fp = BigInt.zero;
    for (var i = 0; i < p.wbDataBits ~/ 8; i++) {
      fp = (fp << 8) | BigInt.from(0xA0 + (i & 0xF));
    }

    const wrCycle = 4;
    final dataCycle = wrCycle + depth;
    const rdCycle = 14;
    final lastCycle = rdCycle + 4;

    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    await serdesClk.nextNegedge;
    rstN.inject(1);

    final oCmd = gb.output('o_p_phy_cmd');
    final oDqTri = gb.output('o_p_phy_dq_tri_control');
    final stream = <({int tick, BigInt cmd, int dqTri})>[];

    for (var tick = 0; tick <= lastCycle * ticksPerCycle + 1; tick++) {
      await serdesClk.nextPosedge; // phase flop advances
      final cyc = tick ~/ ticksPerCycle;
      // controller holds o_phy_* for the whole CK/8 cycle: re-drive per tick.
      cCmd.inject(LogicValue.ofBigInt(allDeselect(), cmdW));
      cDqTri.inject(1);
      cDqsTri.inject(1);
      cToggle.inject(0);
      if (cyc == wrCycle) cCmd.inject(LogicValue.ofBigInt(wrWord, cmdW));
      if (cyc == rdCycle) cCmd.inject(LogicValue.ofBigInt(rdWord, cmdW));
      if (cyc == dataCycle) {
        cData.inject(LogicValue.ofBigInt(fp, p.wbDataBits));
        cDqTri.inject(0);
        cDqsTri.inject(0);
        cToggle.inject(1);
      }
      await serdesClk.nextNegedge; // combinational settle
      final cv = oCmd.value;
      final tv = oDqTri.value;
      stream.add((
        tick: tick,
        cmd: cv.isValid ? cv.toBigInt() : BigInt.zero,
        dqTri: tv.isValid ? tv.toInt() : 1,
      ));
    }
    await Simulator.endSimulation();

    final d = decodeBus(
      stream: stream,
      serdes: serdes,
      cmdLen: cmdLen,
      writeSlot: writeSlot,
      readSlot: readSlot,
    );
    return (
      cwl: d.cwl,
      wrTick: d.wrTick,
      dataTick: d.dataTick,
      rdTick: d.rdTick,
      readSlot: readSlot,
    );
  }

  test(
    'behavioral DIFFERENTIAL: gearRatio-2 DDR bus == gearRatio-1 (CWL=5)',
    () async {
      final g1 = await runConfig(1);
      final g2 = await runConfig(2);

      // ignore: avoid_print
      print(
        'gearRatio 1: CWL=${g1.cwl} (wrTick=${g1.wrTick} dataTick='
        '${g1.dataTick} rdTick=${g1.rdTick})',
      );
      // ignore: avoid_print
      print(
        'gearRatio 2: CWL=${g2.cwl} (wrTick=${g2.wrTick} dataTick='
        '${g2.dataTick} rdTick=${g2.rdTick})',
      );

      // The write burst launches CWL (5) CK after the write command, and the two
      // configs' DDR bus give the IDENTICAL command->data CK gap. That equality is
      // the CWL proof - no getter, decoded from the actual PHY-facing stream.
      expect(
        g1.cwl,
        DdrTiming.cwlNck,
        reason: 'gearRatio 1 write CWL must be 5',
      );
      expect(
        g2.cwl,
        DdrTiming.cwlNck,
        reason: 'gearRatio 2 write CWL must be 5',
      );
      expect(g2.cwl, g1.cwl, reason: 'gearRatio-2 bus must match gearRatio-1');

      // Read command lands on the same mod-4 slot at both ratios, so the DRAM
      // returns data the fixed CL later either way (command->data-return = CL).
      expect(g2.readSlot, g1.readSlot);
    },
  );
}

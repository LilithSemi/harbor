import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_dram_model.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'read calibration runs end to end vs the DRAM model to the write phase',
    () async {
      // Tiny CK period so the power-up reset walk reaches instruction 13 fast.
      final p = DdrParams(
        controllerClkPeriodPs: 800000,
        ddr3ClkPeriodPs: 200000,
      );
      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: 'rstn');

      // Placeholder PHY-return nets driven by the model after construction.
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
      );

      phyData <= model.iserdesData;
      phyDqs <= model.iserdesDqs;
      phyBitslipRef <= model.iserdesBitslipReference;
      phyRdy <= model.idelayctrlRdy;

      await ctrl.build();
      await model.build();

      rstN.inject(0);
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      rstN.inject(1);

      final statesSeen = <int>{};
      var sawMprEnabled = false;
      var reachedWrite = false;
      for (var i = 0; i < 30000 && !reachedWrite; i++) {
        await clk.nextPosedge;
        // Only the state field: other debug1 bits (cap_valid) stay X until
        // the first ANALYZE_DATA.
        final st = ctrl.debug1.value.getRange(0, 6);
        if (st.isValid) {
          final s = st.toInt();
          statesSeen.add(s);
          if (s == 9) reachedWrite = true; // ISSUE_WRITE_1 (write phase)
        }
        if (model.mprEnabled.value.isValid &&
            model.mprEnabled.value.toInt() == 1) {
          sawMprEnabled = true;
        }
      }

      // The full read-calibration path runs against the model: bitslip training,
      // MPR read, DQS collect/analyze, the per-bit IDELAY eye-centre walk, the
      // bitslip retrain, then (write leveling skipped on the HR bank) the write
      // phase.
      for (final st in [
        1, // BITSLIP_DQS_TRAIN_1
        2, // MPR_READ
        3, // COLLECT_DQS
        4, // ANALYZE_DQS
        5, // CALIBRATE_DQS
        6, // BITSLIP_DQS_TRAIN_2
        7, // START_WRITE_LEVEL
      ]) {
        expect(statesSeen, contains(st), reason: 'never reached cal state $st');
      }
      expect(
        reachedWrite,
        isTrue,
        reason: 'read calibration never completed to the write phase',
      );
      // MPR was enabled during read calibration (and disabled again afterwards).
      expect(sawMprEnabled, isTrue);

      await Simulator.endSimulation();
    },
  );
}

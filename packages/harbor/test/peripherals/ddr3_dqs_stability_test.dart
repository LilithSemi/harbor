import 'dart:async';
import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());
  for (final scenario in ['stable', 'changed', 'recovered']) {
    final jitter = scenario != 'stable';
    final recovery = scenario == 'recovered';
    test(
      'DQS stability ${jitter
          ? recovery
                ? "accepts stable samples after a change"
                : "rejects a changed latest sample"
          : "accepts matching samples"}',
      () async {
        final p = DdrParams(
          controllerClkPeriodPs: 800000,
          ddr3ClkPeriodPs: 200000,
        );
        final clk = SimpleClockGenerator(10).clk;
        final rstN = Logic()..inject(0);
        final dqs = Logic(width: p.lanes * 8)..inject(0);
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
          phyIserdesData: Logic(width: p.dqBits * p.lanes * 8)..inject(0),
          phyIserdesDqs: dqs,
          phyIserdesBitslipReference: Logic(width: p.lanes * 8)
            ..inject(BigInt.parse('78' * p.lanes, radix: 16)),
          phyIdelayctrlRdy: Logic()..inject(1),
        );
        await ctrl.build();
        Logic sig(String n) => ctrl.signals.firstWhere((s) => s.name == n);
        Simulator.setMaxSimTime(2000000);
        unawaited(Simulator.run());
        await clk.nextNegedge;
        await clk.nextNegedge;
        rstN.inject(1);
        var collection = -1;
        var previousState = -1;
        var checked = false;
        int? nextState;
        int? rejectedState;
        for (var cycle = 0; cycle < 30000 && !checked; cycle++) {
          await clk.nextNegedge;
          final state = ctrl.debug1.value.getRange(0, 6).toInt();
          if (state == 3 && previousState != 3) collection++;
          if (state == 3) {
            final count = sig('dqs_count_repeat').value.toInt();
            final index = jitter && collection >= 2 ? 9 : 8;
            final sample = ((0x154 << index) >> (count * 8)) & 255;
            dqs.inject(
              BigInt.from(sample) *
                  ((BigInt.one << (p.lanes * 8)) - BigInt.one) ~/
                  BigInt.from(255),
            );
          }
          if (state == 4 &&
              (collection == 2 || (recovery && collection == 4))) {
            final index = sig('dqs_start_index').value.toInt();
            if (index == (jitter ? 9 : 8)) {
              expect(
                sig('dqs_start_index_stored').value.toInt(),
                collection == 4 ? 9 : 8,
              );
              expect(sig('dqs_start_index_repeat').value.toInt(), 1);
              await clk.nextNegedge;
              nextState = ctrl.debug1.value.getRange(0, 6).toInt();
              if (recovery && collection == 2) {
                rejectedState = nextState;
              } else {
                checked = true;
              }
            }
          }
          previousState = state;
        }
        await Simulator.endSimulation();
        expect(
          checked,
          isTrue,
          reason: 'Did not exercise the required DQS sequence',
        );
        if (recovery) expect(rejectedState, 2);
        expect(
          nextState,
          jitter && !recovery ? 2 : 5,
          reason:
              'The newest DQS observation must agree before advancing calibration',
        );
      },
    );
  }
}

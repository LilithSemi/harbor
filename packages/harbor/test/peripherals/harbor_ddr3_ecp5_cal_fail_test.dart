import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'harbor_ddr3_status_bench.dart';

// Separate file: every calibration try sweeps all leveling points, so this
// is slow and runs in parallel with the passing run.
void main() {
  tearDown(Simulator.reset);

  test('ECP5 calibration with no read window: cal_failed rises and stays set '
      'until reset', () async {
    final run = await Ddr3Ecp5StatusRun.start(readSkewBeats: 40);
    int? failedAt;
    for (var i = 0; i < 2000000 && failedAt == null; i++) {
      await run.clk.nextPosedge;
      final s = run.status;
      expect(s.done, isFalse, reason: 'cal_done at cycle $i');
      if (s.failed) failedAt = i;
    }
    expect(failedAt, isNotNull, reason: 'cal_failed never rose');

    var held = true;
    for (var i = 0; i < 2000; i++) {
      await run.clk.nextPosedge;
      held &= run.status.failed;
    }
    final atFail = run.status;

    run.reset.inject(1);
    run.ddrReset.inject(1);
    for (var i = 0; i < 8; i++) {
      await run.ddrClk.nextPosedge;
    }
    final inReset = run.status;
    run.ddrReset.inject(0);
    await run.clk.nextNegedge;
    run.reset.inject(0);
    for (var i = 0; i < 20; i++) {
      await run.clk.nextPosedge;
    }
    final after = run.status;
    await Simulator.endSimulation();

    expect(held, isTrue, reason: 'cal_failed dropped before reset');
    expect(atFail.state, Ddr3Controller.calStateFailed);
    expect(atFail.done, isFalse);
    expect(inReset.failed, isFalse);
    expect(after.failed, isFalse);
    expect(after.state, isNot(Ddr3Controller.calStateFailed));
  }, timeout: const Timeout(Duration(hours: 5)));
}

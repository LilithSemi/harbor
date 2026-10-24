import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'harbor_ddr3_status_bench.dart';

// Separate file: calibration makes this slow, so it runs in parallel with
// the failure run.
void main() {
  tearDown(Simulator.reset);

  test('ECP5 calibration: init_done and cal_done rise in order and cal_state '
      'ends in DONE_CALIBRATE', () async {
    final run = await Ddr3Ecp5StatusRun.start();
    int? initAt;
    int? doneAt;
    var calStarted = false;
    for (var i = 0; i < 200000 && doneAt == null; i++) {
      await run.clk.nextPosedge;
      final s = run.status;
      if (s.state > 0) calStarted = true;
      if (s.init) initAt ??= i;
      if (s.done) doneAt = i;
      expect(s.failed, isFalse, reason: 'cal_failed at cycle $i');
    }
    for (var i = 0; i < 20; i++) {
      await run.clk.nextPosedge;
    }
    final last = run.status;
    await Simulator.endSimulation();
    expect(calStarted, isTrue);
    expect(initAt, isNotNull, reason: 'init_done never rose');
    expect(doneAt, isNotNull, reason: 'cal_done never rose');
    expect(initAt, lessThanOrEqualTo(doneAt!));
    expect(last.init, isTrue);
    expect(last.done, isTrue);
    expect(last.failed, isFalse);
    expect(last.state, Ddr3Controller.calStateDone);
    expect(run.dram.errors, isEmpty);
  }, timeout: const Timeout(Duration(hours: 2)));
}

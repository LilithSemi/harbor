import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'harbor_ddr3_status_bench.dart';

// Separate file: calibration makes this slow, so it runs in parallel with
// the failure run.
void main() {
  tearDown(Simulator.reset);

  // 10 is an uneven ratio to ddr_clk, 32 is an even one.
  for (final clkPeriod in [10, 32]) {
    test('ECP5 calibration, clk period $clkPeriod: init_done and cal_done '
        'rise in order and cal_state follows the FSM', () async {
      await _run(clkPeriod);
    }, timeout: const Timeout(Duration(hours: 2)));
  }
}

Future<void> _run(int clkPeriod) async {
  {
    final run = await Ddr3Ecp5StatusRun.start(clkPeriod: clkPeriod);
    final states = <int>{};
    int? initAt;
    int? doneAt;
    var calStarted = false;
    for (var i = 0; i < 200000 && doneAt == null; i++) {
      await run.clk.nextPosedge;
      final s = run.status;
      if (s.state > 0) calStarted = true;
      states.add(s.state);
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
    expect(
      states.where((s) => s > 0).length,
      greaterThan(3),
      reason: '$states',
    );
    expect(last.attempts, 1);
  }
}

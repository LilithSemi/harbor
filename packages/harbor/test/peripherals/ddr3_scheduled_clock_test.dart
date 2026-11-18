import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'ddr3_scheduled_clock.dart';

void main() {
  tearDown(Simulator.reset);

  test('a flop on a scheduled clock samples a fast clock flop before its '
      'update', () async {
    final ck = SimpleClockGenerator(4).clk;
    final slow = scheduledClock(firstRise: 10, halfPeriod: 8);
    final count = Logic(name: 'count', width: 8);
    final seen = Logic(name: 'seen', width: 8);
    final rises = <int>[];
    Sequential(ck, [count < count + 1]);
    Sequential(slow, [seen < count]);
    count.put(0);
    slow.posedge.listen((_) => rises.add(Simulator.time));
    Simulator.setMaxSimTime(80);
    unawaited(Simulator.run());
    await Simulator.simulationEnded;
    expect(rises.take(3), [10, 26, 42]);
    // CK rises at 2, 6, ... 70, 74, and the last slow edge is at 74: count
    // is 18 before that edge and 19 after it.
    expect(seen.value.toInt(), 18);
  });

  test('a bad half period or a first rise in the past is refused', () {
    expect(
      () => scheduledClock(firstRise: 10, halfPeriod: 0),
      throwsArgumentError,
    );
    expect(
      () => scheduledClock(firstRise: 10, halfPeriod: -4),
      throwsArgumentError,
    );
    expect(
      () => scheduledClock(firstRise: -1, halfPeriod: 4),
      throwsArgumentError,
    );
  });
}

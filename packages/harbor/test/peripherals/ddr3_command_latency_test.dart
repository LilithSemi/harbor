import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_command_latency.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('ordered timestamps survive overlapping accepts and returns', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    final accepted = Logic()..inject(0);
    final returned = Logic()..inject(0);
    final monitor = Ddr3CommandLatency(
      clk: clk,
      reset: reset,
      accepted: accepted,
      returned: returned,
      depth: 4,
    );
    await monitor.build();
    unawaited(Simulator.run());
    await clk.nextNegedge;
    await clk.nextNegedge;
    reset.inject(0);

    final samples = <int>[];
    Future<void> tick({bool start = false, bool end = false}) async {
      accepted.put(start ? 1 : 0);
      returned.put(end ? 1 : 0);
      if (monitor.sampleValid.value.toInt() == 1) {
        samples.add(monitor.sampleCycles.value.toInt());
      }
      await clk.nextNegedge;
    }

    await tick(start: true); // 0
    await tick(start: true); // 1
    await tick(); // 2
    await tick(start: true, end: true); // 3 - 0
    await tick(end: true); // 4 - 1
    await tick(end: true); // 5 - 3
    expect(samples, [3, 3, 2]);
    expect(monitor.invalid.value.toInt(), 0);

    await tick(end: true);
    expect(monitor.invalid.value.toInt(), 1);
    await tick(start: true);
    await tick(end: true);
    expect(samples, [3, 3, 2]);

    reset.put(1);
    await tick();
    reset.put(0);
    for (var i = 0; i < 5; i++) {
      await tick(start: true);
    }
    expect(monitor.invalid.value.toInt(), 1);
    await tick(end: true);
    expect(samples, [3, 3, 2]);
  });
}

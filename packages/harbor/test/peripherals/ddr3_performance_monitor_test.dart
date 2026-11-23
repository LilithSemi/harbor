import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/bus/port/memory_waist.dart';
import 'package:harbor/src/peripherals/ddr3_performance_monitor.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });
  test(
    'DDR probes distinguish queueing, responses, backpressure and channels',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(),
          clear = Logic(),
          command = Logic(),
          stalled = Logic(),
          returned = Logic();
      final ws = List.generate(
        2,
        (_) => HarborMemoryWaist(
          const HarborMemoryWaistConfig(
            addressWidth: 32,
            dataWidth: 32,
            outstanding: 8,
          ),
        ),
      );
      for (final w in ws)
        for (final signal in [
          w.reqValid,
          w.reqReady,
          w.reqWrite,
          w.rdataValid,
          w.rdataReady,
          w.rdataLast,
          w.wdataValid,
          w.wdataReady,
          w.wrespValid,
          w.wrespReady,
        ])
          signal.inject(0);
      final m = Ddr3PerformanceMonitor(
        clk: clk,
        reset: reset,
        clear: clear,
        waists: ws,
        command: command,
        stalled: stalled,
        returned: returned,
      );
      await m.build();
      reset.inject(1);
      clear.inject(0);
      command.inject(0);
      stalled.inject(1);
      returned.inject(0);
      Simulator.setMaxSimTime(10000);
      unawaited(Simulator.run());
      await clk.nextNegedge;
      await clk.nextNegedge;
      reset.inject(0);
      int e(String n) => m.events[n]!.value.toInt();
      await clk.nextNegedge;
      expect(e('controller_stall'), 0);
      command.inject(1);
      await clk.nextNegedge;
      expect(e('controller_stall'), 1);
      expect(e('controller_accept'), 0);
      stalled.inject(0);
      returned.inject(1);
      await clk.nextNegedge;
      expect(e('controller_accept'), 1);
      expect(e('controller_return'), 1);
      final a = ws[0], b = ws[1];
      a.reqValid.inject(1);
      await clk.nextNegedge;
      expect(e('ch0_request_stall'), 1);
      expect(e('ch0_read_wait'), 0);
      a.reqReady.inject(1);
      await clk.nextNegedge;
      a.reqValid.inject(0);
      await clk.nextNegedge;
      expect(e('ch0_read_wait'), 1);
      expect(e('ch1_read_wait'), 0);
      b.reqValid.inject(1);
      b.reqReady.inject(1);
      await clk.nextNegedge;
      b.reqValid.inject(0);
      a.rdataValid.inject(1);
      await clk.nextNegedge;
      expect(e('ch0_read_backpressure'), 1);
      expect(e('ch0_read_beats'), 0);
      expect(e('ch0_read_wait'), 0);
      a.rdataReady.inject(1);
      await clk.nextNegedge;
      expect(e('ch0_read_beats'), 1);
      a.rdataLast.inject(1);
      a.reqValid.inject(1);
      await clk.nextNegedge;
      a.rdataValid.inject(0);
      a.reqValid.inject(0);
      await clk.nextNegedge;
      expect(
        e('ch0_read_wait'),
        1,
        reason: 'simultaneous last beat and next request retain pending count',
      );
      a.rdataValid.inject(1);
      await clk.nextNegedge;
      a.rdataValid.inject(0);
      await clk.nextNegedge;
      expect(e('ch0_read_wait'), 0);
      expect(e('ch1_read_wait'), 1);
      a.reqWrite.inject(1);
      a.reqValid.inject(1);
      a.wdataValid.inject(1);
      a.wdataReady.inject(1);
      a.wrespValid.inject(1);
      a.wrespReady.inject(1);
      await clk.nextNegedge;
      expect(e('ch0_write_requests'), 1);
      expect(e('ch0_read_requests'), 0);
      expect(e('ch0_write_beats'), 1);
      expect(e('ch0_write_responses'), 1);
      clear.inject(1);
      await clk.nextNegedge;
      clear.inject(0);
      await clk.nextNegedge;
      expect(e('ch1_read_wait'), 0);
    },
  );

  test(
    'controller histograms separate channel tags and exclude writes',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic()..inject(1),
          command = Logic()..inject(0),
          returned = Logic()..inject(0);
      final clear = Logic()..inject(0);
      final commandTag = Logic(width: 4)..inject(0),
          returnTag = Logic(width: 4)..inject(0);
      final waists = List.generate(
        2,
        (_) => HarborMemoryWaist(
          const HarborMemoryWaistConfig(
            addressWidth: 32,
            dataWidth: 32,
            outstanding: 4,
          ),
        ),
      );
      for (final w in waists) {
        for (final signal in [
          w.reqValid,
          w.reqReady,
          w.reqWrite,
          w.rdataValid,
          w.rdataReady,
          w.rdataLast,
          w.wdataValid,
          w.wdataReady,
          w.wrespValid,
          w.wrespReady,
        ]) {
          signal.inject(0);
        }
      }
      final monitor = Ddr3PerformanceMonitor(
        clk: clk,
        reset: reset,
        clear: clear,
        waists: waists,
        command: command,
        stalled: Const(0),
        returned: returned,
        readLatency: (commandTag: commandTag, returnTag: returnTag, depth: 4),
      );
      await monitor.build();
      unawaited(Simulator.run());
      await clk.nextNegedge;
      await clk.nextNegedge;
      reset.put(0);
      final hits = <String, int>{};
      for (var cycle = 0; cycle < 42; cycle++) {
        clear.put(cycle == 5 ? 1 : 0);
        command.put(cycle < 3 ? 1 : 0);
        commandTag.put(
          cycle == 0
              ? 1
              : cycle == 1
              ? 3
              : 0,
        );
        returned.put([2, 8, 40].contains(cycle) ? 1 : 0);
        returnTag.put(
          cycle == 8
              ? 3
              : cycle == 40
              ? 1
              : 0,
        );
        for (final entry in monitor.events.entries.where(
          (e) => e.key.contains('_latency_'),
        )) {
          if (entry.value.value.toInt() == 1) {
            hits.update(entry.key, (count) => count + 1, ifAbsent: () => 1);
          }
        }
        await clk.nextNegedge;
      }
      expect(hits, {'ch1_latency_lt16': 1, 'ch0_latency_32_63': 1});
    },
  );
}

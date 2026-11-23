import 'package:rohd/rohd.dart';

import '../bus/port/memory_waist.dart';
import 'ddr3_command_latency.dart';

/// Event signals for performance counters of a DDR3 memory port.
///
/// Each event is high for one cycle per occurrence: controller commands,
/// stalls and returns, and per waist the requests, beats, stalls and read
/// waits. With [readLatency], each read channel also has a histogram of
/// controller read latency in four bins. `ch<i>_latency_invalid_cycles` is
/// a level, not a pulse: it stays high after a timestamp overflow or an
/// unmatched return until reset, so a counter of it counts the cycles with
/// no valid histogram. The monitor only observes, and no output goes back
/// to flow control.
class Ddr3PerformanceMonitor extends Module {
  /// The event outputs, by name.
  final Map<String, Logic> events = {};
  Ddr3PerformanceMonitor({
    required Logic clk,
    required Logic reset,
    required Logic clear,
    required List<HarborMemoryWaist> waists,
    required Logic command,
    required Logic stalled,
    required Logic returned,
    ({Logic commandTag, Logic returnTag, int depth})? readLatency,
  }) : super(name: 'ddr_performance_monitor') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    clear = addInput('clear', clear);
    command = addInput('command', command);
    stalled = addInput('stalled', stalled);
    returned = addInput('returned', returned);
    void event(String name, Logic value) {
      events[name] = addOutput(name)..gets(value);
    }

    event('cycles', Const(1));
    event('controller_stall', command & stalled);
    event('controller_accept', command & ~stalled);
    event('controller_return', returned);
    for (var i = 0; i < waists.length; i++) {
      final w = waists[i];
      Logic observe(String n, Logic v) => addInput('ch${i}_$n', v);
      final reqValid = observe('req_valid', w.reqValid),
          reqReady = observe('req_ready', w.reqReady),
          write = observe('req_write', w.reqWrite);
      final rdValid = observe('rd_valid', w.rdataValid),
          rdReady = observe('rd_ready', w.rdataReady),
          rdLast = observe('rd_last', w.rdataLast);
      final wdValid = observe('wd_valid', w.wdataValid),
          wdReady = observe('wd_ready', w.wdataReady);
      final wrValid = observe('wr_valid', w.wrespValid),
          wrReady = observe('wr_ready', w.wrespReady);
      final accepted = reqValid & reqReady, readRequest = accepted & ~write;
      final readBeat = rdValid & rdReady, readDone = readBeat & rdLast;
      // A waist has at most `outstanding` reads in flight.
      final pending = Logic(
        name: 'ch${i}_pending',
        width: w.config.outstanding.bitLength,
      );
      Sequential(clk, reset: reset | clear, [
        If(readRequest & ~readDone, then: [pending < pending + 1]),
        If(readDone & ~readRequest, then: [pending < pending - 1]),
      ]);
      event('ch${i}_request_stall', reqValid & ~reqReady);
      event('ch${i}_read_requests', readRequest);
      event('ch${i}_write_requests', accepted & write);
      event('ch${i}_read_beats', readBeat);
      event('ch${i}_read_wait', pending.neq(0) & ~rdValid);
      event('ch${i}_read_backpressure', rdValid & ~rdReady);
      event('ch${i}_write_beats', wdValid & wdReady);
      event('ch${i}_write_responses', wrValid & wrReady);
    }
    if (readLatency != null) {
      final commandTag = addInput(
        'command_tag',
        readLatency.commandTag,
        width: 4,
      );
      final returnTag = addInput('return_tag', readLatency.returnTag, width: 4);
      // A fabric clear drops the waist queues, but accepted controller
      // commands still return. Keep their timestamps until controller reset.
      for (var i = 0; i < waists.length; i++) {
        final tag = (i << 1) | 1;
        final latency = Ddr3CommandLatency(
          name: 'ch${i}_command_latency',
          clk: clk,
          reset: reset,
          accepted: command & ~stalled & commandTag.eq(tag),
          returned: returned & returnTag.eq(tag),
          depth: readLatency.depth,
        );
        final cycles = latency.sampleCycles;
        final sample = latency.sampleValid;
        event('ch${i}_latency_lt16', sample & cycles.lt(16));
        event('ch${i}_latency_16_31', sample & cycles.gte(16) & cycles.lt(32));
        event('ch${i}_latency_32_63', sample & cycles.gte(32) & cycles.lt(64));
        event('ch${i}_latency_ge64', sample & cycles.gte(64));
        event('ch${i}_latency_invalid_cycles', latency.invalid);
      }
    }
  }
}

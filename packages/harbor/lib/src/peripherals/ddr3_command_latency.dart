import 'package:rohd/rohd.dart';

import '../bus/port/reg_fifo.dart';

/// Measures acceptance-to-return latency of one ordered DDR read channel.
/// Requests and returns are pulses already demultiplexed by channel tag.
/// Overflow or an orphan return invalidates measurements until reset. The
/// observer has no outputs that feed request or response flow control.
class Ddr3CommandLatency extends Module {
  static const timestampWidth = 24;

  Logic get sampleValid => output('sample_valid');
  Logic get sampleCycles => output('sample_cycles');
  Logic get invalid => output('invalid');

  Ddr3CommandLatency({
    required Logic clk,
    required Logic reset,
    required Logic accepted,
    required Logic returned,
    required int depth,
    super.name = 'ddr_command_latency',
  }) : super(definitionName: 'Ddr3CommandLatency_d$depth') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    accepted = addInput('accepted', accepted);
    returned = addInput('returned', returned);

    final cycle = Logic(name: 'cycle', width: timestampWidth);
    final invalidReg = Logic(name: 'invalid_reg');
    final enabled = ~reset & ~invalidReg;
    final starts = HarborRegFifo(
      name: 'start_times',
      clk: clk,
      reset: reset,
      depth: depth,
      pushValid: enabled & accepted,
      pushData: cycle,
      popReady: enabled & returned,
    );

    final overflow = enabled & accepted & ~starts.pushReady;
    final orphan = enabled & returned & ~starts.popValid;
    Sequential(clk, reset: reset, [
      cycle < cycle + 1,
      invalidReg < invalidReg | overflow | orphan,
    ]);
    addOutput('sample_valid') <= starts.popFire & ~overflow;
    addOutput('sample_cycles', width: timestampWidth) <= cycle - starts.popData;
    addOutput('invalid') <= invalidReg;
  }
}

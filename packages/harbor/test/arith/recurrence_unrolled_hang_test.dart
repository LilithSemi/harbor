// Minimal repro: HarborDivSqrtRecurrence hangs the ROHD simulator (a true
// stall, not a slow run) in pipelined mode with stages: 1.
//
// Build parameters (HarborDivSqrtRecurrence.integer):
//   width = 32
//   mode  = HarborFpDivMode.pipelined
//   radix = 2
//   stages = 1
//   (killMask width 1, no tag, no narrow)
//
// Cycle sequence that triggers it:
//   cycle 1: in_valid = 0 (idle/not accepted), in_a = 3743104970,
//            in_b = 4131104019 (garbage left on the bus by an op this
//            engine does not accept, e.g. an illegal/unrelated op
//            elsewhere upstream)
//   cycle 2: in_valid = 1, in_op = HarborDivSqrtOp.divUnsigned,
//            in_a = 100, in_b = 7 (an ordinary small unsigned divide)
//
// Expected: in_ready goes high within a few cycles once the divide is
// accepted. Observed: the simulator never reaches cycle 3's negedge at
// all (confirmed with a print right after `await clk.nextNegedge` for
// every cycle: cycle 1 and 2 print, cycle 3 never does), so this is the
// simulator failing to settle, not merely a slow computation.
//
// Reproduces with HarborDivSqrtRecurrence alone: no HarborIntMulDiv, no
// absent-path/illegal-op machinery, and no multiply hardware involved at
// all. Found while adding absent-path support to HarborIntMulDiv
// (int_mul_div.dart); it is not an int_mul_div.dart bug.
//
// To point this at the real package when copying it into the repo, swap
// the relative imports below for 'package:harbor/src/arith/...'.

import 'dart:async';
import 'dart:isolate';

import 'package:harbor/src/arith/fpu_config.dart';
import 'package:harbor/src/arith/recurrence.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

Future<String> _run() => Isolate.run(() async {
  const width = 32;
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final killMask = Logic(name: 'kill_mask', width: 1);
  final inValid = Logic(name: 'in_valid');
  final inOp = Logic(name: 'in_op', width: 2);
  final inA = Logic(name: 'in_a', width: width);
  final inB = Logic(name: 'in_b', width: width);
  final outReady = Logic(name: 'out_ready');
  final rec = HarborDivSqrtRecurrence.integer(
    width,
    HarborFpDivMode.pipelined,
    2,
    1,
    clk: clk,
    reset: reset,
    killMask: killMask,
    inValid: inValid,
    inOp: inOp,
    inA: inA,
    inB: inB,
    outReady: outReady,
  );
  await rec.build();

  reset.put(1);
  killMask.put(0);
  inValid.put(0);
  outReady.put(1);
  inOp.put(HarborDivSqrtOp.divUnsigned.index);
  inA.put(BigInt.from(3743104970));
  inB.put(BigInt.from(4131104019));
  unawaited(Simulator.run());
  await clk.nextNegedge;
  await clk.nextNegedge;
  reset.put(0);

  var cycle = 0;
  const limit = 20;

  // Cycle 1: idle, with the garbage operands already on the bus.
  await clk.nextNegedge;
  cycle++;
  // ignore: avoid_print
  print('cycle=$cycle reached (idle, garbage on in_a/in_b)');

  // Cycle 2: a real, ordinary small unsigned divide.
  inValid.put(1);
  inA.put(BigInt.from(100));
  inB.put(BigInt.from(7));
  while (cycle < limit) {
    await clk.nextNegedge;
    cycle++;
    // ignore: avoid_print
    print('cycle=$cycle reached, in_ready=${rec.inReady.value}');
    if (rec.inReady.value.toBool()) {
      break;
    }
  }
  await Simulator.endSimulation();
  return cycle >= limit ? 'HUNG at cycle $cycle' : 'OK after $cycle cycles';
});

void main() {
  test(
    'HarborDivSqrtRecurrence pipelined stages:1 hangs on this sequence',
    () async {
      final result = await _run();
      // ignore: avoid_print
      print(result);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

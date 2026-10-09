import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_ulx3s_top.dart';

/// Runs [SdramBistMaster] over 64 words against a wishbone ram with a 3
/// cycle ack. When [corruptAt] is set, the ram flips bit 0 of that word.
Future<SdramBistMaster> _runBist({int? corruptAt}) async {
  await Simulator.reset();
  final clk = SimpleClockGenerator(16000).clk;
  final reset = Logic(name: 'reset')..inject(1);
  final ready = Logic(name: 'ready')..inject(0);
  final ack = Logic(name: 'ack')..inject(0);
  final datR = Logic(name: 'dat_r', width: 32)..inject(0);
  final bist = SdramBistMaster(
    clk: clk,
    reset: reset,
    ready: ready,
    ack: ack,
    datR: datR,
    adrWidth: 26,
    words: 64,
  );
  await bist.build();
  final mem = <int, int>{};
  var wait = 0;
  final sub = clk.posedge.listen((_) {
    if (ack.value.toInt() == 1) {
      ack.inject(0);
      return;
    }
    if (bist.cyc.value.toInt() != 1) return;
    if (++wait < 3) return;
    wait = 0;
    final a = bist.adr.value.toInt();
    if (bist.we.value.toInt() == 1) {
      var v = bist.datW.value.toInt();
      if (a == corruptAt) v ^= 1;
      mem[a] = v;
    } else {
      datR.inject(mem[a] ?? 0);
    }
    ack.inject(1);
  });
  unawaited(Simulator.run());
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  ready.inject(1);
  while (bist.loops.value.toInt() < 2) {
    await clk.nextPosedge;
  }
  await sub.cancel();
  await Simulator.endSimulation();
  await Simulator.simulationEnded;
  return bist;
}

void main() {
  group('bist master', () {
    tearDown(Simulator.reset);

    test('bist passes on a good ram and loops', () async {
      final bist = await _runBist();
      expect(bist.pass.value.toInt(), 1);
      expect(bist.fail.value.toInt(), 0);
    });

    test('bist flags a bad word', () async {
      final bist = await _runBist(corruptAt: 4 * 37);
      expect(bist.pass.value.toInt(), 0);
      expect(bist.fail.value.toInt(), 1);
    });
  });
}

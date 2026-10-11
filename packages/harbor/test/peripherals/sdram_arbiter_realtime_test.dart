import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// Port 0 is best effort and always has a random request ready. Port 1 is
/// realtime and streams 8-word reads with at most [inFlight] in flight, as
/// a [HarborSdram] scanout port does. The two ports use other rows of the
/// same banks, so most requests miss the open row.
Future<SdramEngineStack> _run(int clockHz, int inFlight, int seed) async {
  final s = SdramEngineStack(
    clockHz: clockHz,
    ports: 2,
    portRealtime: const [false, true],
  );
  await s.start();
  final c = s.config;
  final rng = Random(seed);
  final colMask = (1 << c.colWidth) - 1;

  int addrOf(int row, int bank, int col) =>
      (((row << c.bankBits) | bank) << c.colWidth) | col;

  for (var i = 0; i < 400; i++) {
    final words = 1 + rng.nextInt(8);
    final col = rng.nextInt(colMask + 2 - words);
    final addr = addrOf(64 + rng.nextInt(4), rng.nextInt(c.banks), col);
    if (rng.nextBool()) {
      s.write(addr, [for (var w = 0; w < words; w++) rng.nextInt(1 << 16)]);
    } else {
      s.read(addr, words);
    }
  }

  // A line walks the pages of all banks, as a framebuffer does.
  var next = addrOf(8, 0, 0);
  final limit = s.cycle + 200000;
  while (s.pending > s.pendingReads(1)) {
    if (s.cycle > limit) throw StateError('the best effort port starved');
    while (s.pendingReads(1) < inFlight) {
      s.read(next, 8, port: 1);
      next += 8;
    }
    await s.clk.nextPosedge;
  }
  await s.drain();
  await s.idle(50);
  await s.stop();
  return s;
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final hz in [100000000, 125000000]) {
    for (final inFlight in [1, 2, 3]) {
      final mhz = hz ~/ 1000000;
      test(
        '$mhz MHz, $inFlight in flight: realtime wins every grant point, '
        'never preempts, and both classes stay inside their bounds',
        () async {
          final s = await _run(hz, inFlight, 7 + mhz + inFlight);
          final rtBound = HarborSdram.realtimeWaitBound(s.cycles);
          final beBound = HarborSdram.bestEffortWaitBound(s.cycles, inFlight);
          print(
            '$mhz MHz, $inFlight in flight: realtime wait ${s.maxWait[1]} '
            '(bound $rtBound), '
            'best effort wait ${s.maxWait[0]} (bound $beBound)',
          );
          // Errors hold the scoreboard, the take order of the read data
          // (no preemption) and every grant a best effort port won over a
          // waiting realtime port.
          expect(s.errors, isEmpty);
          expect(s.maxWait[1], lessThanOrEqualTo(rtBound));
          expect(s.maxWait[0], lessThanOrEqualTo(beBound));
        },
        timeout: const Timeout(Duration(minutes: 10)),
      );
    }
  }
}

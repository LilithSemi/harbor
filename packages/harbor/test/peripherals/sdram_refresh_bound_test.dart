import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// Checks design fix 2 from the review: the refresh window the pin model
/// derives from [SdramEngineStack]'s own [SdramRefreshPolicy] holds both
/// at idle (pull-in bottoms out at -p, then about one refresh a refi) and
/// under saturating traffic (owed never passes k).
int sdramRefreshOwed(SdramEngineStack s) {
  final o = s.top.engine.refreshOwed;
  return o.value.toInt().toSigned(o.width);
}

Future<SdramEngineStack> sdramSaturateRefresh(
  int clockHz,
  int minCycles, {
  required int seed,
  int maxPostponed = 8,
  int maxPulledIn = 8,
}) async {
  final s = SdramEngineStack(
    clockHz: clockHz,
    maxGrantWords: 16,
    maxPostponed: maxPostponed,
    maxPulledIn: maxPulledIn,
  );
  await s.start();
  var maxOwed = 0;
  s.clk.posedge.listen((_) {
    final o = sdramRefreshOwed(s);
    if (o > maxOwed) maxOwed = o;
  });

  final rng = Random(seed);
  final c = s.config;
  final rows = [for (var i = 0; i < 3; i++) rng.nextInt(1 << c.rowWidth)];
  final c0 = s.cycle;
  while (s.cycle - c0 < minCycles) {
    // Queue a small batch, then drain: this yields to the simulator so
    // s.cycle actually advances, instead of piling up an unbounded queue.
    for (var i = 0; i < 50; i++) {
      final words = 1 + rng.nextInt(16);
      final col = rng.nextInt((1 << c.colWidth) - words + 1);
      final bank = rng.nextInt(c.banks);
      final row = rows[rng.nextInt(rows.length)];
      final addr = (((row << c.bankBits) | bank) << c.colWidth) | col;
      if (rng.nextBool()) {
        s.write(
          addr,
          [for (var w = 0; w < words; w++) rng.nextInt(1 << 16)],
          masks: [for (var w = 0; w < words; w++) rng.nextInt(4)],
        );
      } else {
        s.read(addr, words);
      }
    }
    await s.drain();
  }
  await s.idle(50);
  await s.stop();

  expect(maxOwed, lessThanOrEqualTo(maxPostponed), reason: 'refresh_owed');
  expect(s.errors, isEmpty);
  return s;
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    '125 MHz: idle pull-in settles at -p, then about one refresh a refi',
    () async {
      final s = SdramEngineStack(clockHz: 125000000);
      await s.start();
      var minOwed = 0;
      s.clk.posedge.listen((_) {
        final o = sdramRefreshOwed(s);
        if (o < minOwed) minOwed = o;
      });

      final refi = s.cycles.refi;
      await s.idle(20 * refi);
      expect(minOwed, equals(-s.cycles.maxPulledIn));

      final before = s.model.refreshTimesPs.length;
      await s.idle(15 * refi);
      final after = s.model.refreshTimesPs.length;
      await s.stop();

      expect(after - before, inInclusiveRange(8, 20));
      expect(s.errors, isEmpty);
    },
  );
}

import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  // Short bursts that leave rows open, then idle. A refresh then needs a
  // precharge all first and stays committed. At 25 MHz the refresh takes
  // 2 cycles, so the commit must end at the pick, or a second refresh goes
  // out that the credit does not count at its floor.
  test(
    '25 MHz: bursts then idle never issue a refresh the credit missed',
    () async {
      final s = SdramEngineStack(clockHz: 25000000);
      await s.start();
      final c = s.config;
      final rng = Random(5);
      var refreshes = 0;
      final c0 = s.cycle;
      while (s.cycle - c0 < 150 * s.cycles.refi) {
        for (var i = 0; i < 1 + rng.nextInt(3); i++) {
          final bank = rng.nextInt(c.banks);
          final addr =
              (((rng.nextInt(1 << c.rowWidth) << c.bankBits) | bank) <<
                  c.colWidth) |
              rng.nextInt(1 << (c.colWidth - 3));
          s.read(addr, 8);
        }
        await s.drain();
        await s.idle(40 + rng.nextInt(300));
        refreshes++;
      }
      await s.idle(50);
      await s.stop();
      expect(refreshes, greaterThan(20));
      // The refreshes are the pulled in ones plus one for each refi.
      final elapsed = s.cycle - c0;
      expect(
        s.model.refreshTimesPs.length,
        lessThanOrEqualTo(s.cycles.maxPulledIn + elapsed ~/ s.cycles.refi + 2),
      );
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

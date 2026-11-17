import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  // A realtime port that reads lines of 80 requests with a gap between, as
  // a 640 pixel line at 25 MHz does. Refreshes must keep the pull-in and
  // postpone window of the pin model.
  test(
    '25 MHz: refresh stays in its window under a line stream',
    () async {
      final s = SdramEngineStack(
        clockHz: 25000000,
        ports: 2,
        portRealtime: const [false, true],
      );
      await s.start();
      final c = s.config;
      int addrOf(int row, int bank, int col) =>
          (((row << c.bankBits) | bank) << c.colWidth) | col;
      var next = addrOf(8, 0, 0);
      for (var line = 0; line < 60; line++) {
        for (var r = 0; r < 80; r++) {
          while (s.pendingReads(1) >= 3) {
            await s.clk.nextPosedge;
          }
          s.read(next, 8, port: 1);
          next += 8;
          await s.clk.nextPosedge;
        }
        await s.idle(120);
      }
      await s.drain();
      await s.idle(50);
      await s.stop();
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

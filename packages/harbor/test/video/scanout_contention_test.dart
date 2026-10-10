import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'scanout_contention_harness.dart';

/// A 64-pixel mode with the same fetch load as 640x480 at 25 MHz: 64 words
/// in an 80-pixel line. Through the sdram clock crossing a word costs about
/// 10 system cycles, so the fetcher is always behind and always asks for the
/// bus, as on hardware.
const _timing = HarborDisplayTiming(
  hActive: 64,
  hFrontPorch: 4,
  hSyncWidth: 8,
  hBackPorch: 4,
  vActive: 6,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: 25175000,
);

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  // A burst of 16 reads at about 10 cycles each, the bench's own access and
  // the grant hand-over. A full 640-word line holds the bus for about 6400
  // cycles without the release.
  const bound = 256;

  test(
    'a second master is not locked out while the fetcher runs',
    () async {
      final b = ScanoutContentionBench(timing: _timing, burstWords: 16);
      await b.start();
      // Let the fetcher fall behind, so it asks for the bus all the time.
      for (var i = 0; i < 400; i++) {
        await b.sysClk.nextPosedge;
      }
      const fb = ScanoutContentionBench.sdramBase + 0x40000;
      const sram = ScanoutContentionBench.sramBase;
      for (var i = 0; i < 24; i++) {
        await b.write(fb + i * 4, 0x00C00000 | i);
        if (i % 3 == 0) {
          await b.write(sram + i * 4, ~i & 0xFFFFFFFF);
          expect(await b.read(sram + i * 4), equals(~i & 0xFFFFFFFF));
        }
      }
      expect(await b.read(fb + 23 * 4), equals(0x00C00000 | 23));
      print('bench ${b.benchStats}');
      print('display ${b.displayStats}');
      print('line fetch sys cycles ${b.lineCycles}');

      expect(b.benchStats.longestAccess, lessThan(bound));
      expect(b.benchStats.longestSramAccess, lessThan(bound));
      expect(b.displayStats.longestAccess, lessThan(bound));
      expect(b.lineCycles, isNotEmpty);
      expect(b.model.errors, isEmpty);
      await b.stop();
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

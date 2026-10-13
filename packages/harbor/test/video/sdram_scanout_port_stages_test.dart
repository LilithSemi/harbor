import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_harness.dart';

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  // Each stage adds a cycle on the request and the return path. The
  // in-flight limit covers them, so lines still stream.
  for (final (stages, periodPs) in [(1, 8000), (2, 10000)]) {
    final mhz = 1000000 ~/ periodPs;
    test('$mhz MHz, $stages read port stages: 640-pixel 32 bpp lines meet '
        'every line while the fabric fills the frame', () async {
      final r = await runFullWidthScanout(
        memPeriodPs: periodPs,
        readPortStages: stages,
      );
      print(
        '$mhz MHz, $stages stages: line fetch '
        '${r.lineCycles.reduce((a, b) => a < b ? a : b)} to '
        '${r.lineCycles.reduce((a, b) => a > b ? a : b)} mem cycles, '
        '${r.mbPerSecond.toStringAsFixed(1)} MB/s worst line, bus worst '
        'access ${r.longestAccess} (bound ${r.accessBound}), underrun '
        'frames ${r.underrunFrames}',
      );
      expect(r.underrunFrames, isZero);
      expect(r.mbPerSecond, greaterThan(80.5));
      expect(r.longestAccess, lessThanOrEqualTo(r.accessBound));
    }, timeout: const Timeout(Duration(minutes: 90)));
  }
}

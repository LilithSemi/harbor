import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_harness.dart';

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  // With 1 in flight the worst line is about the 80.5 MB/s that a 640-pixel
  // 32 bpp line needs at 125 MHz. At 100 MHz it is about 74 MB/s and lines
  // underrun.
  test('125 MHz, 1 in flight: 640-pixel 32 bpp lines still meet every '
      'line while the fabric fills the frame', () async {
    final r = await runFullWidthScanout(memPeriodPs: 8000, maxInFlight: 1);
    print(
      '125 MHz, 1 in flight: line fetch '
      '${r.lineCycles.reduce((a, b) => a < b ? a : b)} to '
      '${r.lineCycles.reduce((a, b) => a > b ? a : b)} mem cycles, '
      '${r.mbPerSecond.toStringAsFixed(1)} MB/s worst line against the '
      '80.5 MB/s need, bus worst access ${r.longestAccess} '
      '(bound ${r.accessBound}), underrun frames ${r.underrunFrames}',
    );
    expect(r.underrunFrames, isZero);
    expect(r.longestAccess, lessThanOrEqualTo(r.accessBound));
  }, timeout: const Timeout(Duration(minutes: 90)));
}

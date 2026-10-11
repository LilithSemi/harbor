import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_harness.dart';

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('125 MHz: 640-pixel 32 bpp lines from the sdram scanout port meet '
      'every line while the fabric fills the frame', () async {
    final r = await runFullWidthScanout(memPeriodPs: 8000);
    print(
      '125 MHz: line fetch ${r.lineCycles.reduce((a, b) => a < b ? a : b)}'
      ' to ${r.lineCycles.reduce((a, b) => a > b ? a : b)} mem cycles, '
      '${r.mbPerSecond.toStringAsFixed(1)} MB/s worst line, '
      'bus worst access ${r.longestAccess} (bound ${r.accessBound}), '
      'frames ${r.frames}, underrun frames ${r.underrunFrames}',
    );
    expect(r.underrunFrames, isZero);
    expect(r.longestAccess, lessThanOrEqualTo(r.accessBound));
    expect(r.accessBound, lessThan(4096 ~/ 16));
  }, timeout: const Timeout(Duration(minutes: 90)));
}

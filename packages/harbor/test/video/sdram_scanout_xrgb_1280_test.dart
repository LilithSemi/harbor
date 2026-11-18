@Tags(['slow'])
library;

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_harness.dart';

/// 1280-pixel lines of 2 active lines at 32 bpp, with the 125 MHz sdram and a
/// 62.5 MHz pixel clock. A line is 5120 bytes, 5 rows of the sdram, and takes
/// about 80% of the line time.
void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('125 MHz: 1280 pixel xrgb8888 lines from the sdram scanout port meet '
      'every line', () async {
    const hActive = 1280;
    final b = SdramScanoutBench(
      timing: vgaLinesOf(hActive, 2),
      memPeriodPs: 8000,
      pixelPeriodPs: 16000,
      stride: 5120,
    );
    await b.start();
    expect(b.sdram.scanoutStride(hActive * 4), 5120);
    await b.waitFrames(2);
    for (final (a, n) in b.requests) {
      expect(a >> 10, (a + 2 * n - 1) >> 10, reason: 'crosses a page');
    }
    final bad = b.frameErrors();
    expect(bad, isEmpty);
    final worst = b.lineCycles.reduce((a, c) => a > c ? a : c);
    print(
      '1280 xrgb8888 at 125 MHz: line fetch '
      '${b.lineCycles.reduce((a, c) => a < c ? a : c)} to $worst mem '
      'cycles, frames ${b.frames}, underrun frames ${b.underrunFrames}',
    );
    expect(b.underrunFrames, isZero);
    expect(b.model.errors, isEmpty);
    await b.stop();
  }, timeout: const Timeout(Duration(minutes: 20)));
}

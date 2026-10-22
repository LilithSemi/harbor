import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_harness.dart';

/// [hActive]-pixel lines of 4 active lines with the horizontal timing of
/// a 720p60 or 1080p60 mode.
HarborDisplayTiming _timing(int hActive) => HarborDisplayTiming(
  hActive: hActive,
  hFrontPorch: hActive == 1920 ? 88 : 110,
  hSyncWidth: hActive == 1920 ? 44 : 40,
  hBackPorch: hActive == 1920 ? 148 : 220,
  vActive: 4,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: hActive == 1920 ? 148500000 : 74250000,
);

/// Scans nv12 lines of [hActive] pixels from the sdram scanout port at
/// 125 MHz for 4 frames and checks every request and the underrun flag.
Future<void> _nv12(int hActive, int pixelPeriodPs) async {
  const stride = 2048;
  const chroma = SdramScanoutBench.sdramBase + 0x20000;
  final b = SdramScanoutBench(
    timing: _timing(hActive),
    memPeriodPs: 8000,
    pixelPeriodPs: pixelPeriodPs,
    stride: stride,
    formats: const [HarborPixelFormat.nv12],
    planeBases: const [chroma],
    planePitches: const [stride],
  );
  await b.start();
  expect(b.sdram.scanoutStride(hActive), stride);
  await b.waitFrames(4);

  final fb = b.fbBase;
  // Each request lies in one plane line of the frame.
  bool inLine(int a, int n) {
    for (var y = 0; y < 4; y++) {
      final s = fb + y * stride;
      if (a >= s && a + 2 * n <= s + hActive) return true;
    }
    for (var c = 0; c < 2; c++) {
      final s = chroma + c * stride;
      if (a >= s && a + 2 * n <= s + hActive) return true;
    }
    return false;
  }

  var words = 0;
  for (final (a, n) in b.requests) {
    expect(inLine(a, n), isTrue, reason: '0x${a.toRadixString(16)} $n');
    expect(a >> 10, (a + 2 * n - 1) >> 10, reason: 'crosses a page');
    words += n;
  }
  // Four luma lines and two chroma lines of hActive / 2 words a frame.
  expect(words ~/ (3 * hActive), greaterThanOrEqualTo(3));
  final worst = b.lineCycles.reduce((a, c) => a > c ? a : c);
  final best = b.lineCycles.reduce((a, c) => a < c ? a : c);
  print(
    'nv12 $hActive at 125 MHz: plane line fetch $best to $worst mem '
    'cycles, ${(hActive * 125e6 / worst / 1e6).toStringAsFixed(1)} MB/s '
    'worst line, frames ${b.frames}, underrun frames ${b.underrunFrames}',
  );
  expect(b.underrunFrames, isZero);
  expect(b.model.errors, isEmpty);
  await b.stop();
}

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test(
    '125 MHz: 720p60 nv12 lines from the sdram scanout port meet every line',
    () => _nv12(1280, 13468),
    timeout: const Timeout(Duration(minutes: 50)),
  );

  test(
    '125 MHz: 1080p60 nv12 lines from the sdram scanout port meet every '
    'line',
    () => _nv12(1920, 6734),
    timeout: const Timeout(Duration(minutes: 50)),
  );
}

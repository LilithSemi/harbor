import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import 'sdram_scanout_harness.dart';

/// Lines of [hActive] pixels, 1920 with 1 active line or 960 with 2, with
/// the horizontal timing of 1080p60, or of 1080p60 at half size, so a line
/// takes half the time and holds half the bytes, as the ratios of 1080p60
/// are.
HarborDisplayTiming overlayTimingFor(int hActive) => HarborDisplayTiming(
  hActive: hActive,
  hFrontPorch: hActive == 1920 ? 88 : 44,
  hSyncWidth: hActive == 1920 ? 44 : 22,
  hBackPorch: hActive == 1920 ? 148 : 74,
  vActive: hActive == 1920 ? 1 : 2,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: 148500000,
);

/// Scans an nv12 primary with an xrgb8888 overlay [width] pixels wide at
/// [dstX] on every line, from the sdram scanout port at 125 MHz for 2
/// frames. Checks that every request lies in one plane line and in one
/// page, then prints the line bandwidth and the underruns.
Future<void> scanOverlay(int width, int dstX, {int hActive = 960}) async {
  final overlayTiming = overlayTimingFor(hActive);
  final stride = hActive == 1920 ? 2048 : 1024;
  const chroma = SdramScanoutBench.sdramBase + 0x20000;
  const ovBase = SdramScanoutBench.sdramBase + 0x40000;
  // Each overlay line starts on a new 1 KB row.
  final ovPitch = (4 * width + 1023) & ~1023;
  final b = SdramScanoutBench(
    timing: overlayTiming,
    memPeriodPs: 8000,
    pixelPeriodPs: 6734,
    stride: stride,
    formats: const [HarborPixelFormat.nv12],
    planeBases: const [chroma],
    planePitches: [stride],
    overlay: BenchOverlay(
      format: HarborPixelFormat.xrgb8888,
      base: const [ovBase],
      pitch: [ovPitch],
      dstX: dstX,
      width: width,
      height: overlayTiming.vActive,
    ),
  );
  await b.start();
  await b.waitFrames(2);

  final fb = b.fbBase;
  bool inLine(int a, int n) {
    bool within(int s, int bytes) => a >= s && a + 2 * n <= s + bytes;
    for (var y = 0; y < overlayTiming.vActive; y++) {
      if (within(fb + y * stride, hActive)) return true;
      if (within(ovBase + y * ovPitch, 4 * width)) return true;
    }
    for (var c = 0; c < (overlayTiming.vActive + 1) ~/ 2; c++) {
      if (within(chroma + c * stride, hActive)) return true;
    }
    return false;
  }

  for (final (a, n) in b.requests) {
    expect(inLine(a, n), isTrue, reason: '0x${a.toRadixString(16)} $n');
    expect(a >> 10, (a + 2 * n - 1) >> 10, reason: 'crosses a page');
  }

  // Join the requests into line fetches, in the order of lineCycles.
  final fetches = <(int, int)>[];
  for (final (a, n) in b.requests) {
    if (fetches.isNotEmpty && fetches.last.$1 + 2 * fetches.last.$2 == a) {
      fetches.last = (fetches.last.$1, fetches.last.$2 + n);
    } else {
      fetches.add((a, n));
    }
  }
  var worst = double.infinity;
  for (var i = 0; i < fetches.length && i < b.lineCycles.length; i++) {
    final mbs = 2 * fetches[i].$2 * 125e6 / b.lineCycles[i] / 1e6;
    if (mbs < worst) worst = mbs;
  }
  // An even line fetches a luma line, a chroma line and an overlay line.
  final lineUs = overlayTiming.hTotal / 148.5;
  final need = (hActive + hActive + 4 * width) / lineUs;
  print(
    'nv12 + $width-pixel xrgb8888 overlay at 125 MHz: worst line fetch '
    '${worst.toStringAsFixed(1)} MB/s, need ${need.toStringAsFixed(1)} '
    'MB/s on an even line, frames ${b.frames}, underrun frames '
    '${b.underrunFrames}, overlay underruns '
    '${b.display.output('overlay_underrun_count').value.toInt()}',
  );
  expect(b.model.errors, isEmpty);
  await b.stop();
}

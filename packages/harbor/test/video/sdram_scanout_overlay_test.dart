import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_harness.dart';

/// 1920-pixel lines of 4 active lines with the horizontal timing of
/// 1080p60.
const _timing = HarborDisplayTiming(
  hActive: 1920,
  hFrontPorch: 88,
  hSyncWidth: 44,
  hBackPorch: 148,
  vActive: 4,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: 148500000,
);

/// Scans an nv12 primary with an xrgb8888 overlay [width] pixels wide at
/// [dstX] on every line, from the sdram scanout port at 125 MHz for 4
/// frames. Checks that every request lies in one plane line and in one
/// page, then prints the line bandwidth and the underruns.
Future<void> _scan(int width, int dstX) async {
  const stride = 2048;
  const chroma = SdramScanoutBench.sdramBase + 0x20000;
  const ovBase = SdramScanoutBench.sdramBase + 0x40000;
  // Each overlay line starts on a new 1 KB row.
  final ovPitch = (4 * width + 1023) & ~1023;
  final b = SdramScanoutBench(
    timing: _timing,
    memPeriodPs: 8000,
    pixelPeriodPs: 6734,
    stride: stride,
    formats: const [HarborPixelFormat.nv12],
    planeBases: const [chroma],
    planePitches: const [stride],
    overlay: BenchOverlay(
      format: HarborPixelFormat.xrgb8888,
      base: const [ovBase],
      pitch: [ovPitch],
      dstX: dstX,
      width: width,
      height: _timing.vActive,
    ),
  );
  await b.start();
  await b.waitFrames(4);

  final fb = b.fbBase;
  bool inLine(int a, int n) {
    bool within(int s, int bytes) => a >= s && a + 2 * n <= s + bytes;
    for (var y = 0; y < 4; y++) {
      if (within(fb + y * stride, 1920)) return true;
      if (within(ovBase + y * ovPitch, 4 * width)) return true;
    }
    for (var c = 0; c < 2; c++) {
      if (within(chroma + c * stride, 1920)) return true;
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
  final lineUs = _timing.hTotal / 148.5;
  final need = (1920 + 1920 + 4 * width) / lineUs;
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

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test(
    '125 MHz: 1080p60 nv12 with a 640 pixel xrgb8888 overlay on the sdram '
    'scanout port',
    () => _scan(640, 640),
    timeout: const Timeout(Duration(minutes: 150)),
  );

  test(
    '125 MHz: 1080p60 nv12 with a full width xrgb8888 overlay on the sdram '
    'scanout port',
    () => _scan(1920, 0),
    timeout: const Timeout(Duration(minutes: 150)),
  );
}

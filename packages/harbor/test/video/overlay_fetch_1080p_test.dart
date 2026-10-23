import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'plane_memory.dart';

// 1080p60: 148.5 MHz pixel clock, 2200 pixel cycles a line.
const _pixelPs = 6734;
const _hActive = 1920;
const _vActive = 1080;
const _hTotal = 2200;

// The first beat comes 24 memory cycles after a take, then one 32-bit beat
// each cycle.
const _latency = 24;

const _y = 0x01000000;
const _c = 0x02000000;
const _ov = 0x04000000;
const _ovPitch = 8192;

/// Scans [lines] lines of an nv12 primary with an xrgb8888 overlay of
/// [width] by [height] at ([dstX], 0), after a frame start and three blank
/// lines, with a memory clock of [sysPs]. Checks every word that the read
/// side gives back, and returns the underrun count of each plane.
Future<List<int>> _scan({
  required int width,
  required int height,
  required int dstX,
  required int sysPs,
  int lines = 6,
}) async {
  final pixelClk = SimpleClockGenerator(_pixelPs).clk;
  final sysClk = SimpleClockGenerator(sysPs).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final frameStart = Logic(name: 'frame_start');
  final lineStart = Logic(name: 'line_start');
  final col0 = Logic(name: 'col0', width: 11);
  final col1 = Logic(name: 'col1', width: 11);
  final ovCol = Logic(name: 'ov_col', width: 12);
  const pitch = 2048;
  final memory = HarborMemoryWaist(
    const HarborMemoryWaistConfig(
      addressWidth: 32,
      dataWidth: 32,
      outstanding: 4,
    ),
  );
  final so = HarborDualClockScanout(
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    sysClk: sysClk,
    sysReset: sysReset,
    frameStart: frameStart,
    lineStart: lineStart,
    col: col0,
    fbBase: Const(_y, width: 32),
    stride: Const(pitch, width: 32),
    memory: memory,
    formats: const [HarborPixelFormat.nv12],
    hActive: _hActive,
    vActive: _vActive,
    planeBase: [Const(_c, width: 32)],
    planePitch: [Const(pitch, width: 32)],
    planeCol: [col1],
    overlay: HarborScanoutOverlay(
      formats: const [HarborPixelFormat.xrgb8888],
      enable: Const(1),
      base: [Const(_ov, width: 32)],
      pitch: [Const(_ovPitch, width: 32)],
      srcX: Const(0, width: 12),
      srcY: Const(0, width: 11),
      dstX: Const(dstX, width: 12),
      dstY: Const(0, width: 11),
      width: Const(width, width: 12),
      height: Const(height, width: 11),
      col: [ovCol],
    ),
  );
  await so.build();
  final mem = WaistMemory(memory, sysClk, latency: _latency, depth: 4);
  var busy = 0;
  var cycles = 0;
  sysClk.posedge.listen((_) {
    cycles++;
    if (memory.rdataValid.value.toBool()) busy++;
  });

  pixelReset.inject(1);
  sysReset.inject(1);
  frameStart.inject(0);
  lineStart.inject(0);
  col0.inject(0);
  col1.inject(0);
  ovCol.inject(0);
  Simulator.setMaxSimTime(1 << 40);
  unawaited(Simulator.run());
  await pixelClk.nextPosedge;
  await pixelClk.nextPosedge;
  pixelReset.inject(0);
  sysReset.inject(0);
  await pixelClk.nextNegedge;

  frameStart.inject(1);
  await pixelClk.nextNegedge;
  frameStart.inject(0);
  for (var i = 0; i < 3 * _hTotal; i++) {
    await pixelClk.nextNegedge;
  }
  var checked = 0;
  (int, int, int?)? want;
  for (var y = 0; y < lines; y++) {
    for (var x = 0; x < _hTotal; x++) {
      await pixelClk.nextNegedge;
      if (want case (final w0, final w1, final wo)) {
        expect(so.pixel.value.toInt(), w0, reason: 'y$y x$x');
        expect(so.planeData(1).value.toInt(), w1, reason: 'y$y x$x');
        if (wo != null) {
          expect(so.overlayData(0).value.toInt(), wo, reason: 'y$y x$x');
        }
        checked++;
      }
      lineStart.inject(x == _hActive ? 1 : 0);
      if (x < _hActive) {
        col0.inject(x >> 2);
        col1.inject(x >> 2);
        final inside = x >= dstX && x < dstX + width && y < height;
        ovCol.inject(inside ? x - dstX : 0);
        want = (
          _y + y * pitch + 4 * (x >> 2),
          _c + (y >> 1) * pitch + 4 * (x >> 2),
          inside ? _ov + y * _ovPitch + 4 * (x - dstX) : null,
        );
      } else {
        want = null;
      }
    }
  }
  final counts = [
    so.planeUnderrunCount(0).value.toInt(),
    so.planeUnderrunCount(1).value.toInt(),
    so.overlayUnderrunCount(0).value.toInt(),
  ];
  print(
    'nv12 + ${width}x$height xrgb8888 overlay, 1080p60, memory '
    '${(1e6 / sysPs).toStringAsFixed(0)} MHz: ${mem.requests.length} '
    'requests, memory busy ${(100 * busy / cycles).toStringAsFixed(1)}% '
    'of $cycles cycles, $checked pixels checked, underrun counts $counts',
  );
  expect(checked, lines * _hActive);
  return counts;
}

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  // 150 MHz gives 600 MB/s peak, as for the planar formats alone.
  test('nv12 with a 640x360 xrgb8888 overlay on a 600 MB/s memory never '
      'underruns', () async {
    expect(await _scan(width: 640, height: 360, dstX: 640, sysPs: 6667), [
      0,
      0,
      0,
    ]);
  }, timeout: const Timeout(Duration(minutes: 150)));

  // An even line fetches a luma line, a chroma line and an overlay line:
  // 2880 words, 713 MB/s over a 14.8 us line. The luma and overlay lines
  // go first, and the chroma line has two line times. 200 MHz gives 2962
  // cycles a line.
  test('nv12 with a full screen xrgb8888 overlay on an 800 MB/s memory never '
      'underruns', () async {
    expect(await _scan(width: 1920, height: 1080, dstX: 0, sysPs: 5000), [
      0,
      0,
      0,
    ]);
  }, timeout: const Timeout(Duration(minutes: 150)));

  // 150 MHz (600 MB/s) cannot fetch 2400 words of luma and overlay in the
  // 2222 cycles of a line.
  test('a full screen xrgb8888 overlay on a 600 MB/s memory shows an '
      'underrun on the display ports', () async {
    final (count, flag) = await _display(sysPs: 6667);
    expect(count, greaterThan(0));
    expect(flag, isTrue);
  }, timeout: const Timeout(Duration(minutes: 150)));
}

/// A display with 1080p60 line timing and 4 active lines, an nv12 primary
/// and a full screen xrgb8888 overlay at alpha 128, with a memory clock of
/// [sysPs]. The frame start comes after the active lines from reset, so
/// fewer lines keep the simulation short. Returns the overlay underrun
/// count and whether `underrun` was high in the last active line, both
/// from the display ports.
Future<(int, bool)> _display({required int sysPs}) async {
  const timing = HarborDisplayTiming(
    hActive: _hActive,
    hFrontPorch: 88,
    hSyncWidth: 44,
    hBackPorch: 148,
    vActive: 4,
    vFrontPorch: 1,
    vSyncWidth: 1,
    vBackPorch: 1,
    pixelClock: 148500000,
  );
  const pitch = 2048;
  final pixelClk = SimpleClockGenerator(_pixelPs).clk;
  final sysClk = SimpleClockGenerator(sysPs).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final memory = HarborMemoryWaist(
    const HarborMemoryWaistConfig(
      addressWidth: 32,
      dataWidth: 32,
      outstanding: 4,
    ),
  );
  final disp = HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: timing,
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    sysClk: sysClk,
    sysReset: sysReset,
    enable: Const(1),
    fbBase: Const(_y, width: 32),
    memory: memory,
    outputType: HarborDisplayInterface.parallelRgb,
    pixelFormat: HarborPixelFormat.nv12,
    planeBase: [Const(_c, width: 32)],
    planePitch: [Const(pitch, width: 32), Const(pitch, width: 32)],
    overlayFormats: const [HarborPixelFormat.xrgb8888],
    overlayEnable: Const(1),
    overlayBase: [Const(_ov, width: 32)],
    overlayPitch: [Const(_ovPitch, width: 32)],
    overlaySrcX: Const(0, width: 12),
    overlaySrcY: Const(0, width: 3),
    overlayDstX: Const(0, width: 12),
    overlayDstY: Const(0, width: 3),
    overlayWidth: Const(_hActive, width: 12),
    overlayHeight: Const(timing.vActive, width: 3),
    overlayAlpha: Const(128, width: 8),
  );
  await disp.build();
  WaistMemory(memory, sysClk, latency: _latency, depth: 4);
  final gen = disp.subModules.whereType<VideoTimingGenerator>().single;

  pixelReset.inject(1);
  sysReset.inject(1);
  Simulator.setMaxSimTime(1 << 40);
  unawaited(Simulator.run());
  await pixelClk.nextPosedge;
  await pixelClk.nextPosedge;
  pixelReset.inject(0);
  sysReset.inject(0);

  // The first frame start, then the frame it primes.
  var frame = 0;
  var flag = false;
  while (true) {
    await pixelClk.nextNegedge;
    final (x, y) = (gen.x.value.toInt(), gen.y.value.toInt());
    if (x == 0 && y == timing.vActive) frame++;
    if (frame == 2) break;
    if (frame == 1 && y == timing.vActive - 1 && x == _hActive) {
      flag = disp.underrun.value.toInt() == 1;
    }
  }
  final count = disp.output('overlay_underrun_count_0').value.toInt();
  print(
    'nv12 + full screen xrgb8888 overlay on the display, 1080p60 lines, '
    'memory ${(1e6 / sysPs).toStringAsFixed(0)} MHz: overlay underrun '
    'count $count, underrun $flag, plane underrun counts '
    '${[for (var k = 0; k < 2; k++) disp.output('plane_underrun_count_$k').value.toInt()]}',
  );
  return (count, flag);
}

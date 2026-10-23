import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'overlay_reference.dart';
import 'plane_memory.dart';

const _memConfig = HarborMemoryWaistConfig(
  addressWidth: 32,
  dataWidth: 32,
  outstanding: 4,
);

/// A 16x8 mode with 6 clocks of horizontal blank.
const _timing = HarborDisplayTiming(
  hActive: 16,
  hFrontPorch: 2,
  hSyncWidth: 2,
  hBackPorch: 2,
  vActive: 8,
  vFrontPorch: 2,
  vSyncWidth: 1,
  vBackPorch: 2,
  pixelClock: 1000000,
);

const _primary = PlaneLayout([0x1000, 0x4000], [128, 128]);
const _overlay = PlaneLayout([0x10000, 0x20000, 0x30000], [128, 128, 128]);

/// A word of memory at byte address [a].
int _word(int a) {
  var v = (a * 0x9e3779b1 + 0x7f4a7c15) & 0xffffffff;
  v ^= v >> 15;
  v = (v * 0x2c1b3c6d) & 0xffffffff;
  return v ^ (v >> 12);
}

int _byte(int a) => (_word(a & ~3) >> (8 * (a & 3))) & 0xff;

/// Runs one frame for each of [states] on a display with the primary
/// format [primary] and the overlay set [overlay], after two frames that
/// prime it. The test sets the overlay inputs for frame f + 1 at pixel
/// (1, 0) of frame f. Every active pixel must match [overlayFrame], and
/// the overlay requests of each frame must be [overlayFetches].
Future<void> _run({
  required HarborPixelFormat primary,
  required List<HarborPixelFormat> overlay,
  required List<OverlayFrame> states,
  HarborCscCoefficients? csc,
}) async {
  final ovCsc = csc ?? HarborCscCoefficients.bt601Limited;
  final pixelClk = SimpleClockGenerator(20).clk;
  final sysClk = SimpleClockGenerator(4).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final memory = HarborMemoryWaist(_memConfig);
  final planar = primary.planes.length > 1;
  final n = overlay.map((f) => f.planes.length).reduce((a, b) => a > b ? a : b);
  final enable = Logic(name: 'ov_enable');
  final sel = overlay.length > 1
      ? Logic(name: 'ov_sel', width: (overlay.length - 1).bitLength)
      : null;
  final srcX = Logic(width: 5);
  final srcY = Logic(width: 4);
  final dstX = Logic(width: 5);
  final dstY = Logic(width: 4);
  final width = Logic(width: 5);
  final height = Logic(width: 4);
  final alpha = Logic(width: 8);
  final coeff = [for (var k = 0; k < 9; k++) Logic(width: 16)];
  final inOff = [for (var j = 0; j < 3; j++) Logic(width: 10)];
  final outOff = [for (var i = 0; i < 3; i++) Logic(width: 8)];
  final ovYuv = overlay.any((f) => f.yuv);
  final disp = HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: _timing,
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    sysClk: sysClk,
    sysReset: sysReset,
    enable: Const(1),
    fbBase: Const(_primary.base[0], width: 32),
    memory: memory,
    outputType: HarborDisplayInterface.parallelRgb,
    pixelFormat: primary,
    lineStride: planar ? null : _primary.pitch[0],
    planeBase: planar ? [Const(_primary.base[1], width: 32)] : const [],
    planePitch: planar
        ? [for (final p in _primary.pitch) Const(p, width: 32)]
        : const [],
    overlayFormats: overlay,
    overlayEnable: enable,
    overlayFormatSel: sel,
    overlayBase: [
      for (var j = 0; j < n; j++) Const(_overlay.base[j], width: 32),
    ],
    overlayPitch: [
      for (var j = 0; j < n; j++) Const(_overlay.pitch[j], width: 32),
    ],
    overlaySrcX: srcX,
    overlaySrcY: srcY,
    overlayDstX: dstX,
    overlayDstY: dstY,
    overlayWidth: width,
    overlayHeight: height,
    overlayAlpha: alpha,
    overlayCscCoeff: ovYuv ? coeff : null,
    overlayCscInOffset: ovYuv ? inOff : null,
    overlayCscOutOffset: ovYuv ? outOff : null,
  );
  await disp.build();
  final mem = WaistMemory(memory, sysClk, latency: 4, data: _word);
  final gen = disp.subModules.whereType<VideoTimingGenerator>().single;
  final delay = disp.pipelineDelay;

  void set(OverlayFrame s) {
    enable.inject(s.enable ? 1 : 0);
    sel?.inject(s.format);
    srcX.inject(s.srcX);
    srcY.inject(s.srcY);
    dstX.inject(s.dstX);
    dstY.inject(s.dstY);
    width.inject(s.width);
    height.inject(s.height);
    alpha.inject(s.alpha);
    final regs = ovCsc.registers();
    for (var k = 0; k < 9; k++) {
      coeff[k].inject(regs[k]);
    }
    for (var j = 0; j < 3; j++) {
      inOff[j].inject(regs[9 + j]);
      outOff[j].inject(regs[12 + j]);
    }
  }

  // Frames 0 and 1 prime the display with an overlay off, frame f + 2
  // shows states[f].
  const off = OverlayFrame(
    enable: false,
    dstX: 0,
    dstY: 0,
    width: 0,
    height: 0,
  );
  OverlayFrame stateOf(int f) =>
      f < 2 || f - 2 >= states.length ? off : states[f - 2];
  final want = <int, List<List<List<int>>>>{};
  List<List<List<int>>> frameOf(int f) => want.putIfAbsent(f, () {
    final s = stateOf(f);
    return overlayFrame(
      hActive: _timing.hActive,
      vActive: _timing.vActive,
      primary: (y) => surfaceLine(
        format: primary,
        layout: _primary,
        byte: _byte,
        line: y,
        x0: 0,
        width: _timing.hActive,
        csc: HarborCscCoefficients.bt709Limited,
      ),
      format: overlay[s.format],
      layout: _overlay,
      byte: _byte,
      state: s,
      csc: ovCsc,
    );
  });

  pixelReset.inject(1);
  sysReset.inject(1);
  set(off);
  Simulator.setMaxSimTime(1 << 40);
  unawaited(Simulator.run());
  addTearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    Simulator.reset();
  });
  await pixelClk.nextPosedge;
  await pixelClk.nextPosedge;
  pixelReset.inject(0);
  sysReset.inject(0);

  final frames = states.length + 2;
  final history = <int>[];
  // The index in the requests where the requests of frame f start.
  final firstRequest = <int, int>{};
  var frame = -1;
  var checked = 0;
  while (frame < frames) {
    await pixelClk.nextNegedge;
    final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
    if (gx == 0 && gy == 0) frame++;
    if (gx == 0 && gy == _timing.vActive) {
      firstRequest[frame + 1] = mem.requests.length;
    }
    history.add(frame);
    if (gx == 1 && gy == 0 && frame >= 0) set(stateOf(frame + 1));
    if (history.length <= delay) continue;
    final f = history[history.length - 1 - delay];
    if (f < 2 || f >= frames || disp.de.value.toInt() != 1) continue;
    final (px, py) = (disp.x.value.toInt(), disp.y.value.toInt());
    expect(
      [
        disp.red.value.toInt(),
        disp.green.value.toInt(),
        disp.blue.value.toInt(),
      ],
      frameOf(f)[py][px],
      reason: 'frame $f ($px, $py) ${stateOf(f)}',
    );
    checked++;
  }
  expect(checked, states.length * _timing.hActive * _timing.vActive);

  // The overlay requests of each frame, joined into lines.
  for (var f = 2; f < frames; f++) {
    final lines = <(int, int)>[];
    for (final (a, beats) in mem.requests.sublist(
      firstRequest[f]!,
      firstRequest[f + 1]!,
    )) {
      if (a < _overlay.base[0]) continue;
      if (lines.isNotEmpty && lines.last.$1 + 4 * lines.last.$2 == a) {
        lines.last = (lines.last.$1, lines.last.$2 + beats);
      } else {
        lines.add((a, beats));
      }
    }
    final s = stateOf(f);
    final fetches = overlayFetches(
      hActive: _timing.hActive,
      vActive: _timing.vActive,
      format: overlay[s.format],
      layout: _overlay,
      state: s,
    );
    expect(
      lines.toSet(),
      fetches.toSet(),
      reason: 'frame $f overlay fetches $s',
    );
    expect(lines, hasLength(fetches.length), reason: 'frame $f twice');
  }
  for (var j = 0; j < n; j++) {
    expect(disp.output('overlay_underrun_count_$j').value.toInt(), 0);
  }
  expect(disp.underrun.value.toInt(), 0);
}

void main() {
  // Placement, crop, alpha and enable for each format of a 4:2:0 set.
  test('a 4:2:0 overlay over xrgb8888 matches the reference', () {
    return _run(
      primary: HarborPixelFormat.xrgb8888,
      overlay: const [
        HarborPixelFormat.nv12,
        HarborPixelFormat.p010,
        HarborPixelFormat.i420,
      ],
      states: const [
        OverlayFrame(dstX: 0, dstY: 0, width: 16, height: 8),
        OverlayFrame(
          srcX: 2,
          srcY: 2,
          dstX: 0,
          dstY: 0,
          width: 5,
          height: 3,
          alpha: 128,
        ),
        OverlayFrame(
          format: 1,
          srcX: 6,
          srcY: 4,
          dstX: 13,
          dstY: 0,
          width: 6,
          height: 3,
        ),
        OverlayFrame(
          format: 2,
          srcX: 4,
          srcY: 2,
          dstX: 0,
          dstY: 6,
          width: 4,
          height: 5,
          alpha: 200,
        ),
        OverlayFrame(srcX: 10, dstX: 12, dstY: 5, width: 8, height: 6),
        OverlayFrame(
          format: 1,
          srcX: 8,
          srcY: 2,
          dstX: 7,
          dstY: 2,
          width: 1,
          height: 4,
        ),
        OverlayFrame(
          format: 2,
          srcX: 2,
          srcY: 6,
          dstX: 2,
          dstY: 7,
          width: 9,
          height: 1,
        ),
        OverlayFrame(dstX: 0, dstY: 0, width: 16, height: 8, alpha: 0),
        OverlayFrame(enable: false, dstX: 0, dstY: 0, width: 16, height: 8),
        OverlayFrame(
          format: 2,
          srcX: 6,
          srcY: 2,
          dstX: 3,
          dstY: 1,
          width: 10,
          height: 5,
          alpha: 77,
        ),
        OverlayFrame(
          srcX: 6,
          srcY: 4,
          dstX: 1,
          dstY: 1,
          width: 14,
          height: 6,
          alpha: 255,
        ),
        OverlayFrame(
          format: 1,
          srcX: 5,
          srcY: 3,
          dstX: 2,
          dstY: 1,
          width: 7,
          height: 4,
        ),
        OverlayFrame(dstX: 20, dstY: 0, width: 4, height: 4),
        OverlayFrame(dstX: 0, dstY: 9, width: 4, height: 4),
        OverlayFrame(dstX: 0, dstY: 0, width: 0, height: 4),
      ],
    );
  });

  // Packed RGB crops start on any pixel, so rgb565 starts mid-word.
  test('a packed rgb overlay over nv12 matches the reference', () {
    return _run(
      primary: HarborPixelFormat.nv12,
      overlay: const [HarborPixelFormat.xrgb8888, HarborPixelFormat.rgb565],
      states: const [
        OverlayFrame(
          srcX: 3,
          srcY: 1,
          dstX: 0,
          dstY: 0,
          width: 16,
          height: 8,
          alpha: 128,
        ),
        OverlayFrame(
          format: 1,
          srcX: 3,
          srcY: 5,
          dstX: 2,
          dstY: 1,
          width: 9,
          height: 5,
        ),
        OverlayFrame(
          format: 1,
          srcX: 0,
          dstX: 11,
          dstY: 4,
          width: 8,
          height: 6,
          alpha: 255,
        ),
        OverlayFrame(
          format: 1,
          srcX: 7,
          srcY: 3,
          dstX: 0,
          dstY: 3,
          width: 1,
          height: 1,
          alpha: 255,
        ),
        OverlayFrame(
          srcX: 2,
          dstX: 15,
          dstY: 7,
          width: 3,
          height: 3,
          alpha: 31,
        ),
        OverlayFrame(enable: false, dstX: 0, dstY: 0, width: 16, height: 8),
      ],
    );
  });

  test('a yuyv overlay matches the reference', () {
    return _run(
      primary: HarborPixelFormat.xrgb8888,
      overlay: const [HarborPixelFormat.yuyv],
      csc: HarborCscCoefficients.bt2020Full,
      states: const [
        OverlayFrame(srcX: 2, srcY: 1, dstX: 1, dstY: 0, width: 6, height: 8),
        OverlayFrame(
          srcX: 6,
          srcY: 3,
          dstX: 9,
          dstY: 2,
          width: 5,
          height: 4,
          alpha: 128,
        ),
        OverlayFrame(
          srcX: 3,
          dstX: 0,
          dstY: 0,
          width: 16,
          height: 8,
          alpha: 254,
        ),
      ],
    );
  });
}

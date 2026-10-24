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
/// [setAt] of frame f. Every active pixel must match [overlayFrame], and
/// the overlay requests of each frame must be [overlayFetches]. No frame
/// may fetch a word twice.
///
/// [slow] makes the prime of a state slow: for state i, request n after
/// its frame start has latency l when `slow[i]` is (n, l). Then the first
/// [lateRows] rows of that frame are not checked, and neither are its
/// overlay requests. The underrun counts named in [late] must be more than
/// 0, and the others 0. With [surfaceWidth], no overlay request may go
/// past the end of a surface line of that many pixels. With [port], the
/// display reads a scanout port model in place of the memory waist.
/// [clocks] are the pixel and system clock periods.
Future<void> _run({
  required HarborPixelFormat primary,
  required List<HarborPixelFormat> overlay,
  required List<OverlayFrame> states,
  HarborCscCoefficients? csc,
  (int, int) setAt = (1, 0),
  Map<int, (int, int)> slow = const {},
  int lateRows = 2,
  Set<String> late = const {},
  int? surfaceWidth,
  bool port = false,
  (int, int) clocks = (20, 4),
}) async {
  final ovCsc = csc ?? HarborCscCoefficients.bt601Limited;
  final pixelClk = SimpleClockGenerator(clocks.$1).clk;
  final sysClk = SimpleClockGenerator(clocks.$2).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final memory = port ? null : HarborMemoryWaist(_memConfig);
  final rqReady = Logic(name: 'rq_ready');
  final rdValid = Logic(name: 'rd_valid');
  final rdData = Logic(name: 'rd_data', width: 16);
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
  final update = Logic(name: 'update');
  final disp = HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: _timing,
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    sysClk: sysClk,
    sysReset: sysReset,
    enable: Const(1),
    update: update,
    fbBase: Const(_primary.base[0], width: 32),
    memory: memory,
    rqReady: port ? rqReady : null,
    rdValid: port ? rdValid : null,
    rdData: port ? rdData : null,
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
  // Each request as (byte address, 32-bit words).
  final List<(int, int)> Function() requests;
  final int Function() count;
  final void Function(int) setLatency;
  if (port) {
    final m = PortMemory(
      rqValid: disp.rqValid,
      rqAddr: disp.rqAddr,
      rqWords: disp.rqWords,
      rqReady: rqReady,
      rdValid: rdValid,
      rdData: rdData,
      clk: sysClk,
      data: _word,
    );
    requests = () => [for (final (a, n) in m.requests) (a, n ~/ 2)];
    count = () => m.requests.length;
    setLatency = (l) => m.latency = l;
  } else {
    final m = WaistMemory(memory!, sysClk, latency: 4, data: _word);
    requests = () => m.requests;
    count = () => m.requests.length;
    setLatency = (l) => m.latency = l;
  }
  final gen = disp.subModules.whereType<VideoTimingGenerator>().single;
  final delay = disp.pipelineDelay;

  // A register block writes the inputs, then pulses update. The values
  // at reset need no update, because frame 0 shows nothing.
  void set(OverlayFrame s, {bool pulse = true}) {
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
    if (pulse) pulseUpdate(update, sysClk);
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
  update.inject(0);
  set(off, pulse: false);
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
  // The request index and latency of the slow request of the next frame.
  (int, int)? slowAt;
  final slowSeen = <int>{};
  bool isSlow(int f) => slow.containsKey(f - 2);
  while (frame < frames) {
    await pixelClk.nextNegedge;
    final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
    if (gx == 0 && gy == 0) frame++;
    if (gx == 0 && gy == _timing.vActive) {
      firstRequest[frame + 1] = count();
      if (slow[frame + 1 - 2] case (final n, final l)) {
        slowAt = (count() + n, l);
      }
    }
    if (slowAt case (final at, final l)) {
      if (count() == at) {
        setLatency(l);
      } else if (count() > at) {
        setLatency(4);
        slowAt = null;
      }
    }
    if (isSlow(frame) && gy == 4 && disp.underrun.value.toInt() == 1) {
      slowSeen.add(frame);
    }
    history.add(frame);
    if ((gx, gy) == setAt && frame >= 0) set(stateOf(frame + 1));
    if (history.length <= delay) continue;
    final f = history[history.length - 1 - delay];
    if (f < 2 || f >= frames || disp.de.value.toInt() != 1) continue;
    final (px, py) = (disp.x.value.toInt(), disp.y.value.toInt());
    if (isSlow(f) && py < lateRows) continue;
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
  expect(
    checked,
    (states.length * _timing.vActive - slow.length * lateRows) *
        _timing.hActive,
  );

  // A frame fetches each word at most once, also a slow frame.
  for (var f = 2; f < frames; f++) {
    final words = [
      for (final (a, n) in requests().sublist(
        firstRequest[f]!,
        firstRequest[f + 1]!,
      ))
        for (var i = 0; i < n; i++) a + 4 * i,
    ];
    expect(
      words.length,
      words.toSet().length,
      reason: 'frame $f fetches a word twice',
    );
  }

  // The overlay requests of each frame, joined into lines.
  for (var f = 2; f < frames; f++) {
    if (isSlow(f)) continue;
    final lines = <(int, int)>[];
    for (final (a, beats) in requests().sublist(
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
    if (surfaceWidth != null) {
      final format = overlay[s.format];
      for (final (a, beats) in requests().sublist(
        firstRequest[f]!,
        firstRequest[f + 1]!,
      )) {
        if (a < _overlay.base[0]) continue;
        final k = _overlay.base.lastIndexWhere((b) => b <= a);
        final end = (a - _overlay.base[k]) % _overlay.pitch[k] + 4 * beats;
        expect(
          end,
          lessThanOrEqualTo(format.lineBytes(k, surfaceWidth)),
          reason: 'frame $f plane $k request at $a $s',
        );
      }
    }
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
  final counts = [
    for (final name in disp.outputs.keys)
      if (name.contains('underrun_count')) name,
  ];
  for (final name in counts) {
    expect(
      disp.output(name).value.toInt(),
      late.contains(name) ? greaterThan(0) : 0,
      reason: name,
    );
  }
  expect(late.difference(counts.toSet()), isEmpty);
  expect(slowSeen, {for (final i in slow.keys) i + 2});
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

  // The crop ends at the right edge of a surface of 16 pixels, on the
  // screen, so no plane fetches the word after the line.
  test('a crop to the full surface width fetches no word past the line', () {
    return _run(
      primary: HarborPixelFormat.xrgb8888,
      overlay: const [
        HarborPixelFormat.nv12,
        HarborPixelFormat.yuyv,
        HarborPixelFormat.i420,
        HarborPixelFormat.p010,
      ],
      surfaceWidth: 16,
      states: const [
        OverlayFrame(dstX: 0, dstY: 0, width: 16, height: 8),
        OverlayFrame(
          format: 1,
          dstX: 0,
          dstY: 0,
          width: 16,
          height: 8,
          alpha: 128,
        ),
        OverlayFrame(
          format: 2,
          srcX: 6,
          srcY: 2,
          dstX: 0,
          dstY: 1,
          width: 10,
          height: 5,
        ),
        OverlayFrame(format: 3, dstX: 0, dstY: 2, width: 16, height: 4),
        OverlayFrame(
          format: 1,
          srcX: 4,
          dstX: 4,
          dstY: 2,
          width: 12,
          height: 3,
          alpha: 200,
        ),
      ],
    );
  });

  // Each state changes in the middle of the frame before it.
  test('an overlay change takes effect at the next frame start', () {
    return _run(
      primary: HarborPixelFormat.xrgb8888,
      overlay: const [HarborPixelFormat.nv12, HarborPixelFormat.rgb565],
      setAt: (9, 4),
      states: const [
        OverlayFrame(srcX: 2, dstX: 1, dstY: 1, width: 9, height: 6),
        OverlayFrame(
          format: 1,
          srcX: 5,
          srcY: 3,
          dstX: 6,
          dstY: 3,
          width: 7,
          height: 4,
          alpha: 99,
        ),
        OverlayFrame(enable: false, dstX: 0, dstY: 0, width: 16, height: 8),
        OverlayFrame(
          srcX: 4,
          srcY: 4,
          dstX: 0,
          dstY: 0,
          width: 16,
          height: 8,
          alpha: 180,
        ),
      ],
    );
  });

  for (final port in [false, true]) {
    final mode = port ? 'a scanout port' : 'a memory waist';

    // Line 0 comes so late that the first line start comes before the
    // prime ends. Rows 0 and 1 are late, and the rows after them must be
    // the correct rows.
    test('a line start in the prime counts the late lines on $mode', () {
      const full = OverlayFrame(
        dstX: 0,
        dstY: 0,
        width: 16,
        height: 8,
        alpha: 128,
      );
      const low = OverlayFrame(
        srcX: 2,
        srcY: 2,
        dstX: 2,
        dstY: 3,
        width: 10,
        height: 4,
      );
      return _run(
        primary: HarborPixelFormat.xrgb8888,
        overlay: const [HarborPixelFormat.nv12],
        states: const [full, full, low, low],
        slow: const {0: (0, 620), 2: (0, 620)},
        late: const {
          'plane_underrun_count_0',
          'overlay_underrun_count_0',
          'overlay_underrun_count_1',
        },
        port: port,
      );
    });

    // Primary line 1 comes so late that the first line start comes in the
    // second prime step, before overlay line 1 goes.
    test('a line start in the second prime step counts the late lines on '
        '$mode', () {
      const top = OverlayFrame(dstX: 0, dstY: 0, width: 16, height: 8);
      const inside = OverlayFrame(
        dstX: 1,
        dstY: 1,
        width: 12,
        height: 6,
        alpha: 99,
      );
      return _run(
        primary: HarborPixelFormat.nv12,
        overlay: const [HarborPixelFormat.xrgb8888],
        states: const [top, top, inside, inside],
        slow: const {0: (2, 580), 2: (2, 580)},
        late: {
          'plane_underrun_count_0',
          'overlay_underrun_count_0',
          if (port) 'plane_underrun_count_1',
        },
        port: port,
      );
    });
  }

  // The pixel clock period is 2 system clocks. Line 0 is so late that the
  // second prime step sends its request one or two pixel clocks before the
  // first line start. The line start must not send its lines before the
  // system side took that request. An overlay at screen line 3 keeps the
  // prime in phase 2 until its line 0 is done.
  test('a line start just after the second prime step waits for its '
      'request', () {
    const top = OverlayFrame(
      srcX: 3,
      dstX: 0,
      dstY: 0,
      width: 4,
      height: 8,
      alpha: 128,
    );
    const low = OverlayFrame(
      srcX: 3,
      dstX: 2,
      dstY: 3,
      width: 4,
      height: 4,
      alpha: 128,
    );
    return _run(
      primary: HarborPixelFormat.nv12,
      overlay: const [HarborPixelFormat.xrgb8888],
      states: const [top, top, top, top, low, low],
      slow: const {
        0: (0, 220),
        1: (0, 221),
        2: (0, 222),
        3: (0, 223),
        4: (0, 222),
        5: (0, 223),
      },
      lateRows: 3,
      late: const {
        'plane_underrun_count_0',
        'plane_underrun_count_1',
        'overlay_underrun_count_0',
      },
      clocks: (8, 4),
    );
  });

  // Overlay line 0 is on screen line 0 only, and comes after the first
  // pixel of line 0. Nothing else in the frame is late.
  test('a late overlay line 0 on screen line 0 counts', () {
    const row0 = OverlayFrame(
      dstX: 0,
      dstY: 0,
      width: 16,
      height: 1,
      alpha: 128,
    );
    return _run(
      primary: HarborPixelFormat.xrgb8888,
      overlay: const [HarborPixelFormat.xrgb8888],
      states: const [row0, row0],
      slow: const {0: (2, 540), 1: (2, 570)},
      lateRows: 1,
      late: const {'overlay_underrun_count_0'},
    );
  });

  HarborDualClockDisplay build(
    HarborPixelFormat primary, {
    List<HarborPixelFormat>? overlay,
    HarborDisplayTiming timing = _timing,
  }) {
    final n = overlay
        ?.map((f) => f.planes.length)
        .reduce((a, b) => a > b ? a : b);
    final planar = primary.planes.length > 1;
    return HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: Logic(),
      pixelReset: Logic(),
      sysClk: Logic(),
      sysReset: Logic(),
      enable: Logic(),
      update: Const(1),
      fbBase: Logic(width: 32),
      memory: HarborMemoryWaist(_memConfig),
      outputType: HarborDisplayInterface.parallelRgb,
      pixelFormat: primary,
      planeBase: planar ? [Logic(width: 32)] : const [],
      planePitch: planar ? [Logic(width: 32), Logic(width: 32)] : const [],
      overlayFormats: overlay,
      overlayEnable: overlay == null ? null : Logic(),
      overlayFormatSel: (overlay?.length ?? 0) > 1 ? Logic(width: 1) : null,
      overlayBase: [for (var j = 0; j < (n ?? 0); j++) Logic(width: 32)],
      overlayPitch: [for (var j = 0; j < (n ?? 0); j++) Logic(width: 32)],
      overlaySrcX: overlay == null ? null : Logic(width: 5),
      overlaySrcY: overlay == null ? null : Logic(width: 4),
      overlayDstX: overlay == null ? null : Logic(width: 5),
      overlayDstY: overlay == null ? null : Logic(width: 4),
      overlayWidth: overlay == null ? null : Logic(width: 5),
      overlayHeight: overlay == null ? null : Logic(width: 4),
      overlayAlpha: overlay == null ? null : Logic(width: 8),
    );
  }

  test('a build without an overlay has no overlay ports or logic', () async {
    for (final f in [HarborPixelFormat.xrgb8888, HarborPixelFormat.nv12]) {
      final d = build(f);
      await d.build();
      final ports = [...d.inputs.keys, ...d.outputs.keys];
      expect(ports.where((p) => p.contains('overlay')), isEmpty);
      expect(d.blend, isNull);
      expect(d.overlayUnpack, isNull);
      expect(d.pipelineDelay, f.yuv ? 9 : 2);
      expect(d.generateSynth(), isNot(contains('overlay')));
    }
  });

  test('an overlay build has the overlay ports and its own name', () async {
    const nv12 = HarborPixelFormat.nv12;
    const xrgb = HarborPixelFormat.xrgb8888;
    final cases = [
      (xrgb, [xrgb], 7),
      (xrgb, [nv12], 12),
      (nv12, [xrgb], 12),
      (nv12, [nv12, xrgb], 12),
    ];
    final names = <String>{};
    for (final (p, o, delay) in cases) {
      final d = build(p, overlay: o);
      await d.build();
      expect(d.pipelineDelay, delay, reason: '${p.name} $o');
      names.add(d.definitionName);
      final n = o.map((f) => f.planes.length).reduce((a, b) => a > b ? a : b);
      final ins = {for (final e in d.inputs.entries) e.key: e.value.width};
      final outs = {for (final e in d.outputs.entries) e.key: e.value.width};
      expect(ins, containsPair('overlay_enable', 1));
      expect(ins, containsPair('overlay_alpha', 8));
      for (final x in ['src_x', 'dst_x', 'width']) {
        expect(ins, containsPair('overlay_$x', 5));
      }
      for (final y in ['src_y', 'dst_y', 'height']) {
        expect(ins, containsPair('overlay_$y', 4));
      }
      for (var j = 0; j < n; j++) {
        expect(ins, containsPair('overlay_base_$j', 32));
        expect(ins, containsPair('overlay_pitch_$j', 32));
        expect(outs, containsPair('overlay_underrun_count_$j', 16));
      }
      expect(outs, containsPair('overlay_underrun', n));
      expect(outs, containsPair('plane_underrun_count_0', 16));
      expect(ins.containsKey('overlay_format_sel'), o.length > 1);
      expect(ins.containsKey('overlay_csc_coeff_8'), o.any((f) => f.yuv));
      expect(d.overlayCsc == null, !o.any((f) => f.yuv));
    }
    expect(names, hasLength(cases.length));
  });

  test('a YUV overlay needs 2 clocks of horizontal blank', () {
    HarborDisplayTiming blank(int n) => HarborDisplayTiming(
      hActive: 16,
      hFrontPorch: n,
      hSyncWidth: 0,
      hBackPorch: 0,
      vActive: 8,
      vFrontPorch: 1,
      vSyncWidth: 1,
      vBackPorch: 1,
      pixelClock: 1000000,
    );
    const nv12 = HarborPixelFormat.nv12;
    const xrgb = HarborPixelFormat.xrgb8888;
    expect(
      () => build(xrgb, overlay: [nv12], timing: blank(1)),
      throwsArgumentError,
    );
    expect(
      () => build(xrgb, overlay: [nv12], timing: blank(2)),
      returnsNormally,
    );
    expect(
      () => build(xrgb, overlay: [xrgb], timing: blank(0)),
      returnsNormally,
    );
  });
}

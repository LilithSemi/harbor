import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'plane_memory.dart';

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

const _memConfig = HarborMemoryWaistConfig(
  addressWidth: 32,
  dataWidth: 32,
  outstanding: 4,
);

/// One value for each control input of the test build.
class _Set {
  final int format;
  final List<int> base;
  final List<int> pitch;
  final List<int> csc;
  final bool ovEnable;
  final int ovFormat;
  final List<int> ovBase;
  final List<int> ovPitch;
  final int srcX;
  final int srcY;
  final int dstX;
  final int dstY;
  final int width;
  final int height;
  final int alpha;
  final List<int> ovCsc;

  /// Set [i]. Each value is different in the next set. Each pitch has its
  /// low 2 bits set, which the display ignores.
  _Set(int i)
    : format = i & 1,
      base = [0x10000 + 0x4000 * i, 0x100000 + 0x4000 * i],
      pitch = [0x103 + 0x40 * i, 0x81 + 0x40 * i],
      csc = [
        for (var k = 0; k < 9; k++) 0x100 * (i + 1) + k,
        for (var j = 0; j < 3; j++) 16 * (i + 1) + j,
        for (var j = 0; j < 3; j++) 8 * (i + 1) + j,
      ],
      ovEnable = i.isEven,
      ovFormat = (i + 1) & 1,
      ovBase = [0x200000 + 0x4000 * i, 0x300000 + 0x4000 * i],
      ovPitch = [0x202 + 0x40 * i, 0x101 + 0x40 * i],
      srcX = 2 * (i + 1),
      srcY = 2 * (i % 3),
      dstX = i + 1,
      dstY = (i + 2) % 5,
      width = 4 + i,
      height = 1 + i,
      alpha = 40 + 50 * i,
      ovCsc = [
        for (var k = 0; k < 9; k++) 0x200 * (i + 1) + k,
        for (var j = 0; j < 3; j++) 32 * (i + 1) + j,
        for (var j = 0; j < 3; j++) 4 * (i + 1) + j,
      ];

  /// The frame registers that this set gives, by signal name. An
  /// xrgb8888 frame does not fetch plane 1, so it has no `base_1`.
  Map<String, int> get frame => {
    'format_reg': format,
    'base_0': base[0],
    if (format == 0) 'base_1': base[1],
    'p0_pitch': pitch[0] & ~3,
    'p1_pitch': pitch[1] & ~3,
    for (final (k, n) in _cscNames('csc').indexed) '${n}_frame': csc[k],
    'ov_enable_frame': ovEnable ? 1 : 0,
    'ov_format': ovFormat,
    'ov0_base': ovBase[0],
    'ov1_base': ovBase[1],
    'p2_pitch': ovPitch[0] & ~3,
    'p3_pitch': ovPitch[1] & ~3,
    'ov_src_x': srcX,
    'ov_src_y': srcY,
    'ov_dst_x': dstX,
    'ov_dst_y': dstY,
    'ov_width': width,
    'ov_height': height,
    'overlay_alpha_frame': alpha,
    for (final (k, n) in _cscNames('overlay_csc').indexed)
      '${n}_frame': ovCsc[k],
  };
}

List<String> _cscNames(String prefix) => [
  for (var k = 0; k < 9; k++) '${prefix}_coeff_$k',
  for (var j = 0; j < 3; j++) '${prefix}_in_offset_$j',
  for (var i = 0; i < 3; i++) '${prefix}_out_offset_$i',
];

/// An nv12 and xrgb8888 display with an xrgb8888 and nv12 overlay, so it
/// has two plane bases, two color conversions and an overlay.
class _Bench {
  final pixelClk = SimpleClockGenerator(20).clk;
  final sysClk = SimpleClockGenerator(4).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final update = Logic(name: 'update');
  final format = Logic(name: 'format', width: 1);
  final base = [for (var k = 0; k < 2; k++) Logic(width: 32)];
  final pitch = [for (var k = 0; k < 2; k++) Logic(width: 32)];
  final csc = [
    for (var k = 0; k < 15; k++) Logic(width: k < 9 ? 16 : (k < 12 ? 10 : 8)),
  ];
  final ovEnable = Logic(name: 'ov_enable');
  final ovFormat = Logic(name: 'ov_format_sel', width: 1);
  final ovBase = [for (var k = 0; k < 2; k++) Logic(width: 32)];
  final ovPitch = [for (var k = 0; k < 2; k++) Logic(width: 32)];
  final srcX = Logic(width: 5);
  final srcY = Logic(width: 4);
  final dstX = Logic(width: 5);
  final dstY = Logic(width: 4);
  final width = Logic(width: 5);
  final height = Logic(width: 4);
  final alpha = Logic(width: 8);
  final ovCsc = [
    for (var k = 0; k < 15; k++) Logic(width: k < 9 ? 16 : (k < 12 ? 10 : 8)),
  ];
  final memory = HarborMemoryWaist(_memConfig);
  late final HarborDualClockDisplay display;
  late final HarborDualClockScanout scanout;
  late final VideoTimingGenerator gen;

  _Bench() {
    display = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: _timing,
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
      enable: Const(1),
      update: update,
      fbBase: base[0],
      memory: memory,
      outputType: HarborDisplayInterface.parallelRgb,
      formats: const [HarborPixelFormat.nv12, HarborPixelFormat.xrgb8888],
      formatSel: format,
      planeBase: [base[1]],
      planePitch: pitch,
      cscCoeff: csc.sublist(0, 9),
      cscInOffset: csc.sublist(9, 12),
      cscOutOffset: csc.sublist(12),
      overlayFormats: const [
        HarborPixelFormat.xrgb8888,
        HarborPixelFormat.nv12,
      ],
      overlayEnable: ovEnable,
      overlayFormatSel: ovFormat,
      overlayBase: ovBase,
      overlayPitch: ovPitch,
      overlaySrcX: srcX,
      overlaySrcY: srcY,
      overlayDstX: dstX,
      overlayDstY: dstY,
      overlayWidth: width,
      overlayHeight: height,
      overlayAlpha: alpha,
      overlayCscCoeff: ovCsc.sublist(0, 9),
      overlayCscInOffset: ovCsc.sublist(9, 12),
      overlayCscOutOffset: ovCsc.sublist(12),
    );
  }

  /// The inputs in the order that [set] changes them.
  List<(Logic, int)> inputs(_Set s) => [
    (format, s.format),
    for (var k = 0; k < 2; k++) ...[
      (base[k], s.base[k]),
      (pitch[k], s.pitch[k]),
    ],
    for (var k = 0; k < 15; k++) (csc[k], s.csc[k]),
    (ovEnable, s.ovEnable ? 1 : 0),
    (ovFormat, s.ovFormat),
    for (var k = 0; k < 2; k++) ...[
      (ovBase[k], s.ovBase[k]),
      (ovPitch[k], s.ovPitch[k]),
    ],
    (srcX, s.srcX),
    (srcY, s.srcY),
    (dstX, s.dstX),
    (dstY, s.dstY),
    (width, s.width),
    (height, s.height),
    (alpha, s.alpha),
    for (var k = 0; k < 15; k++) (ovCsc[k], s.ovCsc[k]),
  ];

  void set(_Set s) {
    for (final (l, v) in inputs(s)) {
      l.inject(v);
    }
  }

  Future<void> start() async {
    await display.build();
    WaistMemory(memory, sysClk, latency: 4);
    gen = display.subModules.whereType<VideoTimingGenerator>().single;
    scanout = display.subModules.whereType<HarborDualClockScanout>().single;
    pixelReset.inject(1);
    sysReset.inject(1);
    update.inject(0);
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
  }

  Logic _sig(Module m, String n) => m.signals.firstWhere((s) => s.name == n);

  /// The frame registers, by the names of [_Set.frame], one clock after a
  /// frame start.
  Map<String, int> frame() {
    int v(Module m, String n) => _sig(m, n).value.toInt();
    final out = <String, int>{};
    for (final n in _Set(0).frame.keys) {
      if (n == 'base_1' && v(scanout, 'format_reg') == 1) continue;
      if (n.startsWith('base_')) {
        final k = n.substring(5);
        out[n] =
            (v(scanout, 'p${k}_next_addr') - v(scanout, 'p${k}_pitch')) &
            0xffffffff;
      } else if (n.endsWith('_frame') &&
          (n.startsWith('csc') || n.startsWith('overlay_'))) {
        out[n] = v(display, n);
      } else {
        out[n] = v(scanout, n);
      }
    }
    return out;
  }
}

/// The frame registers of each frame from 1 to [frames]. [onCycle] runs at
/// each pixel clock fall with the frame, x and y of the timing generator.
Future<Map<int, Map<String, int>>> _frames(
  _Bench b,
  int frames,
  FutureOr<void> Function(int frame, int x, int y) onCycle,
) async {
  final got = <int, Map<String, int>>{};
  var frame = -1;
  while (frame < frames) {
    await b.pixelClk.nextNegedge;
    final (gx, gy) = (b.gen.x.value.toInt(), b.gen.y.value.toInt());
    if (gx == 0 && gy == 0) frame++;
    if (gx == 1 && gy == _timing.vActive && frame >= 0) {
      got[frame + 1] = b.frame();
    }
    await onCycle(frame, gx, gy);
  }
  return got;
}

void main() {
  test('a mid-frame update takes effect at the next frame start and an '
      'input change without update changes nothing', () async {
    final b = _Bench();
    await b.start();
    b.set(_Set(0));
    pulseUpdate(b.update, b.sysClk);
    final pending = <(int, int, int), int>{};
    final got = await _frames(b, 6, (f, x, y) {
      pending[(f, x, y)] = b.display.updatePending.value.toInt();
      if (f == 2 && x == 0 && y == 3) b.set(_Set(1));
      if (f == 4 && x == 0 && y == 3) pulseUpdate(b.update, b.sysClk);
    });
    for (var f = 1; f <= 4; f++) {
      expect(got[f], _Set(0).frame, reason: 'frame $f');
    }
    for (var f = 5; f <= 6; f++) {
      expect(got[f], _Set(1).frame, reason: 'frame $f');
    }
    // High from the clock after the pulse until the take in the clock
    // before the frame start, then low.
    final high = [
      for (final MapEntry(key: (f, x, y), :value) in pending.entries)
        if (f == 4 && (y > 3 || (y == 3 && x > 0)) && y < _timing.vActive)
          value,
    ];
    expect(high, everyElement(1));
    expect(high.length, greaterThan(4 * _timing.hTotal));
    expect(pending[(4, 2, _timing.vActive)], 0);
    expect(pending[(3, 0, 5)], 0);
  });

  test('an update while one is pending waits and does not tear the '
      'set', () async {
    final b = _Bench();
    await b.start();
    b.set(_Set(0));
    pulseUpdate(b.update, b.sysClk);
    final pending = <(int, int, int), int>{};
    final got = await _frames(b, 6, (f, x, y) async {
      pending[(f, x, y)] = b.display.updatePending.value.toInt();
      if (f == 2 && x == 0 && y == 2) {
        b.set(_Set(2));
        pulseUpdate(b.update, b.sysClk);
      }
      // While set 2 waits for its take, the inputs change to set 3 one
      // input each system clock, then an update goes.
      if (f == 2 && x == 0 && y == 4) {
        for (final (l, v) in b.inputs(_Set(3))) {
          l.inject(v);
          await b.sysClk.nextPosedge;
        }
        pulseUpdate(b.update, b.sysClk);
      }
    });
    expect(got[1], _Set(0).frame);
    expect(got[2], _Set(0).frame);
    expect(got[3], _Set(2).frame);
    expect(got[4], _Set(3).frame);
    expect(got[5], _Set(3).frame);
    final high = [
      for (final MapEntry(key: (f, x, y), :value) in pending.entries)
        if ((f == 2 && (y > 2 || (y == 2 && x > 0))) ||
            (f == 3 && y < _timing.vActive))
          value,
    ];
    expect(high, everyElement(1));
    expect(pending[(3, 2, _timing.vActive)], 0);
  });

  test('an rgb build takes fb_base only at an update', () async {
    final pixelClk = SimpleClockGenerator(20).clk;
    final sysClk = SimpleClockGenerator(4).clk;
    final pixelReset = Logic(name: 'pixel_reset');
    final sysReset = Logic(name: 'sys_reset');
    final update = Logic(name: 'update');
    final fbBase = Logic(name: 'fb_base', width: 32);
    final memory = HarborMemoryWaist(_memConfig);
    final d = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: _timing,
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
      enable: Const(1),
      update: update,
      fbBase: fbBase,
      memory: memory,
      outputType: HarborDisplayInterface.parallelRgb,
    );
    await d.build();
    final m = WaistMemory(memory, sysClk, latency: 4);
    final gen = d.subModules.whereType<VideoTimingGenerator>().single;
    pixelReset.inject(1);
    sysReset.inject(1);
    update.inject(0);
    fbBase.inject(0x10000);
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
    pulseUpdate(update, sysClk);
    final first = <int, int>{};
    var frame = -1;
    var pendingAt = -1;
    while (frame < 5) {
      await pixelClk.nextNegedge;
      final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
      if (gx == 0 && gy == 0) frame++;
      if (gx == 0 && gy == _timing.vActive)
        first[frame + 1] = m.requests.length;
      if (frame == 1 && gx == 0 && gy == 2) fbBase.inject(0x20000);
      if (frame == 3 && gx == 0 && gy == 2) pulseUpdate(update, sysClk);
      if (frame == 3 && gx == 4 && gy == 2) {
        pendingAt = d.updatePending.value.toInt();
      }
    }
    int baseOf(int f) => m.requests[first[f]!].$1;
    expect(
      [for (var f = 1; f <= 5; f++) baseOf(f)],
      [0x10000, 0x10000, 0x10000, 0x20000, 0x20000],
    );
    expect(pendingAt, 1);
    expect(d.updatePending.value.toInt(), 0);
  });

  group('caps', () {
    HarborDualClockDisplay build(
      List<HarborPixelFormat> formats, {
      List<HarborPixelFormat>? overlay,
    }) {
      final planar = HarborDualClockScanout.isPlanar(formats);
      final planes = formats
          .map((f) => f.planes.length)
          .reduce((a, b) => a > b ? a : b);
      return HarborDualClockDisplay(
        target: const HarborSimTarget(),
        timing: _timing,
        pixelClk: Logic(),
        pixelReset: Logic(),
        sysClk: Logic(),
        sysReset: Logic(),
        enable: Logic(),
        update: Logic(),
        fbBase: Logic(width: 32),
        memory: HarborMemoryWaist(_memConfig),
        outputType: HarborDisplayInterface.parallelRgb,
        formats: formats,
        formatSel: formats.length > 1 ? Logic() : null,
        planeBase: [for (var k = 1; k < planes; k++) Logic(width: 32)],
        planePitch: planar
            ? [for (var k = 0; k < planes; k++) Logic(width: 32)]
            : const [],
        overlayFormats: overlay,
        overlayEnable: overlay == null ? null : Logic(),
        overlayBase: [if (overlay != null) Logic(width: 32)],
        overlayPitch: [if (overlay != null) Logic(width: 32)],
        overlaySrcX: overlay == null ? null : Logic(width: 5),
        overlaySrcY: overlay == null ? null : Logic(width: 4),
        overlayDstX: overlay == null ? null : Logic(width: 5),
        overlayDstY: overlay == null ? null : Logic(width: 4),
        overlayWidth: overlay == null ? null : Logic(width: 5),
        overlayHeight: overlay == null ? null : Logic(width: 4),
        overlayAlpha: overlay == null ? null : Logic(width: 8),
      );
    }

    for (final (name, formats, overlay, count, masks) in [
      ('rgb only', [HarborPixelFormat.xrgb8888], null, 1, [0x004]),
      (
        'nv12 and xrgb8888',
        [HarborPixelFormat.nv12, HarborPixelFormat.xrgb8888],
        null,
        2,
        [0x044],
      ),
      (
        'nv12 and xrgb8888 with an xrgb8888 overlay',
        [HarborPixelFormat.nv12, HarborPixelFormat.xrgb8888],
        [HarborPixelFormat.xrgb8888],
        3,
        [0x044, 0x004],
      ),
    ]) {
      test(name, () async {
        final d = build(formats, overlay: overlay);
        await d.build();
        expect(d.planeCount, count);
        expect(d.planeFormats, masks);
        expect(d.overlayPresent, overlay != null);
        expect(d.output('plane_count').width, 4);
        expect(d.output('plane_count').value.toInt(), count);
        for (final (n, mask) in masks.indexed) {
          final port = d.output('plane_formats_$n');
          expect(port.width, harborPixelFormatBitOrder.length);
          expect(port.value.toInt(), mask);
        }
        expect(d.tryOutput('plane_formats_${masks.length}'), isNull);
        expect(
          d.output('overlay_present').value.toInt(),
          overlay == null ? 0 : 1,
        );
        expect(d.tryInput('update'), isNotNull);
        expect(d.updatePending.width, 1);
      });
    }
  });
}

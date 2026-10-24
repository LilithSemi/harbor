@Tags(['slow'])
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';
import 'overlay_reference.dart';
import 'plane_memory.dart';
import 'sdram_scanout_harness.dart';

Iterable<Module> _all(Module m) sync* {
  yield m;
  for (final s in m.subModules) {
    yield* _all(s);
  }
}

/// [timing] with [lines] active lines and 3 blank lines, so a line has its
/// full width and deadline but a frame stays short enough to simulate.
HarborDisplayTiming _lines(HarborDisplayTiming t, int lines) =>
    HarborDisplayTiming(
      hActive: t.hActive,
      hFrontPorch: t.hFrontPorch,
      hSyncWidth: t.hSyncWidth,
      hBackPorch: t.hBackPorch,
      vActive: lines,
      vFrontPorch: 1,
      vSyncWidth: 1,
      vBackPorch: 1,
      hSyncPositive: t.hSyncPositive,
      vSyncPositive: t.vSyncPositive,
      pixelClock: t.pixelClock,
    );

/// The R, G and B of an xrgb8888 or rgb565 pixel [x] of a line.
List<int> _rgb(HarborPixelFormat f, int Function(int addr) word, int x) {
  if (f == HarborPixelFormat.xrgb8888) {
    final w = word(4 * x);
    return [(w >> 16) & 0xff, (w >> 8) & 0xff, w & 0xff];
  }
  final w = word(4 * (x >> 1));
  final h = x.isOdd ? w >> 16 : w & 0xffff;
  final r = (h >> 11) & 0x1f, g = (h >> 5) & 0x3f, b = h & 0x1f;
  return [(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)];
}

/// The controls of one ULX3S frame: the format index, the base and the
/// pitch of plane 0.
typedef _PortSet = (int format, int base, int pitch);

/// A display with formats [xrgb8888, rgb565] on a [HarborSdram] scanout
/// port. The bench sets [first] at the start and [second] in frame 3, each
/// with one `update` pulse on the scanout clock. Every pixel of frame 2
/// must show [first], and every pixel of frames 4 and 5 [second].
Future<void> _ulx3s({
  required HarborDisplayTiming timing,
  required int pixelPeriodPs,
  required int first,
  required int second,
}) async {
  const formats = [HarborPixelFormat.xrgb8888, HarborPixelFormat.rgb565];
  final b = SdramScanoutBench(
    timing: _lines(timing, 4),
    memPeriodPs: 8000,
    pixelPeriodPs: pixelPeriodPs,
    formats: formats,
    driven: true,
  );
  await b.start();
  addTearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });
  final scanClk = b.sdram.output('scan_clk');
  _PortSet setOf(int i) {
    final f = formats[i];
    return (
      i,
      SdramScanoutBench.sdramBase + 0x10000 + 0x100000 * i,
      b.sdram.scanoutStride(f.lineBytes(0, timing.hActive)),
    );
  }

  void apply(_PortSet s) {
    b.formatSel.inject(s.$1);
    b.fbIn.inject(s.$2);
    b.pitch0.inject(s.$3);
    pulseUpdate(b.update, scanClk);
  }

  final sets = [setOf(first), setOf(second)];
  apply(sets[0]);
  final d = _all(b.display).whereType<HarborDualClockDisplay>().single;
  final gen = _all(d).whereType<VideoTimingGenerator>().single;
  final delay = d.pipelineDelay;
  final out = b.display;
  final history = <int>[];
  var frame = -1;
  var checked = 0;
  var pendingSeen = false;
  var pendingLow = false;
  while (frame < 6) {
    await b.pixelClk.nextNegedge;
    final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
    if (gx == 0 && gy == 0) frame++;
    if (frame == 3 && gx == 0 && gy == 1) apply(sets[1]);
    if (frame == 3 && gx == 4 && gy == 1) {
      pendingSeen = out.output('update_pending').value.toInt() == 1;
    }
    if (frame == 4 && gx == 4 && gy == 0) {
      pendingLow = out.output('update_pending').value.toInt() == 0;
    }
    history.add(frame);
    if (history.length <= delay) continue;
    final f = history[history.length - 1 - delay];
    if ((f != 2 && f != 4 && f != 5) || out.output('de').value.toInt() != 1) {
      continue;
    }
    final px = out.output('x').value.toInt();
    final y = out.output('y').value.toInt();
    final s = sets[f == 2 ? 0 : 1];
    expect(
      [
        out.output('red').value.toInt(),
        out.output('green').value.toInt(),
        out.output('blue').value.toInt(),
      ],
      _rgb(formats[s.$1], (a) => b.expected(s.$2 + y * s.$3 + a), px),
      reason: 'frame $f ($px, $y) ${formats[s.$1].name}',
    );
    checked++;
  }
  expect(checked, 3 * 4 * timing.hActive);
  expect(pendingSeen, isTrue);
  expect(pendingLow, isTrue);
  expect(b.model.errors, isEmpty);
  await b.stop();
}

/// An nv12 and xrgb8888 display with an xrgb8888 overlay on an AXI4
/// memory master port.
class _Ax7203Rig extends BridgeModule {
  static const config = HarborMemoryWaistConfig(
    addressWidth: 32,
    dataWidth: 32,
    outstanding: 4,
  );

  late final HarborDualClockDisplay display;

  _Ax7203Rig(HarborDisplayTiming timing)
    : super('DisplayAx7203Rig', name: 'rig') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('pixel_clk', PortDirection.input);
    createPort('pixel_reset', PortDirection.input);
    final xw = (timing.hTotal - 1).bitLength;
    final yw = (timing.vTotal - 1).bitLength;
    final ins = {
      'update': 1,
      'fb_base': 32,
      'format_sel': 1,
      'plane_base_1': 32,
      'plane_pitch_0': 32,
      'plane_pitch_1': 32,
      'overlay_enable': 1,
      'overlay_base_0': 32,
      'overlay_pitch_0': 32,
      'overlay_src_x': xw,
      'overlay_src_y': yw,
      'overlay_dst_x': xw,
      'overlay_dst_y': yw,
      'overlay_width': xw,
      'overlay_height': yw,
      'overlay_alpha': 8,
    };
    for (final MapEntry(:key, :value) in ins.entries) {
      createPort(key, PortDirection.input, width: value);
    }
    final mem = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      config: config,
      clk: input('clk'),
      reset: input('reset'),
    );
    display = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: input('pixel_clk'),
      pixelReset: input('pixel_reset'),
      sysClk: input('clk'),
      sysReset: input('reset'),
      enable: Const(1),
      update: input('update'),
      fbBase: input('fb_base'),
      memory: mem.waist,
      outputType: HarborDisplayInterface.parallelRgb,
      formats: const [HarborPixelFormat.nv12, HarborPixelFormat.xrgb8888],
      formatSel: input('format_sel'),
      planeBase: [input('plane_base_1')],
      planePitch: [input('plane_pitch_0'), input('plane_pitch_1')],
      overlayFormats: const [HarborPixelFormat.xrgb8888],
      overlayEnable: input('overlay_enable'),
      overlayBase: [input('overlay_base_0')],
      overlayPitch: [input('overlay_pitch_0')],
      overlaySrcX: input('overlay_src_x'),
      overlaySrcY: input('overlay_src_y'),
      overlayDstX: input('overlay_dst_x'),
      overlayDstY: input('overlay_dst_y'),
      overlayWidth: input('overlay_width'),
      overlayHeight: input('overlay_height'),
      overlayAlpha: input('overlay_alpha'),
    );
    for (final n in [
      'de',
      'x',
      'y',
      'red',
      'green',
      'blue',
      'underrun',
      'update_pending',
      'plane_underrun_count_0',
      'plane_underrun_count_1',
      'overlay_underrun_count_0',
    ]) {
      addOutput(n, width: display.output(n).width) <= display.output(n);
    }
  }
}

/// A word of memory at word index [i].
int _hash(int i) {
  var v = (i * 0x9e3779b1 + 0x7f4a7c15) & 0xffffffff;
  v ^= v >> 15;
  v = (v * 0x2c1b3c6d) & 0xffffffff;
  return v ^ (v >> 12);
}

int _byte(int a) => (_hash(a >> 2) >> (8 * (a & 3))) & 0xff;

/// The controls of one AX7203 frame.
class _AxSet {
  final int format;
  final PlaneLayout primary;
  final PlaneLayout overlay;
  final OverlayFrame state;

  const _AxSet(this.format, this.primary, this.overlay, this.state);
}

void main() {
  // Frames 0 and 1 prime the display.
  test('ulx3s: 640x480 timing on an sdram scanout port, xrgb8888 then '
      'rgb565 through update', () async {
    await _ulx3s(
      timing: const HarborDisplayTiming.vga640x480(),
      pixelPeriodPs: 39722,
      first: 0,
      second: 1,
    );
  }, timeout: const Timeout(Duration(hours: 3)));

  test('ulx3s: 1280x720 timing on an sdram scanout port, rgb565 then '
      'xrgb8888 through update', () async {
    await _ulx3s(
      timing: const HarborDisplayTiming.hd720(),
      pixelPeriodPs: 13468,
      first: 1,
      second: 0,
    );
  }, timeout: const Timeout(Duration(hours: 3)));

  test('ax7203: 1024x768 timing on the axi4 fabric, nv12 and xrgb8888 '
      'with an xrgb8888 overlay through update', () async {
    final timing = _lines(const HarborDisplayTiming.xga1024x768(), 6);
    final rig = _Ax7203Rig(timing);
    final top = MasterTop(
      rig,
      iface: 'bus',
      kind: HarborFabricKind.axi4,
      config: _Ax7203Rig.config,
    );
    // The pixel clock is 65 MHz and the system clock twice that.
    final pixelClk = SimpleClockGenerator(40).clk;
    final sysClk = SimpleClockGenerator(20).clk;
    top.input('clk').srcConnection! <= sysClk;
    top.input('pixel_clk').srcConnection! <= pixelClk;
    final mem = BeatMemory(top, sysClk, fill: _hash);
    final ins = {
      for (final p in rig.inputs.keys)
        if (!['clk', 'reset', 'pixel_clk', 'pixel_reset'].contains(p) &&
            !p.startsWith('bus_'))
          p: Logic(name: 'tb_$p', width: rig.input(p).width),
    };
    for (final MapEntry(:key, :value) in ins.entries) {
      top.input(key).srcConnection! <= value;
      value.inject(0);
    }
    final reset = Logic(name: 'reset');
    final pixelReset = Logic(name: 'pixel_reset');
    top.input('reset').srcConnection! <= reset;
    top.input('pixel_reset').srcConnection! <= pixelReset;
    reset.inject(1);
    pixelReset.inject(1);
    await top.build();
    mem.start();

    final sets = [
      const _AxSet(
        0,
        PlaneLayout([0x100000, 0x200000], [1024, 1024]),
        PlaneLayout([0x400000], [4096]),
        OverlayFrame(
          srcX: 16,
          srcY: 2,
          dstX: 300,
          dstY: 1,
          width: 256,
          height: 4,
          alpha: 128,
        ),
      ),
      const _AxSet(
        1,
        PlaneLayout([0x800000, 0x200000], [4096, 1024]),
        PlaneLayout([0x600000], [2048]),
        OverlayFrame(
          srcX: 3,
          srcY: 0,
          dstX: 900,
          dstY: 2,
          width: 200,
          height: 3,
          alpha: 77,
        ),
      ),
    ];
    void apply(_AxSet s) {
      final v = {
        'fb_base': s.primary.base[0],
        'format_sel': s.format,
        'plane_base_1': s.primary.base[1],
        'plane_pitch_0': s.primary.pitch[0],
        'plane_pitch_1': s.primary.pitch[1],
        'overlay_enable': s.state.enable ? 1 : 0,
        'overlay_base_0': s.overlay.base[0],
        'overlay_pitch_0': s.overlay.pitch[0],
        'overlay_src_x': s.state.srcX,
        'overlay_src_y': s.state.srcY,
        'overlay_dst_x': s.state.dstX,
        'overlay_dst_y': s.state.dstY,
        'overlay_width': s.state.width,
        'overlay_height': s.state.height,
        'overlay_alpha': s.state.alpha,
      };
      for (final MapEntry(:key, :value) in v.entries) {
        ins[key]!.inject(value);
      }
      pulseUpdate(ins['update']!, sysClk);
    }

    final formats = [HarborPixelFormat.nv12, HarborPixelFormat.xrgb8888];
    final want = <int, List<List<List<int>>>>{};
    List<List<List<int>>> frameOf(_AxSet s) => overlayFrame(
      hActive: timing.hActive,
      vActive: timing.vActive,
      primary: (y) => surfaceLine(
        format: formats[s.format],
        layout: s.primary,
        byte: _byte,
        line: y,
        x0: 0,
        width: timing.hActive,
        csc: HarborCscCoefficients.bt709Limited,
      ),
      format: HarborPixelFormat.xrgb8888,
      layout: s.overlay,
      byte: _byte,
      state: s.state,
      csc: HarborCscCoefficients.bt709Limited,
    );

    Simulator.setMaxSimTime(1 << 50);
    unawaited(Simulator.run());
    addTearDown(() async {
      if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
      Simulator.reset();
    });
    await pixelClk.nextPosedge;
    await pixelClk.nextPosedge;
    reset.inject(0);
    pixelReset.inject(0);
    apply(sets[0]);

    final gen = _all(rig).whereType<VideoTimingGenerator>().single;
    final delay = rig.display.pipelineDelay;
    final history = <int>[];
    var frame = -1;
    var checked = 0;
    var pendingSeen = false;
    var pendingLow = false;
    while (frame < 6) {
      await pixelClk.nextNegedge;
      final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
      if (gx == 0 && gy == 0) frame++;
      if (frame == 3 && gx == 0 && gy == 1) apply(sets[1]);
      if (frame == 3 && gx == 4 && gy == 1) {
        pendingSeen = top.output('update_pending').value.toInt() == 1;
      }
      if (frame == 4 && gx == 4 && gy == 0) {
        pendingLow = top.output('update_pending').value.toInt() == 0;
      }
      history.add(frame);
      if (history.length <= delay) continue;
      final f = history[history.length - 1 - delay];
      if ((f != 2 && f != 4 && f != 5) || top.output('de').value.toInt() != 1) {
        continue;
      }
      final px = top.output('x').value.toInt();
      final py = top.output('y').value.toInt();
      final s = f == 2 ? 0 : 1;
      expect(
        [
          top.output('red').value.toInt(),
          top.output('green').value.toInt(),
          top.output('blue').value.toInt(),
        ],
        want.putIfAbsent(s, () => frameOf(sets[s]))[py][px],
        reason: 'frame $f ($px, $py) set $s',
      );
      checked++;
    }
    expect(checked, 3 * timing.vActive * timing.hActive);
    expect(pendingSeen, isTrue);
    expect(pendingLow, isTrue);
    for (final n in [
      'plane_underrun_count_0',
      'plane_underrun_count_1',
      'overlay_underrun_count_0',
    ]) {
      expect(top.output(n).value.toInt(), 0, reason: n);
    }
  }, timeout: const Timeout(Duration(hours: 3)));
}

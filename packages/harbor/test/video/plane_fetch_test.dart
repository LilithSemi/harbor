import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';
import 'plane_memory.dart';

const _timing = HarborDisplayTiming(
  hActive: 8,
  hFrontPorch: 1,
  hSyncWidth: 1,
  hBackPorch: 40,
  vActive: 6,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: 1000000,
);

// 50 x 9 pixel cycles in a frame. The first frame start comes at pixel
// cycle 300 (y = 6), the second at 750. 1190 cycles end before the third.
const _runCycles = 1190;

const _fb = 0x1000;
const _stride = 32;
const _base1 = 0x8000;
const _pitch1 = 48;
const _base2 = 0xC000;
const _pitch2 = 64;

/// The requests of one frame of each format for [_timing], as
/// (byte address, 32-bit beats). No build fetches a line past the frame.
const _frames = <HarborPixelFormat, List<(int, int)>>{
  HarborPixelFormat.xrgb8888: [
    (0x1000, 8),
    (0x1020, 8),
    (0x1040, 8),
    (0x1060, 8),
    (0x1080, 8),
    (0x10A0, 8),
  ],
  HarborPixelFormat.yuyv: [
    (0x1000, 4),
    (0x1020, 4),
    (0x1040, 4),
    (0x1060, 4),
    (0x1080, 4),
    (0x10A0, 4),
  ],
  HarborPixelFormat.nv12: [
    (0x1000, 2),
    (0x8000, 2),
    (0x1020, 2),
    (0x8030, 2),
    (0x1040, 2),
    (0x1060, 2),
    (0x8060, 2),
    (0x1080, 2),
    (0x10A0, 2),
  ],
  HarborPixelFormat.p010: [
    (0x1000, 4),
    (0x8000, 4),
    (0x1020, 4),
    (0x8030, 4),
    (0x1040, 4),
    (0x1060, 4),
    (0x8060, 4),
    (0x1080, 4),
    (0x10A0, 4),
  ],
  HarborPixelFormat.i420: [
    (0x1000, 2),
    (0x8000, 1),
    (0xC000, 1),
    (0x1020, 2),
    (0x8030, 1),
    (0xC040, 1),
    (0x1040, 2),
    (0x1060, 2),
    (0x8060, 1),
    (0xC080, 1),
    (0x1080, 2),
    (0x10A0, 2),
  ],
};

class _Run {
  final List<(int, int)> requests;
  final int underrun;
  final int planeUnderrun;

  /// The underrun count of each plane, empty on a one plane build.
  final List<int> counts;
  _Run(this.requests, this.underrun, this.planeUnderrun, this.counts);
}

var _ran = false;

Future<void> _stop() async {
  if (_ran && !Simulator.simulationHasEnded) await Simulator.endSimulation();
  _ran = false;
  await Simulator.reset();
}

/// Runs a display of [formats] for two frames and returns its requests.
/// The tear down ends the simulation.
/// [port] reads through a scanout port, else through a memory waist.
/// [onCycle] runs at each pixel clock fall with the cycle count, and can
/// pulse `update`. The display copies the inputs after reset, with
/// `format_sel` at [formatAtReset].
Future<_Run> _display(
  List<HarborPixelFormat> formats, {
  bool port = false,
  int fb = _fb,
  int stride = _stride,
  List<int> bases = const [_base1, _base2],
  List<int> pitches = const [_pitch1, _pitch2],
  HarborDisplayTiming timing = _timing,
  int runCycles = _runCycles,
  int latency = 3,
  int Function(int cycle)? latencyAt,
  int formatAtReset = 0,
  void Function(
    int cycle,
    Logic? formatSel,
    Module display,
    void Function() update,
  )?
  onCycle,
}) async {
  final pixelClk = SimpleClockGenerator(14).clk;
  final sysClk = SimpleClockGenerator(6).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final enable = Logic(name: 'enable');
  final update = Logic(name: 'update');
  final planes = formats
      .map((f) => f.planes.length)
      .reduce((a, b) => a > b ? a : b);
  final planar = HarborDualClockScanout.isPlanar(formats);
  final formatSel = formats.length > 1
      ? Logic(name: 'format_sel', width: (formats.length - 1).bitLength)
      : null;
  final baseIn = [
    for (var k = 1; k < planes; k++) Const(bases[k - 1], width: 32),
  ];
  final pitchIn = [
    Const(stride, width: 32),
    for (var k = 1; k < planes; k++) Const(pitches[k - 1], width: 32),
  ];
  final memory = port
      ? null
      : HarborMemoryWaist(
          const HarborMemoryWaistConfig(
            addressWidth: 32,
            dataWidth: 32,
            outstanding: 2,
          ),
        );
  final rqReady = port ? Logic(name: 'rq_ready') : null;
  final rdValid = port ? Logic(name: 'rd_valid') : null;
  final rdData = port ? Logic(name: 'rd_data', width: 16) : null;
  final d = HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: timing,
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    sysClk: sysClk,
    sysReset: sysReset,
    enable: enable,
    update: update,
    fbBase: Const(fb, width: 32),
    memory: memory,
    rqReady: rqReady,
    rdValid: rdValid,
    rdData: rdData,
    lineStride: planar ? null : stride,
    outputType: HarborDisplayInterface.parallelRgb,
    formats: formats,
    formatSel: formatSel,
    planeBase: planar ? baseIn : const [],
    planePitch: planar ? pitchIn : const [],
  );
  await d.build();
  final List<(int, int)> requests;
  WaistMemory? waistMemory;
  if (port) {
    requests = PortMemory(
      rqValid: d.rqValid,
      rqAddr: d.rqAddr,
      rqWords: d.rqWords,
      rqReady: rqReady!,
      rdValid: rdValid!,
      rdData: rdData!,
      clk: sysClk,
    ).requests;
  } else {
    waistMemory = WaistMemory(memory!, sysClk, latency: latency);
    requests = waistMemory.requests;
  }
  pixelReset.inject(1);
  sysReset.inject(1);
  enable.inject(1);
  formatSel?.inject(formatAtReset);
  update.inject(0);
  Simulator.setMaxSimTime(100000000);
  _ran = true;
  unawaited(Simulator.run());
  await pixelClk.nextPosedge;
  await pixelClk.nextPosedge;
  pixelReset.inject(0);
  sysReset.inject(0);
  for (var c = 0; c < runCycles; c++) {
    await pixelClk.nextNegedge;
    if (latencyAt != null) waistMemory!.latency = latencyAt(c);
    onCycle?.call(c, formatSel, d, () => pulseUpdate(update, sysClk));
  }
  return _Run(
    List.of(requests),
    d.underrun.value.toInt(),
    planar ? d.planeUnderrun.value.toInt() : 0,
    [
      if (planar)
        for (var k = 0; k < planes; k++)
          d.output('plane_underrun_count_$k').value.toInt(),
    ],
  );
}

void main() {
  tearDown(_stop);

  for (final f in [
    HarborPixelFormat.nv12,
    HarborPixelFormat.p010,
    HarborPixelFormat.i420,
    HarborPixelFormat.yuyv,
    HarborPixelFormat.xrgb8888,
  ]) {
    test('${f.name}: every fetch of two frames in order', () async {
      final r = await _display([f]);
      final want = _frames[f]!;
      expect(r.requests, [...want, ...want]);
      expect(r.underrun, 0);
      expect(r.planeUnderrun, 0);
      expect(r.counts.every((c) => c == 0), isTrue);
    });
  }

  // vActive 5: three chroma lines, the last one for luma line 4 only.
  const odd = HarborDisplayTiming(
    hActive: 8,
    hFrontPorch: 1,
    hSyncWidth: 1,
    hBackPorch: 40,
    vActive: 5,
    vFrontPorch: 1,
    vSyncWidth: 1,
    vBackPorch: 1,
    pixelClock: 1000000,
  );
  // 50 x 8 cycles a frame. Frame starts at 250 and 650, the third at 1050.
  const oddFrames = <HarborPixelFormat, List<(int, int)>>{
    HarborPixelFormat.nv12: [
      (0x1000, 2),
      (0x8000, 2),
      (0x1020, 2),
      (0x8030, 2),
      (0x1040, 2),
      (0x1060, 2),
      (0x8060, 2),
      (0x1080, 2),
    ],
    HarborPixelFormat.i420: [
      (0x1000, 2),
      (0x8000, 1),
      (0xC000, 1),
      (0x1020, 2),
      (0x8030, 1),
      (0xC040, 1),
      (0x1040, 2),
      (0x1060, 2),
      (0x8060, 1),
      (0xC080, 1),
      (0x1080, 2),
    ],
  };
  for (final f in oddFrames.keys) {
    test('${f.name}: an odd vActive fetches every line once', () async {
      final r = await _display([f], timing: odd, runCycles: 1040);
      final want = oddFrames[f]!;
      expect(r.requests, [...want, ...want]);
      expect(r.underrun, 0);
    });
  }

  test('a slow memory counts underruns and still fetches', () async {
    var mid = <int>[];
    final r = await _display(
      [HarborPixelFormat.nv12],
      // Slow only in the active lines, so each frame start primes in time.
      latencyAt: (c) => (c >= 445 && c < 745) || c >= 895 ? 300 : 3,
      onCycle: (c, _, d, _) {
        // After the first frame, before the second frame start.
        if (c == 740) {
          mid = [
            for (var k = 0; k < 2; k++)
              d.output('plane_underrun_count_$k').value.toInt(),
          ];
        }
      },
    );
    expect(r.underrun, 1);
    expect(r.planeUnderrun, 3);
    expect(mid[0], greaterThan(0));
    expect(mid[1], greaterThan(0));
    // A frame start clears the flag, not the count.
    expect(r.counts[0], greaterThan(mid[0]));
    expect(r.counts[1], greaterThan(mid[1]));
    expect(r.requests.length, greaterThan(9));
  });

  test('format_sel picks the format at frame start', () async {
    final r = await _display(
      [
        HarborPixelFormat.xrgb8888,
        HarborPixelFormat.nv12,
        HarborPixelFormat.i420,
      ],
      formatAtReset: 1,
      onCycle: (c, sel, _, update) {
        // Between the two frame starts.
        if (c == 500) {
          sel!.inject(2);
          update();
        }
      },
    );
    expect(r.requests, [
      ..._frames[HarborPixelFormat.nv12]!,
      ..._frames[HarborPixelFormat.i420]!,
    ]);
    expect(r.underrun, 0);
  });

  test('a scanout port ignores the low 2 bits of each base and pitch, plane 0 '
      'too', () async {
    final r = await _display(
      [HarborPixelFormat.nv12],
      port: true,
      fb: _fb + 3,
      stride: _stride + 3,
      bases: [_base1 + 3],
      pitches: [_pitch1 + 3],
    );
    // 16-bit words: two for each 32-bit word.
    final want = [
      for (final (a, n) in _frames[HarborPixelFormat.nv12]!) (a, 2 * n),
    ];
    expect(r.requests, [...want, ...want]);
    expect(r.underrun, 0);
  });

  test('i420 on a scanout port fetches every plane line', () async {
    final r = await _display([HarborPixelFormat.i420], port: true);
    final want = [
      (0x1000, 4),
      (0x8000, 2),
      (0xC000, 2),
      (0x1020, 4),
      (0x8030, 2),
      (0xC040, 2),
      (0x1040, 4),
      (0x1060, 4),
      (0x8060, 2),
      (0xC080, 2),
      (0x1080, 4),
      (0x10A0, 4),
    ];
    expect(r.requests, [...want, ...want]);
    expect(r.underrun, 0);
  });

  test('planar builds check their inputs', () {
    HarborDualClockDisplay make(
      List<HarborPixelFormat> formats, {
      Logic? sel,
      int bases = 1,
      int? stride,
    }) => HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: _timing,
      pixelClk: Logic(),
      pixelReset: Logic(),
      sysClk: Logic(),
      sysReset: Logic(),
      enable: Logic(),
      update: Const(1),
      fbBase: Logic(width: 32),
      memory: HarborMemoryWaist(
        const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
      ),
      outputType: HarborDisplayInterface.parallelRgb,
      formats: formats,
      formatSel: sel,
      planeBase: [for (var i = 0; i < bases; i++) Logic(width: 32)],
      planePitch: [for (var i = 0; i <= bases; i++) Logic(width: 32)],
      lineStride: stride,
    );
    expect(make([HarborPixelFormat.nv12]).planeUnderrun.width, 2);
    expect(() => make([HarborPixelFormat.nv12], bases: 0), throwsArgumentError);
    expect(
      () => make([HarborPixelFormat.nv12], stride: 64),
      throwsArgumentError,
    );
    expect(make([HarborPixelFormat.nv12]).input('plane_pitch_0').width, 32);
    expect(
      () => make([HarborPixelFormat.nv12, HarborPixelFormat.xrgb8888]),
      throwsArgumentError,
    );
    expect(
      () => make([
        HarborPixelFormat.nv12,
        HarborPixelFormat.rgb888,
      ], sel: Logic()),
      throwsArgumentError,
    );
    final two = make([
      HarborPixelFormat.nv12,
      HarborPixelFormat.xrgb8888,
    ], sel: Logic());
    expect(two.input('format_sel').width, 1);
    expect(
      two.definitionName,
      isNot(make([HarborPixelFormat.nv12]).definitionName),
    );
  });

  test('the read side shows a chroma line for two luma lines', () async {
    final pixelClk = SimpleClockGenerator(14).clk;
    final sysClk = SimpleClockGenerator(6).clk;
    final pixelReset = Logic(name: 'pixel_reset');
    final sysReset = Logic(name: 'sys_reset');
    final frameStart = Logic(name: 'frame_start');
    final lineStart = Logic(name: 'line_start');
    final col0 = Logic(name: 'col0', width: 2);
    final col1 = Logic(name: 'col1', width: 2);
    final memory = HarborMemoryWaist(
      const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
    );
    final so = HarborDualClockScanout(
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
      frameStart: frameStart,
      lineStart: lineStart,
      firstLine: Const(0),
      col: col0,
      fbBase: Const(_fb, width: 32),
      stride: Const(_stride, width: 32),
      memory: memory,
      formats: const [HarborPixelFormat.nv12],
      hActive: 8,
      vActive: 6,
      planeBase: [Const(_base1, width: 32)],
      planePitch: [Const(_pitch1, width: 32)],
      planeCol: [col1],
    );
    await so.build();
    WaistMemory(memory, sysClk, latency: 2);
    pixelReset.inject(1);
    sysReset.inject(1);
    frameStart.inject(0);
    lineStart.inject(0);
    col0.inject(0);
    col1.inject(0);
    Simulator.setMaxSimTime(10000000);
    _ran = true;
    unawaited(Simulator.run());
    await pixelClk.nextPosedge;
    await pixelClk.nextPosedge;
    pixelReset.inject(0);
    sysReset.inject(0);
    await pixelClk.nextNegedge;

    Future<void> pix(int n) async {
      for (var i = 0; i < n; i++) {
        await pixelClk.nextPosedge;
      }
      await pixelClk.nextNegedge;
    }

    Future<void> pulse(Logic s) async {
      s.inject(1);
      await pixelClk.nextPosedge;
      s.inject(0);
      await pixelClk.nextNegedge;
    }

    // Each plane line has two words. The data is one cycle after the
    // column.
    Future<void> expectLine(int y, int c) async {
      for (var w = 0; w < 2; w++) {
        col0.inject(w);
        col1.inject(1 - w);
        await pixelClk.nextPosedge;
        await pixelClk.nextNegedge;
        expect(
          so.pixel.value.toInt(),
          _fb + y * _stride + 4 * w,
          reason: 'y$y',
        );
        expect(
          so.planeData(1).value.toInt(),
          _base1 + c * _pitch1 + 4 * (1 - w),
          reason: 'y$y chroma',
        );
      }
    }

    await pulse(frameStart);
    await pix(80);
    for (var y = 0; y < 6; y++) {
      if (y > 0) {
        await pulse(lineStart);
        await pix(40);
      }
      await expectLine(y, y >> 1);
    }
    expect(so.underrun.value.toInt(), 0);
  });

  for (final kind in HarborFabricKind.values) {
    test('${kind.name}: nv12 fetches every plane line', () async {
      final top = MasterTop(
        _KindRig(kind),
        iface: 'bus',
        kind: kind,
        config: _KindRig.config,
      );
      final pixelClk = SimpleClockGenerator(14).clk;
      final sysClk = SimpleClockGenerator(6).clk;
      top.input('clk').srcConnection! <= sysClk;
      top.input('pixel_clk').srcConnection! <= pixelClk;
      final mem = BeatMemory(top, sysClk, latency: 1, fill: (i) => 4 * i);
      for (final p in ['reset', 'pixel_reset']) {
        top.input(p).srcConnection!.inject(1);
      }
      top.input('enable').srcConnection!.inject(1);
      await top.build();
      // A Wishbone slave port reads whole bursts, so the fetches are taken
      // from the fetcher side of the port.
      final fetched = _fetches(top, sysClk);
      mem.start();
      Simulator.setMaxSimTime(100000000);
      _ran = true;
      unawaited(Simulator.run());
      await pixelClk.nextPosedge;
      await pixelClk.nextPosedge;
      for (final p in ['reset', 'pixel_reset']) {
        top.input(p).srcConnection!.inject(0);
      }
      for (var c = 0; c < _runCycles; c++) {
        await pixelClk.nextNegedge;
      }
      final want = _frames[HarborPixelFormat.nv12]!;
      expect(fetched, [...want, ...want]);
      expect(mem.log, isNotEmpty);
      expect(top.output('underrun').value.toInt(), 0);
    });
  }
}

/// Every request that the [HarborLineFetcher] under [top] sends, as
/// (byte address, beats).
List<(int, int)> _fetches(Module top, Logic clk) {
  Iterable<Module> all(Module m) sync* {
    yield m;
    for (final s in m.subModules) {
      yield* all(s);
    }
  }

  final f = all(top).whereType<HarborLineFetcher>().single;
  final out = <(int, int)>[];
  clk.posedge.listen((_) {
    final valid = f.output('m_REQ_VALID').previousValue;
    final ready = f.input('m_REQ_READY').previousValue;
    if (valid != null &&
        ready != null &&
        valid.isValid &&
        valid.toBool() &&
        ready.isValid &&
        ready.toBool()) {
      out.add((
        f.output('m_REQ_ADDR').previousValue!.toInt(),
        f.output('m_REQ_LEN').previousValue!.toInt() + 1,
      ));
    }
  });
  return out;
}

/// An nv12 display on a memory master port of [kind], named `bus`.
class _KindRig extends BridgeModule {
  static const config = HarborMemoryWaistConfig(
    addressWidth: 32,
    dataWidth: 32,
    outstanding: 2,
  );

  _KindRig(HarborFabricKind kind)
    : super('PlaneFetchKindRig_${kind.name}', name: 'rig') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('pixel_clk', PortDirection.input);
    createPort('pixel_reset', PortDirection.input);
    createPort('enable', PortDirection.input);
    final mem = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: kind,
      config: config,
      clk: input('clk'),
      reset: input('reset'),
    );
    final d = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: _timing,
      pixelClk: input('pixel_clk'),
      pixelReset: input('pixel_reset'),
      sysClk: input('clk'),
      sysReset: input('reset'),
      enable: input('enable'),
      update: Const(1),
      fbBase: Const(_fb, width: 32),
      memory: mem.waist,
      outputType: HarborDisplayInterface.parallelRgb,
      formats: const [HarborPixelFormat.nv12],
      planeBase: [Const(_base1, width: 32)],
      planePitch: [Const(_stride, width: 32), Const(_pitch1, width: 32)],
    );
    addOutput('underrun') <= d.underrun;
  }
}

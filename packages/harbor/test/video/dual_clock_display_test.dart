import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'csc_reference.dart';
import 'echo_memory.dart';
import 'plane_memory.dart';
import 'pixel_unpack_reference.dart';

const _memConfig = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);

/// End-to-end dual-clock display on a tiny 4x2 mode: pixel-domain timing drives
/// the dual-clock scanout, which bursts from a fake system-side memory
/// (address-as-data). After a couple of frames the buffers are primed, so every
/// active pixel must equal fbBase + y*stride + x*4.

/// Expands a 16-bit rgb565 value to 8-bit r/g/b by replicating each
/// channel's top bits into its low bits, the same as the RTL.
List<int> _expandRgb565(int px) {
  final r5 = (px >> 11) & 0x1F;
  final g6 = (px >> 5) & 0x3F;
  final b5 = px & 0x1F;
  final r8 = (r5 << 3) | (r5 >> 2);
  final g8 = (g6 << 2) | (g6 >> 4);
  final b8 = (b5 << 3) | (b5 >> 2);
  return [r8, g8, b8];
}

HarborDualClockDisplay _buildDisplay({
  required HarborDisplayTiming timing,
  required HarborPixelFormat pixelFormat,
}) {
  return HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: timing,
    pixelClk: Logic(name: 'pixel_clk'),
    pixelReset: Logic(name: 'pixel_reset'),
    shiftClk: Logic(name: 'shift_clk'),
    shiftReset: Logic(name: 'shift_reset'),
    sysClk: Logic(name: 'sys_clk'),
    sysReset: Logic(name: 'sys_reset'),
    enable: Logic(name: 'enable'),
    update: Const(1),
    fbBase: Logic(name: 'fb_base', width: 32),
    memory: HarborMemoryWaist(_memConfig),
    pixelFormat: pixelFormat,
  );
}

HarborDisplayTiming _blank(int blank) => HarborDisplayTiming(
  hActive: 4,
  hFrontPorch: blank,
  hSyncWidth: 0,
  hBackPorch: 0,
  vActive: 2,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: 1000000,
);

void main() {
  test('a YUV build with too short a horizontal blank throws', () {
    expect(
      () => _buildDisplay(
        timing: _blank(HarborPixelUnpack.latency - 2),
        pixelFormat: HarborPixelFormat.yuyv,
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('hFrontPorch + hSyncWidth + hBackPorch'),
        ),
      ),
    );
    expect(
      () => _buildDisplay(
        timing: _blank(HarborPixelUnpack.latency - 1),
        pixelFormat: HarborPixelFormat.yuyv,
      ),
      returnsNormally,
    );
    expect(
      () => _buildDisplay(
        timing: _blank(0),
        pixelFormat: HarborPixelFormat.xrgb8888,
      ),
      returnsNormally,
    );
  });

  test('one plane builds of two timings have their own names', () {
    String name(HarborDisplayTiming t, {bool port = false}) =>
        HarborDualClockDisplay(
          target: const HarborSimTarget(),
          timing: t,
          pixelClk: Logic(),
          pixelReset: Logic(),
          sysClk: Logic(),
          sysReset: Logic(),
          enable: Logic(),
          update: Logic(),
          fbBase: Logic(width: 32),
          memory: port ? null : HarborMemoryWaist(_memConfig),
          rqReady: port ? Logic() : null,
          rdValid: port ? Logic() : null,
          rdData: port ? Logic(width: 16) : null,
          lineStride: 2560,
          outputType: HarborDisplayInterface.parallelRgb,
        ).definitionName;
    const vga = HarborDisplayTiming.vga640x480();
    const short = HarborDisplayTiming(
      hActive: 640,
      hFrontPorch: 16,
      hSyncWidth: 96,
      hBackPorch: 48,
      vActive: 400,
      vFrontPorch: 12,
      vSyncWidth: 2,
      vBackPorch: 35,
      pixelClock: 25175000,
    );
    expect(name(vga), isNot(name(short)));
    expect(name(vga, port: true), isNot(name(short, port: true)));
    expect(
      VideoTimingGenerator(
        timing: vga,
        clk: Logic(),
        reset: Logic(),
      ).definitionName,
      isNot(
        VideoTimingGenerator(
          timing: short,
          clk: Logic(),
          reset: Logic(),
        ).definitionName,
      ),
    );
  });

  test('rgb888 pixel format throws', () {
    expect(
      () => _buildDisplay(
        timing: const HarborDisplayTiming.vga640x480(),
        pixelFormat: HarborPixelFormat.rgb888,
      ),
      throwsArgumentError,
    );
  });

  test('parallelRgb needs no shift clock, a TMDS output does', () async {
    HarborDualClockDisplay make(HarborDisplayInterface out) =>
        HarborDualClockDisplay(
          target: const HarborSimTarget(),
          timing: const HarborDisplayTiming.vga640x480(),
          pixelClk: Logic(),
          pixelReset: Logic(),
          sysClk: Logic(),
          sysReset: Logic(),
          enable: Logic(),
          update: Const(1),
          fbBase: Logic(width: 32),
          memory: HarborMemoryWaist(_memConfig),
          outputType: out,
        );
    final d = make(HarborDisplayInterface.parallelRgb);
    await d.build();
    expect(d.inputs.keys, isNot(contains('shift_clk')));
    expect(d.inputs.keys, isNot(contains('shift_reset')));
    expect(d.outputs.keys, contains('pclk'));
    expect(() => make(HarborDisplayInterface.hdmi), throwsArgumentError);
  });

  test('odd hActive with rgb565 throws', () {
    expect(
      () => _buildDisplay(
        timing: const HarborDisplayTiming(
          hActive: 9,
          hFrontPorch: 1,
          hSyncWidth: 1,
          hBackPorch: 1,
          vActive: 2,
          vFrontPorch: 1,
          vSyncWidth: 1,
          vBackPorch: 1,
          pixelClock: 1000000,
        ),
        pixelFormat: HarborPixelFormat.rgb565,
      ),
      throwsArgumentError,
    );
  });

  test('rgb565 scanout expands every pixel to 8-bit r/g/b', () async {
    const timing = HarborDisplayTiming(
      hActive: 8,
      hFrontPorch: 1,
      hSyncWidth: 1,
      hBackPorch: 1,
      vActive: 2,
      vFrontPorch: 1,
      vSyncWidth: 1,
      vBackPorch: 1,
      pixelClock: 1000000,
    );
    const hTotal = 11;
    const vTotal = 5;
    const stride = 16; // hActive * 2 bytes
    const fbBase = 0x100;

    // One line of rgb565 pixels, covering the required colors plus arbitrary
    // values on both even and odd columns.
    const pixels = [
      0xF800, // red, even col
      0x07E0, // green, odd col
      0x001F, // blue, even col
      0xFFFF, // white, odd col
      0x0000, // black, even col
      0x1234, // arbitrary, odd col
      0xABCD, // arbitrary, even col
      0x5678, // arbitrary, odd col
    ];
    const wordsPerLine = 4; // hActive / 2

    int wordAt(int wordIdx) =>
        (pixels[2 * wordIdx + 1] << 16) | pixels[2 * wordIdx];

    final mem = <int, int>{};
    for (var row = 0; row < timing.vActive; row++) {
      for (var w = 0; w < wordsPerLine; w++) {
        mem[fbBase + row * stride + w * 4] = wordAt(w);
      }
    }

    final pixelClk = SimpleClockGenerator(14).clk;
    final sysClk = SimpleClockGenerator(6).clk;
    final pixelReset = Logic(name: 'pixel_reset');
    final sysReset = Logic(name: 'sys_reset');
    final enable = Logic(name: 'enable');
    final base = Logic(name: 'fb_base', width: 32);
    final memory = HarborMemoryWaist(_memConfig);

    final disp = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      shiftClk: sysClk,
      shiftReset: sysReset,
      sysClk: sysClk,
      sysReset: sysReset,
      enable: enable,
      update: Const(1),
      fbBase: base,
      memory: memory,
      pixelFormat: HarborPixelFormat.rgb565,
    );
    final echo = EchoMemory(memory, sysClk, sysReset, table: mem);
    await disp.build();
    await echo.build();

    pixelReset.inject(1);
    sysReset.inject(1);
    enable.inject(1);
    base.inject(fbBase);
    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    addTearDown(() async {
      if (!Simulator.simulationHasEnded) {
        await Simulator.endSimulation();
      }
      Simulator.reset();
    });
    await pixelClk.nextPosedge;
    await pixelClk.nextPosedge;
    pixelReset.inject(0);
    sysReset.inject(0);
    await pixelClk.nextNegedge;

    // Run two full frames so frame-start priming has settled across the CDC.
    for (var i = 0; i < hTotal * vTotal * 2; i++) {
      await pixelClk.nextPosedge;
    }

    var checked = 0;
    for (var i = 0; i < hTotal * vTotal; i++) {
      await pixelClk.nextNegedge;
      if (disp.de.value.toInt() == 1) {
        final x = disp.x.value.toInt();
        final expected = _expandRgb565(pixels[x]);
        expect(disp.red.value.toInt(), equals(expected[0]), reason: 'x=$x r');
        expect(disp.green.value.toInt(), equals(expected[1]), reason: 'x=$x g');
        expect(disp.blue.value.toInt(), equals(expected[2]), reason: 'x=$x b');
        checked++;
      }
      await pixelClk.nextPosedge;
    }
    expect(checked, equals(timing.hActive * timing.vActive));
  });

  test('scans shared memory out as RGB across two clocks', () async {
    const timing = HarborDisplayTiming(
      hActive: 4,
      hFrontPorch: 1,
      hSyncWidth: 1,
      hBackPorch: 1,
      vActive: 2,
      vFrontPorch: 1,
      vSyncWidth: 1,
      vBackPorch: 1,
      pixelClock: 1000000,
    );
    const hTotal = 7;
    const vTotal = 5;
    const stride = 16;
    const fbBase = 0x100;

    final pixelClk = SimpleClockGenerator(14).clk;
    final sysClk = SimpleClockGenerator(6).clk;
    final pixelReset = Logic(name: 'pixel_reset');
    final sysReset = Logic(name: 'sys_reset');
    final enable = Logic(name: 'enable');
    final base = Logic(name: 'fb_base', width: 32);
    final memory = HarborMemoryWaist(_memConfig);

    final disp = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      shiftClk: sysClk, // gpdi not checked here, any clock suffices for shift
      shiftReset: sysReset,
      sysClk: sysClk,
      sysReset: sysReset,
      enable: enable,
      update: Const(1),
      fbBase: base,
      memory: memory,
    );
    final echo = EchoMemory(memory, sysClk, sysReset);
    await disp.build();
    await echo.build();

    pixelReset.inject(1);
    sysReset.inject(1);
    enable.inject(1);
    base.inject(fbBase);
    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    addTearDown(() async {
      if (!Simulator.simulationHasEnded) {
        await Simulator.endSimulation();
      }
      Simulator.reset();
    });
    await pixelClk.nextPosedge;
    await pixelClk.nextPosedge;
    pixelReset.inject(0);
    sysReset.inject(0);
    await pixelClk.nextNegedge;

    // Run two full frames so frame-start priming has settled across the CDC.
    for (var i = 0; i < hTotal * vTotal * 2; i++) {
      await pixelClk.nextPosedge;
    }

    var checked = 0;
    for (var i = 0; i < hTotal * vTotal; i++) {
      await pixelClk.nextNegedge;
      if (disp.de.value.toInt() == 1) {
        final x = disp.x.value.toInt();
        final y = disp.y.value.toInt();
        expect(
          disp.pixelWord.value.toInt(),
          equals(fbBase + y * stride + x * 4),
          reason: 'active pixel ($x,$y)',
        );
        checked++;
      }
      await pixelClk.nextPosedge;
    }
    expect(checked, equals(8));
  });

  // Every output must equal the timing generator from pipelineDelay cycles
  // before, and the word must be the one for that position. A one-stage slip
  // in de, hsync, vsync, x, y or the data fails here.
  test('sync, de and data leave the pipeline together', () async {
    await _alignment(HarborPixelFormat.xrgb8888);
  });

  // A YUV build converts with BT.709 limited after reset. The memory
  // answers each word with its address.
  for (final f in [HarborPixelFormat.nv12, HarborPixelFormat.yuyv]) {
    test('a ${f.name} frame leaves the pipeline with its sync', () async {
      await _alignment(f);
    });
  }

  test('a yuyv display without csc inputs converts with BT.709 limited', () {
    return _convert(
      formats: [HarborPixelFormat.yuyv],
      formatOf: (_) => 0,
      setOf: (_) => HarborCscCoefficients.bt709Limited,
      wired: false,
    );
  });

  // The inputs change in the active part of each frame. The display must
  // use them only from the next frame.
  // The blank of 2 is the least a YUV build takes.
  for (final blank in [4, HarborPixelUnpack.latency - 1]) {
    test('a new conversion set takes effect at the next frame start '
        '(blank $blank)', () {
      final sets = [
        HarborCscCoefficients.bt601Full,
        HarborCscCoefficients.bt2020Limited,
        HarborCscCoefficients.bt709Full,
      ];
      return _convert(
        formats: [HarborPixelFormat.yuyv],
        formatOf: (_) => 0,
        setOf: (f) => sets[f % 3],
        blank: blank,
      );
    });
  }

  // An xrgb8888 frame skips the conversion, a yuyv frame goes through it.
  test('a mixed set converts a yuv frame and passes an rgb frame', () {
    return _convert(
      formats: [HarborPixelFormat.xrgb8888, HarborPixelFormat.yuyv],
      formatOf: (f) => f % 2,
      setOf: (f) => f.isEven
          ? HarborCscCoefficients.bt601Limited
          : HarborCscCoefficients.bt2020Full,
    );
  });

  // The inputs hold another set and enable is low, so no frame start
  // loads them.
  test('the conversion latches reset to BT.709 limited', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic();
    final other = HarborCscCoefficients.bt2020Full.registers();
    final d = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: const HarborDisplayTiming.vga640x480(),
      pixelClk: clk,
      pixelReset: reset,
      sysClk: clk,
      sysReset: reset,
      enable: Const(0),
      update: Const(1),
      fbBase: Const(0, width: 32),
      memory: HarborMemoryWaist(_memConfig),
      outputType: HarborDisplayInterface.parallelRgb,
      pixelFormat: HarborPixelFormat.yuyv,
      cscCoeff: [for (var k = 0; k < 9; k++) Const(other[k], width: 16)],
      cscInOffset: [for (var j = 0; j < 3; j++) Const(other[9 + j], width: 10)],
      cscOutOffset: [
        for (var i = 0; i < 3; i++) Const(other[12 + i], width: 8),
      ],
    );
    await d.build();
    reset.inject(1);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    for (var c = 0; c < 4; c++) {
      await clk.nextPosedge;
    }
    final want = HarborCscCoefficients.bt709Limited.registers();
    final names = [
      for (var k = 0; k < 9; k++) 'csc_coeff_$k',
      for (var j = 0; j < 3; j++) 'csc_in_offset_$j',
      for (var i = 0; i < 3; i++) 'csc_out_offset_$i',
    ];
    for (final (k, name) in names.indexed) {
      final latch = d.internalSignals.singleWhere(
        (s) => s.name == '${name}_frame',
      );
      expect(latch.value.toInt(), want[k], reason: name);
    }
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('an rgb build has no conversion inputs', () async {
    final d = _buildDisplay(
      timing: const HarborDisplayTiming.vga640x480(),
      pixelFormat: HarborPixelFormat.xrgb8888,
    );
    await d.build();
    expect(d.csc, isNull);
    expect(d.inputs.keys.where((k) => k.startsWith('csc_')), isEmpty);
  });
}

/// Runs [frames] frames of a 4x2 mode with [blank] clocks of horizontal
/// blank from a table memory. At pixel (1, 0) of frame f the test sets
/// `format_sel` to `formatOf(f + 1)` and the conversion inputs to
/// `setOf(f + 1)`. Every active pixel of frame 2 and
/// up must match the unpack and conversion models.
Future<void> _convert({
  required List<HarborPixelFormat> formats,
  required int Function(int frame) formatOf,
  required HarborCscCoefficients Function(int frame) setOf,
  bool wired = true,
  int frames = 6,
  int blank = 4,
}) async {
  final timing = HarborDisplayTiming(
    hActive: 4,
    hFrontPorch: 1,
    hSyncWidth: 1,
    hBackPorch: blank - 2,
    vActive: 2,
    vFrontPorch: 1,
    vSyncWidth: 1,
    vBackPorch: 1,
    pixelClock: 1000000,
  );
  const stride = 16;
  const fbBase = 0x100;
  final rng = Random(formats.length);
  final table = {
    for (var a = 0; a < 2 * stride; a += 4) fbBase + a: rng.nextInt(1 << 32),
  };
  List<int> line(int y) => [
    for (var b = 0; b < stride; b++)
      (table[fbBase + y * stride + (b & ~3)]! >> (8 * (b & 3))) & 0xff,
  ];

  final pixelClk = SimpleClockGenerator(14).clk;
  final sysClk = SimpleClockGenerator(6).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final memory = HarborMemoryWaist(_memConfig);
  final multi = formats.length > 1;
  final formatSel = multi ? Logic(name: 'format_sel') : null;
  final coeff = [for (var k = 0; k < 9; k++) Logic(width: 16)];
  final inOff = [for (var j = 0; j < 3; j++) Logic(width: 10)];
  final outOff = [for (var i = 0; i < 3; i++) Logic(width: 8)];
  final update = Logic(name: 'update');
  final disp = HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: timing,
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    shiftClk: sysClk,
    shiftReset: sysReset,
    sysClk: sysClk,
    sysReset: sysReset,
    enable: Const(1),
    update: update,
    fbBase: Const(fbBase, width: 32),
    memory: memory,
    formats: formats,
    formatSel: formatSel,
    lineStride: multi ? null : stride,
    planePitch: multi ? [Const(stride, width: 32)] : const [],
    cscCoeff: wired ? coeff : null,
    cscInOffset: wired ? inOff : null,
    cscOutOffset: wired ? outOff : null,
  );
  final echo = EchoMemory(memory, sysClk, sysReset, table: table);
  await disp.build();
  await echo.build();
  final gen = disp.subModules.whereType<VideoTimingGenerator>().single;
  final delay = disp.pipelineDelay;

  // A register block writes the inputs, then pulses update. Frame 0 shows
  // nothing, so the values at reset need no update.
  void set(int frame, {bool pulse = true}) {
    formatSel?.inject(formatOf(frame));
    final regs = setOf(frame).registers();
    for (var k = 0; k < 9; k++) {
      coeff[k].inject(regs[k]);
    }
    for (var j = 0; j < 3; j++) {
      inOff[j].inject(regs[9 + j]);
      outOff[j].inject(regs[12 + j]);
    }
    if (pulse) pulseUpdate(update, sysClk);
  }

  pixelReset.inject(1);
  sysReset.inject(1);
  update.inject(0);
  set(0, pulse: false);
  Simulator.setMaxSimTime(50000000);
  unawaited(Simulator.run());
  addTearDown(() async {
    if (!Simulator.simulationHasEnded) {
      await Simulator.endSimulation();
    }
    Simulator.reset();
  });
  await pixelClk.nextPosedge;
  await pixelClk.nextPosedge;
  pixelReset.inject(0);
  sysReset.inject(0);

  // The frame of the timing generator on each cycle.
  final history = <int>[];
  var frame = -1;
  var checked = 0;
  while (frame < frames) {
    await pixelClk.nextNegedge;
    final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
    if (gx == 0 && gy == 0) frame++;
    history.add(frame);
    if (gx == 1 && gy == 0 && frame >= 0) set(frame + 1);
    if (history.length <= delay) continue;
    final f = history[history.length - 1 - delay];
    if (f < 2 || disp.de.value.toInt() != 1) continue;
    final (px, py) = (disp.x.value.toInt(), disp.y.value.toInt());
    final fmt = formats[formatOf(f)];
    final p = unpackLine(fmt, timing.hActive, [line(py)])[px];
    final want = fmt.yuv ? cscFixed(setOf(f), p.a, p.b, p.c) : [p.a, p.b, p.c];
    expect(
      [
        disp.red.value.toInt(),
        disp.green.value.toInt(),
        disp.blue.value.toInt(),
      ],
      equals(want),
      reason: 'frame $f ($px,$py) ${fmt.name}',
    );
    checked++;
  }
  expect(checked, (frames - 2) * timing.hActive * timing.vActive);
}

Future<void> _alignment(HarborPixelFormat format) async {
  const timing = HarborDisplayTiming(
    hActive: 4,
    hFrontPorch: 1,
    hSyncWidth: 2,
    hBackPorch: 1,
    vActive: 2,
    vFrontPorch: 1,
    vSyncWidth: 1,
    vBackPorch: 1,
    pixelClock: 1000000,
  );
  const hTotal = 8;
  const vTotal = 5;
  const stride = 16;
  const fbBase = 0x100;
  const chromaBase = 0x400;
  final planar = format.planes.length > 1;

  final pixelClk = SimpleClockGenerator(14).clk;
  final sysClk = SimpleClockGenerator(6).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final enable = Logic(name: 'enable');
  final base = Logic(name: 'fb_base', width: 32);
  final memory = HarborMemoryWaist(_memConfig);

  final disp = HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: timing,
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    shiftClk: sysClk,
    shiftReset: sysReset,
    sysClk: sysClk,
    sysReset: sysReset,
    enable: enable,
    update: Const(1),
    fbBase: base,
    memory: memory,
    pixelFormat: format,
    lineStride: planar ? null : stride,
    planeBase: planar ? [Const(chromaBase, width: 32)] : const [],
    planePitch: planar
        ? [Const(stride, width: 32), Const(stride, width: 32)]
        : const [],
  );
  final echo = EchoMemory(memory, sysClk, sysReset);
  await disp.build();
  await echo.build();
  final gen = disp.subModules.whereType<VideoTimingGenerator>().single;
  final delay = disp.pipelineDelay;
  expect(
    delay,
    format.yuv ? HarborPixelUnpack.latency + HarborCsc.stages + 1 : 2,
  );

  pixelReset.inject(1);
  sysReset.inject(1);
  enable.inject(1);
  base.inject(fbBase);
  Simulator.setMaxSimTime(50000000);
  unawaited(Simulator.run());
  addTearDown(() async {
    if (!Simulator.simulationHasEnded) {
      await Simulator.endSimulation();
    }
    Simulator.reset();
  });
  await pixelClk.nextPosedge;
  await pixelClk.nextPosedge;
  pixelReset.inject(0);
  sysReset.inject(0);
  await pixelClk.nextNegedge;

  for (var i = 0; i < hTotal * vTotal * 2; i++) {
    await pixelClk.nextPosedge;
  }

  List<int> sample(List<Logic> signals) => [
    for (final s in signals) s.value.toInt(),
  ];
  final history = <List<int>>[];
  var active = 0;
  var syncEdges = 0;
  for (var i = 0; i < hTotal * vTotal * 2; i++) {
    await pixelClk.nextNegedge;
    history.add(sample([gen.de, gen.hsync, gen.vsync, gen.x, gen.y]));
    if (history.length > delay + 1) {
      final want = history[history.length - 1 - delay];
      final got = sample([disp.de, disp.hsync, disp.vsync, disp.x, disp.y]);
      expect(got, equals(want), reason: 'cycle $i: de, hsync, vsync, x, y');
      if (got[0] == 1) {
        final (px, py) = (got[3], got[4]);
        final rgb = sample([disp.red, disp.green, disp.blue]);
        if (format.yuv) {
          List<int> line(int base) => [
            for (var b = 0; b < stride; b++)
              ((base + (b & ~3)) >> (8 * (b & 3))) & 0xff,
          ];
          final p = unpackLine(format, timing.hActive, [
            line(fbBase + py * stride),
            if (planar) line(chromaBase + (py >> 1) * stride),
          ])[px];
          expect(
            rgb,
            equals(cscFixed(HarborCscCoefficients.bt709Limited, p.a, p.b, p.c)),
            reason: 'cycle $i',
          );
        } else {
          expect(
            disp.pixelWord.value.toInt(),
            equals(fbBase + py * stride + px * 4),
            reason: 'cycle $i: word for ($px,$py)',
          );
        }
        active++;
      }
      final before = history[history.length - 2 - delay];
      if (before[1] != want[1] || before[2] != want[2]) syncEdges++;
    }
  }
  expect(active, greaterThanOrEqualTo(timing.hActive * timing.vActive));
  expect(syncEdges, greaterThan(4), reason: 'the window must hold sync edges');
}

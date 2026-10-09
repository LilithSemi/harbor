import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

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
    fbBase: Logic(name: 'fb_base', width: 32),
    mDataIn: Logic(name: 'm_dat_i', width: 32),
    mAck: Logic(name: 'm_ack'),
    pixelFormat: pixelFormat,
  );
}

void main() {
  test('rgb888 pixel format throws', () {
    expect(
      () => _buildDisplay(
        timing: const HarborDisplayTiming.vga640x480(),
        pixelFormat: HarborPixelFormat.rgb888,
      ),
      throwsArgumentError,
    );
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
    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');

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
      fbBase: base,
      mDataIn: mDataIn,
      mAck: mAck,
      pixelFormat: HarborPixelFormat.rgb565,
    );
    mAck <= disp.mStb;
    final fbAddr = disp.mAddr;
    Logic fbData = Const(0, width: 32);
    mem.forEach((a, v) {
      fbData = mux(fbAddr.eq(Const(a, width: 32)), Const(v, width: 32), fbData);
    });
    mDataIn <= fbData;
    await disp.build();

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
    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');

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
      fbBase: base,
      mDataIn: mDataIn,
      mAck: mAck,
    );
    mAck <= disp.mStb;
    mDataIn <= disp.mAddr;
    await disp.build();

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

    final pixelClk = SimpleClockGenerator(14).clk;
    final sysClk = SimpleClockGenerator(6).clk;
    final pixelReset = Logic(name: 'pixel_reset');
    final sysReset = Logic(name: 'sys_reset');
    final enable = Logic(name: 'enable');
    final base = Logic(name: 'fb_base', width: 32);
    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');

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
      fbBase: base,
      mDataIn: mDataIn,
      mAck: mAck,
    );
    mAck <= disp.mStb;
    mDataIn <= disp.mAddr;
    await disp.build();
    final gen = disp.subModules.whereType<VideoTimingGenerator>().single;

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
      if (history.length > HarborDualClockDisplay.pipelineDelay + 1) {
        final want =
            history[history.length - 1 - HarborDualClockDisplay.pipelineDelay];
        final got = sample([disp.de, disp.hsync, disp.vsync, disp.x, disp.y]);
        expect(got, equals(want), reason: 'cycle $i: de, hsync, vsync, x, y');
        if (got[0] == 1) {
          expect(
            disp.pixelWord.value.toInt(),
            equals(fbBase + got[4] * stride + got[3] * 4),
            reason: 'cycle $i: word for (${got[3]},${got[4]})',
          );
          active++;
        }
        final before =
            history[history.length - 2 - HarborDualClockDisplay.pipelineDelay];
        if (before[1] != want[1] || before[2] != want[2]) syncEdges++;
      }
    }
    expect(active, greaterThanOrEqualTo(timing.hActive * timing.vActive));
    expect(
      syncEdges,
      greaterThan(4),
      reason: 'the window must hold sync edges',
    );
  });
}

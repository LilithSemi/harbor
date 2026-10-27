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

void main() {
  group('enable', () {
    late Logic pixelClk;
    late Logic sysClk;
    late Logic enable;
    late Logic update;
    late HarborDualClockDisplay d;
    late WaistMemory m;
    late VideoTimingGenerator gen;

    Future<void> start() async {
      pixelClk = SimpleClockGenerator(20).clk;
      sysClk = SimpleClockGenerator(4).clk;
      final pixelReset = Logic(name: 'pixel_reset');
      final sysReset = Logic(name: 'sys_reset');
      enable = Logic(name: 'enable');
      update = Logic(name: 'update');
      final memory = HarborMemoryWaist(_memConfig);
      d = HarborDualClockDisplay(
        target: const HarborSimTarget(),
        timing: _timing,
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        sysClk: sysClk,
        sysReset: sysReset,
        enable: enable,
        update: update,
        fbBase: Const(0x10000, width: 32),
        memory: memory,
        outputType: HarborDisplayInterface.parallelRgb,
      );
      await d.build();
      m = WaistMemory(memory, sysClk, latency: 4);
      gen = d.subModules.whereType<VideoTimingGenerator>().single;
      pixelReset.inject(1);
      sysReset.inject(1);
      update.inject(0);
      enable.inject(0);
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

    // Runs to the end of [frames] and gives the count of `de` clocks of
    // each frame.
    Future<Map<int, int>> run(
      int frames,
      FutureOr<void> Function(int frame, int x, int y) onCycle,
    ) async {
      final de = <int, int>{};
      var frame = -1;
      while (frame < frames) {
        await pixelClk.nextNegedge;
        final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
        if (gx == 0 && gy == 0) frame++;
        if (frame >= 0) {
          de[frame] = (de[frame] ?? 0) + d.de.value.toInt();
        }
        await onCycle(frame, gx, gy);
      }
      return de;
    }

    test('an update with enable low clears update_pending', () async {
      await start();
      final pending = <int>[];
      await run(3, (f, x, y) {
        if (f == 1 && x == 0 && y == 2) pulseUpdate(update, sysClk);
        if (f == 1 && x == 4 && y == 2)
          pending.add(d.updatePending.value.toInt());
      });
      expect(pending, [1]);
      expect(d.updatePending.value.toInt(), 0);
      expect(m.requests, isEmpty);
    });

    test('enable takes effect on a frame boundary', () async {
      await start();
      var requestsOff = -1;
      final de = await run(5, (f, x, y) {
        if (f == 1 && x == 0 && y == 3) {
          enable.inject(1);
          pulseUpdate(update, sysClk);
        }
        if (f == 1 && x == 5 && y == 3) requestsOff = m.requests.length;
        if (f == 3 && x == 0 && y == 3) {
          enable.inject(0);
          pulseUpdate(update, sysClk);
        }
      });
      const full = 16 * 8;
      expect([for (var f = 0; f <= 5; f++) de[f]], [0, 0, full, full, 0, 0]);
      expect(requestsOff, 0);
      expect(m.requests, isNotEmpty);
      expect(d.updatePending.value.toInt(), 0);
    });
  });

  // In port mode the control side is on its own clock, faster and slower
  // than the port clock.
  for (final controlPeriod in [2, 14]) {
    test('a port mode display with a control clock of period '
        '$controlPeriod takes an update once and gives the underrun '
        'counts', () async {
      final pixelClk = SimpleClockGenerator(20).clk;
      final scanClk = SimpleClockGenerator(4).clk;
      final ctrlClk = SimpleClockGenerator(controlPeriod).clk;
      final pixelReset = Logic(name: 'pixel_reset');
      final scanReset = Logic(name: 'scan_reset');
      final ctrlReset = Logic(name: 'ctrl_reset');
      final update = Logic(name: 'update');
      final fbBase = Logic(name: 'fb_base', width: 32);
      final rqReady = Logic(name: 'rq_ready');
      final rdValid = Logic(name: 'rd_valid');
      final rdData = Logic(name: 'rd_data', width: 16);
      final d = HarborDualClockDisplay(
        target: const HarborSimTarget(),
        timing: _timing,
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        sysClk: scanClk,
        sysReset: scanReset,
        controlClk: ctrlClk,
        controlReset: ctrlReset,
        enable: Const(1),
        update: update,
        fbBase: fbBase,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
        outputType: HarborDisplayInterface.parallelRgb,
        formats: const [HarborPixelFormat.xrgb8888, HarborPixelFormat.rgb565],
        formatSel: Const(0),
        planePitch: [Const(64, width: 32)],
      );
      await d.build();
      final scanout = d.subModules.whereType<HarborDualClockScanout>().single;
      final gen = d.subModules.whereType<VideoTimingGenerator>().single;
      // Each line comes late, so each line is an underrun.
      final mem = PortMemory(
        rqValid: d.rqValid,
        rqAddr: d.rqAddr,
        rqWords: d.rqWords,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
        clk: scanClk,
        latency: 300,
      );
      final toggle = d.signals.firstWhere((s) => s.name == 'update_toggle');
      for (final r in [pixelReset, scanReset, ctrlReset]) {
        r.inject(1);
      }
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
      for (final r in [pixelReset, scanReset, ctrlReset]) {
        r.inject(0);
      }

      // Every control clock value of a count is a value that the port
      // side count had, and it does not go down.
      final out = d.output('plane_underrun_count_0');
      final src = scanout.planeUnderrunCount(0);
      var last = 0;
      final seen = <int>{0};
      var flips = 0;
      var prevToggle = 0;
      final bad = <String>[];
      ctrlClk.posedge.listen((_) {
        final v = out.value;
        if (!v.isValid) return;
        final n = v.toInt();
        if (n < last || !seen.contains(n)) bad.add('$n after $last');
        last = n;
        final t = toggle.value.toInt();
        if (t != prevToggle) flips++;
        prevToggle = t;
      });
      scanClk.posedge.listen((_) {
        final v = src.value;
        if (v.isValid) seen.add(v.toInt());
      });

      final first = <int, int>{};
      var frame = -1;
      var flipsBefore = -1;
      while (frame < 6) {
        await pixelClk.nextNegedge;
        final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
        if (gx == 0 && gy == 0) frame++;
        if (gx == 0 && gy == _timing.vActive) {
          first[frame + 1] = mem.requests.length;
        }
        if (frame == 2 && gx == 0 && gy == 2) {
          flipsBefore = flips;
          fbBase.inject(0x20000);
          pulseUpdate(update, ctrlClk);
        }
        if (frame == 4 && gx == 0 && gy == 0) mem.latency = 4;
      }
      expect(flips - flipsBefore, 1);
      expect(d.updatePending.value.toInt(), 0);
      expect(mem.requests[first[2]!].$1, 0x10000);
      expect(mem.requests[first[3]!].$1, 0x20000);
      expect(bad, isEmpty);
      final n = src.value.toInt();
      expect(n, greaterThan(4));
      expect(out.value.toInt(), n);
    });
  }

  // A port mode display with its own control clock. fb_base changes in
  // frame 2 with no update, then one reset goes in the vertical blank of
  // frame 3.
  for (final control in [true, false]) {
    final what = control
        ? 'control_reset alone copies the live inputs'
        : 'sys_reset alone does not touch the update handshake';
    test(what, () async {
      final pixelClk = SimpleClockGenerator(20).clk;
      final scanClk = SimpleClockGenerator(4).clk;
      final ctrlClk = SimpleClockGenerator(14).clk;
      final pixelReset = Logic(name: 'pixel_reset');
      final scanReset = Logic(name: 'scan_reset');
      final ctrlReset = Logic(name: 'ctrl_reset');
      final update = Logic(name: 'update');
      final fbBase = Logic(name: 'fb_base', width: 32);
      final rqReady = Logic(name: 'rq_ready');
      final rdValid = Logic(name: 'rd_valid');
      final rdData = Logic(name: 'rd_data', width: 16);
      final d = HarborDualClockDisplay(
        target: const HarborSimTarget(),
        timing: _timing,
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        sysClk: scanClk,
        sysReset: scanReset,
        controlClk: ctrlClk,
        controlReset: ctrlReset,
        enable: Const(1),
        update: update,
        fbBase: fbBase,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
        outputType: HarborDisplayInterface.parallelRgb,
        formats: const [HarborPixelFormat.xrgb8888, HarborPixelFormat.rgb565],
        formatSel: Const(0),
        planePitch: [Const(64, width: 32)],
      );
      await d.build();
      final gen = d.subModules.whereType<VideoTimingGenerator>().single;
      final mem = PortMemory(
        rqValid: d.rqValid,
        rqAddr: d.rqAddr,
        rqWords: d.rqWords,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
        clk: scanClk,
      );
      Logic sig(String n) => d.signals.firstWhere((s) => s.name == n);
      final toggle = sig('update_toggle');
      final ack = sig('update_ack');
      for (final r in [pixelReset, scanReset, ctrlReset]) {
        r.inject(1);
      }
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
      for (final r in [pixelReset, scanReset, ctrlReset]) {
        r.inject(0);
      }

      // The handshake state at each control clock from frame 2 on.
      var watch = false;
      final toggles = <int>{};
      final acks = <int>{};
      final pending = <int>{};
      ctrlClk.posedge.listen((_) {
        if (!watch) return;
        toggles.add(toggle.value.toInt());
        acks.add(ack.value.toInt());
        pending.add(d.updatePending.value.toInt());
      });

      final first = <int, int>{};
      var frame = -1;
      while (frame < 6) {
        await pixelClk.nextNegedge;
        final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
        if (gx == 0 && gy == 0) frame++;
        if (gx == 0 && gy == _timing.vActive) {
          first[frame + 1] = mem.requests.length;
        }
        if (frame == 2 && gx == 0 && gy == 0) watch = true;
        if (frame == 2 && gx == 0 && gy == 2) fbBase.inject(0x30000);
        if (frame == 3 && gx == 0 && gy == _timing.vActive + 2) {
          final (r, clk) = control
              ? (ctrlReset, ctrlClk)
              : (scanReset, scanClk);
          r.inject(1);
          for (var i = 0; i < 3; i++) {
            await clk.nextPosedge;
          }
          r.inject(0);
        }
      }
      int baseOf(int f) => mem.requests[first[f]!].$1;
      expect(baseOf(2), 0x10000);
      expect(baseOf(3), 0x10000);
      expect(baseOf(4), 0x10000);
      expect([
        baseOf(5),
        baseOf(6),
      ], control ? [0x30000, 0x30000] : [0x10000, 0x10000]);
      expect(d.updatePending.value.toInt(), 0);
      if (!control) {
        expect(toggles, hasLength(1));
        expect(acks, hasLength(1));
        expect(pending, {0});
      }
    });
  }

  // A 1-clock control_reset on a fast control clock while an update waits
  // for its take. The reset goes in at each control clock up to 12 before
  // the take. The control side must not copy the inputs from a take to
  // its load.
  for (final controlPeriod in [2, 4]) {
    test('a 1-clock control_reset of period $controlPeriod during an '
        'update does not change the set that the pixel side takes', () async {
      final pixelClk = SimpleClockGenerator(20).clk;
      final scanClk = SimpleClockGenerator(4).clk;
      final ctrlClk = SimpleClockGenerator(controlPeriod).clk;
      final pixelReset = Logic(name: 'pixel_reset');
      final scanReset = Logic(name: 'scan_reset');
      final ctrlReset = Logic(name: 'ctrl_reset');
      final update = Logic(name: 'update');
      final fbBase = Logic(name: 'fb_base', width: 32);
      final rqReady = Logic(name: 'rq_ready');
      final rdValid = Logic(name: 'rd_valid');
      final rdData = Logic(name: 'rd_data', width: 16);
      final d = HarborDualClockDisplay(
        target: const HarborSimTarget(),
        timing: _timing,
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        sysClk: scanClk,
        sysReset: scanReset,
        controlClk: ctrlClk,
        controlReset: ctrlReset,
        enable: Const(1),
        update: update,
        fbBase: fbBase,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
        outputType: HarborDisplayInterface.parallelRgb,
        formats: const [HarborPixelFormat.xrgb8888, HarborPixelFormat.rgb565],
        formatSel: Const(0),
        planePitch: [Const(64, width: 32)],
      );
      await d.build();
      final gen = d.subModules.whereType<VideoTimingGenerator>().single;
      final mem = PortMemory(
        rqValid: d.rqValid,
        rqAddr: d.rqAddr,
        rqWords: d.rqWords,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
        clk: scanClk,
      );
      Logic sig(String n) => d.signals.firstWhere((s) => s.name == n);
      final take = sig('update_take');
      final capture = sig('update_capture');
      for (final r in [pixelReset, scanReset, ctrlReset]) {
        r.inject(1);
      }
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
      for (final r in [pixelReset, scanReset, ctrlReset]) {
        r.inject(0);
      }

      // The edge times of each take and each capture. The values are read
      // half a clock before the edge.
      final takes = <int>[];
      final captures = <int>[];
      pixelClk.negedge.listen((_) {
        if (take.value == LogicValue.one) takes.add(Simulator.time + 10);
      });
      ctrlClk.negedge.listen((_) {
        if (capture.value == LogicValue.one) {
          captures.add(Simulator.time + controlPeriod ~/ 2);
        }
      });

      const tries = 12;
      final h = _timing.hTotal;
      final first = <int, int>{};
      var frame = -1;
      while (frame < 2 * tries + 3) {
        await pixelClk.nextNegedge;
        final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
        if (gx == 0 && gy == 0) frame++;
        if (gx == 0 && gy == _timing.vActive) {
          first[frame + 1] = mem.requests.length;
        }
        final i = (frame - 2) ~/ 2;
        if (frame < 2 || frame.isOdd || i >= tries) continue;
        if (gx == 0 && gy == 2) {
          fbBase.inject(0x20000 + 0x10000 * i);
          pulseUpdate(update, ctrlClk);
        }
        // The take edge is 3.5 pixel clocks after this negedge.
        if (gx == h - 4 && gy == _timing.vActive - 1) {
          final edge = Simulator.time + 70 - (i + 1) * controlPeriod;
          for (var n = 0; Simulator.time < edge - controlPeriod; n++) {
            if (n > 100) fail('no control clock before $edge');
            await ctrlClk.nextNegedge;
          }
          ctrlReset.inject(1);
          await ctrlClk.nextNegedge;
          ctrlReset.inject(0);
        }
      }
      final torn = [
        for (final t in takes)
          for (final c in captures)
            if (c >= t && c <= t + 20) 'take $t capture $c',
      ];
      expect(takes.length, greaterThanOrEqualTo(tries));
      expect(torn, isEmpty);
      for (var i = 0; i < tries; i++) {
        expect(
          mem.requests[first[2 * i + 4]!].$1,
          0x20000 + 0x10000 * i,
          reason: 'try $i',
        );
      }
      expect(d.updatePending.value.toInt(), 0);
    });
  }
}

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'plane_memory.dart';

// 1920 pixel lines of 1960 cycles, 3 active lines and 6 in a frame. The
// first frame start comes at pixel cycle 5880, the second at 17640 and the
// third at 29400.
const _timing = HarborDisplayTiming(
  hActive: 1920,
  hFrontPorch: 1,
  hSyncWidth: 1,
  hBackPorch: 38,
  vActive: 3,
  vFrontPorch: 1,
  vSyncWidth: 1,
  vBackPorch: 1,
  pixelClock: 1000000,
);

const _fb = 0x10000;
const _base1 = 0x100000;

/// Every line fetch that the [HarborLineFetcher] under [top] starts, as
/// (byte address, words).
List<(int, int)> _lineFetches(Module top, Logic clk) {
  Iterable<Module> all(Module m) sync* {
    yield m;
    for (final s in m.subModules) {
      yield* all(s);
    }
  }

  final f = all(top).whereType<HarborLineFetcher>().single;
  final out = <(int, int)>[];
  clk.posedge.listen((_) {
    final start = f.input('fetch_start').previousValue;
    if (start != null && start.isValid && start.toBool()) {
      out.add((
        f.input('fetch_addr').previousValue!.toInt(),
        f.input('words').previousValue!.toInt(),
      ));
    }
  });
  return out;
}

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('an xrgb8888 and nv12 build takes the plane 0 pitch of each '
      'frame', () async {
    final pixelClk = SimpleClockGenerator(14).clk;
    final sysClk = SimpleClockGenerator(6).clk;
    final pixelReset = Logic(name: 'pixel_reset');
    final sysReset = Logic(name: 'sys_reset');
    final formatSel = Logic(name: 'format_sel');
    final pitch0 = Logic(name: 'pitch0', width: 32);
    final update = Logic(name: 'update');
    final memory = HarborMemoryWaist(
      const HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: 2,
      ),
    );
    final d = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: _timing,
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
      enable: Const(1),
      update: update,
      fbBase: Const(_fb, width: 32),
      memory: memory,
      burstWords: 64,
      outputType: HarborDisplayInterface.parallelRgb,
      formats: const [HarborPixelFormat.xrgb8888, HarborPixelFormat.nv12],
      formatSel: formatSel,
      planeBase: [Const(_base1, width: 32)],
      planePitch: [pitch0, Const(1920, width: 32)],
    );
    await d.build();
    WaistMemory(memory, sysClk, latency: 3);
    final fetches = _lineFetches(d, sysClk);
    pixelReset.inject(1);
    sysReset.inject(1);
    formatSel.inject(0);
    pitch0.inject(7680);
    update.inject(0);
    Simulator.setMaxSimTime(1 << 40);
    unawaited(Simulator.run());
    await pixelClk.nextPosedge;
    await pixelClk.nextPosedge;
    pixelReset.inject(0);
    sysReset.inject(0);
    pulseUpdate(update, sysClk);
    for (var c = 0; c < 28000; c++) {
      await pixelClk.nextNegedge;
      if (c == 12000) {
        formatSel.inject(1);
        pitch0.inject(1920);
        pulseUpdate(update, sysClk);
      }
    }
    expect(fetches, [
      (0x10000, 1920),
      (0x11E00, 1920),
      (0x13C00, 1920),
      (0x10000, 480),
      (0x100000, 480),
      (0x10780, 480),
      (0x100780, 480),
      (0x10F00, 480),
    ]);
    expect(d.underrun.value.toInt(), 0);
    expect(d.output('plane_underrun_count_0').value.toInt(), 0);
    expect(d.output('plane_underrun_count_1').value.toInt(), 0);
  }, timeout: const Timeout(Duration(minutes: 30)));
}

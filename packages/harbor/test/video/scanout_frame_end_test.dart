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

const _base = 0x1000;
const _stride = 128;

/// Runs an xrgb8888 display for 7 frames. All requests of frame 3 have
/// latency [slow], also the requests that are still in flight at the
/// frame start of frame 4. All other requests have latency 4. A frame
/// with a wrong row must have `underrun` high in its last row. Frame 3
/// must have a wrong row, and the frames after it must be correct with
/// `underrun` low. With [late4], only the requests from row 5 of frame 3
/// to the frame start of frame 4 are slow, and frame 4 must have a wrong
/// row 0, because the line in flight at its frame start ends after its
/// line 0 starts. With [planar], the build has two formats and uses the
/// planar scanout.
Future<void> _run({
  required bool port,
  required bool planar,
  required int slow,
  bool late4 = false,
}) async {
  final pixelClk = SimpleClockGenerator(20).clk;
  final sysClk = SimpleClockGenerator(4).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final memory = port
      ? null
      : HarborMemoryWaist(
          const HarborMemoryWaistConfig(
            addressWidth: 32,
            dataWidth: 32,
            outstanding: 4,
          ),
        );
  final rqReady = Logic(name: 'rq_ready');
  final rdValid = Logic(name: 'rd_valid');
  final rdData = Logic(name: 'rd_data', width: 16);
  final disp = HarborDualClockDisplay(
    target: const HarborSimTarget(),
    timing: _timing,
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    sysClk: sysClk,
    sysReset: sysReset,
    enable: Const(1),
    fbBase: Const(_base, width: 32),
    memory: memory,
    rqReady: port ? rqReady : null,
    rdValid: port ? rdValid : null,
    rdData: port ? rdData : null,
    lineStride: planar ? null : _stride,
    formats: planar
        ? const [HarborPixelFormat.xrgb8888, HarborPixelFormat.rgb565]
        : null,
    formatSel: planar ? Const(0) : null,
    planePitch: planar ? [Const(_stride, width: 32)] : const [],
    outputType: HarborDisplayInterface.parallelRgb,
  );
  await disp.build();
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
    );
    setLatency = (l) => m.latency = l;
  } else {
    final m = WaistMemory(memory!, sysClk, latency: 4);
    setLatency = (l) => m.latency = l;
  }
  final gen = disp.subModules.whereType<VideoTimingGenerator>().single;
  final delay = disp.pipelineDelay;

  pixelReset.inject(1);
  sysReset.inject(1);
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

  const frames = 7;
  final history = <int>[];
  final bad = <int, Set<int>>{};
  final underrun = <int, bool>{};
  var frame = -1;
  while (frame < frames) {
    await pixelClk.nextNegedge;
    final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
    if (gx == 0 && gy == 0) frame++;
    if (gx == 0 && gy == _timing.vActive) {
      setLatency(frame == 2 && !late4 ? slow : 4);
    }
    if (late4 && frame == 3 && gx == 0 && gy == _timing.vActive - 3) {
      setLatency(slow);
    }
    if (gx == 0 && gy == _timing.vActive - 1 && frame >= 2) {
      underrun[frame] = disp.underrun.value.toInt() == 1;
    }
    history.add(frame);
    if (history.length <= delay) continue;
    final f = history[history.length - 1 - delay];
    if (f < 2 || f >= frames || disp.de.value.toInt() != 1) continue;
    final (px, py) = (disp.x.value.toInt(), disp.y.value.toInt());
    final v = disp.pixelWord.value;
    if (!v.isValid || v.toInt() != _base + py * _stride + 4 * px) {
      (bad[f] ??= {}).add(py);
    }
  }
  for (final f in bad.keys) {
    expect(underrun[f], isTrue, reason: 'frame $f rows ${bad[f]}');
  }
  expect(bad.keys, [3, if (late4) 4], reason: '$bad');
  if (late4) expect(bad[4], contains(0));
  expect(underrun, {2: false, 3: true, 4: late4, 5: false, 6: false});
}

void main() {
  for (final planar in [false, true]) {
    for (final port in [false, true]) {
      final kind =
          '${planar ? 'a planar' : 'a one plane'} scanout on '
          '${port ? 'a scanout port' : 'a memory waist'}';
      for (final slow in [150, 250]) {
        test('a frame slow to its end flags its rows and keeps the next '
            'frame on $kind, latency $slow', () async {
          await _run(port: port, planar: planar, slow: slow);
        });
      }
      test('a line in flight past line 0 of the next frame flags line 0 on '
          '$kind', () async {
        await _run(port: port, planar: planar, slow: 900, late4: true);
      });
    }
  }
}

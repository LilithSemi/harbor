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

/// Runs a one plane xrgb8888 display for two frames that prime it, then
/// one frame for each entry of [slow]. In frame f, request n after its
/// frame start has latency l when `slow[f - 2]` is (n, l, r), and all
/// other requests have latency 4. The rows from r on of that frame must
/// be the correct rows, and all rows of the other frames. `underrun` must
/// be high in the last row of each slow frame and low in the last row of
/// each other frame.
Future<void> _run({
  required bool port,
  required List<(int, int, int)?> slow,
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
    lineStride: _stride,
    outputType: HarborDisplayInterface.parallelRgb,
  );
  await disp.build();
  final List<(int, int)> requests;
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
    requests = m.requests;
    setLatency = (l) => m.latency = l;
  } else {
    final m = WaistMemory(memory!, sysClk, latency: 4);
    requests = m.requests;
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

  final frames = slow.length + 2;
  (int, int, int)? slowOf(int f) => f < 2 || f >= frames ? null : slow[f - 2];
  final history = <int>[];
  final underrun = <int, bool>{};
  var frame = -1;
  var checked = 0;
  (int, int)? slowAt;
  while (frame < frames) {
    await pixelClk.nextNegedge;
    final (gx, gy) = (gen.x.value.toInt(), gen.y.value.toInt());
    if (gx == 0 && gy == 0) frame++;
    if (gx == 0 && gy == _timing.vActive) {
      if (slowOf(frame + 1) case (final n, final l, _)) {
        slowAt = (requests.length + n, l);
      }
    }
    if (slowAt case (final at, final l)) {
      if (requests.length == at) {
        setLatency(l);
      } else if (requests.length > at) {
        setLatency(4);
        slowAt = null;
      }
    }
    if (gx == 0 && gy == _timing.vActive - 1 && frame >= 2) {
      underrun[frame] = disp.underrun.value.toInt() == 1;
    }
    history.add(frame);
    if (history.length <= delay) continue;
    final f = history[history.length - 1 - delay];
    if (f < 2 || f >= frames || disp.de.value.toInt() != 1) continue;
    final (px, py) = (disp.x.value.toInt(), disp.y.value.toInt());
    if (py < (slowOf(f)?.$3 ?? 0)) continue;
    expect(
      disp.pixelWord.value.toInt(),
      _base + py * _stride + 4 * px,
      reason: 'frame $f ($px, $py)',
    );
    checked++;
  }
  expect(
    checked,
    slow.fold(0, (a, s) => a + _timing.vActive - (s?.$3 ?? 0)) *
        _timing.hActive,
  );
  expect(underrun, {for (var f = 2; f < frames; f++) f: slowOf(f) != null});
  final end = _base + _timing.vActive * _stride;
  for (final (a, _) in requests) {
    expect(a, lessThan(end), reason: 'a fetch past the frame');
  }
}

void main() {
  for (final port in [false, true]) {
    test('a one plane scanout on '
        '${port ? 'a scanout port' : 'a memory waist'} fetches no line past '
        'the frame', () async {
      await _run(port: port, slow: const [null, null]);
    });
  }

  // Line 0 is late, so one or more line starts come before the prime
  // sends line 1. Request n is the first request of line 0.
  for (final port in [false, true]) {
    final mode = port ? 'a scanout port' : 'a memory waist';
    test('a line start in the first prime step on $mode sets underrun '
        'and keeps the rows', () async {
      await _run(
        port: port,
        slow: const [(0, 600, 2), null, (0, 1000, 5), null],
      );
    });

    // Line 1 is late, so a line start comes before the prime ends.
    test('a line start in the second prime step on $mode sets underrun '
        'and keeps the rows', () async {
      final n = port ? 4 : 1;
      await _run(port: port, slow: [(n, 600, 2), null, (n, 900, 5), null]);
    });
  }
}

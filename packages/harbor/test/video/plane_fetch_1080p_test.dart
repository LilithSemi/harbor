import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'plane_memory.dart';

// 1080p60: 148.5 MHz pixel clock, 2200 pixel cycles a line.
const _pixelPs = 6734;
const _hActive = 1920;
const _hTotal = 2200;

// The memory runs at 150 MHz. Its first beat comes 24 cycles (160 ns)
// after a take, then one 32-bit beat each cycle: 600 MB/s peak.
const _sysPs = 6667;
const _latency = 24;

const _y = 0x01000000;
const _c = 0x02000000;

/// Scans [lines] luma lines of [format] after a frame start and three
/// blank lines. Checks every word that the read side gives back.
Future<void> _scan(HarborPixelFormat format, {int lines = 6}) async {
  final pixelClk = SimpleClockGenerator(_pixelPs).clk;
  final sysClk = SimpleClockGenerator(_sysPs).clk;
  final pixelReset = Logic(name: 'pixel_reset');
  final sysReset = Logic(name: 'sys_reset');
  final frameStart = Logic(name: 'frame_start');
  final lineStart = Logic(name: 'line_start');
  final col0 = Logic(name: 'col0', width: 11);
  final col1 = Logic(name: 'col1', width: 11);
  final pitch0 = format.lineBytes(0, _hActive);
  final pitch1 = format.lineBytes(1, _hActive);
  final memory = HarborMemoryWaist(
    const HarborMemoryWaistConfig(
      addressWidth: 32,
      dataWidth: 32,
      outstanding: 4,
    ),
  );
  final so = HarborDualClockScanout(
    pixelClk: pixelClk,
    pixelReset: pixelReset,
    sysClk: sysClk,
    sysReset: sysReset,
    frameStart: frameStart,
    lineStart: lineStart,
    col: col0,
    fbBase: Const(_y, width: 32),
    stride: Const(pitch0, width: 32),
    memory: memory,
    formats: [format],
    hActive: _hActive,
    vActive: 1080,
    planeBase: [Const(_c, width: 32)],
    planePitch: [Const(pitch1, width: 32)],
    planeCol: [col1],
  );
  await so.build();
  final mem = WaistMemory(memory, sysClk, latency: _latency, depth: 4);
  var busy = 0;
  var cycles = 0;
  sysClk.posedge.listen((_) {
    cycles++;
    if (memory.rdataValid.value.toBool()) busy++;
  });

  pixelReset.inject(1);
  sysReset.inject(1);
  frameStart.inject(0);
  lineStart.inject(0);
  col0.inject(0);
  col1.inject(0);
  Simulator.setMaxSimTime(1 << 40);
  unawaited(Simulator.run());
  await pixelClk.nextPosedge;
  await pixelClk.nextPosedge;
  pixelReset.inject(0);
  sysReset.inject(0);
  await pixelClk.nextNegedge;

  // A pixel x of plane 0 is in word x >> s0, of plane 1 in word x >> s1.
  final s0 = format.planes[0].bytesPerGroup == 1 ? 2 : 1;
  final s1 = format.planes[1].bytesPerGroup == 2 ? 2 : 1;
  frameStart.inject(1);
  await pixelClk.nextNegedge;
  frameStart.inject(0);
  for (var i = 0; i < 3 * _hTotal; i++) {
    await pixelClk.nextNegedge;
  }
  var checked = 0;
  int? want0;
  int? want1;
  for (var y = 0; y < lines; y++) {
    for (var x = 0; x < _hTotal; x++) {
      await pixelClk.nextNegedge;
      if (want0 != null) {
        expect(so.pixel.value.toInt(), want0, reason: 'y$y x$x');
        expect(so.planeData(1).value.toInt(), want1, reason: 'y$y x$x');
        checked++;
      }
      lineStart.inject(x == _hActive ? 1 : 0);
      if (x < _hActive) {
        col0.inject(x >> s0);
        col1.inject(x >> s1);
        want0 = _y + y * pitch0 + 4 * (x >> s0);
        want1 = _c + (y >> 1) * pitch1 + 4 * (x >> s1);
      } else {
        want0 = null;
      }
    }
  }
  print(
    '${format.name} 1080p60: ${mem.requests.length} requests, memory busy '
    '${(100 * busy / cycles).toStringAsFixed(1)}% of $cycles cycles, '
    '$checked words checked, underrun ${so.underrun.value.toInt()}',
  );
  expectLumaFirst(
    mem.requests.map((r) => (r.$1, 4 * r.$2)),
    luma: _y,
    chroma: _c,
    pitch0: pitch0,
    pitch1: pitch1,
    lineBytes0: pitch0,
  );
  expect(so.underrun.value.toInt(), 0);
  expect(so.planeUnderrunCount(0).value.toInt(), 0);
  expect(so.planeUnderrunCount(1).value.toInt(), 0);
  expect(so.planeUnderrun.value.toInt(), 0);
  expect(checked, lines * _hActive);
}

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  for (final f in [HarborPixelFormat.nv12, HarborPixelFormat.p010]) {
    test(
      '${f.name}: 1080p60 lines on a 600 MB/s memory never underrun',
      () => _scan(f),
      timeout: const Timeout(Duration(minutes: 50)),
    );
  }
}

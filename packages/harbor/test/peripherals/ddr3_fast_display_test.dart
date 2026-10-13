import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import 'ddr3_fast_bench.dart';

const _cores = [CoreCfg('c0', 2, 8), CoreCfg('c1', 2, 8), CoreCfg('c2', 2, 8)];

/// 640x480 at 60 Hz: one line is 2560 bytes in 31.78 us. At the AX7203
/// controller clock (CK 400 MHz / 4 = 100 MHz, 10 ns) that is 3178 cycles.
const _lineWords = 640;
const _lineBudgetCycles = 3178;

/// Runs [lines] display lines back to back while the cores send random
/// cache line and single word traffic. Returns the cycles of each line.
Future<List<int>> _display({
  required int readChannels,
  required int lines,
  int? displayReadChannel,
  List<int?> coreChannels = const [null, null, null],
}) async {
  final cores = [
    for (var i = 0; i < _cores.length; i++)
      CoreCfg(
        _cores[i].name,
        _cores[i].idWidth,
        _cores[i].outstanding,
        readChannel: coreChannels[i],
      ),
  ];
  final top = Ddr3FabricBench(
    cores: cores,
    readChannels: readChannels,
    outstanding: 8,
    display: true,
    displayReadChannel: displayReadChannel,
  );
  final run = await Ddr3FabricRun.start(
    top,
    seed: 11,
    stall: 0.1,
    cores: [for (final c in cores) c.name],
  );
  final rng = Random(11);
  var stop = false;
  // Keep each core busy: 8-beat cache lines and single words, both ways.
  run.sim.onFall(() {
    if (stop) return;
    for (var c = 0; c < cores.length; c++) {
      final m = run.managers[cores[c].name]!;
      if (m.aw.queue.length + m.ar.queue.length > 4) continue;
      final line = rng.nextInt(4) != 0;
      final beats = line ? 8 : 1;
      final addr =
          0x1000000 * (c + 1) + rng.nextInt(0x40000) * 32 + rng.nextInt(8) * 4;
      final write = rng.nextInt(3) == 0;
      final b = Burst(
        id: rng.nextInt(4),
        write: write,
        addr: addr,
        len: beats - 1,
        size: 2,
        burst: line
            ? HarborMemoryBurst.wrap.value
            : HarborMemoryBurst.incr.value,
        data: [
          if (write)
            for (var i = 0; i < beats; i++) rng.nextInt(1 << 32),
        ],
        strb: [
          if (write)
            for (var i = 0; i < beats; i++) 0xf,
        ],
      );
      if (write) {
        m.write(b);
      } else {
        m.read(b);
      }
    }
  });
  // Controller cycles each arbiter source waits with a command ready.
  final front = top.ddr.subModules.whereType<Ddr3MemoryPort>().single;
  Logic sig(String n) => front.signals.firstWhere((x) => x.name == n);
  final srcs = [for (var i = 0; i <= readChannels; i++) sig('src${i}_valid')];
  final grant = sig('arb_grant');
  final wait = List.filled(srcs.length, 0);
  final maxWait = List.filled(srcs.length, 0);
  run.ddrClk.posedge.listen((_) {
    final g = grant.previousValue;
    for (var i = 0; i < srcs.length; i++) {
      final v = srcs[i].previousValue;
      if (v == null || !v.isValid || v.toInt() == 0) {
        wait[i] = 0;
      } else if (g != null && g.isValid && g[i].toBool()) {
        wait[i] = 0;
      } else {
        wait[i]++;
        if (wait[i] > maxWait[i]) maxWait[i] = wait[i];
      }
    }
  });
  await run.sim.cycles(2000);

  final times = <int>[];
  for (var l = 0; l < lines; l++) {
    run.sim.set('disp_fetch_addr', 0x200000 + l * _lineWords * 4);
    run.sim.set('disp_words', _lineWords);
    run.sim.set('disp_fetch_start', 1);
    await run.sim.cycles(1);
    run.sim.set('disp_fetch_start', 0);
    var n = 1;
    while (top.output('disp_done').value.toInt() != 1) {
      await run.sim.cycles(1);
      n++;
      if (n > 100000) throw StateError('line $l never finished');
    }
    times.add(n);
  }
  stop = true;
  final errors = run.allErrors;
  await Simulator.endSimulation();
  expect(errors, isEmpty);
  // ignore: avoid_print
  print('ARBITER max wait per source (write, read 0, read 1..): $maxWait');
  return times;
}

void main() {
  tearDown(Simulator.reset);

  for (final (rc, dch, cch, what) in [
    (1, null, const <int?>[null, null, null], 'one read channel'),
    (2, null, const <int?>[null, null, null], 'two read channels, default map'),
    (
      2,
      1,
      const <int?>[null, null, null],
      'two read channels, display alone on 1',
    ),
  ]) {
    test(
      'a 640x480 display line fetch with 3 busy cores, $what',
      () async {
        final t = await _display(
          readChannels: rc,
          lines: 12,
          displayReadChannel: dch,
          coreChannels: cch,
        );
        final worst = t.reduce(max);
        // ignore: avoid_print
        print(
          'DISPLAY $what: line cycles $t, worst $worst of '
          '$_lineBudgetCycles, margin ${_lineBudgetCycles - worst} cycles '
          '(${(100 * (_lineBudgetCycles - worst) / _lineBudgetCycles).toStringAsFixed(1)}%)',
        );
        expect(worst, lessThan(_lineBudgetCycles));
      },
      timeout: const Timeout(Duration(hours: 3)),
    );
  }
}

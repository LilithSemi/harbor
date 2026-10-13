import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import 'ddr3_fast_bench.dart';

const _cores = [CoreCfg('c0', 1, 8), CoreCfg('c1', 1, 8)];

// MB/s of [bytes] moved in [ns].
double _mbs(int bytes, int ns) => bytes * 1000 / ns;

Burst _incr(bool write, int addr, int beats, Random rng) => Burst(
  id: 0,
  write: write,
  addr: addr,
  len: beats - 1,
  size: 2,
  burst: HarborMemoryBurst.incr.value,
  data: [
    if (write)
      for (var i = 0; i < beats; i++) rng.nextInt(1 << 32),
  ],
  strb: [
    if (write)
      for (var i = 0; i < beats; i++) 0xf,
  ],
);

/// Read MB/s of both cores reading [beats]-beat bursts, then write MB/s of
/// one core writing [beats]-beat bursts. Fabric and memory at 100 MHz.
Future<(double, double, double)> _measure(
  int readChannels,
  int n,
  int gap,
) async {
  final top = Ddr3FabricBench(
    cores: _cores,
    readChannels: readChannels,
    outstanding: n,
    readGap: gap,
  );
  final run = await Ddr3FabricRun.start(
    top,
    stall: 0,
    cores: [for (final c in _cores) c.name],
  );
  final rng = Random(3);
  final ms = [for (final c in _cores) run.managers[c.name]!];

  Future<double> reads(int beats, int count) async {
    final t0 = Simulator.time;
    final before = [for (final m in ms) m.rBeats.length];
    for (var c = 0; c < ms.length; c++) {
      // A 4 KB row per bank: core 0 starts in bank 0, core 1 in bank 4,
      // and each reads in order from there.
      final base = 0x100000 + c * 0x4000;
      for (var i = 0; i < count; i++) {
        ms[c].read(_incr(false, base + i * beats * 4, beats, rng));
      }
    }
    await waitUntil(
      run.sim,
      () => [
        for (var c = 0; c < ms.length; c++)
          ms[c].rBeats.length - before[c] == count * beats,
      ].every((x) => x),
      limit: 400000,
    );
    return _mbs(ms.length * count * beats * 4, Simulator.time - t0);
  }

  Future<double> writes(int beats, int count) async {
    final t0 = Simulator.time;
    final m = ms.first;
    final before = m.bResp.length;
    for (var i = 0; i < count; i++) {
      m.write(_incr(true, 0x800000 + i * beats * 4, beats, rng));
    }
    await waitUntil(
      run.sim,
      () => m.bResp.length - before == count,
      limit: 400000,
    );
    return _mbs(count * beats * 4, Simulator.time - t0);
  }

  final r16 = await reads(16, 96);
  final r1 = await reads(1, 160);
  final w16 = await writes(16, 96);
  final errors = run.allErrors;
  await Simulator.endSimulation();
  expect(errors, isEmpty);
  return (r16, r1, w16);
}

void main() {
  tearDown(Simulator.reset);

  for (final (rc, n, gap) in [
    (1, 1, 1),
    (1, 8, 1),
    (2, 1, 1),
    (2, 8, 1),
    (1, 8, 0),
    (2, 8, 0),
  ]) {
    test(
      'throughput with $rc read channels, N $n, read gap $gap',
      () async {
        final (r16, r1, w16) = await _measure(rc, n, gap);
        // ignore: avoid_print
        print(
          'THROUGHPUT rc $rc N $n gap $gap: 2 cores 16-beat reads '
          '${r16.toStringAsFixed(1)} MB/s, 2 cores 1-beat reads '
          '${r1.toStringAsFixed(1)} MB/s, 1 core 16-beat writes '
          '${w16.toStringAsFixed(1)} MB/s',
        );
        expect(r16, greaterThan(0));
      },
      timeout: const Timeout(Duration(hours: 2)),
    );
  }
}

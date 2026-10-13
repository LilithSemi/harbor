import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../bus/fabric/axi4_fabric_harness.dart' show checkReads, checkWrites;
import '../bus/port/memory_harness.dart';
import 'ddr3_fast_bench.dart';

const _cores = [CoreCfg('c0', 2, 8), CoreCfg('c1', 3, 8), CoreCfg('c2', 1, 4)];

// Each core writes and reads its own region, and reads a shared region
// that nobody writes.
const _own = 0x10000;
const _shared = 0x100000;
const _span = 0x4000;

int _base(int core) => (core + 1) * _own;

Burst _at(Burst b, int base) => Burst(
  id: b.id,
  write: b.write,
  addr: b.addr + base,
  len: b.len,
  size: b.size,
  burst: b.burst,
  data: b.data,
  strb: b.strb,
);

Future<void> _random({
  required int readChannels,
  required int outstanding,
  required int seed,
  int count = 40,
  HarborFabricTopology topology = HarborFabricTopology.crossbar,
}) async {
  final top = Ddr3FabricBench(
    cores: _cores,
    readChannels: readChannels,
    outstanding: outstanding,
    topology: topology,
  );
  final run = await Ddr3FabricRun.start(
    top,
    seed: seed,
    cores: [for (final c in _cores) c.name],
  );
  final rng = Random(seed);

  // Read requests seen at each read channel of the DDR3.
  final arCount = List.filled(readChannels, 0);
  run.sim.onRise(() {
    for (var k = 0; k < readChannels; k++) {
      final p = k == 0 ? 'bus' : 'bus_r$k';
      final v = top.ddr.input('${p}_ARVALID').previousValue;
      final r = top.ddr.output('${p}_ARREADY').previousValue;
      if (v?.toInt() == 1 && r?.toInt() == 1) arCount[k]++;
    }
  });

  Future<void> drain() => waitUntil(
    run.sim,
    () => run.managers.values.every(
      (m) =>
          m.aw.idleNow &&
          m.bResp.length == m.awOrder.length &&
          m.ar.idleNow &&
          m.rBeats.length == m.readBeatsExpected,
    ),
    limit: 400000,
  );

  for (var c = 0; c < _cores.length; c++) {
    final m = run.managers[_cores[c].name]!;
    final gen = BurstGen(
      rng,
      busBytes: 4,
      idWidth: _cores[c].idWidth,
      span: _span - 1024,
      long: 0.03,
    );
    for (var i = 0; i < count; i++) {
      if (rng.nextBool()) {
        m.write(_at(gen.next(write: true), _base(c)));
      } else {
        m.read(_at(gen.next(write: false), _shared));
      }
    }
  }
  await drain();
  final phase1 = {
    for (final c in _cores) c.name: run.managers[c.name]!.arOrder.length,
  };

  // Read every own region back in 256 beat bursts.
  for (var c = 0; c < _cores.length; c++) {
    final m = run.managers[_cores[c].name]!;
    for (var a = 0; a < _span; a += 1024) {
      m.read(
        Burst(
          id: 0,
          write: false,
          addr: _base(c) + a,
          len: 255,
          size: 2,
          burst: HarborMemoryBurst.incr.value,
        ),
      );
    }
  }
  await drain();

  final golden = WordMemory(4);
  final errors = <String>[...run.allErrors];
  for (final c in _cores) {
    final m = run.managers[c.name]!;
    for (final x in m.awOrder) {
      final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
      for (var i = 0; i < x.beats; i++) {
        golden.write(addrs[i], x.data[i], x.strb[i]);
      }
    }
    errors.addAll(checkWrites(c.name, m.awOrder, m.bResp, (_) => 0));
  }
  final start = WordMemory(4);
  for (final c in _cores) {
    final m = run.managers[c.name]!;
    final want = <Burst, List<int>>{};
    for (final (i, b) in m.arOrder.indexed) {
      final mem = i < phase1[c.name]! ? start : golden;
      want[b] = [
        for (final a in beatAddrs(b.addr, b.len, b.size, b.burst)) mem.read(a),
      ];
    }
    errors.addAll(checkReads(c.name, m.arOrder, m.rBeats, (b) => (0, want[b])));
  }
  final busError = top.output('bus_error').value.toInt();
  final fabricError = top.output('fabric_error').value.toInt();
  await Simulator.endSimulation();
  // ignore: avoid_print
  print(
    'readChannels $readChannels N $outstanding seed $seed: ARs per channel '
    '$arCount, DRAM reads ${run.model.reads} writes ${run.model.writes} '
    'activates ${run.model.activates} refreshes ${run.model.refreshes}',
  );
  expect(errors.take(20), isEmpty);
  expect(busError, 0);
  expect(fabricError, 0);
  if (readChannels > 1) {
    expect(arCount.every((n) => n > 0), isTrue, reason: '$arCount');
  }
}

void main() {
  tearDown(Simulator.reset);

  for (final (rc, n, seed) in [(2, 8, 1), (2, 8, 2), (1, 8, 3), (2, 1, 4)]) {
    test(
      'random multi-master traffic, $rc read channels, N $n, seed $seed',
      () => _random(readChannels: rc, outstanding: n, seed: seed),
      timeout: const Timeout(Duration(hours: 2)),
    );
  }

  test(
    'random multi-master traffic on a shared fabric, 2 read channels',
    () => _random(
      readChannels: 2,
      outstanding: 8,
      seed: 5,
      topology: HarborFabricTopology.shared,
    ),
    timeout: const Timeout(Duration(hours: 2)),
  );
}

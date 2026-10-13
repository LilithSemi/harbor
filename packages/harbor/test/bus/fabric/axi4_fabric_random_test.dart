import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import 'axi4_fabric_harness.dart';

// AXI4-Lite ports mixed in: a Lite master, and a Lite slave with a
// timeout that full masters also send bursts and narrow accesses to.
const _mastersLite = [...masters3, MasterCfg('m3', 1, 2, lite: true)];
const _slavesLite = [
  ...slaves3,
  SlaveCfg('s3', 0, 1, 0x30000, 0x8000, timeout: 64, lite: true),
];

// One single beat, full width request for an AXI4-Lite master.
Burst _liteBurst(Random rng, {required bool write}) => Burst(
  id: 0,
  write: write,
  addr: rng.nextInt(0x1000 ~/ busBytes) * busBytes,
  len: 0,
  size: busBytes.bitLength - 1,
  burst: 1,
  data: write ? [rng.nextInt(1 << 32)] : const [],
  strb: write ? [rng.nextInt(16)] : const [],
);

// Random traffic from every master at once. Phase one mixes writes to each
// master's own page with reads of pages nobody writes and requests to
// unmapped space. Phase two reads back the written pages.
Future<void> _random(
  HarborFabricTopology topology,
  int seed, {
  List<MasterCfg> masters = masters3,
  List<SlaveCfg> slaves = slaves3,
  int phase1 = 70,
  int phase2 = 35,
}) async {
  final b = await Bench.start(
    topology,
    seed: seed,
    masters: masters,
    slaves: slaves,
  );
  final rng = Random(seed * 31 + 7);
  Burst next(MasterCfg cfg, {required bool write}) => cfg.lite
      ? _liteBurst(rng, write: write)
      : BurstGen(
          rng,
          busBytes: busBytes,
          idWidth: cfg.idWidth,
          span: 0x1000,
          long: 0.02,
        ).next(write: write);
  for (var k = 0; k < phase1; k++) {
    for (var mi = 0; mi < masters.length; mi++) {
      final cfg = masters[mi];
      final write = rng.nextBool();
      final x = next(cfg, write: write);
      final int base;
      if (rng.nextDouble() < 0.06) {
        base = unmapped + rng.nextInt(4) * 0x1000;
      } else {
        final s = slaves[rng.nextInt(slaves.length)];
        base = s.base + (write ? mi : 4 + rng.nextInt(2)) * 0x1000;
      }
      final y = moved(x, base);
      final m = b.managers[cfg.name]!;
      write ? m.write(y) : m.read(y);
    }
  }
  await b.drain();
  for (var k = 0; k < phase2; k++) {
    for (final cfg in masters) {
      final s = slaves[rng.nextInt(slaves.length)];
      final page = rng.nextInt(masters.length);
      b.managers[cfg.name]!.read(
        moved(next(cfg, write: false), s.base + page * 0x1000),
      );
    }
  }
  await b.drain();
  await b.sim.stop();

  final golden = b.golden();
  final errors = [...b.errors];
  b.checkRegions();
  errors.addAll(b.errors);
  for (final cfg in masters) {
    final m = b.managers[cfg.name]!;
    errors
      ..addAll(checkWrites(cfg.name, m.awOrder, m.bResp, b.respOf))
      ..addAll(
        checkReads(cfg.name, m.arOrder, m.rBeats, (x) {
          final resp = b.respOf(x);
          if (resp != 0) return (resp, null);
          return (
            0,
            [
              for (final a in beatAddrs(x.addr, x.len, x.size, x.burst))
                golden[b.slaveOf(x.addr)!].read(a),
            ],
          );
        }),
      );
  }
  for (var i = 0; i < slaves.length; i++) {
    final mem = b.memories[slaves[i].name]!;
    errors.addAll(diffMemory(golden[i], mem.mem));
  }
  must(errors.take(20).toList(), isEmpty);
  // The small limits are reached, so the check above means something. The
  // directed tests fill the large one.
  for (final s in slaves.where((s) => s.outstanding <= 4)) {
    must(
      b.memories[s.name]!.maxInflight,
      s.outstanding,
      reason: '${s.name} never reached its outstanding limit',
    );
  }
  must(b.busError(), 0);
}

void main() {
  for (final topology in HarborFabricTopology.values) {
    for (final seed in [1, 2]) {
      test(
        '${topology.name} random traffic, seed $seed',
        () => isolated(() => _random(topology, seed)),
        timeout: const Timeout(Duration(minutes: 10)),
      );
    }
    test(
      '${topology.name} random traffic with AXI4-Lite ports',
      () => isolated(
        () => _random(topology, 3, masters: _mastersLite, slaves: _slavesLite),
      ),
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}

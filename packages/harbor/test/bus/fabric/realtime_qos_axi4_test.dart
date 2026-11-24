// Real-time QoS on the AXI4 fabric: the wait of a real-time read stays under
// the bound while two masters send long bursts, the slave never sees a
// burst above the cap from them, and the data is right.

import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import '../port/port_harness.dart';
import 'axi4_fabric_harness.dart';
import 'realtime_qos_axi4_harness.dart';

// An exclusive burst goes to the slave whole when the cap is below its
// length, and a write burst keeps the worst code of its pieces.
Future<void> _exclusiveAndMerge(HarborFabricTopology t) async {
  const masters = [
    MasterCfg('rt', 3, 4, realtime: true),
    MasterCfg('x', 3, 4, exclusiveIds: 4),
    MasterCfg('w', 3, 4),
  ];
  const slaves = [SlaveCfg('s0', 5, 4, 0x00000, 0x10000)];
  final shell = FabricShell(
    t,
    masters: masters,
    slaves: slaves,
    realtimeBurstCap: 4,
  );
  final sim = Sim(shell);
  final rng = Random(8);
  final mgr = {
    for (final m in masters)
      m.name: AxiManager(
        sim,
        m.name,
        rng,
        awIdle: 0,
        wIdle: 0,
        arIdle: 0,
        stall: 0,
        lockPorts: m.name == 'x',
      ),
  };
  // The second piece of a write at 0x2000 gets SLVERR, the others OKAY.
  final mem = DetMem(sim, 's0', rng, bResp: (a) => a == 0x2010 ? 2 : 0);
  await sim.start();
  Simulator.setMaxSimTime(8000000);
  mgr['x']!
    ..read(rtRead(1, 0x100, 7), lock: true)
    ..read(rtRead(2, 0x400, 15));
  mgr['w']!
    ..write(rtWrite(1, 0x2000, 15))
    ..write(rtWrite(2, 0x3000, 15));
  await waitUntil(
    sim,
    () => mgr['x']!.rBeats.length == 24 && mgr['w']!.bResp.length == 2,
    limit: 20000,
  );
  await sim.stop();
  final x = mem.reads.where((e) => e.$1.addr == 0x100).single;
  must(x.$1.beats, 8);
  must(x.$2, 1);
  for (final (r, lock) in mem.reads) {
    if (lock == 0) expect(r.beats, lessThanOrEqualTo(4), reason: '$r');
  }
  for (final w in mem.writes) {
    expect(w.beats, lessThanOrEqualTo(4), reason: '$w');
  }
  final b = {for (final (id, resp) in mgr['w']!.bResp) id: resp};
  must(b, {1: 2, 2: 0});
  must(mgr['x']!.rBeats.where((e) => e.$4 == 1).length, 2);
}

// Cycles to move 16 bursts of 256 beats: reads, then writes.
Future<(int, int)> _stream(bool realtime) async {
  final b = await Bench.start(
    HarborFabricTopology.shared,
    masters: [
      MasterCfg('rt', 2, 4, realtime: realtime),
      const MasterCfg('a', 3, 4),
    ],
    slaves: const [SlaveCfg('s0', 5, 4, 0x00000, 0x10000)],
    stall: 0,
  );
  var now = 0;
  b.sim.onRise(() => now++);
  final a = b.managers['a']!;
  for (var i = 0; i < 16; i++) {
    a.read(rtRead(i % 4, (i % 8) * 0x1000, 255));
  }
  var t0 = now;
  await waitUntil(b.sim, () => a.rBeats.length == 16 * 256, limit: 100000);
  final reads = now - t0;
  for (var i = 0; i < 16; i++) {
    a.write(rtWrite(i % 4, 0x8000 + (i % 8) * 0x1000, 255));
  }
  t0 = now;
  await waitUntil(b.sim, () => a.bResp.length == 16, limit: 100000);
  final writes = now - t0;
  await b.sim.stop();
  await Simulator.reset();
  return (reads, writes);
}

// Writes and reads of long and odd bursts come back right, and the slave
// takes only bursts of at most the cap from the masters that are not
// real-time.
Future<void> _data(HarborFabricTopology t, List<SlaveCfg> slaves) async {
  final b = await Bench.start(
    t,
    masters: rtMasters,
    slaves: slaves,
    stall: 0.2,
    realtimeBurstCap: rtCap,
  );
  final writes = <Burst>[];
  void w(String m, Burst x) {
    writes.add(x);
    b.managers[m]!.write(x);
  }

  final rng = Random(5);
  for (var si = 0; si < slaves.length; si++) {
    final base = slaves[si].base;
    w('a', rtWrite(1, base + 0x0000, 255));
    w('a', rtWrite(2, base + 0x0800, 37));
    w('a', rtWrite(3, base + 0x1000, 15, burst: 0));
    w('a', rtWrite(4 & 7, base + 0x1800, 7, burst: 2));
    w('b', rtWrite(1, base + 0x4000, 200));
    w('b', rtWrite(5, base + 0x4800, 9));
    w('b', rtWrite(5, base + 0x5000, 0));
    w('rt', rtWrite(1, base + 0x8000, 15));
    w('rt', rtWrite(2, base + 0x8100, 3));
    for (var i = 0; i < 3; i++) {
      w(
        'a',
        rtWrite(rng.nextInt(8), base + 0x2000 + i * 0x400, rng.nextInt(120)),
      );
      w(
        'b',
        rtWrite(rng.nextInt(8), base + 0x6000 + i * 0x400, rng.nextInt(120)),
      );
    }
  }
  await b.drain(limit: 300000);
  for (var si = 0; si < slaves.length; si++) {
    final base = slaves[si].base;
    b.managers['a']!
      ..read(rtRead(1, base + 0x0000, 255))
      ..read(rtRead(2, base + 0x0800, 37))
      ..read(rtRead(3, base + 0x1000, 15, burst: 0))
      ..read(rtRead(4, base + 0x1800, 7, burst: 2))
      ..read(rtRead(5, base + 0x4000, 200));
    b.managers['b']!
      ..read(rtRead(1, base + 0x4000, 200))
      ..read(rtRead(5, base + 0x4800, 9))
      ..read(rtRead(5, base + 0x0000, 255));
    b.managers['rt']!
      ..read(rtRead(1, base + 0x8000, 15))
      ..read(rtRead(2, base + 0x0800, 37))
      ..read(rtRead(3, base + 0x4000, 200));
  }
  await b.drain(limit: 300000);
  await b.sim.stop();
  b.checkRegions();
  final want = _wantFrom(b, writes);
  final errors = [...b.errors];
  for (final e in b.managers.entries) {
    final m = e.value;
    errors
      ..addAll(checkReads(e.key, m.arOrder, m.rBeats, want))
      ..addAll(checkWrites(e.key, m.awOrder, m.bResp, b.respOf));
  }
  for (final s in slaves) {
    final m = b.memories[s.name]!;
    for (final x in [...m.awOrder, ...m.arOrder]) {
      // The master index is above the 3 ID bits of the masters.
      final fromRt = x.id >> 3 == 0;
      if (!fromRt && x.burst == 1 && x.beats > rtCap) {
        errors.add('${s.name} took $x from a master that is not real-time');
      }
    }
  }
  must(errors.take(20).toList(), isEmpty);
}

ReadWant Function(Burst) _wantFrom(Bench b, List<Burst> writes) {
  final golden = [for (final _ in b.slaveCfgs) WordMemory(busBytes)];
  for (final x in writes) {
    final s = b.slaveOf(x.addr)!;
    final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
    for (var i = 0; i < x.beats; i++) {
      golden[s].write(addrs[i], x.data[i], x.strb[i]);
    }
  }
  return (x) => (
    0,
    [
      for (final a in beatAddrs(x.addr, x.len, x.size, x.burst))
        golden[b.slaveOf(x.addr)!].read(a),
    ],
  );
}

void main() {
  tearDown(() async => Simulator.reset());

  test('the path of an access counts the registered grant of AXI4', () {
    int path(HarborFabricKind k, [HarborFabricPipeline? p]) =>
        HarborFabric.pathCyclesOf(
          kind: k,
          pipeline: p ?? HarborFabricPipeline.balanced,
          fabrics: 2,
          memoryPorts: 0,
        );
    must(path(HarborFabricKind.wishbone), 4);
    must(path(HarborFabricKind.axi4, HarborFabricPipeline.compact), 10);
    must(path(HarborFabricKind.axi4, HarborFabricPipeline.balanced), 14);
    must(path(HarborFabricKind.axi4, HarborFabricPipeline.fast), 14);
    must(path(HarborFabricKind.tilelink), 8);
  });

  forEachPipeline((p) {
    test(
      'axi4: a 256 beat stream with the cap on and no real-time traffic',
      () async {
        final off = await _stream(false);
        final on = await _stream(true);
        // ignore: avoid_print
        print('axi4 stream cycles, reads/writes: realtime off $off, on $on');
      },
    );

    for (final t in HarborFabricTopology.values) {
      test('axi4 ${t.name}: exclusive bursts stay whole and a split write '
          'keeps its worst code', () async {
        await _exclusiveAndMerge(t);
      });
      for (final slaves in [rtN1Slave, rtTwoSlaves]) {
        test(
          'axi4 ${t.name}, ${slaves.length} slave(s): two real-time masters stay '
          'under the bound',
          () async {
            await rtTiming(t, rtMasters2, slaves, rtCap);
          },
        );
      }
      for (final slaves in [rtOneSlave, rtTwoSlaves]) {
        final n = '${t.name}, ${slaves.length} slave(s)';
        test(
          'axi4 $n: the real-time read wait stays under the bound',
          () async {
            await rtTiming(t, rtMasters, slaves, rtCap);
          },
        );
        test('axi4 $n: split bursts keep the data and the bursts of the '
            'other masters stay under the cap', () async {
          await _data(t, slaves);
        });
      }
    }
  });
}

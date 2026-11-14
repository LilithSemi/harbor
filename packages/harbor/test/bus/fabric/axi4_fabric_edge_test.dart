import 'package:harbor/harbor.dart' show HarborFabricTopology;
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import 'axi4_fabric_harness.dart';
import 'axi4_fabric_test.dart' show checkAll, rd, wr;

// Regions with starts that are not aligned to their size and sizes that are
// not a power of two, full and AXI4-Lite, with and without offset.
const _slaves = [
  SlaveCfg('sa', 2, 2, 0x00000, 0x10000),
  SlaveCfg('sb', 2, 2, 0x13000, 0x3000),
  SlaveCfg('sc', 0, 1, 0x40100, 0x100, lite: true),
  SlaveCfg('sd', 0, 1, 0x51000, 0x3000, lite: true, offset: true),
  SlaveCfg('se', 2, 2, 0x67000, 0x2000, offset: true),
];

// An access at the bottom and at the top of each region, from a full and a
// Lite master, reaches the slave with the address it must see.
Future<void> _addressRebuild(HarborFabricTopology t) async {
  final b = await Bench.start(
    t,
    stall: 0.2,
    masters: const [MasterCfg('m0', 2, 4), MasterCfg('mL', 1, 2, lite: true)],
    slaves: _slaves,
  );
  final m0 = b.managers['m0']!;
  final mL = b.managers['mL']!;
  final writes = <Burst>[];
  final want = <String, Set<int>>{};
  for (final s in _slaves) {
    final lo = s.base;
    final hi = s.base + s.size - busBytes;
    final mid = s.base + (s.size ~/ 2 & ~(busBytes - 1));
    writes
      ..add(wr(1, lo, 0))
      ..add(wr(2, hi, 0));
    mL.write(wr(0, mid, 0));
    writes.add(wr(0, mid, 0));
    want[s.name] = {s.see(lo), s.see(hi), s.see(mid)};
  }
  for (final x in writes.where((x) => x.id != 0)) {
    m0.write(x);
  }
  await b.drain();
  for (final s in _slaves) {
    final hi = s.base + s.size - busBytes;
    m0
      ..read(rd(1, s.base, 0))
      ..read(rd(2, hi, 0));
    mL.read(rd(0, s.base + (s.size ~/ 2 & ~(busBytes - 1)), 0));
  }
  // A full slave burst that ends at the top of the region.
  m0.read(rd(3, 0x16000 - 4 * busBytes, 3));
  await b.drain();
  await b.sim.stop();
  checkAll(b, writes: writes);
  for (final s in _slaves) {
    final m = b.memories[s.name]!;
    must(m.awOrder.map((x) => x.addr).toSet(), want[s.name], reason: s.name);
    must(m.arOrder.map((x) => x.addr).toSet(), {
      ...want[s.name]!,
      if (s.name == 'sb') s.see(0x16000 - 4 * busBytes),
    }, reason: s.name);
  }
  must(b.busError(), 0);
}

// An AXI4-Lite slave with a timeout that stops answering is cut off. The
// request in flight and later ones get SLVERR, the late response is
// dropped, and a second Lite slave still works.
Future<void> _liteTimeout(HarborFabricTopology t) async {
  final b = await Bench.start(
    t,
    stall: 0.2,
    masters: const [MasterCfg('m0', 2, 4)],
    slaves: const [
      SlaveCfg('s0', 0, 1, 0x00000, 0x1000, lite: true),
      SlaveCfg('sL', 0, 1, 0x10000, 0x1000, lite: true, timeout: 40),
    ],
  );
  final m0 = b.managers['m0']!;
  final sL = b.memories['sL']!;
  final first = wr(1, 0x10010, 0);
  m0
    ..write(first)
    ..read(rd(1, 0x10010, 0));
  await b.drain();
  must(m0.bResp, [(1, 0)]);
  must(m0.rBeats.map((x) => x.$3).toList(), [0]);

  sL.holdResponses = true;
  m0.read(rd(2, 0x10020, 0));
  await b.drain(limit: 2000);
  must(b.busError(), 1);
  must(m0.rBeats.last.$3, 2);
  final seen = sL.awOrder.length + sL.arOrder.length;
  sL.holdResponses = false;
  await waitUntil(b.sim, () => sL.inflight == 0);
  await b.sim.cycles(50);
  must(m0.rBeats.length, 2);

  final ok = wr(3, 0x0100, 0);
  m0
    ..write(wr(3, 0x10030, 0))
    ..read(rd(2, 0x10030, 0))
    ..write(ok)
    ..read(rd(3, 0x0100, 0));
  await b.drain(limit: 4000);
  await b.sim.stop();
  must(sL.awOrder.length + sL.arOrder.length, seen);
  must(m0.bResp.skip(1).toList(), [(3, 2), (3, 0)]);
  must(m0.rBeats.skip(2).map((x) => (x.$1, x.$3)).toSet(), {(2, 2), (3, 0)});
  must(b.errors, isEmpty);
}

void main() {
  const long = Timeout(Duration(minutes: 5));
  for (final t in HarborFabricTopology.values) {
    group(t.name, () {
      test(
        'slaves see the full address or offset at region edges',
        () => isolated(() => _addressRebuild(t)),
        timeout: long,
      );
      test(
        'timeout cuts off an AXI4-Lite slave',
        () => isolated(() => _liteTimeout(t)),
        timeout: long,
      );
    });
  }
}

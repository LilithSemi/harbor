// The real-time read timing bench of the AXI4 fabric tests.

import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import '../port/port_harness.dart';
import 'axi4_fabric_harness.dart';

const rtCap = 8;

const rtMasters = [
  MasterCfg('rt', 2, 4, realtime: true),
  MasterCfg('a', 3, 4),
  MasterCfg('b', 3, 4),
];

const rtMasters2 = [
  MasterCfg('rt2', 3, 4, realtime: true),
  MasterCfg('rt', 3, 4, realtime: true),
  MasterCfg('a', 3, 4),
  MasterCfg('b', 3, 4),
];

// One slave takes the fabric without a request stage per master, and two
// slaves with an ID remap take the full one.
const rtOneSlave = [SlaveCfg('s0', 5, 4, 0x00000, 0x10000)];
const rtN1Slave = [SlaveCfg('s0', 5, 1, 0x00000, 0x10000)];
const rtTwoSlaves = [
  SlaveCfg('s0', 5, 4, 0x00000, 0x10000),
  SlaveCfg('s1', 1, 2, 0x10000, 0x10000),
];

// s1 is an AXI4-Lite slave that only the real-time master reads.
const rtLiteSlaves = [
  SlaveCfg('s0', 5, 4, 0x00000, 0x10000),
  SlaveCfg('s1', 0, 1, 0x10000, 0x10000, lite: true),
];

// s1 has 1 slave ID bit for 4 requests, so its ID remap has fewer slots than
// requests.
const rtFewIdSlaves = [
  SlaveCfg('s0', 5, 4, 0x00000, 0x10000),
  SlaveCfg('s1', 1, 4, 0x10000, 0x10000),
];

Burst rtRead(int id, int addr, int len, {int burst = 1}) =>
    Burst(id: id, write: false, addr: addr, len: len, size: 2, burst: burst);

Burst rtWrite(int id, int addr, int len, {int burst = 1}) => Burst(
  id: id,
  write: true,
  addr: addr,
  len: len,
  size: 2,
  burst: burst,
  data: [for (var i = 0; i <= len; i++) (addr << 8) + i + id * 0x1000000],
  strb: List.filled(len + 1, 0xf),
);

// An in order subordinate: one read beat per cycle, and one B for each write
// after its last W beat. [bResp] gives the B code by the address of the
// request.
class DetMem {
  final String p;
  final WordMemory mem = WordMemory(busBytes);
  final List<(Burst, int)> reads = [];
  final List<Burst> writes = [];
  final int Function(int addr) bResp;
  late final Source r;
  late final Source b;
  final Queue<Map<String, int>> _beats = Queue();
  final Queue<Burst> _aw = Queue();
  final Queue<Map<String, int>> _b = Queue();

  DetMem(Sim s, this.p, Random rng, {this.bResp = _okay}) {
    Burst req(String ch, Map<String, int> f, bool write) => Burst(
      id: f['${p}_${ch}ID']!,
      write: write,
      addr: f['${p}_${ch}ADDR']!,
      len: f['${p}_${ch}LEN']!,
      size: f['${p}_${ch}SIZE']!,
      burst: f['${p}_${ch}BURST']!,
    );
    List<String> fields(String ch) => [
      for (final f in ['ID', 'ADDR', 'LEN', 'SIZE', 'BURST', 'LOCK'])
        '${p}_$ch$f',
    ];
    Sink(s, '${p}_ARVALID', '${p}_ARREADY', fields('AR'), rng, (f) {
      final x = req('AR', f, false);
      reads.add((x, f['${p}_ARLOCK']!));
      final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
      for (var i = 0; i <= x.len; i++) {
        _beats.add({
          '${p}_RID': x.id,
          '${p}_RDATA': mem.read(addrs[i]),
          '${p}_RRESP': 0,
          '${p}_RLAST': i == x.len ? 1 : 0,
        });
      }
    });
    Sink(s, '${p}_AWVALID', '${p}_AWREADY', fields('AW'), rng, (f) {
      final x = req('AW', f, true);
      writes.add(x);
      _aw.add(x);
    });
    Sink(s, '${p}_WVALID', '${p}_WREADY', ['${p}_WLAST'], rng, (f) {
      if (f['${p}_WLAST'] == 1) {
        final x = _aw.removeFirst();
        _b.add({'${p}_BID': x.id, '${p}_BRESP': bResp(x.addr)});
      }
    });
    r = Source(s, '${p}_RVALID', '${p}_RREADY', rng);
    b = Source(s, '${p}_BVALID', '${p}_BREADY', rng);
    s.onFall(() {
      if (r.queue.isEmpty && _beats.isNotEmpty) {
        r.queue.add(_beats.removeFirst());
      }
      if (b.queue.isEmpty && _b.isNotEmpty) b.queue.add(_b.removeFirst());
    });
  }
}

int _okay(int addr) => 0;

// Waits of the reads of one master, from ARVALID to the first R beat.
class RtWait {
  int now = 0;
  int? start;
  final List<int> waits = [];

  RtWait(Sim s, String p) {
    s.onRise(() {
      now++;
      if (start == null && s.pre('${p}_ARVALID') == 1) start = now;
      if (start != null &&
          s.pre('${p}_RVALID') == 1 &&
          s.pre('${p}_RREADY') == 1) {
        waits.add(now - start!);
        start = null;
      }
    });
  }
}

HarborFabricMaster rtFabricMaster(MasterCfg m) => HarborFabricMaster(
  name: m.name,
  interface: Axi4Interface(
    addressWidth: addrW,
    dataWidth: dataW,
    idWidth: m.idWidth,
  ),
  realtime: m.realtime,
  writeStallFree: true,
);

Future<void> rtTiming(
  HarborFabricTopology t,
  List<MasterCfg> masters,
  List<SlaveCfg> slaves,
  int cap, {
  int shift = 0,
}) async {
  final shell = FabricShell(
    t,
    masters: masters,
    slaves: slaves,
    realtimeBurstCap: cap,
  );
  final sim = Sim(shell);
  final rng = Random(3);
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
      ),
  };
  final mems = {
    for (final s in slaves)
      if (!s.lite) s.name: DetMem(sim, s.name, rng),
  };
  final liteErrors = <String>[];
  for (final s in slaves.where((s) => s.lite)) {
    AxiMemory(
      sim,
      s.name,
      rng,
      busBytes: busBytes,
      outstanding: 1,
      errors: liteErrors,
      stall: 0,
      lite: true,
    );
  }
  final rtNames = [
    for (final m in masters)
      if (m.realtime) m.name,
  ];
  final others = [
    for (final m in masters)
      if (!m.realtime) m.name,
  ];
  final waits = {for (final n in rtNames) n: RtWait(sim, n)};
  await sim.start();
  Simulator.setMaxSimTime(8000000);

  // The other masters hammer every full slave with 256 beat reads.
  for (var i = 0; i < 12; i++) {
    for (final n in others) {
      for (var si = 0; si < slaves.length; si++) {
        if (slaves[si].lite) continue;
        final base = slaves[si].base + (n == others.first ? 0 : 0x4000);
        mgr[n]!.read(rtRead(i % 8, base + (i % 3) * 0x800, 255));
      }
    }
  }
  const reads = 24;
  for (var i = 0; i < reads; i++) {
    await sim.cycles(37 + (i * 11) % 29 + shift);
    final s = slaves[i % slaves.length];
    for (final (k, n) in rtNames.indexed) {
      mgr[n]!.read(rtRead(i % 4, s.base + 0x8000 + k * 0x1000 + i * 0x40, 15));
    }
    await waitUntil(
      sim,
      () => rtNames.every((n) => mgr[n]!.rBeats.length == (i + 1) * 16),
      limit: 20000,
    );
  }
  await waitUntil(
    sim,
    () => mgr.values.every((m) => m.rBeats.length == m.readBeatsExpected),
    limit: 200000,
  );
  await sim.stop();

  final lite = slaves.any((s) => s.lite);
  final bound = HarborFabric.realtimeWaitBound(
    kind: HarborFabricKind.axi4,
    masters: [for (final m in masters) rtFabricMaster(m)],
    cap: cap,
    slaveOutstanding: slaves.map((s) => s.outstanding).reduce(max),
    sharedSlaves: t == HarborFabricTopology.shared ? slaves.length : 1,
    realtimeBeats: 16,
    pathCycles: HarborFabric.pathCyclesOf(
      kind: HarborFabricKind.axi4,
      pipeline: harnessPipeline,
      liteSlave: lite,
      memoryPorts: 0,
    ),
    pipeline: harnessPipeline,
    liteSlave: lite,
  );
  final worst = waits.values.map((w) => w.waits.reduce(max)).reduce(max);
  // ignore: avoid_print
  print(
    'axi4 ${harnessPipeline.name} ${t.name} ${slaves.length} slaves '
    '${rtNames.length} rt shift $shift: worst wait $worst, bound $bound',
  );
  for (final w in waits.values) {
    must(w.waits.length, reads);
  }
  must(liteErrors, isEmpty);
  expect(worst, lessThanOrEqualTo(bound));
  for (final m in mems.values) {
    for (final (x, _) in m.reads) {
      // A burst of a master that is not real-time is at most the cap.
      final fromRt = x.id >> 3 < rtNames.length;
      if (!fromRt) expect(x.beats, lessThanOrEqualTo(cap), reason: '$x');
    }
  }
}

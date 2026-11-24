// Real-time QoS on the AXI4 fabric: the wait of a real-time read stays under
// the bound while two masters send long bursts, the slave never sees a
// burst above the cap from them, and the data is right.

import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import '../port/port_harness.dart';
import 'axi4_fabric_harness.dart';

const _cap = 8;

const _masters = [
  MasterCfg('rt', 2, 4, realtime: true),
  MasterCfg('a', 3, 4),
  MasterCfg('b', 3, 4),
];

const _masters2 = [
  MasterCfg('rt2', 3, 4, realtime: true),
  MasterCfg('rt', 3, 4, realtime: true),
  MasterCfg('a', 3, 4),
  MasterCfg('b', 3, 4),
];

// One slave takes the fabric without a request stage per master, and two
// slaves with an ID remap take the full one.
const _oneSlave = [SlaveCfg('s0', 5, 4, 0x00000, 0x10000)];
const _n1Slave = [SlaveCfg('s0', 5, 1, 0x00000, 0x10000)];
const _twoSlaves = [
  SlaveCfg('s0', 5, 4, 0x00000, 0x10000),
  SlaveCfg('s1', 1, 2, 0x10000, 0x10000),
];

Burst _rd(int id, int addr, int len, {int burst = 1}) =>
    Burst(id: id, write: false, addr: addr, len: len, size: 2, burst: burst);

Burst _wr(int id, int addr, int len, {int burst = 1}) => Burst(
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
class _DetMem {
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

  _DetMem(Sim s, this.p, Random rng, {this.bResp = _okay}) {
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
class _Wait {
  int now = 0;
  int? start;
  final List<int> waits = [];

  _Wait(Sim s, String p) {
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

HarborFabricMaster _fm(MasterCfg m) => HarborFabricMaster(
  name: m.name,
  interface: Axi4Interface(
    addressWidth: addrW,
    dataWidth: dataW,
    idWidth: m.idWidth,
  ),
  realtime: m.realtime,
  writeStallFree: true,
);

Future<void> _timing(
  HarborFabricTopology t,
  List<MasterCfg> masters,
  List<SlaveCfg> slaves,
  int cap,
) async {
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
  final mems = {for (final s in slaves) s.name: _DetMem(sim, s.name, rng)};
  final rtNames = [
    for (final m in masters)
      if (m.realtime) m.name,
  ];
  final others = [
    for (final m in masters)
      if (!m.realtime) m.name,
  ];
  final waits = {for (final n in rtNames) n: _Wait(sim, n)};
  await sim.start();
  Simulator.setMaxSimTime(8000000);

  // The other masters hammer every slave with 256 beat reads.
  for (var i = 0; i < 12; i++) {
    for (final n in others) {
      for (var si = 0; si < slaves.length; si++) {
        final base = slaves[si].base + (n == others.first ? 0 : 0x4000);
        mgr[n]!.read(_rd(i % 8, base + (i % 3) * 0x800, 255));
      }
    }
  }
  const reads = 24;
  for (var i = 0; i < reads; i++) {
    await sim.cycles(37 + (i * 11) % 29);
    final s = slaves[i % slaves.length];
    for (final (k, n) in rtNames.indexed) {
      mgr[n]!.read(_rd(i % 4, s.base + 0x8000 + k * 0x1000 + i * 0x40, 15));
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

  final bound = HarborFabric.realtimeWaitBound(
    kind: HarborFabricKind.axi4,
    masters: [for (final m in masters) _fm(m)],
    cap: cap,
    slaveOutstanding: slaves.map((s) => s.outstanding).reduce(max),
    sharedSlaves: t == HarborFabricTopology.shared ? slaves.length : 1,
    realtimeBeats: 16,
  );
  final worst = waits.values.map((w) => w.waits.reduce(max)).reduce(max);
  // ignore: avoid_print
  print(
    'axi4 ${t.name} ${slaves.length} slaves ${rtNames.length} rt: worst wait '
    '$worst, bound $bound',
  );
  for (final w in waits.values) {
    must(w.waits.length, reads);
  }
  expect(worst, lessThanOrEqualTo(bound));
  for (final m in mems.values) {
    for (final (x, _) in m.reads) {
      // A burst of a master that is not real-time is at most the cap.
      final fromRt = x.id >> 3 < rtNames.length;
      if (!fromRt) expect(x.beats, lessThanOrEqualTo(cap), reason: '$x');
    }
  }
}

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
  final mem = _DetMem(sim, 's0', rng, bResp: (a) => a == 0x2010 ? 2 : 0);
  await sim.start();
  Simulator.setMaxSimTime(8000000);
  mgr['x']!
    ..read(_rd(1, 0x100, 7), lock: true)
    ..read(_rd(2, 0x400, 15));
  mgr['w']!
    ..write(_wr(1, 0x2000, 15))
    ..write(_wr(2, 0x3000, 15));
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
    a.read(_rd(i % 4, (i % 8) * 0x1000, 255));
  }
  var t0 = now;
  await waitUntil(b.sim, () => a.rBeats.length == 16 * 256, limit: 100000);
  final reads = now - t0;
  for (var i = 0; i < 16; i++) {
    a.write(_wr(i % 4, 0x8000 + (i % 8) * 0x1000, 255));
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
    masters: _masters,
    slaves: slaves,
    stall: 0.2,
    realtimeBurstCap: _cap,
  );
  final writes = <Burst>[];
  void w(String m, Burst x) {
    writes.add(x);
    b.managers[m]!.write(x);
  }

  final rng = Random(5);
  for (var si = 0; si < slaves.length; si++) {
    final base = slaves[si].base;
    w('a', _wr(1, base + 0x0000, 255));
    w('a', _wr(2, base + 0x0800, 37));
    w('a', _wr(3, base + 0x1000, 15, burst: 0));
    w('a', _wr(4 & 7, base + 0x1800, 7, burst: 2));
    w('b', _wr(1, base + 0x4000, 200));
    w('b', _wr(5, base + 0x4800, 9));
    w('b', _wr(5, base + 0x5000, 0));
    w('rt', _wr(1, base + 0x8000, 15));
    w('rt', _wr(2, base + 0x8100, 3));
    for (var i = 0; i < 3; i++) {
      w('a', _wr(rng.nextInt(8), base + 0x2000 + i * 0x400, rng.nextInt(120)));
      w('b', _wr(rng.nextInt(8), base + 0x6000 + i * 0x400, rng.nextInt(120)));
    }
  }
  await b.drain(limit: 300000);
  for (var si = 0; si < slaves.length; si++) {
    final base = slaves[si].base;
    b.managers['a']!
      ..read(_rd(1, base + 0x0000, 255))
      ..read(_rd(2, base + 0x0800, 37))
      ..read(_rd(3, base + 0x1000, 15, burst: 0))
      ..read(_rd(4, base + 0x1800, 7, burst: 2))
      ..read(_rd(5, base + 0x4000, 200));
    b.managers['b']!
      ..read(_rd(1, base + 0x4000, 200))
      ..read(_rd(5, base + 0x4800, 9))
      ..read(_rd(5, base + 0x0000, 255));
    b.managers['rt']!
      ..read(_rd(1, base + 0x8000, 15))
      ..read(_rd(2, base + 0x0800, 37))
      ..read(_rd(3, base + 0x4000, 200));
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
      if (!fromRt && x.burst == 1 && x.beats > _cap) {
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
    int path(HarborFabricKind k) =>
        HarborFabric.pathCyclesOf(kind: k, fabrics: 2, memoryPorts: 0);
    must(path(HarborFabricKind.wishbone), 4);
    must(path(HarborFabricKind.axi4), 10);
    must(path(HarborFabricKind.tilelink), 8);
  });

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
    for (final slaves in [_n1Slave, _twoSlaves]) {
      test(
        'axi4 ${t.name}, ${slaves.length} slave(s): two real-time masters stay '
        'under the bound',
        () async {
          await _timing(t, _masters2, slaves, _cap);
        },
      );
    }
    for (final slaves in [_oneSlave, _twoSlaves]) {
      final n = '${t.name}, ${slaves.length} slave(s)';
      test('axi4 $n: the real-time read wait stays under the bound', () async {
        await _timing(t, _masters, slaves, _cap);
      });
      test('axi4 $n: split bursts keep the data and the bursts of the '
          'other masters stay under the cap', () async {
        await _data(t, slaves);
      });
    }
  }
}

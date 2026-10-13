import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../../peripherals/ddr3_fast_bench.dart';
import '../../peripherals/sdram_memory_port_bench.dart';
import '../port/memory_harness.dart';
import '../port/port_harness.dart';
import 'axi4_fabric_harness.dart' show exposeInterface;

const _okay = 0;
const _exOkay = 1;

/// m0 has 3 ID bits and slots for IDs 0 to 3. m1 has 2 ID bits and picks
/// its slots from the default budget of 8, which gives it 4. m2 has no
/// exclusive access.
const _masters = [
  ('m0', 3, 4),
  ('m1', 2, HarborExclusive.auto),
  ('m2', 1, null),
];

/// The monitor of [_masters]: the master index sits above 3 ID bits.
final _excl = HarborAxi4Exclusive.forMasters(
  [for (final m in _masters) m.$2],
  [for (final m in _masters) m.$3],
)!;
const _slaveIdW = 5;

int _sid(int master, int id) => master << 3 | id;

/// Builds an AXI4 fabric in [top] from [_masters] to the port `bus` of
/// [mem], with each master port on the top as `<name>_*`.
void _linkFabric(
  BridgeModule top,
  BridgeModule mem,
  int addrW,
  BusAddressRange range,
  int outstanding,
) {
  final ms = <HarborFabricMaster>[];
  for (final (name, idW, excl) in _masters) {
    final intf = Axi4Interface(
      addressWidth: addrW,
      dataWidth: 32,
      idWidth: idW,
    );
    exposeInterface(top, intf, name, PairDirection.fromProvider);
    ms.add(HarborFabricMaster(name: name, interface: intf, exclusiveIds: excl));
  }
  expect(_excl.runs, [(0, 4), (8, 4)]);
  expect(HarborAxi4Fabric.exclusiveOf(ms), _excl);
  expect(HarborAxi4Fabric.fullIdWidthOf(ms), _slaveIdW);
  HarborFabric.build(
    kind: HarborFabricKind.axi4,
    topology: HarborFabricTopology.shared,
    clk: top.input('clk'),
    reset: top.input('reset'),
    masters: ms,
    slaves: [
      HarborFabricSlave(
        name: 'mem',
        range: range,
        interface: mem.interface('bus').interface,
        outstanding: outstanding,
        exclusive: _excl,
      ),
    ],
  );
}

class _SramTop extends BridgeModule {
  late final HarborSram sram;

  _SramTop() : super('ExclSramTop', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    sram = addSubModule(
      HarborSram(
        baseAddress: 0,
        size: 4096,
        busAddressWidth: 12,
        protocol: HarborFabricKind.axi4,
        idWidth: _slaveIdW,
        exclusive: _excl,
      ),
    );
    for (final p in ['clk', 'reset']) {
      sram.input(p).srcConnection! <= input(p);
    }
    _linkFabric(
      this,
      sram,
      12,
      BusAddressRange(0, 0x1000),
      HarborSram.outstanding,
    );
  }
}

/// Exclusive and plain accesses from the masters of a running bench.
class _Agents {
  final Sim s;
  final Map<String, AxiManager> m;
  final HarborMemoryWaist waist;

  /// Write requests the waist took, as (slave side ID, address), in order.
  final List<(int, int)> writeTakes = [];

  _Agents(this.s, this.waist)
    : m = {
        for (final (name, _, _) in _masters)
          name: AxiManager(
            s,
            name,
            Random(name.hashCode),
            awIdle: 0.2,
            wIdle: 0.1,
            arIdle: 0.2,
            stall: 0.2,
            lockPorts: true,
          ),
      } {
    s.onRise(() {
      int pre(Logic l) => (l.previousValue ?? l.value).toInt();
      if (pre(waist.reqValid) == 1 &&
          pre(waist.reqReady) == 1 &&
          pre(waist.reqWrite) == 1) {
        writeTakes.add((pre(waist.reqId), pre(waist.reqAddr)));
      }
    });
  }

  static Burst _word(int id, int addr, {int? data}) => Burst(
    id: id,
    write: data != null,
    addr: addr,
    len: 0,
    size: 2,
    burst: 1,
    data: data == null ? const [] : [data],
    strb: data == null ? const [] : [0xf],
  );

  /// Reads the word at [addr] and returns (data, resp).
  Future<(int, int)> read(
    String master,
    int id,
    int addr, {
    bool lock = false,
  }) async {
    final a = m[master]!;
    int count() => a.rBeats.where((b) => b.$1 == id).length;
    final before = count();
    a.read(_word(id, addr), lock: lock);
    await waitUntil(s, () => count() > before, limit: 200000);
    final beat = a.rBeats.lastWhere((b) => b.$1 == id);
    return (beat.$2, beat.$3);
  }

  /// Writes [data] to the word at [addr] and returns BRESP.
  Future<int> write(
    String master,
    int id,
    int addr,
    int data, {
    bool lock = false,
  }) async {
    final a = m[master]!;
    int count() => a.bResp.where((b) => b.$1 == id).length;
    final before = count();
    a.write(_word(id, addr, data: data), lock: lock);
    await waitUntil(s, () => count() > before, limit: 200000);
    return a.bResp.lastWhere((b) => b.$1 == id).$2;
  }

  /// Adds 1 to the word at [addr] [n] times with exclusive pairs, and
  /// retries a pair that fails. Returns the errors.
  Future<List<String>> increment(String master, int id, int addr, int n) async {
    final bad = <String>[];
    var done = 0;
    var tries = 0;
    while (done < n && tries < 50 * n) {
      tries++;
      final (v, rResp) = await read(master, id, addr, lock: true);
      if (rResp != _exOkay) bad.add('$master id $id: RRESP $rResp');
      final bResp = await write(master, id, addr, v + 1, lock: true);
      if (bResp == _exOkay) {
        done++;
      } else if (bResp != _okay) {
        bad.add('$master id $id: BRESP $bResp');
      }
    }
    if (done < n) bad.add('$master id $id: $done of $n in $tries tries');
    return bad;
  }

  /// Plain writes from m2 to the next two granules after [addr], [n] times.
  Future<void> noise(int addr, int n) async {
    for (var i = 0; i < n; i++) {
      await write('m2', 0, addr + 64, i);
      await write('m2', 1, addr + 128, i);
    }
  }
}

/// The checks every memory runs.
Future<List<String>> _scenarios(_Agents a, {required int n}) async {
  final bad = <String>[];
  void want(String what, int got, int expected) {
    if (got != expected) bad.add('$what: got $got, want $expected');
  }

  // Two masters each add 1 [n] times to the same word, with m2 writing the
  // granules next to it.
  const ctr = 0x100;
  want('clear counter', await a.write('m2', 0, ctr, 0), _okay);
  final runs = await Future.wait([
    a.increment('m0', 1, ctr, n),
    a.increment('m1', 2, ctr, n),
    a.noise(ctr, n).then((_) => <String>[]),
  ]);
  bad.addAll(runs.expand((r) => r));
  want('counter', (await a.read('m2', 0, ctr)).$1, 2 * n);

  // One master, two IDs: each ID has its own slot.
  const x = 0x200, y = 0x240;
  await a.write('m2', 0, x, 0x11);
  await a.write('m2', 0, y, 0x22);
  want('id 0 reads x', (await a.read('m0', 0, x, lock: true)).$2, _exOkay);
  want('id 1 reads y', (await a.read('m0', 1, y, lock: true)).$2, _exOkay);
  want('id 0 writes y', await a.write('m0', 0, y, 0x33, lock: true), _okay);
  want('y after id 0', (await a.read('m2', 0, y)).$1, 0x22);
  want('id 1 writes y', await a.write('m0', 1, y, 0x44, lock: true), _exOkay);
  want('id 0 writes x', await a.write('m0', 0, x, 0x55, lock: true), _exOkay);
  want('x', (await a.read('m2', 0, x)).$1, 0x55);
  want('y', (await a.read('m2', 0, y)).$1, 0x44);
  want('id 1 again', await a.write('m0', 1, y, 0x66, lock: true), _okay);

  // A plain write from another master between the pair fails it.
  const z = 0x280;
  await a.write('m2', 0, z, 0x77);
  want('m0 reads z', (await a.read('m0', 3, z, lock: true)).$2, _exOkay);
  want('m1 writes z', await a.write('m1', 0, z, 0x88), _okay);
  want('m0 writes z', await a.write('m0', 3, z, 0x99, lock: true), _okay);
  want('z', (await a.read('m2', 0, z)).$1, 0x88);

  // An exclusive write with no exclusive read fails and writes nothing.
  const w = 0x2c0;
  await a.write('m2', 0, w, 0xaa);
  want('lone write', await a.write('m1', 3, w, 0xbb, lock: true), _okay);
  want('w', (await a.read('m2', 0, w)).$1, 0xaa);

  // A broken exclusive write (unaligned) gets OKAY and writes nothing.
  want('m1 reads w', (await a.read('m1', 3, w, lock: true)).$2, _exOkay);
  want(
    'unaligned write',
    await a.write('m1', 3, w + 2, 0xcc, lock: true),
    _okay,
  );
  want('w after unaligned', (await a.read('m2', 0, w)).$1, 0xaa);

  // An exclusive read never clears the slot of another ID.
  const v = 0x380;
  await a.write('m2', 0, v, 0x100);
  want('m0 reads v', (await a.read('m0', 0, v, lock: true)).$2, _exOkay);
  want('m1 reads v', (await a.read('m1', 0, v, lock: true)).$2, _exOkay);
  want('m0 writes v', await a.write('m0', 0, v, 0x101, lock: true), _exOkay);
  want('m1 after m0', await a.write('m1', 0, v, 0x102, lock: true), _okay);
  want('v', (await a.read('m2', 0, v)).$1, 0x101);

  // A failed exclusive write clears no slot.
  want('m0 reads v again', (await a.read('m0', 1, v, lock: true)).$2, _exOkay);
  want('m1 lone v', await a.write('m1', 1, v, 0x103, lock: true), _okay);
  want('m0 after lone', await a.write('m0', 1, v, 0x104, lock: true), _exOkay);
  want('v after lone', (await a.read('m2', 0, v)).$1, 0x104);

  // m0 has no slot for ID 5: its exclusive read gets OKAY.
  want('m0 id 5', (await a.read('m0', 5, v, lock: true)).$2, _okay);

  // m2 has no slot: its exclusive read gets OKAY and its exclusive write
  // is a plain write.
  want('m2 lock read', (await a.read('m2', 1, w, lock: true)).$2, _okay);
  want('m2 lock write', await a.write('m2', 1, w, 0xdd, lock: true), _okay);
  want('w after m2', (await a.read('m2', 0, w)).$1, 0xdd);

  // Race: an exclusive write and a plain write to the same word in flight
  // together. The first the waist takes wins.
  const r = 0x300;
  var scFirst = 0, plainFirst = 0;
  for (var gap = -3; gap <= 3; gap++) {
    await a.write('m2', 0, r, 0);
    want('race read', (await a.read('m0', 2, r, lock: true)).$2, _exOkay);
    final from = a.writeTakes.length;
    Future<int> sc() => a.write('m0', 2, r, 0x1000 + gap, lock: true);
    Future<int> plainWrite() => a.write('m1', 1, r, 0x2000 + gap);
    final Future<int> first;
    final Future<int> second;
    if (gap >= 0) {
      first = sc();
      await a.s.cycles(gap);
      second = plainWrite();
    } else {
      first = plainWrite();
      await a.s.cycles(-gap);
      second = sc();
    }
    final scResp = await (gap >= 0 ? first : second);
    final plain = gap >= 0 ? second : first;
    want('race plain resp', await plain, _okay);
    final takes = a.writeTakes.sublist(from).where((t) => t.$2 == r).toList();
    if (takes.first.$1 == _sid(0, 2)) {
      scFirst++;
      want('race gap $gap, exclusive first', scResp, _exOkay);
    } else {
      plainFirst++;
      want('race gap $gap, plain first', scResp, _okay);
    }
    want('race gap $gap value', (await a.read('m2', 0, r)).$1, 0x2000 + gap);
  }
  if (scFirst == 0 || plainFirst == 0) {
    bad.add('race: exclusive first $scFirst, plain first $plainFirst');
  }

  // An exclusive read next to a plain write of the same word. When the
  // exclusive write passes, the read must have seen the plain write.
  const q = 0x340;
  for (var gap = 0; gap <= 6; gap++) {
    await a.write('m2', 0, q, 0x5000);
    final plain = a.write('m2', 1, q, 0x6000 + gap);
    await a.s.cycles(gap);
    final (v, rResp) = await a.read('m0', 1, q, lock: true);
    want('next read resp', rResp, _exOkay);
    await plain;
    final scResp = await a.write('m0', 1, q, v + 1, lock: true);
    if (scResp == _exOkay && v != 0x6000 + gap) {
      bad.add('next gap $gap: passed after reading 0x${v.toRadixString(16)}');
    }
  }

  for (final e in a.m.entries) {
    if (e.value.awOrder.length != e.value.bResp.length) {
      bad.add('${e.key}: B responses missing');
    }
  }
  return bad;
}

/// One request the waist took, or one write response it gave.
typedef _Event = ({int cycle, bool take, int id, bool write, int addr});

/// The monitor rules applied to the waist order: returns the response
/// codes each ID must get, reads and writes apart, and the memory words.
({Map<int, List<int>> r, Map<int, List<int>> b, Map<int, int> mem}) _model(
  List<_Event> events,
  Map<(int, int), (bool, int)> issued,
  Set<int> slotIds,
) {
  const g = 6;
  final valid = <int, bool>{};
  final key = <int, int>{};
  final ring = <(bool, int)>[];
  final r = <int, List<int>>{};
  final b = <int, List<int>>{};
  final mem = <int, int>{};
  final takes = <int, int>{};
  for (final e in events) {
    if (!e.take) {
      ring.removeAt(0);
      continue;
    }
    final n = takes[e.id << 1 | (e.write ? 1 : 0)] =
        (takes[e.id << 1 | (e.write ? 1 : 0)] ?? -1) + 1;
    final (lock, data) = issued[(e.id << 1 | (e.write ? 1 : 0), n)]!;
    final excl = lock && slotIds.contains(e.id);
    final k = e.addr >> g;
    if (!e.write) {
      if (excl) {
        valid[e.id] = !ring.any((w) => w.$1 && w.$2 == k);
        key[e.id] = k;
      }
      (r[e.id] ??= []).add(excl ? _exOkay : _okay);
      continue;
    }
    final pass = excl && (valid[e.id] ?? false) && key[e.id] == k;
    final writes = !excl || pass;
    (b[e.id] ??= []).add(pass ? _exOkay : _okay);
    if (writes) {
      for (final id in valid.keys) {
        if (key[id] == k) valid[id] = false;
      }
      mem[e.addr] = data;
    }
    ring.add((writes, k));
  }
  return (r: r, b: b, mem: mem);
}

/// Random traffic with stalls on every channel, checked against [_model].
/// Chains of ops on one granule run with no drain, so entries wait in the
/// FIFOs behind other takes.
Future<void> _stress(int seed, double stall, int idle) async {
  final shell = MemSlaveShell(
    const HarborMemoryWaistConfig(
      addressWidth: 16,
      dataWidth: 32,
      idWidth: 3,
      outstanding: 4,
    ),
    exclusive: const HarborAxi4Exclusive([(0, 4)]),
  );
  final s = Sim(shell);
  await s.start();
  Simulator.setMaxSimTime(400000000);
  final errors = <String>[];
  final rng = Random(seed);
  final mem = WaistMemory(
    s,
    'mem',
    rng,
    outstanding: 4,
    busBytes: 4,
    errors: errors,
    stall: stall,
  );
  final a = AxiManager(
    s,
    'bus',
    rng,
    awIdle: idle == 0 ? 0 : 0.3,
    wIdle: idle == 0 ? 0 : 0.5,
    arIdle: idle == 0 ? 0 : 0.3,
    stall: stall,
    lockPorts: true,
  );
  final events = <_Event>[];
  var cycle = 0;
  s.onRise(() {
    cycle++;
    if (s.pre('mem_REQ_VALID') == 1 && s.pre('mem_REQ_READY') == 1) {
      events.add((
        cycle: cycle,
        take: true,
        id: s.pre('mem_REQ_ID'),
        write: s.pre('mem_REQ_WRITE') == 1,
        addr: s.pre('mem_REQ_ADDR'),
      ));
    }
    if (s.pre('mem_WRESP_VALID') == 1 && s.pre('mem_WRESP_READY') == 1) {
      events.add((cycle: cycle, take: false, id: 0, write: true, addr: 0));
    }
  });
  final issued = <(int, int), (bool, int)>{};
  final count = <int, int>{};
  var value = 1;
  Future<void> drain() => waitUntil(
    s,
    () =>
        a.aw.idleNow &&
        a.ar.idleNow &&
        a.bResp.length == a.awOrder.length &&
        a.rBeats.length == a.readBeatsExpected,
  );
  void op(int id, bool write, bool lock, int addr) {
    final tag = id << 1 | (write ? 1 : 0);
    final n = count[tag] = (count[tag] ?? -1) + 1;
    final data = value++;
    issued[(tag, n)] = (lock, data);
    final burst = Burst(
      id: id,
      write: write,
      addr: addr,
      len: 0,
      size: 2,
      burst: 1,
      data: write ? [data] : const [],
      strb: write ? const [0xf] : const [],
    );
    if (write) {
      a.write(burst, lock: lock);
    } else {
      a.read(burst, lock: lock);
    }
  }

  const x = 0x140;
  for (var round = 0; round < 120; round++) {
    final kind = round % 3;
    if (kind == 1) {
      // Reserve for several IDs, then a chain of 2 to 5 mixed ops on one
      // granule with no drain, so entries wait behind other takes.
      for (final id in [0, 1, 2, 3]) {
        op(id, false, true, x);
      }
      await drain();
      final len = 2 + rng.nextInt(4);
      for (var i = 0; i < len; i++) {
        final id = rng.nextInt(6);
        op(
          id,
          rng.nextInt(3) != 0,
          id < 4 && rng.nextBool(),
          x + 4 * rng.nextInt(2),
        );
      }
    } else if (kind == 2) {
      // LR then X of the same ID with a plain write and other IDs between.
      final id = rng.nextInt(4);
      op(id, false, true, x);
      if (rng.nextBool()) op(4 + rng.nextInt(2), true, false, x);
      op((id + 1) % 4, false, true, x);
      op(id, true, true, x);
      op((id + 1) % 4, true, true, x);
    } else {
      for (var i = 0; i < 8; i++) {
        final id = rng.nextInt(6);
        op(
          id,
          rng.nextBool(),
          id < 4 && rng.nextInt(4) != 0,
          0x100 + 0x40 * rng.nextInt(3) + 4 * rng.nextInt(2),
        );
      }
    }
    if (rng.nextInt(3) == 0) await drain();
  }
  await drain();
  await s.stop();
  final want = _model(events, issued, {0, 1, 2, 3});
  final gotR = <int, List<int>>{};
  for (final (id, _, resp, _) in a.rBeats) {
    (gotR[id] ??= []).add(resp);
  }
  final gotB = <int, List<int>>{};
  for (final (id, resp) in a.bResp) {
    (gotB[id] ??= []).add(resp);
  }
  expect(errors, isEmpty);
  expect(gotR, want.r);
  expect(gotB, want.b);
  for (final e in want.mem.entries) {
    expect(mem.mem.read(e.key), e.value, reason: '0x${e.key}');
  }
  var ex = 0;
  for (final l in gotB.values) {
    ex += l.where((r) => r == _exOkay).length;
  }
  final takes = [
    for (final e in events)
      if (e.take) e,
  ];
  var b2b = 0;
  for (var i = 1; i < takes.length; i++) {
    if (takes[i].cycle == takes[i - 1].cycle + 1) b2b++;
  }
  expect(ex, greaterThan(0));
  expect(b2b, greaterThan(0));
}

/// Takes per cycle of 64 single-word requests from one ID with no idle and
/// no stalls, and the cycles from the AXI4 handshake of the first one to
/// its waist take.
Future<(double, int)> _rate(
  HarborAxi4Exclusive? ex, {
  required bool reads,
  bool lock = false,
}) async {
  final shell = MemSlaveShell(
    const HarborMemoryWaistConfig(
      addressWidth: 16,
      dataWidth: 32,
      idWidth: 3,
      outstanding: 8,
    ),
    exclusive: ex,
  );
  final s = Sim(shell);
  await s.start();
  final errors = <String>[];
  final rng = Random(1);
  WaistMemory(
    s,
    'mem',
    rng,
    outstanding: 8,
    busBytes: 4,
    errors: errors,
    stall: 0,
  );
  final a = AxiManager(
    s,
    'bus',
    rng,
    awIdle: 0,
    wIdle: 0,
    arIdle: 0,
    stall: 0,
    lockPorts: true,
  );
  final takes = <int>[];
  final accepts = <int>[];
  final ch = reads ? 'AR' : 'AW';
  var cycle = 0;
  s.onRise(() {
    cycle++;
    if (s.pre('mem_REQ_VALID') == 1 && s.pre('mem_REQ_READY') == 1) {
      takes.add(cycle);
    }
    if (s.pre('bus_${ch}VALID') == 1 && s.pre('bus_${ch}READY') == 1) {
      accepts.add(cycle);
    }
  });
  for (var i = 0; i < 64; i++) {
    final b = Burst(
      id: 1,
      write: !reads,
      addr: 0x100 + 4 * (i % 8),
      len: 0,
      size: 2,
      burst: 1,
      data: reads ? const [] : [i],
      strb: reads ? const [] : const [0xf],
    );
    if (reads) {
      a.read(b, lock: lock);
    } else {
      a.write(b, lock: lock);
    }
  }
  await waitUntil(s, () => takes.length == 64);
  await s.stop();
  expect(errors, isEmpty);
  return ((64 - 17) / (takes.last - takes[16]), takes[0] - accepts[0]);
}

void main() {
  tearDown(endAndReset);

  test('exclusive access on an SRAM', () async {
    final top = _SramTop();
    final s = Sim(top);
    await s.start();
    Simulator.setMaxSimTime(100000000);
    final a = _Agents(s, top.sram.bus.fabricWaist);
    final bad = await _scenarios(a, n: 20);
    await s.stop();
    expect(bad, isEmpty);
  });

  test('exclusive access on an ECP5 SDRAM', () async {
    late _Agents a;
    final bench = await SdramPortBench.start(
      HarborFabricKind.axi4,
      const HarborMemoryWaistConfig(
        addressWidth: 25,
        dataWidth: 32,
        idWidth: _slaveIdW,
        outstanding: 8,
      ),
      fabricPeriodPs: 20000,
      exclusive: _excl,
      link: (top, sdram) =>
          _linkFabric(top, sdram, 25, BusAddressRange(0, 1 << 25), 8),
      attach: (s) {},
    );
    a = _Agents(bench.s, bench.sdram.bus!.fabricWaist);
    final bad = [...await _scenarios(a, n: 16), ...bench.model.errors.take(8)];
    await bench.stop();
    expect(bad, isEmpty);
  });

  test('exclusive access on a fast sim DDR3 with two read channels', () async {
    final top = Ddr3FabricBench(
      cores: [
        for (final (name, idW, excl) in _masters)
          CoreCfg(
            name,
            idW,
            4,
            readChannel: excl == null ? 1 : 0,
            exclusiveIds: excl,
          ),
      ],
      readChannels: 2,
      outstanding: 8,
    );
    final run = await Ddr3FabricRun.start(top);
    final a = _Agents(run.sim, top.ddr.bus.fabricWaist);
    final bad = [...await _scenarios(a, n: 16), ...run.allErrors.take(8)];
    await run.sim.stop();
    expect(bad, isEmpty);
  });

  test(
    'an exclusive read that can miss a write in flight sets no slot',
    () async {
      final shell = MemSlaveShell(
        const HarborMemoryWaistConfig(
          addressWidth: 16,
          dataWidth: 32,
          idWidth: 4,
          outstanding: 4,
        ),
        exclusive: const HarborAxi4Exclusive([(0, 4)]),
      );
      final s = Sim(shell);
      await s.start();
      final errors = <String>[];
      final rng = Random(3);
      final mem = WaistMemory(
        s,
        'mem',
        rng,
        outstanding: 4,
        busBytes: 4,
        errors: errors,
        stall: 0,
      );
      final a = AxiManager(
        s,
        'bus',
        rng,
        awIdle: 0,
        wIdle: 0,
        arIdle: 0,
        stall: 0,
        lockPorts: true,
      );
      const q = 0x40;
      mem.mem.write(q, 0x10, 0xf);
      Burst word(int id, {int? data}) => Burst(
        id: id,
        write: data != null,
        addr: q,
        len: 0,
        size: 2,
        burst: 1,
        data: data == null ? const [] : [data],
        strb: data == null ? const [] : [0xf],
      );

      // ID 8 has no slot. Its write is taken with no data yet, so the
      // exclusive read of ID 1 after it returns the old value.
      a.write(word(8, data: 0x20), data: false);
      await waitUntil(s, () => mem.writes.length == 1);
      a.read(word(1), lock: true);
      await waitUntil(s, () => a.rBeats.length == 1);
      a.w.queue.add({'bus_WDATA': 0x20, 'bus_WSTRB': 0xf, 'bus_WLAST': 1});
      await waitUntil(s, () => a.bResp.length == 1);
      final (_, data, rResp, _) = a.rBeats.single;
      a.write(word(1, data: data + 1), lock: true);
      await waitUntil(s, () => a.bResp.length == 2);
      await s.stop();
      expect(errors, isEmpty);
      expect((data, rResp), (0x10, _exOkay));
      expect(a.bResp.last, (1, _okay));
      expect(mem.mem.read(q), 0x20);
    },
  );

  test('back to back takes match the monitor rules', () async {
    final shell = MemSlaveShell(
      const HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 32,
        idWidth: 3,
        outstanding: 4,
      ),
      exclusive: const HarborAxi4Exclusive([(0, 4)]),
    );
    final s = Sim(shell);
    await s.start();
    Simulator.setMaxSimTime(100000000);
    final errors = <String>[];
    final rng = Random(11);
    final mem = WaistMemory(
      s,
      'mem',
      rng,
      outstanding: 4,
      busBytes: 4,
      errors: errors,
      stall: 0,
    );
    final a = AxiManager(
      s,
      'bus',
      rng,
      awIdle: 0,
      wIdle: 0,
      arIdle: 0,
      stall: 0,
      lockPorts: true,
    );
    final events = <_Event>[];
    var cycle = 0;
    s.onRise(() {
      cycle++;
      if (s.pre('mem_REQ_VALID') == 1 && s.pre('mem_REQ_READY') == 1) {
        events.add((
          cycle: cycle,
          take: true,
          id: s.pre('mem_REQ_ID'),
          write: s.pre('mem_REQ_WRITE') == 1,
          addr: s.pre('mem_REQ_ADDR'),
        ));
      }
      if (s.pre('mem_WRESP_VALID') == 1 && s.pre('mem_WRESP_READY') == 1) {
        events.add((cycle: cycle, take: false, id: 0, write: true, addr: 0));
      }
    });

    // Random single-word accesses on three granules from IDs 0 to 3 (with
    // slots) and 4 to 5 (none), sent in batches so takes come back to back.
    final issued = <(int, int), (bool, int)>{};
    final count = <int, int>{};
    var value = 1;
    Future<void> drain() => waitUntil(
      s,
      () =>
          a.aw.idleNow &&
          a.ar.idleNow &&
          a.bResp.length == a.awOrder.length &&
          a.rBeats.length == a.readBeatsExpected,
    );
    void op(int id, bool write, bool lock, int addr) {
      final tag = id << 1 | (write ? 1 : 0);
      final n = count[tag] = (count[tag] ?? -1) + 1;
      final data = value++;
      issued[(tag, n)] = (lock, data);
      final burst = Burst(
        id: id,
        write: write,
        addr: addr,
        len: 0,
        size: 2,
        burst: 1,
        data: write ? [data] : const [],
        strb: write ? const [0xf] : const [],
      );
      if (write) {
        a.write(burst, lock: lock);
      } else {
        a.read(burst, lock: lock);
      }
    }

    // Each round either sends 6 random accesses at once, or reserves a
    // granule for IDs 1 and 2 and then sends two accesses to it at once,
    // which the waist takes in back to back cycles.
    const x = 0x140;
    final pairs = <List<(int, bool, bool)>>[
      [(4, true, false), (1, true, true)],
      [(1, true, true), (4, true, false)],
      [(2, true, true), (1, true, true)],
      [(1, false, true), (1, true, true)],
      [(4, true, false), (1, false, true)],
      [(1, true, true), (2, false, true)],
    ];
    for (var round = 0; round < 180; round++) {
      if (round.isOdd) {
        op(1, false, true, x);
        op(2, false, true, x);
        await drain();
        for (final (id, write, lock) in pairs[rng.nextInt(pairs.length)]) {
          op(id, write, lock, x);
        }
      } else {
        for (var i = 0; i < 6; i++) {
          final id = rng.nextInt(6);
          op(
            id,
            rng.nextBool(),
            id < 4 && rng.nextInt(4) != 0,
            0x100 + 0x40 * rng.nextInt(3) + 4 * rng.nextInt(2),
          );
        }
      }
      await drain();
    }
    await s.stop();

    final want = _model(events, issued, {0, 1, 2, 3});
    final gotR = <int, List<int>>{};
    for (final (id, _, resp, _) in a.rBeats) {
      (gotR[id] ??= []).add(resp);
    }
    final gotB = <int, List<int>>{};
    for (final (id, resp) in a.bResp) {
      (gotB[id] ??= []).add(resp);
    }
    expect(errors, isEmpty);
    expect(gotR, want.r);
    expect(gotB, want.b);
    for (final e in want.mem.entries) {
      expect(mem.mem.read(e.key), e.value, reason: '0x${e.key}');
    }

    // The bypass cases happened: a take right after a conflicting take of
    // each kind, in both orders.
    final takes = [
      for (final e in events)
        if (e.take) e,
    ];
    final seen = <String>{};
    for (var i = 1; i < takes.length; i++) {
      final (p, q) = (takes[i - 1], takes[i]);
      if (q.cycle != p.cycle + 1 || p.addr >> 6 != q.addr >> 6) continue;
      seen.add('${p.write ? 'w' : 'r'}${q.write ? 'w' : 'r'}');
      if (p.id == q.id) seen.add('same id');
    }
    expect(seen, containsAll(['ww', 'wr', 'rw', 'same id']));
  });

  for (final (seed, stall, idle) in [(2, 0.3, 0), (3, 0.3, 1)]) {
    test('stress with stalls, seed $seed', () => _stress(seed, stall, idle));
  }

  test('plain traffic keeps one take per cycle on a monitored port', () async {
    const ex = HarborAxi4Exclusive([(0, 4)]);
    for (final reads in [true, false]) {
      final (plainRate, plainLat) = await _rate(null, reads: reads);
      await endAndReset();
      final (rate, lat) = await _rate(ex, reads: reads);
      await endAndReset();
      expect(plainRate, 1.0, reason: 'reads $reads, no monitor');
      expect(rate, 1.0, reason: 'reads $reads, monitor');
      expect(lat, plainLat, reason: 'reads $reads');
    }
  });

  test('reset clears every reservation and the monitor recovers', () async {
    final shell = MemSlaveShell(
      const HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 32,
        idWidth: 3,
        outstanding: 4,
      ),
      exclusive: const HarborAxi4Exclusive([(0, 4)]),
    );
    final s = Sim(shell);
    await s.start();
    final errors = <String>[];
    final rng = Random(7);
    final mem = WaistMemory(
      s,
      'mem',
      rng,
      outstanding: 4,
      busBytes: 4,
      errors: errors,
      stall: 0,
    );
    final a = AxiManager(
      s,
      'bus',
      rng,
      awIdle: 0,
      wIdle: 0,
      arIdle: 0,
      stall: 0,
      lockPorts: true,
    );
    const q = 0x80;
    Burst word(int id, {int? data}) => Burst(
      id: id,
      write: data != null,
      addr: q,
      len: 0,
      size: 2,
      burst: 1,
      data: data == null ? const [] : [data],
      strb: data == null ? const [] : [0xf],
    );
    a.read(word(1), lock: true);
    await waitUntil(s, () => a.rBeats.length == 1);
    await s.cycles(2);
    s.set('reset', 1);
    await s.cycles(3);
    s.set('reset', 0);
    await s.cycles(2);
    a.write(word(1, data: 0x55), lock: true);
    await waitUntil(s, () => a.bResp.length == 1);
    a.read(word(1), lock: true);
    await waitUntil(s, () => a.rBeats.length == 2);
    a.write(word(1, data: 0x66), lock: true);
    await waitUntil(s, () => a.bResp.length == 2);
    await s.stop();
    expect(errors, isEmpty);
    expect(a.bResp, [(1, _okay), (1, _exOkay)]);
    expect(mem.mem.read(q), 0x66);
  });

  test('the granule bounds an exclusive access and its clear', () async {
    final shell = MemSlaveShell(
      const HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 32,
        idWidth: 4,
        outstanding: 4,
      ),
      exclusive: const HarborAxi4Exclusive([(0, 4)], granuleBytes: 16),
    );
    final s = Sim(shell);
    await s.start();
    final errors = <String>[];
    final rng = Random(5);
    final mem = WaistMemory(
      s,
      'mem',
      rng,
      outstanding: 4,
      busBytes: 4,
      errors: errors,
      stall: 0.2,
    );
    final a = AxiManager(s, 'bus', rng, lockPorts: true);
    Burst burst(int addr, int len, {int? data}) => Burst(
      id: 1,
      write: data != null,
      addr: addr,
      len: len,
      size: 2,
      burst: 1,
      data: data == null ? const [] : [for (var i = 0; i <= len; i++) data],
      strb: data == null ? const [] : List.filled(len + 1, 0xf),
    );
    Future<List<int>> read(Burst b) async {
      final from = a.rBeats.length;
      a.read(b, lock: true);
      await waitUntil(s, () => a.rBeats.length == from + b.beats);
      return [for (final r in a.rBeats.sublist(from)) r.$3];
    }

    Future<int> write(Burst b, {bool lock = true}) async {
      final from = a.bResp.length;
      a.write(b, lock: lock);
      await waitUntil(s, () => a.bResp.length > from);
      return a.bResp.last.$2;
    }

    // 32 bytes is more than the 16 byte granule: OKAY and no effect.
    expect(await read(burst(0x80, 7)), List.filled(8, _okay));
    expect(await write(burst(0x80, 7, data: 0x77)), _okay);
    expect(mem.mem.read(0x80), isNot(0x77));

    // 16 bytes fit. A plain write to another word of the granule clears it.
    expect(await read(burst(0x80, 3)), List.filled(4, _exOkay));
    expect(await write(burst(0x8c, 0, data: 0x11), lock: false), _okay);
    expect(await write(burst(0x80, 3, data: 0x22)), _okay);
    expect(mem.mem.read(0x80), isNot(0x22));

    // A plain write to the next granule does not.
    expect(await read(burst(0x80, 3)), List.filled(4, _exOkay));
    expect(await write(burst(0x90, 0, data: 0x33), lock: false), _okay);
    expect(await write(burst(0x80, 3, data: 0x44)), _exOkay);
    expect(mem.mem.read(0x80), 0x44);
    await s.stop();
    expect(errors, isEmpty);
  });

  group('build checks', () {
    Axi4Interface axi(int idW) =>
        Axi4Interface(addressWidth: 16, dataWidth: 32, idWidth: idW);
    List<HarborFabricMaster> masters({int? m1 = HarborExclusive.auto}) => [
      HarborFabricMaster(name: 'm0', interface: axi(2), exclusiveIds: 4),
      HarborFabricMaster(name: 'm1', interface: axi(2), exclusiveIds: m1),
      HarborFabricMaster(name: 'm2', interface: axi(1)),
    ];
    final ids = HarborAxi4Fabric.exclusiveOf(masters());
    Object build(
      List<HarborFabricMaster> ms,
      int slaveIdW,
      HarborAxi4Exclusive? ids,
    ) {
      try {
        HarborFabric.build(
          kind: HarborFabricKind.axi4,
          topology: HarborFabricTopology.shared,
          clk: Logic(),
          reset: Logic(),
          masters: ms,
          slaves: [
            HarborFabricSlave(
              name: 'dram',
              range: BusAddressRange(0, 0x10000),
              interface: axi(slaveIdW),
              outstanding: 4,
              exclusive: ids,
            ),
          ],
        );
        return 'built';
      } on ArgumentError catch (e) {
        return e.message.toString();
      }
    }

    test('a monitored slave that the fabric would remap throws', () {
      expect(
        build(masters(), 3, ids),
        allOf(contains('dram'), contains('ID width 4')),
      );
    });

    test('a monitored slave with full IDs builds', () {
      expect(build(masters(), 4, ids), 'built');
    });

    test('monitor IDs that are not the exclusive masters throw', () {
      expect(build(masters(m1: 2), 4, ids), contains('slots for'));
      expect(
        build([HarborFabricMaster(name: 'm0', interface: axi(2))], 4, ids),
        contains('no exclusive master'),
      );
    });

    test('an exclusive master that reaches a memory slave with no monitor '
        'throws', () {
      expect(
        build(masters(), 4, null),
        allOf(contains('m0'), contains('dram'), contains('no exclusive')),
      );
    });

    test('automatic slot counts split the budget in powers of two', () {
      const a = HarborExclusive.auto;
      expect(HarborExclusive.slotCounts([3, 2, 4], [2, a, a]), [2, 4, 2]);
      expect(HarborExclusive.slotCounts([1, 1], [a, a], budget: 1), [1, 1]);
      expect(HarborExclusive.slotCounts([4, 4, 4, 4], [a, a, a, a]), [
        2,
        2,
        2,
        2,
      ]);
      expect(HarborExclusive.slotCounts([2, 2], [3, a], budget: 2), [3, 1]);
      expect(() => HarborExclusive.slotCounts([1], [3]), throwsArgumentError);
    });

    test('an exclusive master on a read channel without the monitor '
        'throws', () {
      final ms = [
        HarborFabricMaster(
          name: 'm0',
          interface: axi(2),
          exclusiveIds: 1,
          readChannel: 1,
        ),
        HarborFabricMaster(name: 'm1', interface: axi(2)),
      ];
      expect(
        () => HarborFabric.build(
          kind: HarborFabricKind.axi4,
          topology: HarborFabricTopology.shared,
          clk: Logic(),
          reset: Logic(),
          masters: ms,
          slaves: [
            HarborFabricSlave(
              name: 'dram',
              range: BusAddressRange(0, 0x10000),
              interface: axi(3),
              readInterfaces: [
                Axi4ReadOnlyInterface(
                  addressWidth: 16,
                  dataWidth: 32,
                  idWidth: 3,
                ),
              ],
              outstanding: 4,
              exclusive: HarborAxi4Fabric.exclusiveOf(ms),
            ),
          ],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('read channel 0'),
          ),
        ),
      );
    });

    test('a monitor on a port that is not full AXI4 throws', () {
      for (final (kind, readOnly) in [
        (HarborFabricKind.wishbone, false),
        (HarborFabricKind.tilelink, false),
        (HarborFabricKind.axi4, true),
      ]) {
        expect(
          () => MemSlaveShell(
            const HarborMemoryWaistConfig(addressWidth: 16, dataWidth: 32),
            kind: kind,
            readOnly: readOnly,
            exclusive: const HarborAxi4Exclusive([(0, 2)]),
          ),
          throwsArgumentError,
        );
      }
    });

    test('exclusive access on another fabric kind throws', () {
      expect(
        () => HarborFabric.checkPorts(
          kind: HarborFabricKind.wishbone,
          masters: [
            HarborFabricMaster(name: 'm0', interface: axi(1), exclusiveIds: 1),
          ],
          slaves: const [],
          addressWidth: 16,
          dataWidth: 32,
        ),
        throwsArgumentError,
      );
    });

    test('no monitor logic without exclusive IDs', () async {
      Future<String> sv(HarborAxi4Exclusive? ids) async {
        final m = HarborSram(
          baseAddress: 0,
          size: 1024,
          protocol: HarborFabricKind.axi4,
          idWidth: _slaveIdW,
          exclusive: ids,
        );
        await m.build();
        return m.generateSynth();
      }

      final plain = await sv(null);
      expect(plain, isNot(contains('excl_')));
      expect(plain, contains('HarborAxi4MemorySlave_a10_d32_i5_n1 '));
      final monitored = await sv(_excl);
      expect(monitored, contains('excl_match'));
      expect(monitored, contains('HarborAxi4MemorySlave_a10_d32_i5_n1_x'));
    });
  });
}

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import 'axi4_fabric_harness.dart';

Burst rd(int id, int addr, int len, {int burst = 1}) =>
    Burst(id: id, write: false, addr: addr, len: len, size: 2, burst: burst);

Burst wr(int id, int addr, int len) => Burst(
  id: id,
  write: true,
  addr: addr,
  len: len,
  size: 2,
  burst: 1,
  data: [for (var i = 0; i <= len; i++) (addr << 8) + i + id * 0x1000000],
  strb: List.filled(len + 1, 0xf),
);

List<Map<String, int>> wBeats(String p, Burst x) => [
  for (var i = 0; i < x.beats; i++)
    {
      '${p}_WDATA': x.data[i],
      '${p}_WSTRB': x.strb[i],
      '${p}_WLAST': i == x.len ? 1 : 0,
    },
];

// Data a read returns from memory that the test wrote with [writes].
ReadWant Function(Burst) wantFrom(Bench b, List<Burst> writes) {
  final golden = [for (final _ in b.slaveCfgs) WordMemory(busBytes)];
  for (final x in writes) {
    if (b.respOf(x) != 0) continue;
    final s = b.slaveOf(x.addr)!;
    final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
    for (var i = 0; i < x.beats; i++) {
      golden[s].write(addrs[i], x.data[i], x.strb[i]);
    }
  }
  return (x) {
    final resp = b.respOf(x);
    if (resp != 0) return (resp, null);
    return (
      0,
      [
        for (final a in beatAddrs(x.addr, x.len, x.size, x.burst))
          golden[b.slaveOf(x.addr)!].read(a),
      ],
    );
  };
}

// Checks every manager against [writes] and the region and stability
// checks.
void checkAll(Bench b, {List<Burst> writes = const []}) {
  b.checkRegions();
  final want = wantFrom(b, writes);
  final errors = [...b.errors];
  for (final e in b.managers.entries) {
    final m = e.value;
    errors
      ..addAll(checkReads(e.key, m.arOrder, m.rBeats, want))
      ..addAll(checkWrites(e.key, m.awOrder, m.bResp, b.respOf));
  }
  must(errors.take(20).toList(), isEmpty);
}

// A master that issues one ID to two slaves gets the responses in issue
// order: the second request waits until the first one ends.
Future<void> _sameId(HarborFabricTopology t) async {
  final b = await Bench.start(t, stall: 0.2);
  final m0 = b.managers['m0']!;
  final s0 = b.memories['s0']!;
  final s1 = b.memories['s1']!;
  s0.holdResponses = true;
  final writes = [wr(3, 0x0400, 1), wr(3, 0x10400, 0)];
  m0
    ..read(rd(1, 0x0100, 3))
    ..read(rd(2, 0x10200, 1))
    ..read(rd(1, 0x10100, 3))
    ..write(writes[0])
    ..write(writes[1]);
  await b.sim.cycles(300);
  must(s0.arOrder.length, 1);
  must(s0.awOrder.length, 1);
  must(
    s1.arOrder.map((x) => x.addr).toList(),
    [0x10200],
    reason: 'the same-ID read to s1 must wait for the read on s0',
  );
  must(s1.awOrder, isEmpty, reason: 'the same-ID write must wait');
  must(m0.rBeats.map((x) => x.$1).toList(), [2, 2]);
  s0.holdResponses = false;
  await b.drain();
  await b.sim.stop();
  checkAll(b, writes: writes);
  must(m0.rBeats.where((x) => x.$1 == 1).length, 8);
}

// Unmapped requests get DECERR with every read beat and one B after the
// last W beat.
Future<void> _errorSlave(HarborFabricTopology t) async {
  final b = await Bench.start(t, stall: 0.2);
  final m0 = b.managers['m0']!;
  final m1 = b.managers['m1']!;
  m0
    ..read(rd(1, unmapped + 0x40, 15))
    ..read(rd(1, unmapped, 0))
    ..read(rd(2, unmapped + 0x80, 7, burst: 2))
    ..read(rd(3, unmapped + 0x84, 15, burst: 0));
  final late = wr(2, unmapped + 0x100, 7);
  m1.write(late, data: false);
  await b.sim.cycles(200);
  must(m1.bResp, isEmpty, reason: 'B came before the W beats');
  m1.w.queue.addAll(wBeats('m1', late));
  // W before its AW, to the error slave.
  final early = wr(5, unmapped + 0x2000, 3);
  m1.w.queue.addAll(wBeats('m1', early));
  await b.sim.cycles(100);
  m1.write(early, data: false);
  await b.drain();
  await b.sim.stop();
  checkAll(b);
  must(m0.rBeats.length, 16 + 1 + 8 + 16);
  must(m1.bResp, [(2, 3), (5, 3)]);
  for (final mem in b.memories.values) {
    must(mem.awOrder.length + mem.arOrder.length, 0);
  }
}

// Write data may come before its AW, to any slave.
Future<void> _wBeforeAw(HarborFabricTopology t) async {
  final b = await Bench.start(t, stall: 0.2);
  final m0 = b.managers['m0']!;
  final m2 = b.managers['m2']!;
  final writes = [
    wr(1, 0x0200, 5),
    wr(0, 0x10300, 3),
    wr(1, 0x20040, 0),
    wr(0, 0x0800, 15),
  ];
  m0.w.queue
    ..addAll(wBeats('m0', writes[0]))
    ..addAll(wBeats('m0', writes[1]));
  m2.w.queue
    ..addAll(wBeats('m2', writes[2]))
    ..addAll(wBeats('m2', writes[3]));
  await b.sim.cycles(150);
  must(m0.bResp, isEmpty);
  must(m2.bResp, isEmpty);
  m0
    ..write(writes[0], data: false)
    ..write(writes[1], data: false);
  m2
    ..write(writes[2], data: false)
    ..write(writes[3], data: false);
  await b.drain();
  for (final x in writes) {
    m0.read(rd(2, x.addr, x.len));
  }
  await b.drain();
  await b.sim.stop();
  checkAll(b, writes: writes);
}

// A slave with fewer ID bits sees one slave ID per full ID in flight, and a
// new full ID waits for a free one.
Future<void> _remap(HarborFabricTopology t) async {
  final b = await Bench.start(
    t,
    stall: 0.2,
    slaves: const [
      SlaveCfg('s0', 5, 8, 0x00000, 0x10000),
      SlaveCfg('s1', 1, 4, 0x10000, 0x10000),
    ],
  );
  final m0 = b.managers['m0']!;
  final m1 = b.managers['m1']!;
  final s1 = b.memories['s1']!;
  s1.holdResponses = true;
  m1
    ..read(rd(0, 0x10000, 1))
    ..read(rd(0, 0x10010, 2))
    ..read(rd(5, 0x10020, 0))
    ..read(rd(6, 0x10030, 3))
    ..read(rd(0, 0x10040, 0));
  m0.read(rd(1, 0x10050, 1));
  await b.sim.cycles(300);
  must(s1.arOrder.map((x) => x.id).toList(), [0, 0, 1]);
  s1.holdResponses = false;
  await b.drain();
  await b.sim.stop();
  checkAll(b);
  must(s1.arOrder.length, 6);
  must(s1.maxInflight, lessThanOrEqualTo(4));
}

// Each slave stops at its own outstanding limit, reads and writes together.
Future<void> _outstanding(HarborFabricTopology t) async {
  final b = await Bench.start(
    t,
    stall: 0.1,
    slaves: const [
      SlaveCfg('s0', 5, 8, 0x00000, 0x10000),
      SlaveCfg('s1', 5, 3, 0x10000, 0x10000),
    ],
  );
  final writes = <Burst>[];
  for (final s in b.memories.values) {
    s.holdResponses = true;
  }
  var id = 0;
  for (final e in b.managers.entries) {
    final cfg = masters3.firstWhere((m) => m.name == e.key);
    for (var k = 0; k < cfg.outstanding; k++) {
      final i = id++ % (1 << cfg.idWidth);
      e.value.read(rd(i, 0x0100 + k * 0x40, 1));
      final x = wr(i, 0x10000 + id * 0x40, 0);
      e.value.write(x);
      writes.add(x);
    }
  }
  await b.sim.cycles(400);
  must(b.memories['s0']!.inflight, 8);
  must(b.memories['s1']!.inflight, 3);
  for (final s in b.memories.values) {
    s.holdResponses = false;
  }
  await b.drain();
  await b.sim.stop();
  checkAll(b, writes: writes);
}

// A slave that stops answering is cut off: the requests in flight end with
// SLVERR, bus_error stays high, its late responses are dropped and later
// requests to it get SLVERR.
Future<void> _timeout(HarborFabricTopology t) async {
  final b = await Bench.start(
    t,
    stall: 0.2,
    masters: const [MasterCfg('m0', 2, 4), MasterCfg('m1', 3, 8)],
    slaves: const [
      SlaveCfg('s0', 5, 4, 0x00000, 0x10000),
      SlaveCfg('s1', 2, 2, 0x10000, 0x10000, timeout: 60),
    ],
  );
  final m0 = b.managers['m0']!;
  final m1 = b.managers['m1']!;
  final s1 = b.memories['s1']!;
  m0.read(rd(1, 0x10000, 7));
  await waitUntil(b.sim, () => m0.rBeats.isNotEmpty);
  s1.holdResponses = true;
  final dropped = wr(2, 0x10100, 3);
  m0.write(dropped);
  await b.drain(limit: 2000);
  must(b.busError(), 1);
  final okBeats = m0.rBeats.where((x) => x.$3 == 0).length;
  must(okBeats, inInclusiveRange(1, 7));
  must(m0.rBeats.map((x) => x.$4).toList(), [
    for (var i = 0; i < 8; i++) i == 7 ? 1 : 0,
  ]);
  must(m0.rBeats.skip(okBeats).every((x) => x.$3 == 2), isTrue);
  must(m0.bResp, [(2, 2)]);

  // The late responses come out and go nowhere.
  final seen = s1.arOrder.length + s1.awOrder.length;
  s1.holdResponses = false;
  await waitUntil(b.sim, () => s1.inflight == 0);
  await b.sim.cycles(50);
  must(m0.rBeats.length, 8);
  must(m0.bResp.length, 1);
  must(m1.rBeats.length + m1.bResp.length, 0);

  // Later requests to s1 end with SLVERR and never reach it. s0 still works.
  final after = wr(4, 0x0300, 1);
  m0
    ..read(rd(1, 0x10000, 1))
    ..read(rd(1, 0x0000, 1));
  m1
    ..write(wr(4, 0x10200, 2))
    ..write(after)
    ..read(rd(4, 0x0300, 1));
  await b.drain(limit: 4000);
  await b.sim.stop();
  must(s1.arOrder.length + s1.awOrder.length, seen);
  must(m0.rBeats.skip(8).map((x) => (x.$3, x.$4)).toList(), [
    (2, 0),
    (2, 1),
    (0, 0),
    (0, 1),
  ]);
  must(m1.bResp, [(4, 2), (4, 0)]);
  must(m1.rBeats.map((x) => x.$3).toList(), [0, 0]);
  must(b.busError(), 1);
  must(b.errors, isEmpty);
}

// A slave that never takes AR is cut off. The read gets SLVERR on every
// beat, bus_error sticks, and the read the slave takes later goes nowhere.
Future<void> _arHang(HarborFabricTopology t) async {
  final b = await Bench.start(
    t,
    stall: 0.2,
    masters: const [MasterCfg('m0', 2, 4), MasterCfg('m1', 3, 8)],
    slaves: const [
      SlaveCfg('s0', 5, 4, 0x00000, 0x10000),
      SlaveCfg('s1', 2, 2, 0x10000, 0x10000, timeout: 50),
    ],
  );
  final m0 = b.managers['m0']!;
  final m1 = b.managers['m1']!;
  final s1 = b.memories['s1']!;
  s1.ar.gate = () => false;
  m0
    ..read(rd(1, 0x10000, 3))
    ..read(rd(1, 0x10040, 0));
  await b.drain(limit: 2000);
  must(b.busError(), 1);
  must(s1.arOrder, isEmpty);
  must(m0.rBeats.map((x) => (x.$3, x.$4)).toList(), [
    for (var i = 0; i < 4; i++) (2, i == 3 ? 1 : 0),
    (2, 1),
  ]);

  s1.ar.gate = null;
  await b.sim.cycles(100);
  // The slave takes the AR it saw before the cut off and no queued one.
  must(s1.arOrder.length, 1);
  must(m0.rBeats.length, 5, reason: 'a late response reached a master');
  m1
    ..read(rd(2, 0x10100, 1))
    ..read(rd(2, 0x0100, 0));
  await b.drain(limit: 2000);
  await b.sim.stop();
  must(m1.rBeats.map((x) => x.$3).toList(), [2, 2, 0]);
  must(s1.arOrder.length, 1);
  must(b.busError(), 1);
  must(b.errors, isEmpty);
}

// A slave may hold AWREADY until WVALID. W that comes long after its AW,
// or waits behind another write's W, must not trip the timeout. A slave
// that takes neither AW nor W still times out.
Future<void> _awWaitsForW(HarborFabricTopology t) async {
  final b = await Bench.start(
    t,
    stall: 0.2,
    masters: const [MasterCfg('m0', 2, 4), MasterCfg('m1', 3, 8)],
    slaves: const [
      SlaveCfg('s0', 5, 4, 0x00000, 0x10000),
      SlaveCfg('s1', 2, 2, 0x10000, 0x10000, timeout: 40),
    ],
  );
  final m0 = b.managers['m0']!;
  final m1 = b.managers['m1']!;
  final s1 = b.memories['s1']!;
  int now(String port) => b.sim.dut.output(port).value.toInt();
  s1.aw
    ..stall = 0
    ..gate = () => now('s1_WVALID') == 1;
  s1.w
    ..stall = 0
    ..gate = () => now('s1_AWVALID') == 1;
  final late = [wr(1, 0x0100, 3), wr(2, 0x10100, 0)];
  final behind = wr(1, 0x10200, 0);
  m0
    ..write(late[0], data: false)
    ..write(late[1], data: false);
  await waitUntil(b.sim, () => m0.awOrder.length == 2);
  m1.write(behind);
  await b.sim.cycles(400);
  must(b.busError(), 0, reason: 'a slave waiting for W was cut off');
  must(m0.bResp, isEmpty);
  must(m1.bResp, isEmpty);
  m0.w.queue
    ..addAll(wBeats('m0', late[0]))
    ..addAll(wBeats('m0', late[1]));
  await b.drain();
  final writes = [...late, behind];
  for (final x in writes) {
    m1.read(rd(3, x.addr, x.len));
  }
  await b.drain();
  must(b.busError(), 0);
  checkAll(b, writes: writes);

  s1.aw.gate = () => false;
  s1.w.gate = () => false;
  m0.write(wr(2, 0x10300, 0));
  await b.drain(limit: 2000);
  await b.sim.stop();
  must(b.busError(), 1);
  must(m0.bResp.last, (2, 2));
  must(b.errors, isEmpty);
}

// A Lite master reaches a full slave and a full master reaches a Lite
// slave. A burst or a narrow access to the Lite slave gets SLVERR on every
// beat, and a write gets one B after all its W beats.
Future<void> _lite(HarborFabricTopology t) async {
  final b = await Bench.start(
    t,
    stall: 0.2,
    masters: const [MasterCfg('m0', 2, 4), MasterCfg('mL', 1, 2, lite: true)],
    slaves: const [
      SlaveCfg('s0', 5, 4, 0x00000, 0x10000),
      SlaveCfg('sL', 0, 1, 0x10000, 0x1000, lite: true),
    ],
  );
  final m0 = b.managers['m0']!;
  final mL = b.managers['mL']!;
  final sL = b.memories['sL']!;
  final burst = wr(2, 0x10020, 3);
  m0.write(burst, data: false);
  await b.sim.cycles(150);
  must(m0.bResp, isEmpty, reason: 'B came before the W beats');
  m0.w.queue.addAll(wBeats('m0', burst));
  final narrow = Burst(
    id: 2,
    write: true,
    addr: 0x10042,
    len: 0,
    size: 1,
    burst: 1,
    data: [0xabcd0000],
    strb: [0xc],
  );
  final writes = [
    burst,
    wr(1, 0x10010, 0),
    narrow,
    wr(0, 0x0100, 0),
    wr(0, 0x10030, 0),
    wr(0, unmapped, 0),
  ];
  m0
    ..write(writes[1])
    ..write(narrow);
  for (final x in writes.skip(3)) {
    mL.write(x);
  }
  await b.drain();
  m0
    ..read(rd(1, 0x10010, 0))
    ..read(rd(2, 0x10020, 3))
    ..read(Burst(id: 3, write: false, addr: 0x10031, len: 0, size: 0, burst: 1))
    ..read(rd(1, 0x0100, 0));
  for (final a in [0x0100, 0x10010, 0x10030, unmapped]) {
    mL.read(rd(0, a, 0));
  }
  await b.drain();
  await b.sim.stop();
  checkAll(b, writes: writes);
  must(m0.rBeats.where((x) => x.$1 == 2).map((x) => (x.$3, x.$4)).toList(), [
    (2, 0),
    (2, 0),
    (2, 0),
    (2, 1),
  ]);
  must(m0.bResp.where((x) => x.$1 == 2).toList(), [(2, 2), (2, 2)]);
  must(sL.awOrder.map((x) => x.addr).toSet(), {0x10010, 0x10030});
  must(sL.arOrder.length, 3);
  must(b.busError(), 0);
}

void main() {
  const long = Timeout(Duration(minutes: 5));
  for (final t in HarborFabricTopology.values) {
    group(t.name, () {
      test(
        'same ID to two slaves keeps issue order',
        () => isolated(() => _sameId(t)),
        timeout: long,
      );
      test(
        'error slave answers whole bursts with DECERR',
        () => isolated(() => _errorSlave(t)),
        timeout: long,
      );
      test(
        'write data before AW',
        () => isolated(() => _wBeforeAw(t)),
        timeout: long,
      );
      test(
        'ID remap holds one slave ID per full ID',
        () => isolated(() => _remap(t)),
        timeout: long,
      );
      test(
        'outstanding limit per slave',
        () => isolated(() => _outstanding(t)),
        timeout: long,
      );
      test(
        'timeout cuts a slave off and drops late responses',
        () => isolated(() => _timeout(t)),
        timeout: long,
      );
      test(
        'a slave that never takes AR is cut off',
        () => isolated(() => _arHang(t)),
        timeout: long,
      );
      test(
        'a slave that waits for W before AWREADY is not cut off',
        () => isolated(() => _awWaitsForW(t)),
        timeout: long,
      );
      test(
        'AXI4-Lite masters and slaves',
        () => isolated(() => _lite(t)),
        timeout: long,
      );
    });
  }
}

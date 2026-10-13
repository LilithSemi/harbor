import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import '../port/memory_native_harness.dart';
import 'native_fabric_harness.dart';

TlMsg get(int addr, int size) => TlMsg(
  op: tlGet,
  size: size,
  addr: addr,
  mask: [laneMask(addr, size, busBytes)],
);

TlMsg put(int addr, int size, {int op = tlPutFull}) {
  final n = tlBeats(size, busBytes);
  final lanes = laneMask(addr, size, busBytes);
  return TlMsg(
    op: op,
    size: size,
    addr: addr,
    data: [for (var i = 0; i < n; i++) addr * 16 + i],
    mask: List.filled(n, lanes),
  );
}

TlMsg intent(int addr, int size) =>
    TlMsg(op: tlIntent, size: size, addr: addr, mask: [0xf]);

// Records the cycle of each A beat a master sends and each D beat it takes.
class _Times {
  final List<int> a = [];
  final List<int> d = [];
  int _cycle = 0;

  _Times(TlBench b, String m) {
    b.sim.onRise(() {
      _cycle++;
      if (b.sim.pre('${m}_A_VALID') == 1 && b.sim.pre('${m}_A_READY') == 1) {
        a.add(_cycle);
      }
      if (b.sim.pre('${m}_D_VALID') == 1 && b.sim.pre('${m}_D_READY') == 1) {
        d.add(_cycle);
      }
    });
  }
}

Future<void> _finish(TlBench b, {int limit = 20000}) async {
  await b.drain(limit: limit);
  await b.sim.stop();
  must([...b.errors, ...b.checkResponses()], isEmpty);
}

// Unmapped messages get denied answers with all their D beats, and only
// after their last A beat.
Future<void> _errorSlave(HarborFabricTopology t) async {
  final b = await TlBench.start(t, stall: 0.2);
  final times = _Times(b, 'm0');
  b.managers['m0']!.a.idle = 0.7;
  final msgs = [
    put(unmapped, 4),
    get(unmapped + 0x40, 6),
    put(unmapped + 0x80, 5, op: tlArithmetic),
    put(unmapped + 0xc0, 2, op: tlLogical),
    intent(unmapped + 0x100, 5),
    put(unmapped + 0x140, 3, op: tlPutPartial),
  ];
  for (final m in msgs) {
    b.send('m0', m);
  }
  await _finish(b);
  must(msgs.map((m) => m.d.length).toList(), [1, 16, 8, 1, 1, 1]);
  must(msgs[4].d.single.$1, tlHintAck);
  // The error slave answers in order, so the first D beat of each message
  // must follow the last A beat of that message.
  var aBeat = 0;
  var dBeat = 0;
  for (final m in msgs) {
    aBeat += m.data.length;
    must(times.d[dBeat], greaterThan(times.a[aBeat - 1]), reason: '$m');
    dBeat += m.d.length;
  }
}

// A TL-UL slave never sees a burst, an atomic or a hint. Each one is denied
// for the whole message, and legal messages still reach the slave.
Future<void> _ulDeny(HarborFabricTopology t) async {
  final b = await TlBench.start(t, stall: 0.2);
  const base = 0x20000;
  final bad = [
    put(base, 4),
    get(base + 0x10, 4),
    get(base + 0x20, 3),
    put(base + 0x30, 2, op: tlArithmetic),
    put(base + 0x38, 3, op: tlLogical),
    intent(base + 0x40, 2),
  ];
  final good = [put(base + 0x50, 2), get(base + 0x50, 2), get(base + 0x54, 1)];
  for (final m in [...bad, ...good]) {
    b.send('m0', m);
  }
  await _finish(b);
  must(bad.map((m) => m.d.length).toList(), [1, 4, 2, 1, 2, 1]);
  must(bad.every((m) => m.d.every((d) => d.$5 == 1)), isTrue);
  final seen = b.memories['s2']!.msgs;
  must(seen.map((m) => (m.op, m.addr)).toList(), [
    for (final m in good) (m.op, m.addr),
  ]);
}

// A slave with one source bit holds two messages at a time, from any
// master. Each slave source is held by one message only.
Future<void> _remap(HarborFabricTopology t) async {
  final b = await TlBench.start(
    t,
    stall: 0.2,
    slaves: const [
      PortCfg('s0', width: 1, outstanding: 4, base: 0x00000, size: 0x8000),
    ],
  );
  final mem = b.memories['s0']!;
  mem.holdResponses = true;
  final sent = [
    for (var i = 0; i < 4; i++) ('m0', get(0x0000 + i * 0x40, 4)),
    for (var i = 0; i < 4; i++) ('m1', get(0x0800 + i * 0x40, 2)),
    for (var i = 0; i < 2; i++) ('m2', put(0x1000 + i * 4, 2)),
  ];
  for (final (m, x) in sent) {
    b.send(m, x);
  }
  await b.sim.cycles(300);
  must(mem.msgs.length, 2);
  must({for (final m in mem.msgs) m.source}, {0, 1});
  mem.holdResponses = false;
  await _finish(b);
  must(mem.msgs.length, sent.length);
  must(mem.maxInflight, 2);
}

// A slave gets at most its limit, and a master sends at most its own.
Future<void> _outstanding(HarborFabricTopology t) async {
  final b = await TlBench.start(
    t,
    stall: 0,
    masters: const [
      PortCfg('m0', width: 3, outstanding: 8),
      PortCfg('m1', width: 3, outstanding: 2),
    ],
    slaves: const [
      PortCfg('s0', width: 5, outstanding: 3, base: 0x00000, size: 0x8000),
      PortCfg('s3', width: 4, outstanding: 8, base: 0x30000, size: 0x8000),
    ],
  );
  final s0 = b.memories['s0']!;
  final s3 = b.memories['s3']!;
  s0.holdResponses = true;
  s3.holdResponses = true;
  for (var i = 0; i < 6; i++) {
    b
      ..send('m0', get(i * 0x40, 3))
      ..send('m1', get(0x30000 + i * 0x40, 3));
  }
  await b.sim.cycles(300);
  must(s0.msgs.length, 3);
  must(s3.msgs.length, 2);
  s0.holdResponses = false;
  s3.holdResponses = false;
  await _finish(b);
  must(s0.maxInflight, 3);
  must(s3.maxInflight, 2);
}

// A slave that stops in the middle of a D message is cut off. The message
// ends with corrupt beats, the message waiting behind it is denied, late D
// beats go nowhere, and later messages are denied without the slave.
Future<void> _timeout(HarborFabricTopology t) async {
  final b = await TlBench.start(
    t,
    stall: 0.2,
    slaves: const [
      PortCfg('s0', width: 5, outstanding: 4, base: 0x00000, size: 0x8000),
      PortCfg(
        's1',
        width: 2,
        outstanding: 4,
        base: 0x10000,
        size: 0x8000,
        timeout: 60,
      ),
    ],
  );
  final m0 = b.managers['m0']!;
  final m1 = b.managers['m1']!;
  final s1 = b.memories['s1']!;
  final long = get(0x10000, 5);
  m0.send(long);
  await waitUntil(b.sim, () => long.d.isNotEmpty);
  s1
    ..d.idle = 1.0
    ..holdResponses = true;
  final wr = put(0x10100, 4);
  m1.send(wr);
  await b.drain(limit: 3000);
  must(b.busError(), 1);
  final ok = long.d.where((d) => d.$6 == 0).length;
  must(ok, inInclusiveRange(1, 7));
  final init = WordMemory(busBytes);
  must(long.d.map((d) => (d.$4, d.$5, d.$6)).toList(), [
    for (var i = 0; i < 8; i++)
      i < ok ? (init.read(0x10000 + i * busBytes), 0, 0) : (0, 0, 1),
  ]);
  must(wr.d.map((d) => (d.$1, d.$5, d.$6)).toList(), [(tlAccessAck, 1, 0)]);

  // The late beats come out and go nowhere.
  final seen = s1.msgs.length;
  s1
    ..d.idle = 0
    ..holdResponses = false;
  await b.sim.cycles(200);
  must(long.d.length, 8);
  must(wr.d.length, 1);

  // Later messages to s1 are denied and never reach it. s0 still works.
  final after = [get(0x10200, 2), put(0x10300, 3), get(0x0040, 2)];
  b
    ..send('m1', after[0])
    ..send('m0', after[1])
    ..send('m2', after[2]);
  await b.drain(limit: 3000);
  await b.sim.stop();
  must(s1.msgs.length, seen);
  must(after[0].d.map((d) => (d.$5, d.$6)).toList(), [(1, 1)]);
  must(after[1].d.map((d) => (d.$5, d.$6)).toList(), [(1, 0)]);
  must(after[2].d.map((d) => (d.$5, d.$6)).toList(), [(0, 0)]);
  must(b.busError(), 1);
  must(b.errors, isEmpty);
}

// A slave that never takes A is cut off. Its messages are denied, and once
// it takes A again it sees only the beat it saw before the cut off, never a
// beat still queued for it. A master that reaches only s0 gets denied at s1.
Future<void> _aHang(HarborFabricTopology t) async {
  final b = await TlBench.start(
    t,
    stall: 0,
    slaves: const [
      PortCfg('s0', width: 5, outstanding: 4, base: 0x00000, size: 0x8000),
      PortCfg(
        's1',
        width: 2,
        outstanding: 4,
        base: 0x10000,
        size: 0x8000,
        timeout: 40,
      ),
    ],
  );
  final s1 = b.memories['s1']!;
  s1.a.gate = () => false;
  final first = get(0x10000, 2);
  final second = get(0x10040, 2);
  b
    ..send('m0', first)
    ..send('m1', second);
  await b.drain(limit: 3000);
  must(b.busError(), 1);
  must(s1.msgs, isEmpty);
  for (final m in [first, second]) {
    must(m.d.map((d) => (d.$5, d.$6)).toList(), [(1, 1)]);
  }
  s1.a.gate = null;
  await b.sim.cycles(100);
  await b.sim.stop();
  must(s1.msgs.length, lessThanOrEqualTo(1));
  must(b.errors, isEmpty);
}

void main() {
  const long = Timeout(Duration(minutes: 5));
  for (final t in HarborFabricTopology.values) {
    group(t.name, () {
      test(
        'a cut off slave never sees a queued beat',
        () => isolated(() => _aHang(t)),
        timeout: long,
      );
      test(
        'error slave denies whole messages after their last A beat',
        () => isolated(() => _errorSlave(t)),
        timeout: long,
      );
      test(
        'a TL-UL slave gets bursts, atomics and hints denied',
        () => isolated(() => _ulDeny(t)),
        timeout: long,
      );
      test(
        'source remap holds one slave source per message',
        () => isolated(() => _remap(t)),
        timeout: long,
      );
      test(
        'slave and master outstanding limits',
        () => isolated(() => _outstanding(t)),
        timeout: long,
      );
      test(
        'timeout cuts a slave off and drops late beats',
        () => isolated(() => _timeout(t)),
        timeout: long,
      );
    });
  }
}

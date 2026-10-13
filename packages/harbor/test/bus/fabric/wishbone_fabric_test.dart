import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../port/memory_native_harness.dart';
import 'native_fabric_harness.dart';
import 'wishbone_fabric_random_test.dart' show mixedSessions;

WbTxn rd(int addr, {int n = 1, bool burst = false}) => WbTxn(
  false,
  burst ? WbMode.burst : WbMode.classic,
  [for (var i = 0; i < n; i++) WbBeat(addr + i * busBytes, sel: 0xf)],
);

WbTxn wr(int addr, {int n = 1, bool burst = false}) =>
    WbTxn(true, burst ? WbMode.burst : WbMode.classic, [
      for (var i = 0; i < n; i++)
        WbBeat(addr + i * busBytes, data: addr + i, sel: 0xf),
    ]);

// The masters of the answered beats in each CYC slave [s] saw.
List<List<int>> owners(WbBench b, String s) {
  final cfg = b.slaveCfgs.firstWhere((x) => x.name == s);
  return [
    for (final x in b.memories[s]!.sessions)
      [for (final f in x) wbOwner(cfg, f['ADR']!)],
  ];
}

Future<void> _finish(WbBench b) async {
  await b.drain(limit: 20000);
  await b.sim.stop();
  must([...b.checkBeats(), ...b.checkMemories(), ...mixedSessions(b)], isEmpty);
}

// Unmapped beats end with ERR, or with ACK and data 0 for a master with no
// ERR, which sets fold_error. A burst ends at its first ERR.
Future<void> _errorSlave(HarborFabricTopology t) async {
  final b = await WbBench.start(t);
  final burst = rd(unmapped, n: 4, burst: true);
  b
    ..send(0, burst)
    ..send(0, wr(unmapped + 0x40))
    ..send(1, wr(unmapped + 0x80, n: 3, burst: true))
    ..send(2, rd(unmapped + 0x100))
    ..send(2, wr(unmapped + 0x104))
    ..send(0, rd(0x0000));
  await _finish(b);
  must(burst.done, 1);
  must(burst.beats.first.err, 1);
  must(b.managers['m2']!.finished.first.beats.first.rdata, 0);
  must(b.foldError(), 1);
}

// A burst reaches the slave with the master's CTI and BTE.
Future<void> _burstPass(HarborFabricTopology t) async {
  final b = await WbBench.start(t, gap: 0);
  b
    ..send(0, wr(0x0000, n: 4, burst: true))
    ..send(0, rd(0x0000, n: 4, burst: true));
  await _finish(b);
  for (final x in b.memories['s0']!.sessions) {
    must([for (final f in x) f['CTI']], [2, 2, 2, 7]);
    must([for (final f in x) f['BTE']], [0, 0, 0, 0]);
  }
}

// A master holds the grant while it holds CYC, across cycles to the same
// slave, and another master waits for it.
Future<void> _grantHold(HarborFabricTopology t) async {
  final b = await WbBench.start(t, keepCyc: 1, gap: 0);
  for (var i = 0; i < 3; i++) {
    b.send(0, rd(0x0000 + i * 0x10, n: 4, burst: true));
  }
  await b.sim.cycles(2);
  b.send(1, rd(0x0800));
  await _finish(b);
  must(owners(b, 's0'), [
    List.filled(12, 0),
    [1],
  ]);
}

// With maxGrantCycles, a long burst gives the grant away at the end of a
// beat once it held it that long, and finishes later.
Future<void> _maxGrant(HarborFabricTopology t, int? cap) async {
  final b = await WbBench.start(t, gap: 0, wait: 0, maxGrantCycles: cap);
  final long = rd(0x0000, n: 16, burst: true);
  b.send(0, long);
  await b.sim.cycles(3);
  b.send(1, rd(0x0800));
  await _finish(b);
  final o = owners(b, 's0');
  if (cap == null) {
    must(o, [
      List.filled(16, 0),
      [1],
    ]);
  } else {
    must(o.length, 3);
    must(o[1], [1]);
    must(o[0].length, lessThan(16));
    must(o[0].length + o[2].length, 16);
  }
}

// A slave that does not answer is cut off: the access ends with ERR,
// bus_error sticks, CYC to it stays low, and an answer it gives later never
// reaches a master. Other slaves still work.
Future<void> _timeout(HarborFabricTopology t) async {
  final b = await WbBench.start(
    t,
    slaves: const [
      PortCfg('s0', base: 0x00000, size: 0x8000),
      PortCfg('s1', base: 0x10000, size: 0x8000, timeout: 30),
    ],
  );
  final s1 = b.memories['s1']!;
  s1.hold = true;
  final stuck = rd(0x10000);
  b.managers['m0']!.queue.add(stuck);
  await b.drain(limit: 200);
  must(stuck.beats.first.err, 1);
  must(b.busError(), 1);

  // s1 now answers every cycle. Its answers must not reach a master.
  var cycOn = 0;
  b.sim
    ..onRise(() => cycOn += b.sim.pre('s1_CYC'))
    ..onFall(
      () => Simulator.registerAction(
        Simulator.time + 2,
        () => b.sim.set('s1_ACK', 1),
      ),
    );
  final m0Late = rd(0x10010, n: 2, burst: true);
  final m2Late = rd(0x10020);
  b.managers['m0']!.queue.add(m0Late);
  b.managers['m2']!.queue.add(m2Late);
  final other = rd(0x0800);
  b.send(1, other);
  await b.drain(limit: 200);
  await b.sim.stop();
  must(m0Late.done, 1);
  must(m0Late.beats.first.err, 1);
  must(m0Late.beats.first.ack, 0);
  must(m2Late.beats.first.ack, 1);
  must(m2Late.beats.first.rdata, 0xDEADBEEF);
  must(cycOn, 0);
  must(b.busError(), 1);
  must(other.beats.first.ack, 1);
  must(other.beats.first.rdata, b.golden['s0']!.read(0x0800));
}

// A master with a reach set gets the decode error for every slave out of
// reach, and that slave never sees the access.
Future<void> _reach(HarborFabricTopology t) async {
  final b = await WbBench.start(
    t,
    masters: const [
      PortCfg('m0', reach: {'s0'}),
      PortCfg('m1'),
      PortCfg('m2', memory: false, err: false, reach: {'s2'}),
    ],
  );
  final away = wr(0x10040);
  b
    ..send(0, away)
    ..send(0, rd(0x10000))
    ..send(0, wr(0x0040))
    ..send(1, wr(0x10080))
    ..send(1, rd(0x10080))
    ..send(2, rd(0x0040))
    ..send(2, rd(0x20000));
  await _finish(b);
  must(away.beats.first.err, 1);
  must(b.memories['s1']!.sessions.expand((x) => x).length, 2);
  must(b.foldError(), 1);
}

void main() {
  const long = Timeout(Duration(minutes: 5));
  for (final t in HarborFabricTopology.values) {
    group(t.name, () {
      test(
        'error slave ends unmapped beats with ERR',
        () => isolated(() => _errorSlave(t)),
        timeout: long,
      );
      test(
        'a master reaches only its reach set',
        () => isolated(() => _reach(t)),
        timeout: long,
      );
      test(
        'bursts pass through',
        () => isolated(() => _burstPass(t)),
        timeout: long,
      );
      test(
        'grant held while CYC is high',
        () => isolated(() => _grantHold(t)),
        timeout: long,
      );
      test(
        'no grant cap keeps a long burst whole',
        () => isolated(() => _maxGrant(t, null)),
        timeout: long,
      );
      test(
        'maxGrantCycles splits a long burst',
        () => isolated(() => _maxGrant(t, 4)),
        timeout: long,
      );
      test(
        'timeout cuts a slave off and drops late answers',
        () => isolated(() => _timeout(t)),
        timeout: long,
      );
    });
  }
}

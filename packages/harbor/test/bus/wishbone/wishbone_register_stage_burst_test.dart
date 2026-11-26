// A register stage keeps a burst a burst: the slave sees the beats of an
// incrementing burst in one CYC session, and the hold drops at the end, on
// an error, when the master drops CYC, and for a beat that does not continue
// the burst.

import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../fabric/axi4_fabric_harness.dart' show busBytes;
import '../port/memory_harness.dart' show waitUntil;
import '../port/memory_native_harness.dart';
import '../port/port_harness.dart';

const _cfg = WishboneConfig(
  addressWidth: 32,
  dataWidth: 32,
  useErr: true,
  useCti: true,
  useBte: true,
);

WbTxn _burst(int addr, int n, {bool write = false, int? abortAfter}) =>
    WbTxn(write, WbMode.burst, [
      for (var i = 0; i < n; i++)
        WbBeat(addr + i * busBytes, data: addr + i, sel: 0xf),
    ], abortAfter: abortAfter);

WbTxn _single(int addr) =>
    WbTxn(false, WbMode.classic, [WbBeat(addr, sel: 0xf)]);

class _Bench {
  final Sim sim = Sim(WishboneRegisterStage(config: _cfg));
  late final WbMaster master;
  late final WbMemory memory;

  _Bench({double gap = 0, double keepCyc = 0, int errBase = 0xf000}) {
    final rng = Random(5);
    master = WbMaster(sim, 'up', rng, gap: gap, keepCyc: keepCyc);
    memory = WbMemory(
      sim,
      'down',
      rng,
      busBytes: busBytes,
      errBase: errBase,
      wait: 0,
    );
  }

  Future<void> run(List<WbTxn> txns) async {
    await sim.start();
    Simulator.setMaxSimTime(4000000);
    master.queue.addAll(txns);
    await waitUntil(sim, () => master.done, limit: 5000);
    await sim.cycles(6);
    await sim.stop();
  }

  List<int> get sessionBeats => [for (final x in memory.sessions) x.length];
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'a burst reaches the slave in one session with CTI 010 then 111',
    () async {
      final b = _Bench();
      await b.run([_burst(0x100, 8), _burst(0x200, 8), _burst(0x300, 4)]);
      expect(b.sessionBeats, [8, 8, 4]);
      for (final x in b.memory.sessions) {
        expect([for (final f in x) f['CTI']].last, 7);
        expect([for (final f in x) f['CTI']].take(x.length - 1).toSet(), {2});
      }
      for (final t in b.master.finished) {
        for (final x in t.beats) {
          expect(x.err, 0);
          expect(x.rdata, b.memory.mem.read(x.addr));
        }
      }
    },
  );

  test('wait states inside a burst keep it in one session', () async {
    final b = _Bench(gap: 0.5);
    await b.run([_burst(0x100, 8), _burst(0x200, 8)]);
    expect(b.sessionBeats, [8, 8]);
    for (final t in b.master.finished) {
      for (final x in t.beats) {
        expect(x.rdata, b.memory.mem.read(x.addr));
      }
    }
  });

  test('a master that drops CYC inside a burst ends the session', () async {
    final b = _Bench();
    await b.run([_burst(0x100, 8, abortAfter: 3), _burst(0x200, 4)]);
    expect(b.sessionBeats, [3, 4]);
    for (final x in b.master.finished.last.beats) {
      expect(x.rdata, b.memory.mem.read(x.addr));
    }
  });

  test(
    'an error on a CTI 010 beat ends the session and clears the hold',
    () async {
      // The beat at 0x108 and every beat above it get ERR.
      final b = _Bench(errBase: 0x108);
      await b.run([_burst(0x100, 8), _burst(0x40, 4)]);
      final first = b.master.finished.first;
      expect(first.beats[2].err, 1, reason: 'the error reaches the master');
      expect(first.done, 3, reason: 'the burst ends at the error');
      // The slave saw the three beats of the failed burst, then the next
      // burst in its own session.
      expect(b.sessionBeats.first, 3);
      expect(b.sessionBeats.length, 2);
      expect(b.sessionBeats.last, 4);
      for (final x in b.master.finished.last.beats) {
        expect(x.err, 0);
        expect(x.rdata, b.memory.mem.read(x.addr));
      }
    },
  );

  test('a beat that does not continue the burst is answered right', () async {
    // The master keeps CYC between the cycles, so the next cycle starts
    // while the stage holds CYC after a CTI 010 beat.
    final b = _Bench(keepCyc: 1);
    await b.run([
      _burst(0x100, 2, abortAfter: 2),
      _single(0x800),
      _burst(0x400, 3),
    ]);
    for (final t in b.master.finished) {
      for (var i = 0; i < t.done; i++) {
        final x = t.beats[i];
        expect(x.err, 0);
        expect(x.rdata, b.memory.mem.read(x.addr), reason: '$t beat $i');
      }
    }
    expect(b.master.finished.length, 3);
  });
}

// Behind a register stage, a master that stalls inside a read burst holds CYC
// with STB low. The grant cap takes the grant from it, at a point after a
// read, so another master does not wait for the whole burst.

import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart' show waitUntil;
import '../port/memory_native_harness.dart';
import '../port/port_harness.dart';
import 'axi4_fabric_harness.dart' show busBytes;
import 'wishbone_stage_harness.dart';

WbTxn _burst(int addr, int n) => WbTxn(false, WbMode.burst, [
  for (var i = 0; i < n; i++) WbBeat(addr + i * busBytes, sel: 0xf),
]);

Future<int> _worstWait(HarborFabricTopology t, int grantCap) async {
  final sim = Sim(StageFabricShell(t, grantCap: grantCap));
  final rng = Random(3);
  // m0 stalls most cycles inside its bursts.
  final m0 = WbMaster(sim, 'm0', rng, gap: 0.9, keepCyc: 0);
  final m1 = WbMaster(sim, 'm1', rng, gap: 0, keepCyc: 0);
  WbMemory(sim, 's0', rng, busBytes: busBytes, errBase: 0xf000, wait: 0);
  final waits = <int>[];
  var now = 0;
  int? start;
  sim.onRise(() {
    now++;
    final req = sim.pre('m1_CYC') == 1 && sim.pre('m1_STB') == 1;
    if (req && start == null) start = now;
    if (req && sim.pre('m1_ACK') == 1 && start != null) {
      waits.add(now - start!);
      start = null;
    }
  });
  await sim.start();
  Simulator.setMaxSimTime(8000000);
  for (var i = 0; i < 6; i++) {
    m0.queue.add(_burst(0x100 + i * 0x80, 16));
  }
  for (var i = 0; i < 12; i++) {
    await sim.cycles(37);
    m1.queue.add(
      WbTxn(false, WbMode.classic, [WbBeat(0x2000 + i * 4, sel: 0xf)]),
    );
    final want = m1.finished.length + 1;
    await waitUntil(sim, () => m1.finished.length == want, limit: 3000);
  }
  await waitUntil(sim, () => m0.done, limit: 8000);
  await sim.stop();
  for (final tx in [...m0.finished, ...m1.finished]) {
    for (var i = 0; i < tx.done; i++) {
      expect(tx.beats[i].err, 0);
    }
  }
  return waits.reduce(max);
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final t in HarborFabricTopology.values) {
    test('${t.name}: the cap takes the grant from an idle owner behind a '
        'stage', () async {
      final worst = await _worstWait(t, harborDefaultWishboneGrantCap);
      // ignore: avoid_print
      print('${t.name}: worst wait of the other master $worst');
      // Without the idle preempt the wait is 29, with it 9.
      expect(worst, lessThanOrEqualTo(20));
    });
  }
}

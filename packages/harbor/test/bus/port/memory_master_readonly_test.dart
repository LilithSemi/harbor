import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'memory_harness.dart';
import 'port_harness.dart';

Future<void> _reads(
  HarborFabricKind kind,
  HarborMemoryWaistConfig config,
  int seed,
) async {
  final sim = Sim(MemLoopShell(config, kind: kind, readOnly: true));
  final rng = Random(seed);
  final errors = <String>[];
  final busBytes = config.strbWidth;
  final req = WaistRequester(sim, 'up', rng, errors: errors);
  final mem = WaistMemory(
    sim,
    'mem',
    rng,
    outstanding: config.outstanding,
    busBytes: busBytes,
    errors: errors,
  );
  final gen = BurstGen(rng, busBytes: busBytes, idWidth: config.idWidth);
  var writeSideBusy = 0;
  sim.onRise(() {
    if (sim.pre('up_WDATA_READY') != 0 || sim.pre('up_WRESP_VALID') != 0) {
      writeSideBusy++;
    }
  });
  await sim.start();
  Simulator.setMaxSimTime(10000000);

  for (var i = 0; i < 60; i++) {
    req.send(gen.next(write: false));
  }
  await waitUntil(sim, () => req.done && req.req.idleNow);

  expect(errors, isEmpty);
  expect(req.reads, hasLength(60));
  // The slave of each kind may split a burst, so only the data is compared.
  final mirror = WordMemory(busBytes);
  final bad = <String>[];
  for (var k = 0; k < req.reads.length; k++) {
    final x = req.reads[k];
    final beats = req.readResp[k];
    if (beats.length != x.beats) {
      bad.add('$x: ${beats.length} beats');
      continue;
    }
    if (illegalBurst(x, busBytes)) continue;
    final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
    for (var i = 0; i < beats.length; i++) {
      final want = (x.id, mirror.read(addrs[i]), 0, i == x.len ? 1 : 0);
      if (beats[i] != want) bad.add('$x beat $i: got ${beats[i]}');
    }
  }
  expect(bad, isEmpty);
  expect(mem.writes, isEmpty, reason: 'a write reached the native link');
  expect(writeSideBusy, 0);
  await sim.stop();
}

void main() {
  tearDown(endAndReset);

  for (final kind in HarborFabricKind.values) {
    for (final n in [1, 4]) {
      test('${kind.name}: a read only master reads, outstanding $n', () async {
        await _reads(
          kind,
          HarborMemoryWaistConfig(
            addressWidth: 16,
            dataWidth: 32,
            idWidth: n == 1 ? 1 : 3,
            outstanding: n,
          ),
          30 + n,
        );
      });
    }
  }
}

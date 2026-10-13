import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'memory_harness.dart';
import 'port_harness.dart';

Future<void> _loop(HarborMemoryWaistConfig config, {required int seed}) async {
  final sim = Sim(MemLoopShell(config));
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
  final gen = BurstGen(
    rng,
    busBytes: busBytes,
    idWidth: config.idWidth,
    errors: 0.05,
  );
  await sim.start();
  Simulator.setMaxSimTime(10000000);

  for (var i = 0; i < 150; i++) {
    req.send(gen.next(write: rng.nextBool()));
  }
  await waitUntil(sim, () => req.done && req.req.idleNow);

  // A read back of every word after all the writes.
  final first = req.reads.length;
  for (var a = 0; a < 0x2000; a += 16 * busBytes) {
    req.send(
      Burst(
        id: 0,
        write: false,
        addr: a,
        len: 15,
        size: busBytes.bitLength - 1,
        burst: 1,
      ),
    );
  }
  await waitUntil(sim, () => req.done && req.req.idleNow);

  expect(errors, isEmpty);
  expect(<String>[
    for (var k = 0; k < req.writes.length; k++)
      ?diffReq(req.writes[k], mem.writes[k]),
    for (var k = 0; k < req.reads.length; k++)
      ?diffReq(req.reads[k], mem.reads[k]),
  ], isEmpty);
  expect(req.writeResp, [
    for (final x in req.writes) (x.id, x.addr >= 0xf000 ? 1 : 0),
  ]);
  final want = golden(req.writes, busBytes);
  final bad = <String>[];
  for (var k = 0; k < req.reads.length; k++) {
    final x = req.reads[k];
    final beats = req.readResp[k];
    if (beats.length != x.beats) bad.add('$x: ${beats.length} beats');
    for (var i = 0; i < beats.length; i++) {
      final (id, data, err, last) = beats[i];
      final wantData = k >= first
          ? want.read((k - first) * 16 * busBytes + i * busBytes)
          : mem.readData[k][i];
      final w = (x.id, wantData, x.addr >= 0xf000 ? 1 : 0, i == x.len ? 1 : 0);
      if ((id, data, err, last) != w) bad.add('$x beat $i: got $beats[$i]');
    }
  }
  expect(bad, isEmpty);
  expect(diffMemory(want, mem.mem), isEmpty);
  await sim.stop();
}

void main() {
  tearDown(endAndReset);

  test('master port to slave port, 32 bit, 4 outstanding', () async {
    await _loop(
      const HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 32,
        idWidth: 4,
        outstanding: 4,
      ),
      seed: 21,
    );
  });

  test('master port to slave port, 64 bit, 8 outstanding', () async {
    await _loop(
      const HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 64,
        idWidth: 2,
        outstanding: 8,
      ),
      seed: 22,
    );
  });
}

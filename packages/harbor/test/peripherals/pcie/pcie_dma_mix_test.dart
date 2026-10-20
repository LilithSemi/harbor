import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_dma_bench.dart';
import '../../util/pcie_host_model.dart';

void main() {
  tearDown(() async => Simulator.reset());

  for (final (config, count) in [
    (const DmaConfig(), 500),
    (const DmaConfig(width: 128, dataWidth: 128), 60),
    (const DmaConfig(width: 128, kind: HarborFabricKind.wishbone), 60),
  ]) {
    test(
      'random mix of $count descriptors, $config',
      () async {
        await _randomMix(config, count);
      },
      timeout: const Timeout(Duration(hours: 3)),
    );
  }

  for (final width in [64, 128]) {
    test('a 1024 DW completion stays in its slot, W$width', () async {
      final b = await DmaBench.create(
        DmaConfig(width: width, dataWidth: width, maxReadRequestBytes: 4096),
        seed: 40 + width,
      );
      b.seedHost(0x80002000, 0x2000);
      b.maxReadRequest.inject(5);
      final reads = <PcieTlp>[];
      b.sink.onTlp = (t) {
        if (t.kind != PcieTlpKind.memRead32) {
          b.host.receive(t);
          return;
        }
        reads.add(t);
        if (reads.length < 2) return;
        // The second read is answered first, then one 1024 DW completion
        // for the first read.
        for (final r in reads.reversed) {
          b.injected.add(
            PcieTlp.completion(
              completerId: 0x55,
              requesterId: r.requesterId,
              tag: r.tag,
              byteCount: 4096,
              data: b.host.memory.read(r.address, 4096),
            ),
          );
        }
      };
      await b.start();
      await b.setupRing(dmaCplBase, 4);
      await b.enable();
      await b.push(
        hostAddress: 0x80002000,
        localAddress: 0x8000,
        length: 0x2000,
        deviceToHost: false,
      );
      await b.waitRecordWrites(0, 1);
      expect(reads.map((t) => t.lengthDw), [1024, 1024]);
      expect(b.record(0).code, 0);
      b.checkLocal(0x80002000, 0x8000, 0x2000);
      await b.finish();
    });
  }
}

/// Runs [count] random descriptors in both directions and compares both
/// memories with a model at the end.
Future<void> _randomMix(DmaConfig config, int count) async {
  final b = await DmaBench.create(config, seed: count + config.width);
  final random = Random(count * 31 + config.width);
  const hostBase = 0x80000000;
  const hostHigh = 0x240000000;
  const hostSpan = 0x10000;
  const localSpan = 0x40000;
  b.seedHost(hostBase, hostSpan);
  b.seedHost(hostHigh, hostSpan);
  final modelHost = <int, int>{};
  final modelLocal = <int, int>{};
  int hostByte(int a) => modelHost[a] ?? b.host.memory.read(a, 1)[0];
  int localByte(int a) => modelLocal[a] ?? dmaFill(a);

  final jobs = <(int, int, int, bool)>[];
  for (var i = 0; i < count; i++) {
    final roll = random.nextInt(10);
    final len = roll == 0 ? 4 * random.nextInt(1025) : 4 * random.nextInt(97);
    final h =
        (random.nextBool() ? hostBase : hostHigh) +
        4 * random.nextInt((hostSpan - len) ~/ 4 + 1);
    final l = 4 * random.nextInt((localSpan - len) ~/ 4 + 1);
    final d2h = random.nextBool();
    jobs.add((h, l, len, d2h));
    for (var k = 0; k < len; k++) {
      if (d2h) {
        modelHost[h + k] = localByte(l + k);
      } else {
        modelLocal[l + k] = hostByte(h + k);
      }
    }
  }

  var records = 0;
  b.sink.onTlp = (t) {
    if (t.kind.hasData &&
        t.address >= dmaCplBase &&
        t.address < dmaCplBase + 16 * 1024) {
      records++;
    }
    b.host.receive(t);
  };
  await b.start();
  await b.setupRing(dmaCplBase, 10);
  await b.enable();
  for (final (i, (h, l, len, d2h)) in jobs.indexed) {
    while (i - records >= config.queueDepth - 4) {
      await b.cycles(20);
    }
    await b.push(
      hostAddress: h,
      localAddress: l,
      length: len,
      deviceToHost: d2h,
      cookie: i,
    );
  }
  await b.waitUntil(
    () => records >= count,
    timeout: 4000000,
    what: 'all records',
  );
  expect(b.host.violations, isEmpty);
  for (final (i, (h, l, len, _)) in jobs.indexed) {
    final r = b.record(i);
    expect(r.cookie, i);
    expect(r.code, 0, reason: 'descriptor $i');
    expect(r.bytes, len);
    final host = b.host.memory.read(h, len);
    for (var k = 0; k < len; k++) {
      if (host[k] != hostByte(h + k)) {
        fail('descriptor $i: host byte 0x${(h + k).toRadixString(16)}');
      }
      if (b.memory.byte(l + k) != localByte(l + k)) {
        fail('descriptor $i: local byte 0x${(l + k).toRadixString(16)}');
      }
    }
  }
  await b.finish();
}

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_completer_bench.dart';
import '../../util/pcie_host_model.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('the BAR size comes from the endpoint BAR2 size', () {
    HarborPcieMemoryCompleter make({
      HarborPcieEndpointConfig? endpoint,
      int? barBytes,
    }) => HarborPcieMemoryCompleter(
      clk: Logic(),
      reset: Logic(),
      maxPayload: Logic(width: 3),
      rcb128: Logic(),
      completerId: Logic(width: 16),
      rx: HarborPcieStream(width: 64),
      tx: HarborPcieStream(width: 64),
      endpointConfig: endpoint,
      barBytes: barBytes,
    );
    const bar2 = HarborPcieEndpointConfig(bar2Bytes: 1 << 20);
    expect(make(endpoint: bar2).barBytes, 1 << 20);
    expect(make(endpoint: bar2, barBytes: 1 << 20).barBytes, 1 << 20);
    expect(make(endpoint: bar2).definitionName, contains('_S100000_'));
    expect(() => make(endpoint: bar2, barBytes: 16 << 20), throwsArgumentError);
    expect(
      () => make(endpoint: const HarborPcieEndpointConfig()),
      throwsArgumentError,
      reason: 'no BAR2',
    );
    expect(make(barBytes: 1 << 16).barBytes, 1 << 16);
    // The BAR2 hit bit comes from the endpoint too.
    expect(make(endpoint: bar2).barHitBit, 4);
    expect(
      () => HarborPcieMemoryCompleter(
        clk: Logic(),
        reset: Logic(),
        maxPayload: Logic(width: 3),
        rcb128: Logic(),
        completerId: Logic(width: 16),
        rx: HarborPcieStream(width: 64),
        tx: HarborPcieStream(width: 64),
        endpointConfig: bar2,
        barHitBit: 2,
      ),
      throwsArgumentError,
    );
    expect(make().barBytes, 16 << 20);
  });

  test('definition names differ per parameter set', () async {
    String nameOf(CompleterConfig c) => HarborPcieMemoryCompleter(
      clk: Logic(),
      reset: Logic(),
      maxPayload: Logic(width: 3),
      rcb128: Logic(),
      completerId: Logic(width: 16),
      rx: HarborPcieStream(width: c.width),
      tx: HarborPcieStream(width: c.width),
      fabricKind: c.kind,
      dataWidth: c.dataWidth,
      memoryOffset: c.memoryOffset,
      maxPayloadBytes: c.maxPayloadBytes,
    ).definitionName;
    final names = {
      nameOf(const CompleterConfig()),
      nameOf(const CompleterConfig(width: 128)),
      nameOf(const CompleterConfig(dataWidth: 32)),
      nameOf(const CompleterConfig(kind: HarborFabricKind.wishbone)),
      nameOf(const CompleterConfig(memoryOffset: 0)),
      nameOf(const CompleterConfig(maxPayloadBytes: 512)),
    };
    expect(names, hasLength(6));
  });

  test('rejects bad parameters', () {
    HarborPcieMemoryCompleter make({
      int dataWidth = 64,
      int barBytes = 4096,
      int memoryOffset = 0,
      int maxPayloadBytes = 256,
    }) => HarborPcieMemoryCompleter(
      clk: Logic(),
      reset: Logic(),
      maxPayload: Logic(width: 3),
      rcb128: Logic(),
      completerId: Logic(width: 16),
      rx: HarborPcieStream(width: 64),
      tx: HarborPcieStream(width: 64),
      dataWidth: dataWidth,
      addressWidth: 16,
      barBytes: barBytes,
      memoryOffset: memoryOffset,
      maxPayloadBytes: maxPayloadBytes,
    );
    expect(() => make(dataWidth: 16), throwsArgumentError);
    expect(() => make(barBytes: 2048), throwsArgumentError);
    expect(() => make(memoryOffset: 2), throwsArgumentError);
    expect(() => make(memoryOffset: 0xf004), throwsArgumentError);
    expect(() => make(maxPayloadBytes: 64), throwsArgumentError);
  });

  test('writes with every first and last byte enable, 1 to 64 DW', () async {
    const config = CompleterConfig(width: 64, dataWidth: 32);
    final bench = await CompleterBench.create(config, seed: 3);
    await bench.start();
    final r = Random(3);
    final touched = <int>{};
    var address = 0xc0000000;
    Future<void> send(int len, int firstBe, int lastBe) async {
      if ((address & 0xfff) + len * 4 > 0x1000) {
        address = (address & ~0xfff) + 0x1000;
      }
      final tlp = PcieTlp.memWrite(
        address: address,
        data: randomBytes(r, len * 4),
        firstBe: firstBe,
        lastBe: lastBe,
      );
      touched.addAll(bench.span(address, len * 4));
      await bench.write(tlp);
      address += len * 4 + 4 * r.nextInt(3);
    }

    for (var first = 0; first < 16; first++) {
      await send(1, first, 0);
    }
    for (final len in [2, 3]) {
      for (var first = 1; first < 16; first++) {
        for (var last = 1; last < 16; last++) {
          await send(len, first, last);
        }
      }
    }
    for (var len = 1; len <= 64; len++) {
      await send(len, randomBe(r), len > 1 ? randomBe(r) : 0);
    }
    final flush = PcieTlp.memRead(address: 0xc0000000, lengthDw: 1);
    final want = await bench.read(flush);
    await bench.checkReads([(flush, want)], rcb: 64, maxPayload: 256);
    bench.checkMemory(touched);
    expect(bench.writeErrors, 0);
    await bench.finish();
  });

  for (final (mpsCode, rcb128) in [
    (0, false),
    (0, true),
    (1, false),
    (1, true),
  ]) {
    test('reads split by max payload ${128 << mpsCode} and RCB '
        '${rcb128 ? 128 : 64}', () async {
      const config = CompleterConfig(width: 64, dataWidth: 64);
      final bench = await CompleterBench.create(config, seed: 5 + mpsCode);
      bench.maxPayload.inject(mpsCode);
      bench.rcb128.inject(rcb128 ? 1 : 0);
      await bench.start();
      final r = Random(11 + mpsCode * 2 + (rcb128 ? 1 : 0));
      final reads = <(PcieTlp, Uint8List)>[];
      Future<void> read(int address, int len, int firstBe, int lastBe) async {
        final tlp = PcieTlp.memRead(
          address: address,
          lengthDw: len,
          requesterId: kRequesterId,
          tag: reads.length,
          firstBe: firstBe,
          lastBe: lastBe,
        );
        reads.add((tlp, await bench.read(tlp)));
      }

      // Zero length, a full 4 KB page, and reads that end at a page end.
      await read(0xc0001010, 1, 0, 0);
      await read(0xc0002000, 1024, 0xf, 0xf);
      await read(0xc0003f00, 64, 0xe, 0x7);
      await read(0xc0004ffc, 1, 0x6, 0);
      for (var i = 0; i < 30; i++) {
        final (address, len) = placeRequest(r, 0xc0000000, 256);
        await read(
          address,
          len,
          len == 1 ? r.nextInt(16) : randomBe(r),
          len > 1 ? randomBe(r) : 0,
        );
      }
      await bench.checkReads(
        reads,
        rcb: rcb128 ? 128 : 64,
        maxPayload: 128 << mpsCode,
      );
      await bench.finish();
    });
  }

  test('a fabric read error gives a CA completion', () async {
    const config = CompleterConfig(width: 64, dataWidth: 64);
    final bench = await CompleterBench.create(config, seed: 21);
    await bench.start();
    bench.memory.errorBeats.add(bench.fabric(0xc0000140));
    final reads = <(PcieTlp, Uint8List)>[];
    for (final (address, len) in [
      (0xc0000100, 128),
      (0xc0000140, 1),
      (0xc0000200, 16),
    ]) {
      final tlp = PcieTlp.memRead(
        address: address,
        lengthDw: len,
        tag: reads.length,
      );
      reads.add((tlp, await bench.read(tlp)));
    }
    await bench.checkReads(reads, rcb: 64, maxPayload: 256, aborted: {0, 1});
    // The first read sends the chunk before the error, then CA.
    final firstCa = bench.sink.received.indexWhere(
      (c) => c.status == PcieCplStatus.abort,
    );
    expect(firstCa, 1);
    expect(bench.sink.received[1].byteCount, 512 - 0x40);
    expect(bench.sink.received[1].lowerAddress, 0x40);
    await bench.finish();
  });

  test('write errors and poisoned writes are dropped and counted', () async {
    const config = CompleterConfig(width: 64, dataWidth: 32);
    final bench = await CompleterBench.create(config, seed: 23);
    await bench.start();
    bench.memory.errorBeats.add(bench.fabric(0xc0000208));
    final r = Random(23);
    final poisoned = PcieTlp.memWrite(
      address: 0xc0000100,
      data: randomBytes(r, 16),
      poisoned: true,
    );
    await bench.driver.send(poisoned, user: HarborPcieStream.userBar2);
    final failing = PcieTlp.memWrite(
      address: 0xc0000200,
      data: randomBytes(r, 32),
    );
    await bench.driver.send(failing, user: HarborPcieStream.userBar2);
    final good = PcieTlp.memWrite(
      address: 0xc0000300,
      data: randomBytes(r, 32),
    );
    await bench.write(good);
    final flush = PcieTlp.memRead(address: 0xc0000100, lengthDw: 4);
    final want = await bench.read(flush);
    await bench.checkReads([(flush, want)], rcb: 64, maxPayload: 256);
    expect(bench.writeErrors, 2);
    bench.checkMemory([
      for (var i = 0; i < 16; i++) bench.fabric(0xc0000100 + i),
    ]);
    bench.checkMemory([
      for (var i = 0; i < 32; i++) bench.fabric(0xc0000300 + i),
    ]);
    await bench.finish();
  });

  for (final width in [64, 128]) {
    test('a non-posted request that is not a read gets UR, W$width', () async {
      final bench = await CompleterBench.create(
        CompleterConfig(width: width),
        seed: 25,
      );
      await bench.start();
      // An IO read with tag 0x1a, then a memory read behind it.
      await bench.sendRaw([0x02502001, 0x00101a0f, 0x00000010]);
      final tlp = PcieTlp.memRead(address: 0xc0000010, lengthDw: 2, tag: 3);
      final want = await bench.read(tlp);
      await bench.sink.waitFor(2);
      final ur = bench.sink.received.first;
      expect(ur.kind, PcieTlpKind.cpl);
      expect(ur.status, PcieCplStatus.unsupported);
      expect(ur.tag, 0x1a);
      expect(ur.tc, 5);
      expect(ur.attr, 2);
      expect(ur.requesterId, 0x0010);
      expect(ur.completerId, kCompleterId);
      bench.sink.received.removeAt(0);
      await bench.checkReads([(tlp, want)], rcb: 64, maxPayload: 256);
      await bench.finish();
    });
  }

  test('completions echo the request TC and attr', () async {
    const config = CompleterConfig(width: 64, dataWidth: 64);
    final bench = await CompleterBench.create(config, seed: 33);
    await bench.start();
    final reads = <(PcieTlp, Uint8List)>[];
    for (final (i, (tc, attr, len)) in [
      (1, 1, 4),
      (7, 3, 100),
      (3, 2, 1),
      (6, 0, 70),
    ].indexed) {
      final tlp = PcieTlp.memRead(
        address: 0xc0000100 + i * 0x400,
        lengthDw: len,
        tag: i,
        tc: tc,
        attr: attr,
      );
      reads.add((tlp, await bench.read(tlp)));
    }
    await bench.checkReads(reads, rcb: 64, maxPayload: 256);
    expect(bench.sink.received.every((c) => c.tc != 0 || c.attr != 0), isTrue);
    await bench.finish();
  });

  test('read after write sees the write', () async {
    const config = CompleterConfig(width: 64, dataWidth: 64);
    final bench = await CompleterBench.create(config, seed: 27);
    await bench.start();
    final r = Random(27);
    final reads = <(PcieTlp, Uint8List)>[];
    for (var i = 0; i < 20; i++) {
      final (address, len) = placeRequest(r, 0xc0000000, 64);
      await bench.write(
        PcieTlp.memWrite(
          address: address,
          data: randomBytes(r, len * 4),
          firstBe: randomBe(r),
          lastBe: len > 1 ? randomBe(r) : 0,
        ),
      );
      final tlp = PcieTlp.memRead(address: address, lengthDw: len, tag: i);
      reads.add((tlp, await bench.read(tlp)));
    }
    await bench.checkReads(reads, rcb: 64, maxPayload: 256);
    await bench.finish();
  });

  test('bursts across a fabric 4 KB boundary and the 256 beat limit', () async {
    // Fabric page ends are at host offsets 0x7f0, 0x17f0 and 0x27f0.
    const config = CompleterConfig(
      width: 64,
      dataWidth: 32,
      memoryOffset: 0x4810,
      maxPayloadBytes: 2048,
    );
    final bench = await CompleterBench.create(config, seed: 29);
    bench.maxPayload.inject(4);
    await bench.start();
    final r = Random(29);
    final touched = <int>{};
    final reads = <(PcieTlp, Uint8List)>[];
    for (final (address, bytes) in [
      (0xc0000600, 512),
      (0xc0001000, 2048),
      (0xc0002600, 512),
    ]) {
      final tlp = PcieTlp.memWrite(
        address: address,
        data: randomBytes(r, bytes),
        firstBe: 0xe,
        lastBe: 0x3,
      );
      touched.addAll(bench.span(address, bytes));
      await bench.write(tlp);
    }
    for (final (address, len) in [(0xc0000700, 64), (0xc0001000, 1024)]) {
      final tlp = PcieTlp.memRead(
        address: address,
        lengthDw: len,
        tag: reads.length,
      );
      reads.add((tlp, await bench.read(tlp)));
    }
    await bench.checkReads(reads, rcb: 64, maxPayload: 2048);
    bench.checkMemory(touched);
    await bench.finish();
  });
}

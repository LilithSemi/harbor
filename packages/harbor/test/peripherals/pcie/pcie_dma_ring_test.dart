import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_dma_bench.dart';
import '../../util/pcie_host_model.dart';

const _ring = 0x88000000;

const _ringOnly = DmaConfig(fifoSource: false, ringSource: true);

/// STATUS of an idle ring source engine with an empty 64 entry queue.
const _ringIdle = HarborPcieDma.statusRingSource | 64 << 16;

Future<int> _status(DmaBench b) => b.readReg(HarborPcieDma.registerStatus);

/// Checks the descriptor reads: each one is in the ring, does not pass its
/// end, reads at most [maxCount] descriptors, and the reads take the slots
/// in order from [firstSlot].
void _checkFetches(
  DmaBench b,
  List<PcieTlp> fetches, {
  required int firstSlot,
  required int count,
  int maxCount = 4,
}) {
  final size = 1 << b.descLog2;
  var slot = firstSlot;
  var total = 0;
  for (final t in fetches) {
    expect(t.address, b.descBase + 32 * slot, reason: '$t');
    expect(t.lengthDw % 8, 0);
    final n = t.lengthDw ~/ 8;
    expect(n, inInclusiveRange(1, maxCount), reason: '$t');
    expect(slot + n, lessThanOrEqualTo(size), reason: '$t passes the end');
    expect(t.requesterId, dmaCompleterId);
    expect(t.firstBe, 0xf);
    expect(t.lastBe, 0xf);
    slot = (slot + n) % size;
    total += n;
  }
  expect(total, count);
}

void main() {
  tearDown(() async => Simulator.reset());

  test('random mix through the ring', () async {
    await _ringMix(
      const DmaConfig(fifoSource: false, ringSource: true, queueDepth: 8),
      150,
    );
  }, timeout: const Timeout(Duration(hours: 1)));

  for (final config in [
    _ringOnly,
    const DmaConfig(
      width: 128,
      dataWidth: 128,
      fifoSource: false,
      ringSource: true,
    ),
    const DmaConfig(
      width: 128,
      kind: HarborFabricKind.wishbone,
      fifoSource: false,
      ringSource: true,
    ),
  ]) {
    test('ring source alone, $config', () async {
      final b = await DmaBench.create(
        config,
        seed: config.width + config.dataWidth + 11,
      );
      final jobs = [
        (0x80000000, 0x01000, 64, true),
        (0x80001000, 0x02000, 0x180, false),
        (0x180004104, 0x0500c, 1000, true),
        (0x80003f40, 0x04008, 0x180, false),
        (0x80008000, 0x08000, 0x400, true),
        (0x80009004, 0x0a008, 0x204, false),
      ];
      for (final (h, _, len, d2h) in jobs) {
        if (!d2h) b.seedHost(h, len);
      }
      await b.start();
      expect(await b.readReg(HarborPcieDma.registerCaps) & 3, 2);

      // Only the ring is built: no select bit, no push registers.
      await b.writeReg(HarborPcieDma.registerControl, 0x5);
      expect(await b.readReg(HarborPcieDma.registerControl), 1);
      await b.writeReg(HarborPcieDma.registerControl, 0);
      await b.push(hostAddress: 0x80000000, localAddress: 0, length: 4);
      expect(await b.readReg(HarborPcieDma.registerPush), 0);
      expect(
        await b.readReg(HarborPcieDma.registerStatus),
        HarborPcieDma.statusRingSource | config.queueDepth << 16,
      );

      // Bits 4:0 of the ring base read 0.
      await b.writeReg(HarborPcieDma.registerDescBaseLow, _ring | 0x1f);
      expect(await b.readReg(HarborPcieDma.registerDescBaseLow), _ring);
      await b.setupDescRing(_ring, 4);
      expect(await b.readRegs(HarborPcieDma.registerDescBaseLow, 5), [
        _ring,
        0,
        4,
        0,
        0,
      ]);
      await b.setupRing(dmaCplBase, 4);
      for (final (i, (h, l, len, d2h)) in jobs.indexed) {
        b.writeDesc(
          i,
          hostAddress: h,
          localAddress: l,
          length: len,
          deviceToHost: d2h,
          cookie: 0xa00 + i,
        );
      }
      await b.enable();
      await b.doorbell(jobs.length);
      await b.waitRecordWrites(jobs.length - 1, 1);
      expect(b.host.violations, isEmpty);
      for (final (i, (h, l, len, d2h)) in jobs.indexed) {
        if (d2h) {
          b.checkCopy(h, l, len);
        } else {
          b.checkLocal(h, l, len);
        }
        final r = b.record(i);
        expect(r.cookie, 0xa00 + i);
        expect(r.code, 0);
        expect(r.bytes, len);
      }
      expect(b.fetches.map((t) => t.lengthDw), [32, 16]);
      _checkFetches(b, b.fetches, firstSlot: 0, count: jobs.length);
      final fetchTags = b.fetches.map((t) => t.tag).toSet();
      final readTags = b.reads.where((t) => !b.isFetch(t)).map((t) => t.tag);
      expect(fetchTags, hasLength(1));
      expect(readTags.toSet().intersection(fetchTags), isEmpty);
      expect(await b.readReg(HarborPcieDma.registerDescHead), jobs.length);
      expect(await b.readReg(HarborPcieDma.registerDescTail), jobs.length);
      expect(await b.readReg(HarborPcieDma.registerStaleCompletions), 0);
      expect(await b.readReg(HarborPcieDma.registerStatus) & 3, 0);
      await b.finish();
    });
  }

  for (final config in [
    const DmaConfig(fifoSource: false, ringSource: true, queueDepth: 4),
    const DmaConfig(
      width: 128,
      dataWidth: 128,
      fifoSource: false,
      ringSource: true,
      queueDepth: 2,
    ),
  ]) {
    test('fetches wrap and stop at the ring end and the page end, '
        'W${config.width} Q${config.queueDepth}', () async {
      final b = await DmaBench.create(config, seed: 5 + config.width);
      // Slots 0 to 3 are in one 4 KB page, slots 4 to 7 in the next.
      const base = _ring + 0xf80;
      await b.start();
      await b.setupDescRing(base, 3);
      await b.setupRing(dmaCplBase, 4);
      await b.enable();
      final maxCount = min(4, config.queueDepth);
      var cookie = 0;
      Future<void> round(List<int> slots) async {
        final start = cookie;
        final before = b.fetches.length;
        for (final s in slots) {
          b.writeDesc(
            s,
            hostAddress: 0x80000000 + 0x100 * cookie,
            localAddress: 0x100 * cookie,
            length: 16,
            cookie: 0x300 + cookie,
          );
          cookie++;
        }
        await b.doorbell((slots.last + 1) % 8);
        await b.waitRecordWrites(cookie - 1, 1);
        for (var i = start; i < cookie; i++) {
          expect(b.record(i).cookie, 0x300 + i);
          expect(b.record(i).code, 0);
          b.checkCopy(0x80000000 + 0x100 * i, 0x100 * i, 16);
        }
        final fetches = b.fetches.skip(before).toList();
        _checkFetches(
          b,
          fetches,
          firstSlot: slots.first,
          count: slots.length,
          maxCount: maxCount,
        );
        for (final t in fetches) {
          final page = t.address >> 12;
          expect((t.address + 4 * t.lengthDw - 1) >> 12, page);
        }
        expect(
          await b.readReg(HarborPcieDma.registerDescHead),
          (slots.last + 1) % 8,
        );
      }

      await round([0, 1, 2, 3, 4, 5]);
      // The queue was empty, so the first read stops at the page end.
      expect(b.fetches.first.lengthDw, 8 * maxCount);
      final before = b.fetches.length;
      await round([6, 7, 0, 1, 2]);
      // The first read of the second round stops at the ring end.
      expect(b.fetches[before].address, base + 32 * 6);
      expect(b.fetches[before].lengthDw, 16);
      expect(b.host.violations, isEmpty);
      await b.finish();
    });
  }

  for (final width in [64, 128]) {
    test('a doorbell while a fetch is in flight, W$width', () async {
      final b = await DmaBench.create(
        DmaConfig(
          width: width,
          dataWidth: width,
          fifoSource: false,
          ringSource: true,
        ),
        seed: 17 + width,
      );
      await b.start();
      await b.setupDescRing(_ring, 4);
      await b.setupRing(dmaCplBase, 4);
      await b.enable();
      for (var i = 0; i < 5; i++) {
        b.writeDesc(
          i,
          hostAddress: 0x80000000 + 0x200 * i,
          localAddress: 0x200 * i,
          length: 0x40,
          cookie: 0x40 + i,
        );
      }
      b.holdCompletions = true;
      await b.doorbell(2);
      await b.waitUntil(() => b.fetches.isNotEmpty, what: 'first fetch');
      await b.doorbell(5);
      await b.cycles(200);
      expect(b.fetches, hasLength(1));
      expect(b.sink.received.where((t) => t.kind.hasData), isEmpty);
      b.holdCompletions = false;
      await b.waitRecordWrites(4, 1);
      expect(b.fetches.map((t) => t.lengthDw), [16, 24]);
      _checkFetches(b, b.fetches, firstSlot: 0, count: 5);
      for (var i = 0; i < 5; i++) {
        expect(b.record(i).cookie, 0x40 + i);
        b.checkCopy(0x80000000 + 0x200 * i, 0x200 * i, 0x40);
      }
      expect(await b.readReg(HarborPcieDma.registerDescHead), 5);
      expect(b.host.violations, isEmpty);
      await b.finish();
    });
  }

  test('both sources built, select and switch at idle', () async {
    final b = await DmaBench.create(
      const DmaConfig(ringSource: true),
      seed: 33,
    );
    await b.start();
    expect(await b.readReg(HarborPcieDma.registerCaps) & 3, 3);
    expect(await b.readReg(HarborPcieDma.registerControl), 0);
    await b.setupDescRing(_ring, 4);
    await b.setupRing(dmaCplBase, 4);
    await b.enable();
    var records = 0;
    Future<void> expectRecord(int cookie) async {
      await b.waitRecordWrites(records, 1);
      expect(b.record(records).cookie, cookie);
      expect(b.record(records).code, 0);
      records++;
    }

    // The FIFO is the source after reset.
    await b.push(
      hostAddress: 0x80000000,
      localAddress: 0,
      length: 8,
      cookie: 1,
    );
    await expectRecord(1);
    for (var i = 0; i < 2; i++) {
      b.writeDesc(
        i,
        hostAddress: 0x80000100 * (i + 1),
        localAddress: 0x100 * (i + 1),
        length: 8,
        cookie: 2 + i,
      );
    }
    await b.doorbell(1);
    await b.cycles(300);
    expect(b.fetches, isEmpty);
    expect(await _status(b) & HarborPcieDma.statusRingSource, 0);

    // Ring source.
    await b.writeReg(
      HarborPcieDma.registerControl,
      HarborPcieDma.controlEnable | HarborPcieDma.controlRingSource,
    );
    expect(await b.readReg(HarborPcieDma.registerControl), 5);
    await expectRecord(2);
    expect(b.fetches, hasLength(1));
    expect(await _status(b) & HarborPcieDma.statusRingSource, isNonZero);

    // A commit while the ring is the source is lost and sets overflow.
    await b.push(
      hostAddress: 0x80000400,
      localAddress: 0x400,
      length: 8,
      cookie: 9,
    );
    await b.cycles(200);
    expect(b.recordWrites(records), isEmpty);
    expect(
      await b.readReg(HarborPcieDma.registerStatus),
      HarborPcieDma.statusOverflow | _ringIdle,
    );

    // A switch with a fetch in flight waits until the engine is idle.
    b.holdCompletions = true;
    for (var i = 1; i < 4; i++) {
      b.writeDesc(
        i,
        hostAddress: 0x80001000 + 0x100 * i,
        localAddress: 0x1000 + 0x100 * i,
        length: 8,
        cookie: 0x10 + i,
      );
    }
    await b.doorbell(3);
    await b.waitUntil(() => b.fetches.length == 2, what: 'second fetch');
    await b.writeReg(
      HarborPcieDma.registerControl,
      HarborPcieDma.controlEnable,
    );
    expect(await b.readReg(HarborPcieDma.registerControl), 1);
    expect(await _status(b) & HarborPcieDma.statusRingSource, isNonZero);
    await b.doorbell(4);
    b.holdCompletions = false;
    await expectRecord(0x11);
    await expectRecord(0x12);
    await b.cycles(300);
    expect(b.fetches, hasLength(2));
    expect(b.recordWrites(records), isEmpty);
    expect(await b.readReg(HarborPcieDma.registerDescHead), 3);
    expect(await _status(b) & HarborPcieDma.statusRingSource, 0);
    await b.push(
      hostAddress: 0x80000500,
      localAddress: 0x500,
      length: 8,
      cookie: 7,
    );
    await expectRecord(7);
    b.checkCopy(0x80000500, 0x500, 8);
    expect(b.host.violations, isEmpty);
    await b.finish();
  });

  for (final width in [64, 128]) {
    test('fetch errors halt with their code, W$width', () async {
      await _fetchErrors(width);
    });
  }

  test('ring pointer writes wait for a pending engine reset', () async {
    final b = await DmaBench.create(_ringOnly, seed: 61);
    await b.start();
    await b.setupDescRing(_ring, 4);
    await b.setupRing(dmaCplBase, 4);
    await b.enable();
    b.writeDesc(0, hostAddress: 0x80000000, localAddress: 0, length: 0x400);
    await b.doorbell(1);
    await b.waitUntil(
      () => b.sink.received.any((t) => t.kind.hasData),
      what: 'first data write',
    );
    // With TX stopped the engine holds the port in a data write, where an
    // engine reset waits.
    b.sink.stop();
    await b.waitUntil(
      () => b.sink.stream.valid.value.toBool(),
      what: 'data write on the stopped port',
    );
    await b.engineReset();
    await b.doorbell(5);
    await b.writeReg(HarborPcieDma.registerCplHead, 3);
    final pending = b.readRaw(HarborPcieDma.registerControl, 1);
    await b.cycles(50);
    b.sink.start();
    final c = await pending;
    expect(c.data.sublist(0, 4), [3, 0, 0, 0], reason: 'reset pending');
    var control = 3;
    for (var i = 0; i < 50 && control != 1; i++) {
      control = await b.readReg(HarborPcieDma.registerControl);
    }
    expect(control, 1);
    expect(await b.readRegs(HarborPcieDma.registerDescTail, 2), [0, 0]);
    expect(await b.readReg(HarborPcieDma.registerCplHead), 0);
    expect(await _status(b), _ringIdle);
    b.writeDesc(
      0,
      hostAddress: 0x80001000,
      localAddress: 0x100,
      length: 0x20,
      cookie: 0x22,
    );
    await b.doorbell(1);
    await b.waitRecordWrites(0, 1);
    expect(b.record(0).cookie, 0x22);
    b.checkCopy(0x80001000, 0x100, 0x20);
    await b.finish();
  });

  test('a 1 slot ring gives code 10', () async {
    final b = await DmaBench.create(_ringOnly, seed: 62);
    await b.start();
    await b.setupDescRing(_ring, 0);
    await b.setupRing(dmaCplBase, 4);
    await b.enable(mask: HarborPcieDma.causeError);
    await b.cycles(50);
    expect(b.recordWrites(0), isEmpty);
    await b.doorbell(0);
    await b.waitRecordWrites(0, 1);
    expect(b.record(0).code, HarborPcieDma.errorDescRing);
    expect(b.record(0).cookie, 0);
    expect(b.fetches, isEmpty);
    expect(await _status(b) >> 8 & 0xff, HarborPcieDma.errorDescRing);
    expect(b.irqPending, 1);
    await b.finish();
  });

  test('a descriptor ring past 2^64 gives code 10 and no fetch', () async {
    final b = await DmaBench.create(_ringOnly, seed: 64);
    await b.start();
    await b.setupDescRing(0xffffffffffffff00, 4);
    await b.setupRing(dmaCplBase, 4);
    await b.enable(mask: HarborPcieDma.causeError);
    await b.cycles(50);
    expect(b.recordWrites(0), isEmpty);
    await b.doorbell(1);
    await b.waitRecordWrites(0, 1);
    expect(b.record(0).code, HarborPcieDma.errorDescRing);
    expect(b.record(0).cookie, 0);
    expect(b.fetches, isEmpty);
    expect(b.reads, isEmpty);
    expect(b.record(0).src, 0x80000000, reason: 'the head slot');
    expect(await _status(b) >> 8 & 0xff, HarborPcieDma.errorDescRing);
    expect(b.irqPending, 1);
    await b.finish();
  });

  test('a bad third descriptor in a batch reports its slot', () async {
    final b = await DmaBench.create(_ringOnly, seed: 65);
    await b.start();
    await b.setupDescRing(_ring, 4);
    await b.setupRing(dmaCplBase, 4);
    await b.enable(mask: HarborPcieDma.causeError);
    for (var i = 0; i < 4; i++) {
      b.writeDesc(
        i,
        hostAddress: 0x80001000 + 0x100 * i,
        localAddress: 0x100 * i + (i == 2 ? 2 : 0),
        length: 0x40,
        cookie: 0x70 + i,
      );
    }
    await b.doorbell(4);
    await b.waitRecordWrites(2, 1);
    await b.cycles(200);
    final records = [for (var i = 0; i < 3; i++) b.record(i)];
    expect([for (final r in records) r.code], [0, 0, 7]);
    expect([for (final r in records) r.cookie], [0x70, 0x71, 0x72]);
    expect(
      [for (final r in records) r.src],
      [0x80000000, 0x80000001, 0x80000002],
    );
    // The fourth descriptor does not run.
    expect(b.recordWrites(3), isEmpty);
    expect(b.host.memory.read(0x80001300, 0x40), everyElement(0));
    final status = await _status(b);
    expect(status & HarborPcieDma.statusHalted, HarborPcieDma.statusHalted);
    expect(status >> 8 & 0xff, HarborPcieDma.errorAlignment);
    expect(await b.readReg(HarborPcieDma.registerDescHead), 2);
    await b.finish();
  });

  test('rings and host ranges that end at 2^64 are accepted', () async {
    final b = await DmaBench.create(_ringOnly, seed: 66);
    await b.start();
    // 16 descriptors and 16 records end exactly at 2^64.
    await b.setupDescRing(0xfffffffffffffe00, 4);
    await b.setupRing(0xffffffffffffff00, 4);
    await b.enable(mask: HarborPcieDma.causeError);
    b.writeDesc(
      0,
      hostAddress: 0x80001000,
      localAddress: 0x1000,
      length: 0x100,
      cookie: 1,
    );
    await b.doorbell(1);
    await b.waitRecordWrites(0, 1);
    expect(b.record(0).code, 0);
    expect(b.record(0).cookie, 1);
    expect(b.fetches, isNotEmpty);
    b.checkCopy(0x80001000, 0x1000, 0x100);

    // Then host ranges that end at 2^64, with the rings back in low memory.
    await b.engineReset();
    await b.cycles(20);
    await b.setupDescRing(_ring, 4);
    await b.setupRing(dmaCplBase, 4);
    b.seedHost(0xffffffffffffe000, 0x1000);
    b.writeDesc(
      0,
      hostAddress: 0xfffffffffffff000,
      localAddress: 0x2000,
      length: 0x1000,
      cookie: 2,
    );
    b.writeDesc(
      1,
      hostAddress: 0xffffffffffffe000,
      localAddress: 0x4000,
      length: 0x1000,
      deviceToHost: false,
      cookie: 3,
    );
    await b.doorbell(2);
    await b.waitRecordWrites(1, 1);
    expect([b.record(0).code, b.record(1).code], [0, 0]);
    expect([b.record(0).cookie, b.record(1).cookie], [2, 3]);
    b.checkCopy(0xfffffffffffff000, 0x2000, 0x1000);
    b.checkLocal(0xffffffffffffe000, 0x4000, 0x1000);
    expect(b.host.violations, isEmpty);
    await b.finish();
  });

  test('code 11 does not hide a waiting fetch error', () async {
    final b = await DmaBench.create(_ringOnly, seed: 67);
    await b.start();
    await b.setupDescRing(_ring, 4);
    await b.setupRing(dmaCplBase, 0);
    await b.enable(mask: HarborPcieDma.causeError);
    // A tail outside the ring: fetch error 10, and no record can go out.
    await b.doorbell(16);
    await b.waitUntil(() => b.irqPending & 1 == 1, what: 'error cause');
    final status = await _status(b);
    expect(status & HarborPcieDma.statusHalted, HarborPcieDma.statusHalted);
    expect(status >> 8 & 0xff, HarborPcieDma.errorDescRing);
    expect(
      b.sink.received.where((t) => t.kind.hasData && t.kind.isRequest),
      isEmpty,
    );
    await b.finish();
  });

  test('no fetch read goes out without bus master enable', () async {
    final b = await DmaBench.create(_ringOnly, seed: 63);
    await b.start();
    await b.setupDescRing(_ring, 4);
    await b.setupRing(dmaCplBase, 4);
    await b.enable();
    b.writeDesc(0, hostAddress: 0x80000000, localAddress: 0, length: 0x400);
    b.writeDesc(1, hostAddress: 0x80001000, localAddress: 0x1000, length: 16);
    await b.doorbell(1);
    await b.waitUntil(
      () => b.sink.received.any((t) => t.kind.hasData),
      what: 'first data write',
    );
    // The engine holds the stopped TX port. The fetch for slot 1 starts
    // and waits for the port, then bus master enable goes low.
    b.sink.stop();
    await b.waitUntil(
      () => b.sink.stream.valid.value.toBool(),
      what: 'data write on the stopped port',
    );
    await b.doorbell(2);
    await b.cycles(20);
    b.busMaster.inject(0);
    final before = b.sink.received.where((t) => t.kind.isRequest).length;
    b.sink.start();
    await b.cycles(300);
    // Only the write that held the port finishes.
    final after = b.sink.received.where((t) => t.kind.isRequest).toList();
    expect(after.length, before + 1);
    expect(after.last.kind.hasData, isTrue);
    expect(b.fetches, hasLength(1));
    b.busMaster.inject(1);
    await b.waitRecordWrites(1, 1);
    b.checkCopy(0x80000000, 0, 0x400);
    b.checkCopy(0x80001000, 0x1000, 16);
    expect(b.fetches, hasLength(2));
    await b.finish();
  });

  test('two aborts during one fetch do not bring its tag back', () async {
    final b = await DmaBench.create(
      const DmaConfig(
        fifoSource: false,
        ringSource: true,
        readTags: 15,
        timeoutCycles: 3000,
      ),
      seed: 71,
    );
    b.seedHost(0x80000000, 0x40);
    PcieTlp? heldRead;
    PcieTlp? late;
    var dropFetch = false;
    b.sink.onTlp = (t) {
      final isRead =
          t.kind == PcieTlpKind.memRead32 || t.kind == PcieTlpKind.memRead64;
      if (isRead && !b.isFetch(t)) {
        heldRead = t;
        return;
      }
      if (b.isFetch(t) && dropFetch) {
        dropFetch = false;
        late = PcieTlp.completion(
          completerId: 0x55,
          requesterId: t.requesterId,
          tag: t.tag,
          byteCount: t.lengthDw * 4,
          lowerAddress: t.address & 0x7f,
          data: b.host.memory.read(t.address, t.lengthDw * 4),
        );
        return;
      }
      b.host.receive(t);
    };
    await b.start();
    await b.setupDescRing(_ring, 4);
    await b.setupRing(dmaCplBase, 4);
    await b.enable();
    b.writeDesc(
      0,
      hostAddress: 0x80000000,
      localAddress: 0x100,
      length: 0x40,
      deviceToHost: false,
      cookie: 1,
    );
    await b.doorbell(1);
    await b.waitUntil(() => heldRead != null, what: 'host read');
    b.writeDesc(
      1,
      hostAddress: 0x80002000,
      localAddress: 0x2000,
      length: 0x7c,
      cookie: 0xbad,
    );
    dropFetch = true;
    await b.doorbell(2);
    await b.waitUntil(() => late != null, what: 'second fetch');
    // An H2D error while the fetch is out is the first abort, the engine
    // reset is the second.
    b.injected.add(
      PcieTlp.completion(
        completerId: 0x55,
        requesterId: heldRead!.requesterId,
        tag: heldRead!.tag,
        status: PcieCplStatus.unsupported,
        byteCount: 0x40,
      ),
    );
    await b.waitRecordWrites(0, 1);
    expect(b.record(0).code, HarborPcieDma.errorCompletion);
    await b.engineReset();
    await b.cycles(5);
    expect(await _status(b), _ringIdle);

    b.writeDesc(
      0,
      hostAddress: 0x80001000,
      localAddress: 0x1000,
      length: 0x20,
      cookie: 0x55,
    );
    b.holdCompletions = true;
    await b.doorbell(1);
    await b.waitUntil(() => b.fetches.length == 3, what: 'new fetch');
    expect(b.fetches.last.tag, isNot(late!.tag));
    b.injected.add(late!);
    b.holdCompletions = false;
    await b.waitRecordWrites(0, 2);
    expect(b.record(0).cookie, 0x55);
    expect(b.record(0).code, 0);
    b.checkCopy(0x80001000, 0x1000, 0x20);
    expect(b.host.memory.read(0x80002000, 4), everyElement(0));
    expect(await b.readReg(HarborPcieDma.registerStaleCompletions), 1);
    await b.finish();
  });

  test('ring builds generate SystemVerilog', () async {
    for (final fifo in [false, true]) {
      final dma = HarborPcieDma(
        clk: Logic(),
        reset: Logic(),
        completerId: Logic(width: 16),
        maxPayload: Logic(width: 3),
        maxReadRequest: Logic(width: 3),
        rcb128: Logic(),
        busMasterEnable: Logic(),
        msiEnable: Logic(),
        msiVectorsGranted: Logic(width: 3),
        rx: HarborPcieStream(width: 128),
        tx: HarborPcieStream(width: 128),
        fifoSource: fifo,
        ringSource: true,
      );
      await dma.build();
      final sv = dma.generateSynth();
      expect(sv, contains('desc_head'));
      expect(sv, fifo ? contains('sel_active') : isNot(contains('push_0')));
      Simulator.reset();
    }
  });

  test('an engine reset with a fetch in flight moves the fetch tag', () async {
    final b = await DmaBench.create(_ringOnly, seed: 51);
    await b.start();
    await b.setupDescRing(_ring, 4);
    await b.setupRing(dmaCplBase, 4);
    await b.enable();
    b.writeDesc(
      0,
      hostAddress: 0x80000000,
      localAddress: 0x100,
      length: 0x20,
      cookie: 0x31,
    );
    b.holdCompletions = true;
    await b.doorbell(1);
    await b.waitUntil(() => b.fetches.isNotEmpty, what: 'fetch');
    await b.engineReset();
    await b.cycles(5);
    expect(await b.readRegs(HarborPcieDma.registerDescTail, 2), [0, 0]);
    b.holdCompletions = false;
    await b.waitUntil(
      () => !b.host.responder.hasPending,
      what: 'old completion',
    );
    await b.cycles(30);
    expect(await b.readReg(HarborPcieDma.registerStaleCompletions), 1);
    expect(await b.readReg(HarborPcieDma.registerDescHead), 0);
    expect(await b.readReg(HarborPcieDma.registerStatus), _ringIdle);
    expect(b.recordWrites(0), isEmpty);
    await b.doorbell(1);
    await b.waitRecordWrites(0, 1);
    expect(b.fetches, hasLength(2));
    expect(b.fetches[1].tag, isNot(b.fetches[0].tag));
    expect(b.record(0).cookie, 0x31);
    b.checkCopy(0x80000000, 0x100, 0x20);
    await b.finish();
  });
}

/// Runs [count] random descriptors through a 16 slot ring. The host adds
/// descriptors when the ring has room and compares both memories with a
/// model at the end.
Future<void> _ringMix(DmaConfig config, int count) async {
  final b = await DmaBench.create(config, seed: count + 3);
  final random = Random(count * 7 + 1);
  const hostBase = 0x80000000;
  const hostHigh = 0x240000000;
  const hostSpan = 0x10000;
  const localSpan = 0x40000;
  const size = 16;
  b.seedHost(hostBase, hostSpan);
  b.seedHost(hostHigh, hostSpan);
  final modelHost = <int, int>{};
  final modelLocal = <int, int>{};
  int hostByte(int a) => modelHost[a] ?? b.host.memory.read(a, 1)[0];
  int localByte(int a) => modelLocal[a] ?? dmaFill(a);

  final jobs = <(int, int, int, bool)>[];
  for (var i = 0; i < count; i++) {
    final roll = random.nextInt(10);
    // Length 0 is refused with code 9, so the mix has none.
    final len = roll == 0
        ? 4 * (1 + random.nextInt(512))
        : 4 * (1 + random.nextInt(96));
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

  await b.start();
  await b.setupDescRing(_ring, 4);
  await b.setupRing(dmaCplBase, 10);
  await b.enable();
  var tail = 0;
  while (tail < count) {
    final head = await b.readReg(HarborPcieDma.registerDescHead);
    final used = (tail - head) % size;
    final room = min(size - 1 - used, count - tail);
    if (room == 0) {
      await b.cycles(20);
      continue;
    }
    final add = 1 + random.nextInt(room);
    for (var k = 0; k < add; k++) {
      final (h, l, len, d2h) = jobs[tail];
      b.writeDesc(
        tail % size,
        hostAddress: h,
        localAddress: l,
        length: len,
        deviceToHost: d2h,
        cookie: tail,
      );
      tail++;
    }
    await b.doorbell(tail % size);
  }
  await b.waitRecordWrites(count - 1, 1);
  expect(b.host.violations, isEmpty);
  _checkFetches(b, b.fetches, firstSlot: 0, count: count);
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

Future<void> _fetchErrors(int width) async {
  final b = await DmaBench.create(
    DmaConfig(
      width: width,
      dataWidth: width,
      fifoSource: false,
      ringSource: true,
      timeoutCycles: 3000,
    ),
    seed: 44 + width,
  );
  String? mode;
  PcieTlp? dropped;
  b.sink.onTlp = (t) {
    if (!b.isFetch(t) || mode == null) {
      b.host.receive(t);
      return;
    }
    final bytes = b.host.memory.read(t.address, t.lengthDw * 4);
    PcieTlp cpl({
      PcieCplStatus status = PcieCplStatus.success,
      int? byteCount,
      bool poisoned = false,
      List<int>? data,
    }) => PcieTlp.completion(
      completerId: 0x55,
      requesterId: t.requesterId,
      tag: t.tag,
      status: status,
      byteCount: byteCount ?? t.lengthDw * 4,
      lowerAddress: t.address & 0x7f,
      data: data ?? (status == PcieCplStatus.success ? bytes : const []),
      poisoned: poisoned,
    );
    switch (mode) {
      case 'ur':
        b.injected.add(cpl(status: PcieCplStatus.unsupported));
      case 'ca':
        b.injected.add(cpl(status: PcieCplStatus.abort));
      case 'poisoned':
        b.injected.add(cpl(poisoned: true));
      case 'byte count':
        b.injected.add(cpl(byteCount: t.lengthDw * 4 + 4));
      case 'too long':
        b.injected.add(cpl(data: [...bytes, 1, 2, 3, 4]));
      case 'timeout':
        dropped = cpl();
    }
    mode = null;
  };
  await b.start();
  await b.setupDescRing(_ring, 4);
  await b.setupRing(dmaCplBase, 4);
  await b.enable(mask: HarborPcieDma.causeError);

  Future<void> expectHalt(int code, String name) async {
    final r = b.record(0);
    expect(r.code, code, reason: name);
    expect(r.cookie, 0, reason: name);
    expect(r.bytes, 0, reason: name);
    final status = await b.readReg(HarborPcieDma.registerStatus);
    expect(status & HarborPcieDma.statusHalted, isNonZero, reason: name);
    expect(status >> 8 & 0xff, code, reason: name);
    expect(b.irqPending, 1, reason: name);
    await b.writeReg(HarborPcieDma.registerIrqCause, HarborPcieDma.causeError);
    await b.engineReset();
    await b.cycles(2);
    expect(await b.readReg(HarborPcieDma.registerStatus), _ringIdle);
    expect(await b.readRegs(HarborPcieDma.registerDescTail, 2), [0, 0]);
  }

  final cases = [
    ('ur', HarborPcieDma.errorCompletion),
    ('ca', HarborPcieDma.errorCompletion),
    ('poisoned', HarborPcieDma.errorPoisoned),
    ('byte count', HarborPcieDma.errorLength),
    ('too long', HarborPcieDma.errorLength),
    ('timeout', HarborPcieDma.errorTimeout),
  ];
  var recordCount = 0;
  for (final (i, (name, code)) in cases.indexed) {
    for (var s = 0; s < 2; s++) {
      b.writeDesc(
        s,
        hostAddress: 0x80000000 + 0x100 * i + 0x40 * s,
        localAddress: 0x100 * i,
        length: 0x40,
        cookie: 0x70 + i,
      );
    }
    mode = name;
    await b.doorbell(2);
    recordCount++;
    await b.waitRecordWrites(0, recordCount);
    await b.cycles(100);
    expect(b.recordWrites(1), isEmpty, reason: 'halted, $name');
    expect(
      b.host.memory.read(0x80000000 + 0x100 * i, 0x80),
      everyElement(0),
      reason: name,
    );
    await expectHalt(code, name);
  }

  // A tail past the ring end.
  await b.doorbell(16);
  recordCount++;
  await b.waitRecordWrites(0, recordCount);
  expect(b.fetches, hasLength(cases.length));
  await expectHalt(HarborPcieDma.errorDescRing, 'tail');

  // The late answer to the read that timed out matches nothing.
  b.injected.add(dropped!);
  await b.waitUntil(() => b.injected.isEmpty, what: 'late send');
  await b.cycles(20);
  expect(await b.readReg(HarborPcieDma.registerStaleCompletions), 1);
  expect(await b.readReg(HarborPcieDma.registerStatus), _ringIdle);

  b.writeDesc(
    0,
    hostAddress: 0x80002000,
    localAddress: 0x2000,
    length: 0x40,
    cookie: 0x99,
  );
  await b.doorbell(1);
  recordCount++;
  await b.waitRecordWrites(0, recordCount);
  expect(b.record(0).code, 0);
  expect(b.record(0).cookie, 0x99);
  expect(b.fetches.last.tag, isNot(dropped!.tag));
  b.checkCopy(0x80002000, 0x2000, 0x40);
  await b.finish();
}

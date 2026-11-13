import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdio_adma_bench.dart';

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    for (final width in [32, 64]) {
      final tag = '${kind.name}, $width-bit';

      test('card read over a descriptor table ($tag)', () async {
        final b = AdmaBench(kind, width);
        await b.start();
        // An unaligned run across a 4 KB boundary, an odd tail, and an
        // unaligned odd run.
        const runs = [(0x0FE4, 40), (0x2000, 12), (0x3004, 12)];
        b.descriptors(0x100, runs);
        final before = {
          for (final a in [0x0FE0, 0x100C, 0x200C, 0x3000, 0x3010])
            a: b.read32(a),
        };
        final words = [
          for (var i = 0; i < 16; i++) 0x01020304 * (i + 1) ^ 0xA5000000,
        ];
        await b.wr(admaBlkSize, 64);
        await b.wr(admaAdmaAddr, 0x100);
        await b.wr(admaCmd, admaCmdRead | admaTable);
        await b.cardRead(words);

        var n = 0;
        for (final (addr, len) in runs) {
          for (var o = 0; o < len; o += 4) {
            expect(
              b.read32(addr + o),
              words[n],
              reason: 'word $n at 0x${(addr + o).toRadixString(16)}',
            );
            n++;
          }
        }
        before.forEach(
          (a, v) => expect(
            b.read32(a),
            v,
            reason: 'touched 0x${a.toRadixString(16)}',
          ),
        );
        b.checkShapes();
        expect(
          b.probe.writes.any((w) => w.len > 0),
          isTrue,
          reason: 'no burst',
        );
        expect(
          b.probe.doneAt,
          greaterThan(b.probe.lastResp),
          reason: 'data-done before the last write response',
        );
        final st = await b.rd(admaIntStatus);
        expect(st & (admaDataDone | admaAdmaErr), admaDataDone);
        expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
        await Simulator.endSimulation();
      });

      test('card write over a descriptor table ($tag)', () async {
        final b = AdmaBench(kind, width);
        await b.start();
        const runs = [(0x0FF8, 16), (0x2004, 8)];
        b.descriptors(0x180, runs);
        final words = [
          for (var i = 0; i < 6; i++) 0x11111111 * (i + 1) ^ 0x5A0000C3,
        ];
        var n = 0;
        for (final (addr, len) in runs) {
          for (var o = 0; o < len; o += 4) {
            b.write32(addr + o, words[n++]);
          }
        }
        await b.wr(admaBlkSize, 24);
        await b.wr(admaAdmaAddr, 0x180);
        await b.wr(admaCmd, admaCmdWrite | admaTable);
        final got = await b.cardWrite();
        final want = admaFourBitBlock(words);
        expect(got.length, greaterThanOrEqualTo(want.length));
        expect(got.sublist(0, want.length), want);
        b.checkShapes();
        expect(b.probe.writes, isEmpty);
        expect(
          await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
          admaDataDone,
        );
        await Simulator.endSimulation();
      });

      test(
        'a write error ends a card read with the ADMA error bit ($tag)',
        () async {
          final b = AdmaBench(kind, width);
          await b.start();
          await b.wr(admaBlkSize, 32);
          await b.wr(admaAdmaAddr, admaErrBase + 0x1000);
          await b.wr(admaCmd, admaCmdRead);
          await b.cardRead([for (var i = 0; i < 8; i++) i]);
          final st = await b.rd(admaIntStatus);
          expect(st & (admaDataDone | admaAdmaErr), admaDataDone | admaAdmaErr);
          expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
          b.checkShapes();
          await b.wr(admaIntStatus, admaAdmaErr);
          expect(
            await b.rd(admaIntStatus) & admaAdmaErr,
            0,
            reason: 'bit 7 is W1C',
          );
          await Simulator.endSimulation();
        },
      );

      test(
        'a read error ends a card write with the ADMA error bit ($tag)',
        () async {
          final b = AdmaBench(kind, width);
          await b.start();
          await b.wr(admaBlkSize, 8);
          await b.wr(admaAdmaAddr, admaErrBase + 0x1000);
          await b.wr(admaCmd, admaCmdWrite);
          final got = await b.cardWrite();
          expect(
            await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
            admaDataDone | admaAdmaErr,
          );
          // The card must reject the block: its CRC16 is wrong on every
          // lane.
          final data = got.sublist(1, 17);
          final crc = got.sublist(17, 33);
          for (var l = 0; l < 4; l++) {
            expect(
              [for (final g in crc) (g >> l) & 1],
              isNot(admaCrc16([for (final g in data) (g >> l) & 1])),
              reason: 'lane $l has a good CRC',
            );
          }
          expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
          b.checkShapes();
          await Simulator.endSimulation();
        },
      );

      test('a descriptor fetch error ends a card read ($tag)', () async {
        final b = AdmaBench(kind, width);
        await b.start();
        await b.wr(admaBlkSize, 16);
        await b.wr(admaAdmaAddr, admaErrBase + 0x200);
        await b.wr(admaCmd, admaCmdRead | admaTable);
        await b.cardRead([1, 2, 3, 4]);
        expect(
          await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
          admaDataDone | admaAdmaErr,
        );
        expect(b.probe.writes, isEmpty);
        b.checkShapes();
        await Simulator.endSimulation();
      });
    }
  }

  test('card accepts a block only after a driven DAT end bit', () async {
    final b = AdmaBench(HarborFabricKind.wishbone, 64);
    await b.start();
    const word = 0x12345678;
    b.write32(0x2000, word);
    await b.wr(admaBlkSize, 4);
    await b.wr(admaAdmaAddr, 0x2000);
    await b.wr(admaCmd, admaCmdWrite);
    final expected = admaFourBitBlock([word]);
    final got = await b.cardWrite(requiredDataGroups: expected.length);
    final status = await b.rd(admaIntStatus);
    b.checkShapes();
    await Simulator.endSimulation();
    expect(got, hasLength(expected.length + 1));
    expect(got.sublist(0, expected.length), expected);
    expect(got.last, 0xF, reason: 'DAT end bit must be actively driven');
    expect(status & (admaDataDone | admaWriteErr), admaDataDone);
  });

  test('accepted block completes without a busy pulse', () async {
    final b = AdmaBench(HarborFabricKind.wishbone, 64, writeBusyTimeout: 64);
    await b.start();
    const word = 0x12345678;
    b.write32(0x2000, word);
    await b.wr(admaBlkSize, 4);
    await b.wr(admaAdmaAddr, 0x2000);
    await b.wr(admaCmd, admaCmdWrite);
    final expected = admaFourBitBlock([word]);
    final got = await b.cardWrite(
      requiredDataGroups: expected.length,
      statusBusy: const [0, 0, 1, 0, 1], // start, accepted status, end; no busy
    );
    final status = await b.rd(admaIntStatus);
    b.checkShapes();
    await Simulator.endSimulation();
    expect(got.sublist(0, expected.length), expected);
    expect(got.last, 0xF, reason: 'DAT end bit was not driven');
    expect(status & (admaDataDone | admaWriteErr), admaDataDone);
  });

  test('accepted status with a malformed low end bit is rejected', () async {
    final b = AdmaBench(HarborFabricKind.wishbone, 64, writeBusyTimeout: 64);
    await b.start();
    const word = 0x12345678;
    b.write32(0x2000, word);
    await b.wr(admaBlkSize, 4);
    await b.wr(admaAdmaAddr, 0x2000);
    await b.wr(admaCmd, admaCmdWrite);
    final expected = admaFourBitBlock([word]);
    await b.cardWrite(
      requiredDataGroups: expected.length,
      statusBusy: const [0, 0, 1, 0, 0], // malformed token end=0
    );
    final status = await b.rd(admaIntStatus);
    b.checkShapes();
    await Simulator.endSimulation();
    expect(status & (admaDataDone | admaWriteErr), admaDataDone | admaWriteErr);
  });

  for (final (name, answer, addr) in [
    ('a rejected block with no busy', [0, 1, 0, 1, 1, 1, 1], admaErrBase),
    ('a busy that never ends', [0, 0, 1, 0, 1, 0], 0x1000),
  ]) {
    test('a card write ends after $name, and the next write works', () async {
      final b = AdmaBench(HarborFabricKind.wishbone, 32, writeBusyTimeout: 64);
      await b.start();
      await b.wr(admaBlkSize, 8);
      await b.wr(admaAdmaAddr, addr);
      await b.wr(admaCmd, admaCmdWrite);
      await b.cardWrite(statusBusy: answer);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaWriteErr),
        admaDataDone | admaWriteErr,
      );
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');

      b.datIn.inject(0xF);
      await b.wr(admaIntStatus, 0xFF);
      const words = [0x12345678, 0x9ABCDEF0];
      b.write32(0x2000, words[0]);
      b.write32(0x2004, words[1]);
      await b.wr(admaAdmaAddr, 0x2000);
      await b.wr(admaCmd, admaCmdWrite);
      final got = await b.cardWrite();
      final want = admaFourBitBlock(words);
      expect(got.sublist(0, want.length), want);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaWriteErr | admaAdmaErr),
        admaDataDone,
      );
      await Simulator.endSimulation();
    });
  }

  test('STATUS busy stays set while an ADMA access is in flight', () async {
    // The memory never takes a request, so the first ADMA read stays in
    // flight after the command times out.
    final b = AdmaBench(HarborFabricKind.wishbone, 32, stall: 1);
    await b.start();
    await b.wr(admaBlkSize, 8);
    await b.wr(admaAdmaAddr, 0x1000);
    await b.wr(admaCmd, admaCmdWrite);
    var timedOut = false;
    for (var i = 0; i < 400 && !timedOut; i++) {
      timedOut = await b.rd(admaIntStatus) & 0x10 != 0;
    }
    expect(timedOut, isTrue, reason: 'no command timeout');
    expect((await b.rd(admaStatus) >> 8) & 1, 1, reason: 'busy is clear');
    await Simulator.endSimulation();
  });

  // Replaces the deleted sdio_dma_throughput_sim_test: a card read drives
  // ADMA writes into memory through the Wishbone fast path (outstanding
  // 1), with the memory slave made slow and backpressuring so the test
  // proves ADMA writes neither stall forever nor drop data under it.
  test('card read keeps ADMA writes correct against a slow, backpressuring '
      'Wishbone memory slave, outstanding 1 fast path', () async {
    final b = AdmaBench(
      HarborFabricKind.wishbone,
      32,
      dmaOutstanding: 1,
      stall: 0.7,
    );
    await b.start();
    var cycles = 0;
    b.clk.posedge.listen((_) => cycles++);

    const blockWords = 128; // one 512-byte block
    final words = [for (var i = 0; i < blockWords; i++) 0x10000000 + i];
    await b.wr(admaBlkSize, blockWords * 4);
    await b.wr(admaAdmaAddr, 0x1000);
    await b.wr(admaCmd, admaCmdRead);
    final before = cycles;
    await b.cardRead(words);
    final elapsed = cycles - before;

    for (var i = 0; i < blockWords; i++) {
      expect(b.read32(0x1000 + i * 4), words[i], reason: 'word $i');
    }
    b.checkShapes();
    expect(
      await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
      admaDataDone,
    );

    // SimpleClockGenerator(10) gives a 10 ns cycle, as the rest of this
    // suite assumes.
    final seconds = elapsed * 10e-9;
    final mbPerSec = (blockWords * 4) / seconds / 1e6;
    // ignore: avoid_print
    print(
      'SDIO ADMA card-read write throughput: '
      '${mbPerSec.toStringAsFixed(2)} MB/s over $elapsed cycles, '
      'stall 0.7',
    );
    await Simulator.endSimulation();
  });

  for (final (n, stall) in [(16, 0.7), (32, 0.97)]) {
    test(
      'direct DMA CMD18 reads $n blocks, memory stall $stall',
      () => checkDirectCmd18(n, stall),
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }
}

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdio_adma_bench.dart';

void admaKindCases(HarborFabricKind kind, {List<int> widths = const [32, 64]}) {
  for (final width in widths) {
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
        (a, v) =>
            expect(b.read32(a), v, reason: 'touched 0x${a.toRadixString(16)}'),
      );
      b.checkShapes();
      expect(b.probe.writes.any((w) => w.len > 0), isTrue, reason: 'no burst');
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
        await b.cardReadBlocks([
          [for (var i = 0; i < 8; i++) i],
        ], cycles: 4000);
        final st = await b.rd(admaIntStatus);
        expect(st & (admaDataDone | admaAdmaErr), admaAdmaErr);
        expect(b.irq.value.toInt(), 1, reason: 'error interrupt');
        expect(await b.rd(admaAdmaErrStatus), 3, reason: 'transfer state');
        expect(await b.rd(admaAdmaErrAddr), admaErrBase + 0x1000);
        expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
        b.checkShapes();
        await b.wr(admaIntStatus, admaAdmaErr);
        expect(
          await b.rd(admaIntStatus) & admaAdmaErr,
          0,
          reason: 'bit 7 is W1C',
        );
        expect(await b.rd(admaAdmaErrStatus), 0, reason: 'state clears');
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
        final got = await b.cardWrite(throughBlock: true);
        expect(
          await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
          admaAdmaErr,
        );
        expect(await b.rd(admaAdmaErrStatus), 3, reason: 'transfer state');
        expect(await b.rd(admaAdmaErrAddr), admaErrBase + 0x1000);
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
      await b.cardReadBlocks([
        [1, 2, 3, 4],
      ], cycles: 4000);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaAdmaErr,
      );
      expect(await b.rd(admaAdmaErrStatus), 1, reason: 'fetch state');
      expect(await b.rd(admaAdmaErrAddr), admaErrBase + 0x200);
      expect(b.probe.writes, isEmpty);
      b.checkShapes();
      await Simulator.endSimulation();
    });

    // A buffer that runs from mapped into unmapped space. Every word is
    // its own burst, so the first bad word is not the first word.
    test('a later word of a buffer can fail ($tag)', () async {
      final b = AdmaBench(kind, width, burstBeats: 1, writeBatch: 1);
      await b.start();
      await b.wr(admaBlkSize, 16);
      await b.wr(admaAdmaAddr, admaErrBase - 8);
      await b.wr(admaCmd, admaCmdRead);
      await b.cardReadBlocks([
        [0xA0, 0xA1, 0xA2, 0xA3],
      ], cycles: 4000);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaAdmaErr,
      );
      expect(await b.rd(admaAdmaErrStatus), 3);
      expect(
        await b.rd(admaAdmaErrAddr),
        admaErrBase,
        reason: 'the first failed burst, with later writes in flight',
      );
      expect(b.read32(admaErrBase - 8), 0xA0);
      expect(b.read32(admaErrBase - 4), 0xA1);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
      await Simulator.endSimulation();
    });

    test('a fetch error on the second descriptor word ($tag)', () async {
      final b = AdmaBench(kind, width);
      await b.start();
      b.write32(admaErrBase - 4, 0x2000);
      await b.wr(admaBlkSize, 8);
      await b.wr(admaAdmaAddr, admaErrBase - 4);
      await b.wr(admaCmd, admaCmdRead | admaTable);
      await b.cardReadBlocks([
        [1, 2],
      ], cycles: 4000);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaAdmaErr,
      );
      expect(await b.rd(admaAdmaErrStatus), 1);
      expect(await b.rd(admaAdmaErrAddr), admaErrBase);
      expect(b.probe.writes, isEmpty);
      await Simulator.endSimulation();
    });

    test('a fetch error on a later descriptor ($tag)', () async {
      final b = AdmaBench(kind, width);
      await b.start();
      b.descriptors(admaErrBase - 16, [(0x2000, 8), (0x2010, 8)]);
      // The first two descriptors do not end the table.
      b.write32(admaErrBase - 12, 8);
      b.write32(admaErrBase - 4, 8);
      await b.wr(admaBlkSize, 32);
      await b.wr(admaAdmaAddr, admaErrBase - 16);
      await b.wr(admaCmd, admaCmdRead | admaTable);
      await b.cardReadBlocks([
        [1, 2, 3, 4, 5, 6, 7, 8],
      ], cycles: 6000);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaAdmaErr,
      );
      expect(await b.rd(admaAdmaErrStatus), 1);
      expect(await b.rd(admaAdmaErrAddr), admaErrBase);
      expect(b.read32(0x2000), 1);
      expect(b.read32(0x2004), 2);
      expect(b.read32(0x2010), 3);
      expect(b.read32(0x2014), 4);
      await Simulator.endSimulation();
    });

    test('the first error stays until it is cleared ($tag)', () async {
      final b = AdmaBench(kind, width);
      await b.start();
      await b.wr(admaBlkSize, 8);
      await b.wr(admaAdmaAddr, admaErrBase + 0x100);
      await b.wr(admaCmd, admaCmdRead);
      await b.cardReadBlocks([
        [1, 2],
      ], cycles: 3000);
      expect(await b.rd(admaAdmaErrStatus), 3);
      expect(await b.rd(admaAdmaErrAddr), admaErrBase + 0x100);

      // A second failure, a descriptor fetch, does not replace it.
      await b.wr(admaAdmaAddr, admaErrBase + 0x200);
      await b.wr(admaCmd, admaCmdRead | admaTable);
      await b.cardReadBlocks(
        [
          [1, 2],
        ],
        cycles: 3000,
        cmdAlreadySent: false,
      );
      expect(await b.rd(admaAdmaErrStatus), 3, reason: 'first state kept');
      expect(await b.rd(admaAdmaErrAddr), admaErrBase + 0x100);

      // After a clear the next error is the one that shows.
      await b.wr(admaIntStatus, admaAdmaErr);
      expect(await b.rd(admaAdmaErrStatus), 0);
      expect(await b.rd(admaAdmaErrAddr), 0);
      await b.wr(admaAdmaAddr, admaErrBase + 0x200);
      await b.wr(admaCmd, admaCmdRead | admaTable);
      await b.cardReadBlocks([
        [1, 2],
      ], cycles: 3000);
      expect(await b.rd(admaAdmaErrStatus), 1);
      expect(await b.rd(admaAdmaErrAddr), admaErrBase + 0x200);
      await Simulator.endSimulation();
    });

    // A buffer address or length that is not a word multiple is an ADMA
    // error, so no access reaches the fabric.
    Future<void> alignCase(
      AdmaBench b, {
      required int state,
      required int addr,
    }) async {
      await b.cardReadBlocks([
        [1, 2, 3, 4],
      ], cycles: 4000);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaAdmaErr,
      );
      expect(await b.rd(admaAdmaErrStatus), state);
      expect(await b.rd(admaAdmaErrAddr), addr);
      expect(b.probe.writes, isEmpty);
      expect(b.probe.reads, isEmpty);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
      b.checkShapes();
      await Simulator.endSimulation();
    }

    test('a buffer address that is not a word multiple stops the walker '
        '($tag)', () async {
      final b = AdmaBench(kind, width);
      await b.start();
      await b.wr(admaBlkSize, 16);
      await b.wr(admaAdmaAddr, 0x2002);
      await b.wr(admaCmd, admaCmdRead);
      await alignCase(b, state: 3, addr: 0x2002);
    });

    test('a descriptor table address that is not a word multiple stops the '
        'walker ($tag)', () async {
      final b = AdmaBench(kind, width);
      await b.start();
      await b.wr(admaBlkSize, 16);
      await b.wr(admaAdmaAddr, 0x102);
      await b.wr(admaCmd, admaCmdRead | admaTable);
      await alignCase(b, state: 1, addr: 0x102);
    });

    test('a descriptor length that is not a word multiple stops the walker '
        '($tag)', () async {
      final b = AdmaBench(kind, width);
      await b.start();
      b.descriptors(0x100, [(0x2000, 6)]);
      await b.wr(admaBlkSize, 16);
      await b.wr(admaAdmaAddr, 0x100);
      await b.wr(admaCmd, admaCmdRead | admaTable);
      await b.cardReadBlocks([
        [1, 2, 3, 4],
      ], cycles: 4000);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaAdmaErr,
      );
      expect(await b.rd(admaAdmaErrStatus), 3);
      expect(await b.rd(admaAdmaErrAddr), 0x2000);
      expect(b.probe.writes, isEmpty);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
      await Simulator.endSimulation();
    });

    // The first descriptor is good and the second has a buffer address that
    // is not a word multiple. The block count still runs out: the second
    // block goes out as zero words with a wrong CRC16 and the card rejects it.
    test('a bad second descriptor ends a multi block card write ($tag)',
        () async {
      final b = AdmaBench(kind, width);
      await b.start();
      b.descriptors(0x180, [(0x2000, 8), (0x3002, 8)]);
      const words = [0xA1B2C3D4, 0x01020304];
      b.write32(0x2000, words[0]);
      b.write32(0x2004, words[1]);
      await b.wr(admaBlkSize, 8);
      await b.wr(0x58, 2);
      await b.wr(admaAdmaAddr, 0x180);
      await b.wr(admaCmd, admaCmdWrite | admaTable);
      final blocks = await b.cardWriteBlocks(
        2,
        8,
        tokens: const [
          [0, 0, 1, 0, 1],
          [0, 1, 0, 1, 1],
        ],
        untilDone: true,
      );
      expect(blocks[0].sublist(1, 17), admaFourBitBlock(words).sublist(1, 17));
      final data = blocks[1].sublist(1, 17);
      final crc = blocks[1].sublist(17, 33);
      expect(data.every((g) => g == 0), isTrue, reason: 'zero words');
      for (var l = 0; l < 4; l++) {
        expect(
          [for (final g in crc) (g >> l) & 1],
          isNot(admaCrc16([for (final g in data) (g >> l) & 1])),
          reason: 'lane $l has a good CRC',
        );
      }
      final st = await b.rd(admaIntStatus);
      expect(
        st & (admaDataDone | admaWriteErr | admaAdmaErr),
        admaWriteErr | admaAdmaErr,
      );
      expect(await b.rd(admaAdmaErrStatus), 3);
      expect(await b.rd(admaAdmaErrAddr), 0x3002);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
      await Simulator.endSimulation();
    });

    test('a card read works after a read path error ($tag)', () async {
      final b = AdmaBench(kind, width);
      await b.start();
      await b.wr(admaBlkSize, 8);
      await b.wr(admaAdmaAddr, admaErrBase + 0x1000);
      await b.wr(admaCmd, admaCmdWrite);
      await b.cardWrite(throughBlock: true);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaAdmaErr,
      );
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');
      b.datIn.inject(0xF);
      await b.wr(admaIntStatus, 0xFF);

      await b.wr(admaBlkSize, 8);
      await b.wr(admaAdmaAddr, 0x2000);
      await b.wr(admaCmd, admaCmdRead);
      await b.cardRead([0x11223344, 0x55667788]);
      expect(
        await b.rd(admaIntStatus) & (admaDataDone | admaAdmaErr),
        admaDataDone,
      );
      expect(b.read32(0x2000), 0x11223344);
      expect(b.read32(0x2004), 0x55667788);
      await Simulator.endSimulation();
    });
  }
}

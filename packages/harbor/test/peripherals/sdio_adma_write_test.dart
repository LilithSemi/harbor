import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdio_adma_bench.dart';

const _cmd25 = 25 | (1 << 6) | (1 << 8) | (1 << 10);
const _blkCount = 0x58;
const _ctrlSampleFall = 1 << 8;

/// Writes [blocks] blocks of two words with CMD25 over a direct ADMA buffer
/// and checks the blocks the card model takes and the interrupt bits.
Future<void> checkMultiWrite(
  int blocks, {
  int busyDelay = 0,
  int busyLen = 3,
  int lag = 0,
  bool sampleFall = false,
  bool noisy = false,
}) async {
  final b = AdmaBench(HarborFabricKind.wishbone, 64, sampleFall: sampleFall);
  await b.start();
  Simulator.setMaxSimTime(40000000);
  final words = [for (var i = 0; i < blocks * 2; i++) 0x01020304 * (i + 1)];
  for (var i = 0; i < words.length; i++) {
    b.write32(0x2000 + 4 * i, words[i]);
  }
  if (sampleFall) await b.wr(0x00, 0x01 | (1 << 4) | _ctrlSampleFall);
  await b.wr(admaBlkSize, 8);
  await b.wr(_blkCount, blocks);
  await b.wr(admaAdmaAddr, 0x2000);
  await b.wr(admaCmd, _cmd25);
  final got = await b.cardWriteBlocks(
    blocks,
    8,
    busyDelay: busyDelay,
    busyLen: busyLen,
    lag: lag,
    noisyOtherEdge: noisy,
  );
  final st = await b.rd(admaIntStatus);
  await Simulator.endSimulation();
  expect(b.busyConflicts, 0, reason: 'DAT driven while the card was busy');
  expect(got, hasLength(blocks));
  for (var k = 0; k < blocks; k++) {
    final want = admaFourBitBlock(words.sublist(2 * k, 2 * k + 2));
    expect(got[k].sublist(0, want.length), want, reason: 'block $k');
  }
  expect(st & (admaDataDone | admaWriteErr), admaDataDone);
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final n in [2, 3]) {
    test('CMD25 writes $n blocks to a card with a busy phase', () {
      return checkMultiWrite(n);
    });
    test('CMD25 writes $n blocks to a card with no busy phase', () {
      return checkMultiWrite(n, busyLen: 0);
    });
  }

  test('CMD25 waits for a card that starts busy five clocks late', () {
    return checkMultiWrite(2, busyDelay: 4, busyLen: 6);
  });

  test('CMD25 with sample on fall reads the status token and busy', () {
    return checkMultiWrite(2, sampleFall: true, noisy: true);
  });

  test('a busy timeout inside the no-busy window is rejected', () {
    expect(
      () => HarborSdioController(
        baseAddress: 0x60000000,
        writeBusyTimeout: HarborSdioController.writeBusyStartClocks,
      ),
      throwsArgumentError,
    );
  });
}

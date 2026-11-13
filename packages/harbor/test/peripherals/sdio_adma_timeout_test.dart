import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdio_adma_bench.dart';

const _ctrl = 0x00;
const _blkCount = 0x58;
const _dataTimeout = 0x78;
const _timeoutBit = 0x100;
const _datReset = 1 << 9;
const _cmd18 = 18 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10);

List<int> _block(int seed) => [for (var i = 0; i < 2; i++) seed + i * 0x111];

Future<void> _read(
  AdmaBench b,
  int addr,
  int count,
  List<List<int>> sent,
) async {
  await b.wr(admaIntStatus, 0x1FF);
  await b.wr(admaBlkSize, 8);
  await b.wr(_blkCount, count);
  await b.wr(admaAdmaAddr, addr);
  await b.wr(admaCmd, _cmd18);
  await b.cardReadBlocks(sent, cycles: 0);
}

void _expectBlock(AdmaBench b, int addr, List<int> words) {
  for (var i = 0; i < words.length; i++) {
    expect(b.read32(addr + 4 * i), words[i], reason: 'word $i at $addr');
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'a card that stops sending ends the read with the data timeout bit',
    () async {
      final b = AdmaBench(
        HarborFabricKind.wishbone,
        64,
        sampleFall: true,
        errBase: 0x1000000,
      );
      await b.start();
      Simulator.setMaxSimTime(40000000);
      // The read ends with data-done, which follows the timeout bit.
      await b.wr(admaIntEnable, admaDataDone);
      await b.wr(_dataTimeout, 64);
      expect(await b.rd(_dataTimeout), 64);
      final first = _block(0x11110000);
      await _read(b, 0x10000, 3, [first]);
      final st = await b.rd(admaIntStatus);
      expect(st & _timeoutBit, _timeoutBit);
      _expectBlock(b, 0x10000, first);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'still busy');

      final next = _block(0x22220000);
      await b.wr(_blkCount, 1);
      await _read(b, 0x20000, 1, [next]);
      expect(await b.rd(admaIntStatus) & _timeoutBit, 0);
      _expectBlock(b, 0x20000, next);
      await Simulator.endSimulation();
    },
  );

  test(
    'a DAT reset frees a read that has no timeout, and the next read works',
    () async {
      final b = AdmaBench(
        HarborFabricKind.wishbone,
        64,
        sampleFall: true,
        errBase: 0x1000000,
      );
      await b.start();
      Simulator.setMaxSimTime(40000000);
      await b.wr(_dataTimeout, 0);
      await b.wr(admaBlkSize, 8);
      await b.wr(_blkCount, 3);
      await b.wr(admaAdmaAddr, 0x10000);
      await b.wr(admaCmd, _cmd18);
      final first = _block(0x33330000);
      await b.cardReadBlocks([first], cycles: 6000);
      expect((await b.rd(admaStatus) >> 8) & 1, 1, reason: 'not hung');
      expect(await b.rd(admaIntStatus) & _timeoutBit, 0);

      await b.wr(_ctrl, 0x01 | (1 << 4) | _datReset);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'reset kept busy');
      expect(await b.rd(_ctrl) & _datReset, 0);

      final next = _block(0x44440000);
      await b.wr(admaIntEnable, admaDataDone);
      await _read(b, 0x20000, 1, [next]);
      expect(await b.rd(admaIntStatus) & (admaDataDone | 0x1F8), admaDataDone);
      _expectBlock(b, 0x20000, next);
      await Simulator.endSimulation();
    },
  );

  test('lowering DATA_TIMEOUT below the running count ends the wait', () async {
    final b = AdmaBench(
      HarborFabricKind.wishbone,
      64,
      sampleFall: true,
      errBase: 0x1000000,
    );
    await b.start();
    Simulator.setMaxSimTime(40000000);
    await b.wr(_dataTimeout, 0);
    await b.wr(admaBlkSize, 8);
    await b.wr(_blkCount, 2);
    await b.wr(admaAdmaAddr, 0x10000);
    await b.wr(admaCmd, _cmd18);
    await b.cardReadBlocks([_block(0x55550000)], cycles: 1000);
    expect(await b.rd(admaIntStatus) & _timeoutBit, 0);
    await b.wr(_dataTimeout, 16);
    await b.clk.nextPosedge;
    for (var i = 0; i < 200; i++) {
      await b.clk.nextPosedge;
    }
    expect(await b.rd(admaIntStatus) & _timeoutBit, _timeoutBit);
    await Simulator.endSimulation();
  });
}

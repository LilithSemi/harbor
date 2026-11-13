import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdio_adma_bench.dart';

const _ctrl = 0x00;
const _resp0 = 0x28;
const _cmdArg = 0x20;
const _blkCount = 0x58;
const _datReset = 1 << 9;
const _cmdDone = 0x01;
const _cmd13 = 13 | (1 << 6);
const _cmd18 = 18 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10);

List<int> _crc7(List<int> bits) {
  var c = List<int>.filled(7, 0);
  for (final b in bits) {
    final inv = b ^ c[6];
    c = [inv, c[0], c[1], c[2] ^ inv, c[3], c[4], c[5]];
  }
  return [c[6], c[5], c[4], c[3], c[2], c[1], c[0]];
}

List<int> _bits(int v, int w) => [
  for (var i = w - 1; i >= 0; i--) (v >> i) & 1,
];

/// An argument whose CRC7 ends in 0, so the last bit before the end bit is 0.
int _argWithZeroCrcTail(int index) {
  for (var arg = 0x1000; ; arg++) {
    final crc = _crc7([0, 1, ..._bits(index, 6), ..._bits(arg, 32)]);
    if (crc.last == 0) return arg;
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'the CMD end bit is driven, so a slow pull-up cannot fake a start bit',
    () async {
      final b = AdmaBench(HarborFabricKind.wishbone, 64, errBase: 0x1000000);
      await b.start();
      Simulator.setMaxSimTime(40000000);
      const payload = 0xA5C3F00D;
      final frame = [
        0,
        0,
        ..._bits(13, 6),
        ..._bits(payload, 32),
        ..._bits(0, 7),
        1,
      ];
      await b.wr(_cmdArg, _argWithZeroCrcTail(13));
      await b.wr(admaCmd, _cmd13);
      await b.cardRespond(frame);
      expect(await b.rd(admaIntStatus) & (_cmdDone | 0x10), _cmdDone);
      expect(await b.rd(_resp0), payload);
      await Simulator.endSimulation();
    },
  );

  test(
    'a DAT reset also stops a command that waits for its response',
    () async {
      final b = AdmaBench(HarborFabricKind.wishbone, 64, errBase: 0x1000000);
      await b.start();
      Simulator.setMaxSimTime(40000000);
      b.write32(0x10000, 0xDEADBEEF);
      await b.wr(admaBlkSize, 8);
      await b.wr(_blkCount, 1);
      await b.wr(admaAdmaAddr, 0x10000);
      await b.wr(admaCmd, _cmd18);
      for (var i = 0; i < 150; i++) {
        await b.clk.nextPosedge;
      }
      await b.wr(_ctrl, 0x01 | (1 << 4) | _datReset);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'reset kept busy');

      final late = [0x55550000, 0x66660000];
      await b.cardReadBlocks([late], cycles: 3000, cmdAlreadySent: true);
      expect(
        await b.rd(admaIntStatus) & 0x1FF,
        0,
        reason: 'a late card answer',
      );
      expect(b.read32(0x10000), 0xDEADBEEF);
      expect((await b.rd(admaStatus) >> 8) & 1, 0, reason: 'busy came back');

      final next = [0x77770000, 0x88880000];
      await b.wr(admaIntEnable, admaDataDone);
      await b.wr(admaAdmaAddr, 0x20000);
      await b.wr(admaCmd, _cmd18);
      await b.cardReadBlocks([next]);
      expect(b.read32(0x20000), next[0]);
      expect(b.read32(0x20004), next[1]);
      await Simulator.endSimulation();
    },
  );
}

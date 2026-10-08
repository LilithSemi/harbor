import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../integration/test_harness.dart';

void main() {
  tearDown(() async => Simulator.reset());

  group('HarborAudioController bus', () {
    Future<PeripheralTestBench> bench() async {
      final audio = HarborAudioController(baseAddress: 0x10060000);
      audio.port('sdata_in').getsLogic(Const(0));
      audio.port('dma_read_data').getsLogic(Const(0, width: 32));
      audio.port('dma_read_valid').getsLogic(Const(0));
      audio.port('dma_write_ack').getsLogic(Const(0));
      final tb = PeripheralTestBench(audio);
      await tb.init();
      return tb;
    }

    test('a byte store changes only the selected byte', () async {
      final tb = await bench();
      // TX_DMA_ADDR at 0x30.
      await tb.write(0x30, 0x11223344);
      await tb.write(0x30, 0x00AA0000, sel: 0x4);
      expect(await tb.read(0x30), equals(0x11AA3344));
      // INT_ENABLE at 0x78 is one byte wide.
      await tb.write(0x78, 0x5A);
      await tb.write(0x78, 0xFF00, sel: 0x2);
      expect(await tb.read(0x78), equals(0x5A));
      await Simulator.endSimulation();
    });

    test('an address above the registers does not alias one', () async {
      final tb = await bench();
      await tb.write(0x30, 0x11223344);
      await tb.write(0x230, 0xDEADBEEF);
      expect(await tb.read(0x30), equals(0x11223344));
      expect(await tb.read(0x230), equals(0));
      await Simulator.endSimulation();
    });
  });

  group('HarborMediaEngine bus', () {
    test('a byte store changes only the selected byte', () async {
      final eng = HarborMediaEngine(
        baseAddress: 0x40000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.both,
          ),
        ],
      );
      eng.port('dma_read_data').getsLogic(Const(0, width: 128));
      eng.port('dma_read_valid').getsLogic(Const(0));
      eng.port('dma_write_ack').getsLogic(Const(0));
      final tb = PeripheralTestBench(eng);
      await tb.init();
      // Session 0 SESS_SRC_SIZE at 0x118, SESS_WIDTH at 0x130.
      await tb.write(0x118, 0x11223344);
      await tb.write(0x118, 0x00AA0000, sel: 0x4);
      expect(await tb.read(0x118), equals(0x11AA3344));
      await tb.write(0x130, 0x1234);
      await tb.write(0x130, 0xBB00, sel: 0x2);
      expect(await tb.read(0x130), equals(0xBB34));
      await Simulator.endSimulation();
    });
  });
}

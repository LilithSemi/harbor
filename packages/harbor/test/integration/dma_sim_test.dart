import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/mem_target.dart';
import 'test_harness.dart';

/// Wraps [dma] with a [MasterTop] + [BeatMemory] on its `dma` master memory
/// port, then drives the register port through [PeripheralTestBench]. None
/// of these tests trigger a transfer, but the master port still needs a
/// memory behind it to build.
Future<PeripheralTestBench> _bench(HarborDmaController dma) async {
  final cfg = HarborMemoryWaistConfig(
    addressWidth: dma.addressWidth,
    dataWidth: dma.dataWidth,
  );
  final top = MasterTop(
    dma,
    iface: 'dma',
    kind: HarborFabricKind.wishbone,
    config: cfg,
  );
  final tb = PeripheralTestBench(top);
  final mem = BeatMemory(top, tb.clk);
  await tb.init();
  mem.start();
  return tb;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('DMA sim', () {
    test('write CTRL enable and read back', () async {
      final dma = HarborDmaController(baseAddress: 0xD000);
      final tb = await _bench(dma);

      // Global CTRL byte offset 0x00, bit 0 = global enable
      await tb.write(0x00, 0x01);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('write and read INT_ENABLE register', () async {
      final dma = HarborDmaController(baseAddress: 0xD000);
      final tb = await _bench(dma);

      // INT_ENABLE at byte offset 0x10
      await tb.write(0x10, 0x0F);
      final val = await tb.read(0x10);
      expect(val & 0x0F, equals(0x0F));

      await Simulator.endSimulation();
    });

    test('read STATUS register for channel 0', () async {
      final dma = HarborDmaController(baseAddress: 0xD000);
      final tb = await _bench(dma);

      // Channel 0 block starts at byte 0x40. CH_STATUS is +0x08.
      final val = await tb.read(0x48);
      // After reset: busy=0, complete=0, error=0
      expect(val, equals(0));

      await Simulator.endSimulation();
    });

    test('write channel 0 source address and read back', () async {
      final dma = HarborDmaController(baseAddress: 0xD000);
      final tb = await _bench(dma);

      // CH0 SRC is 0x40 + 0x10.
      await tb.write(0x50, 0x80000000);
      final val = await tb.read(0x50);
      expect(val, equals(0x80000000));

      await Simulator.endSimulation();
    });

    test('write channel 0 destination address and read back', () async {
      final dma = HarborDmaController(baseAddress: 0xD000);
      final tb = await _bench(dma);

      // CH0 DST is 0x40 + 0x18.
      await tb.write(0x58, 0x90000000);
      final val = await tb.read(0x58);
      expect(val, equals(0x90000000));

      await Simulator.endSimulation();
    });

    test('write channel 0 length and read back', () async {
      final dma = HarborDmaController(baseAddress: 0xD000);
      final tb = await _bench(dma);

      // CH0 LEN is 0x40 + 0x20.
      await tb.write(0x60, 0x1000);
      final val = await tb.read(0x60);
      expect(val, equals(0x1000));

      await Simulator.endSimulation();
    });

    test('channel 0 CTRL enable', () async {
      final dma = HarborDmaController(baseAddress: 0xD000);
      final tb = await _bench(dma);

      // CH0 CTRL is 0x40 + 0x00. Bit 0 = enable.
      await tb.write(0x40, 0x01);
      final val = await tb.read(0x40);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });
  });
}

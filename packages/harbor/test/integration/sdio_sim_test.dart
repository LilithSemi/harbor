import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('SDIO sim', () {
    test('write clock divider and read back', () async {
      final sdio = HarborSdioController(baseAddress: 0x10000);
      sdio.port('sd_cmd_in').getsLogic(Const(1));
      sdio.port('sd_dat_in').getsLogic(Const(0, width: 4));
      sdio.port('sd_cd').getsLogic(Const(0));
      for (final p in sdio.inputs.keys.where((p) => p.startsWith('dma_'))) {
        sdio.port(p).getsLogic(Const(0, width: sdio.input(p).width));
      }

      final tb = PeripheralTestBench(sdio);
      await tb.init();

      // CLK_DIV byte offset 0x10
      await tb.write(0x10, 50);
      final val = await tb.read(0x10);
      expect(val, equals(50));

      await Simulator.endSimulation();
    });

    test('write CTRL enable and read back', () async {
      final sdio = HarborSdioController(baseAddress: 0x10000);
      sdio.port('sd_cmd_in').getsLogic(Const(1));
      sdio.port('sd_dat_in').getsLogic(Const(0, width: 4));
      sdio.port('sd_cd').getsLogic(Const(0));
      for (final p in sdio.inputs.keys.where((p) => p.startsWith('dma_'))) {
        sdio.port(p).getsLogic(Const(0, width: sdio.input(p).width));
      }

      final tb = PeripheralTestBench(sdio);
      await tb.init();

      // CTRL byte offset 0x00, bit 0 = enable
      await tb.write(0x00, 0x01);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('read STATUS register', () async {
      final sdio = HarborSdioController(baseAddress: 0x10000);
      sdio.port('sd_cmd_in').getsLogic(Const(1));
      sdio.port('sd_dat_in').getsLogic(Const(0, width: 4));
      sdio.port('sd_cd').getsLogic(Const(0));
      for (final p in sdio.inputs.keys.where((p) => p.startsWith('dma_'))) {
        sdio.port(p).getsLogic(Const(0, width: sdio.input(p).width));
      }

      final tb = PeripheralTestBench(sdio);
      await tb.init();

      // STATUS byte offset 0x08
      final val = await tb.read(0x08);
      // card_detect bit 0 should be 0 (sd_cd = 0), busy bit 8 should be 0
      expect(val & 0x01, equals(0));
      expect((val >> 8) & 0x01, equals(0));

      await Simulator.endSimulation();
    });

    test('write bus width (BLK_SIZE) and read back', () async {
      final sdio = HarborSdioController(baseAddress: 0x10000);
      sdio.port('sd_cmd_in').getsLogic(Const(1));
      sdio.port('sd_dat_in').getsLogic(Const(0, width: 4));
      sdio.port('sd_cd').getsLogic(Const(0));
      for (final p in sdio.inputs.keys.where((p) => p.startsWith('dma_'))) {
        sdio.port(p).getsLogic(Const(0, width: sdio.input(p).width));
      }

      final tb = PeripheralTestBench(sdio);
      await tb.init();

      // BLK_SIZE byte offset 0x50
      await tb.write(0x50, 1024);
      final val = await tb.read(0x50);
      expect(val, equals(1024));

      await Simulator.endSimulation();
    });
  });
}

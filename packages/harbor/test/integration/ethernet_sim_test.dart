import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Ethernet sim', () {
    test('write MAC_ADDR_LO and read back', () async {
      final eth = HarborEthernetMac(
        config: const HarborEthernetConfig(),
        baseAddress: 0xB000,
      );
      eth.port('rx_clk').getsLogic(Const(0));
      eth.port('rx_dv').getsLogic(Const(0));
      eth.port('rxd').getsLogic(Const(0, width: 8));
      eth.port('mdio_in').getsLogic(Const(0));
      eth.port('dma_ACK').getsLogic(Const(0));
      eth.port('dma_DAT_MISO').getsLogic(Const(0, width: 32));
      eth.port('dma_ERR').getsLogic(Const(0));

      final tb = PeripheralTestBench(eth);
      await tb.init();

      // MAC_ADDR_LO byte offset 0x10
      await tb.write(0x10, 0xAABBCCDD);
      final val = await tb.read(0x10);
      expect(val, equals(0xAABBCCDD));

      await Simulator.endSimulation();
    });

    test('write MAC_ADDR_HI and read back', () async {
      final eth = HarborEthernetMac(
        config: const HarborEthernetConfig(),
        baseAddress: 0xB000,
      );
      eth.port('rx_clk').getsLogic(Const(0));
      eth.port('rx_dv').getsLogic(Const(0));
      eth.port('rxd').getsLogic(Const(0, width: 8));
      eth.port('mdio_in').getsLogic(Const(0));
      eth.port('dma_ACK').getsLogic(Const(0));
      eth.port('dma_DAT_MISO').getsLogic(Const(0, width: 32));
      eth.port('dma_ERR').getsLogic(Const(0));

      final tb = PeripheralTestBench(eth);
      await tb.init();

      // MAC_ADDR_HI byte offset 0x18
      await tb.write(0x18, 0xEEFF);
      final val = await tb.read(0x18);
      expect(val, equals(0xEEFF));

      await Simulator.endSimulation();
    });

    test('write CTRL enable and read back', () async {
      final eth = HarborEthernetMac(
        config: const HarborEthernetConfig(),
        baseAddress: 0xB000,
      );
      eth.port('rx_clk').getsLogic(Const(0));
      eth.port('rx_dv').getsLogic(Const(0));
      eth.port('rxd').getsLogic(Const(0, width: 8));
      eth.port('mdio_in').getsLogic(Const(0));
      eth.port('dma_ACK').getsLogic(Const(0));
      eth.port('dma_DAT_MISO').getsLogic(Const(0, width: 32));
      eth.port('dma_ERR').getsLogic(Const(0));

      final tb = PeripheralTestBench(eth);
      await tb.init();

      // MAC_CTRL byte offset 0x00, bit 0 = enable
      await tb.write(0x00, 0x01);
      final val = await tb.read(0x00);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('read STATUS register', () async {
      final eth = HarborEthernetMac(
        config: const HarborEthernetConfig(),
        baseAddress: 0xB000,
      );
      eth.port('rx_clk').getsLogic(Const(0));
      eth.port('rx_dv').getsLogic(Const(0));
      eth.port('rxd').getsLogic(Const(0, width: 8));
      eth.port('mdio_in').getsLogic(Const(0));
      eth.port('dma_ACK').getsLogic(Const(0));
      eth.port('dma_DAT_MISO').getsLogic(Const(0, width: 32));
      eth.port('dma_ERR').getsLogic(Const(0));

      final tb = PeripheralTestBench(eth);
      await tb.init();

      // MAC_STATUS byte offset 0x08
      final val = await tb.read(0x08);
      // After reset: tx_enable=0, rx_enable=0
      expect(val & 0x03, equals(0));

      await Simulator.endSimulation();
    });

    test('write INT_ENABLE and read back', () async {
      final eth = HarborEthernetMac(
        config: const HarborEthernetConfig(),
        baseAddress: 0xB000,
      );
      eth.port('rx_clk').getsLogic(Const(0));
      eth.port('rx_dv').getsLogic(Const(0));
      eth.port('rxd').getsLogic(Const(0, width: 8));
      eth.port('mdio_in').getsLogic(Const(0));
      eth.port('dma_ACK').getsLogic(Const(0));
      eth.port('dma_DAT_MISO').getsLogic(Const(0, width: 32));
      eth.port('dma_ERR').getsLogic(Const(0));

      final tb = PeripheralTestBench(eth);
      await tb.init();

      // INT_ENABLE byte offset 0x28
      await tb.write(0x28, 0x3F);
      final val = await tb.read(0x28);
      expect(val, equals(0x3F));

      await Simulator.endSimulation();
    });
  });
}

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

/// Writes [value] to register [offset] at the absolute address [base] +
/// [offset], cut to the port width the way a fabric connects it, and reads it
/// back. An unused offset 0x100 higher in the window must read 0.
Future<void> _absoluteRoundTrip(
  BridgeModule dut,
  int base,
  int offset,
  int value, {
  int mask = 0xFFFFFFFF,
}) async {
  final tb = PeripheralTestBench(dut);
  await tb.init();
  final aw = tb.input('adr').width;
  int at(int a) => a & ((1 << aw) - 1);

  await tb.write(at(base + offset), value);
  expect(await tb.read(at(base + offset)) & mask, equals(value));
  expect(await tb.read(at(base + 0x100 + offset)), equals(0));

  await Simulator.endSimulation();
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('absolute address decode', () {
    test('gpio', () async {
      final gpio = HarborGpio(
        baseAddress: 0x10001000,
        pinCount: 8,
        busAddressWidth: 32,
      );
      gpio.port('gpio_in').getsLogic(Const(0, width: 8));
      await _absoluteRoundTrip(gpio, 0x10001000, 0x08, 0xA5);
    });

    test('i2c', () async {
      final i2c = HarborI2cController(
        baseAddress: 0x10006000,
        busAddressWidth: 32,
      );
      i2c.port('scl_in').getsLogic(Const(1));
      i2c.port('sda_in').getsLogic(Const(1));
      await _absoluteRoundTrip(i2c, 0x10006000, 0x20, 200);
    });

    test('spi', () async {
      final spi = HarborSpiController(
        baseAddress: 0x10005000,
        busAddressWidth: 32,
      );
      spi.port('spi_miso').getsLogic(Const(0));
      await _absoluteRoundTrip(spi, 0x10005000, 0x00, 0x01, mask: 0x01);
    });

    test('sdio', () async {
      final sdio = HarborSdioController(
        baseAddress: 0x10010000,
        busAddressWidth: 32,
      );
      sdio.port('sd_cmd_in').getsLogic(Const(1));
      sdio.port('sd_dat_in').getsLogic(Const(0, width: 4));
      sdio.port('sd_cd').getsLogic(Const(0));
      await _absoluteRoundTrip(sdio, 0x10010000, 0x10, 50);
    });

    test('display', () async {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.vga,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0x1000C000,
      );
      display.port('pixel_clk').getsLogic(Const(0));
      display.port('fb_data').getsLogic(Const(0, width: 32));
      display.port('fb_ack').getsLogic(Const(0));
      await _absoluteRoundTrip(display, 0x1000C000, 0x20, 640);
    });

    test('efuse', () async {
      final efuse = HarborEfuseDevice(baseAddress: 0x1000A000);
      efuse.port('fuse_rdata').getsLogic(Const(0, width: 32));
      efuse.port('fuse_done').getsLogic(Const(0));
      await _absoluteRoundTrip(efuse, 0x1000A000, 0x10, 5);
    });

    test('ethernet', () async {
      final eth = HarborEthernetMac(
        config: const HarborEthernetConfig(),
        baseAddress: 0x1000B000,
      );
      eth.port('rx_clk').getsLogic(Const(0));
      eth.port('rx_dv').getsLogic(Const(0));
      eth.port('rxd').getsLogic(Const(0, width: 8));
      eth.port('mdio_in').getsLogic(Const(0));
      eth.port('dma_rdata').getsLogic(Const(0, width: 32));
      eth.port('dma_ack').getsLogic(Const(0));
      await _absoluteRoundTrip(eth, 0x1000B000, 0x10, 0xAABBCCDD);
    });

    test('temperature sensor', () async {
      final temp = HarborTemperatureSensor(baseAddress: 0x10013000);
      temp.port('temp_raw_in').getsLogic(Const(0, width: 12));
      temp.port('temp_valid_in').getsLogic(Const(0));
      await _absoluteRoundTrip(temp, 0x10013000, 0x00, 0x03, mask: 0x03);
    });

    test('watchdog', () async {
      final wdt = HarborWatchdog(baseAddress: 0x10002000);
      await _absoluteRoundTrip(wdt, 0x10002000, 0x10, 5000);
    });

    test('aplic', () async {
      // Bit 15 of the base is above the 0x8000 window but inside the port.
      final aplic = HarborAplic(baseAddress: 0x0C008000, sources: 4, harts: 1);
      for (var i = 0; i < 4; i++) {
        aplic.port('src_irq_$i').getsLogic(Const(0));
      }
      await _absoluteRoundTrip(aplic, 0x0C008000, 0x0004, 0x01);
    });

    test('trace encoder', () async {
      final trace = HarborTraceEncoder(baseAddress: 0x30000000);
      for (final p in [
        'valid',
        'is_branch',
        'branch_taken',
        'is_exception',
        'is_eret',
        'priv_change',
      ]) {
        trace.port(p).getsLogic(Const(0));
      }
      trace.port('pc').getsLogic(Const(0, width: 64));
      trace.port('exception_cause').getsLogic(Const(0, width: 5));
      trace.port('priv_mode').getsLogic(Const(0, width: 2));
      await _absoluteRoundTrip(trace, 0x30000000, 0x10, 0x1000);
    });

    for (final dw in [32, 64]) {
      test('trng on a $dw-bit bus', () async {
        const base = 0x40000000;
        final trng = HarborTrng(
          const HarborTrngConfig(baseAddress: base, seed: 0xC0FFEE),
          busDataWidth: dw,
        );
        trng.port('noise').getsLogic(Const(0));
        final tb = PeripheralTestBench(trng);
        await tb.init();
        final aw = tb.input('adr').width;
        int at(int a) => a & ((1 << aw) - 1);
        final status = dw >= 64 ? 0x08 : 0x04;

        expect(await tb.read(at(base + status)) & 1, equals(1));
        expect(await tb.read(at(base)), equals(0xC0FFEE));
        expect(await tb.read(at(base + 0x100 + status)), equals(0));

        await Simulator.endSimulation();
      });
    }
  });
}

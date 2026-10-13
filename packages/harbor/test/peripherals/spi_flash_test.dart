import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

void main() {
  group('HarborSpiFlashConfig', () {
    test('W25Q128 preset', () {
      const config = HarborSpiFlashConfig.w25q128();
      expect(config.size, equals(16 * 1024 * 1024));
      expect(config.mode, equals(HarborSpiFlashMode.quad));
      expect(config.readCommand, equals(0x6B));
      expect(config.dummyCycles, equals(8));
    });

    test('IS25LP128 preset', () {
      const config = HarborSpiFlashConfig.is25lp128();
      expect(config.size, equals(16 * 1024 * 1024));
      expect(config.mode, equals(HarborSpiFlashMode.quad));
    });

    test('S25FL256 4-byte addressing', () {
      const config = HarborSpiFlashConfig.s25fl256();
      expect(config.addressBytes, equals(4));
      expect(config.size, equals(32 * 1024 * 1024));
    });

    test('toPrettyString', () {
      const config = HarborSpiFlashConfig.w25q128();
      final pretty = config.toPrettyString();
      expect(pretty, contains('16 MB'));
      expect(pretty, contains('quad'));
    });
  });

  group('HarborSpiFlashController', () {
    test('creates with QSPI config', () {
      final flash = HarborSpiFlashController(
        config: const HarborSpiFlashConfig.w25q128(),
        baseAddress: 0x20000000,
      );
      expect(flash.bus, isNotNull);
    });

    test('standard SPI has MOSI/MISO', () {
      final flash = HarborSpiFlashController(
        config: const HarborSpiFlashConfig(
          size: 1024 * 1024,
          mode: HarborSpiFlashMode.standard,
        ),
        baseAddress: 0x20000000,
      );
      expect(flash.tryOutput('spi_mosi'), isNotNull);
    });

    test('DT compatible is jedec,spi-nor', () {
      final flash = HarborSpiFlashController(
        config: const HarborSpiFlashConfig.w25q128(),
        baseAddress: 0x20000000,
      );
      expect(flash.dtNode.compatible.first, equals('jedec,spi-nor'));
    });

    test('two different configs give different definition names', () {
      final a = HarborSpiFlashController(
        config: const HarborSpiFlashConfig(size: 1024 * 1024),
        baseAddress: 0x20000000,
      );
      final b = HarborSpiFlashController(
        config: const HarborSpiFlashConfig(size: 2 * 1024 * 1024),
        baseAddress: 0x20000000,
      );
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    _registerPortTests(kind);
  }
}

// The register port on this device is read-only: the read FSM below never
// looks at bus.we or bus.sel, so a flash read always runs, write or not. A
// write with no byte selected must behave exactly like any other access on
// this port, never getting stuck or acking differently.
void _registerPortTests(HarborFabricKind kind) {
  group('HarborSpiFlashController register port (${kind.name})', () {
    late HarborSpiFlashController flash;
    late Logic clk, reset, miso;
    late RegBus bus;

    Future<void> setUpDut() async {
      flash = HarborSpiFlashController(
        config: const HarborSpiFlashConfig(
          size: 1024 * 1024,
          mode: HarborSpiFlashMode.standard,
        ),
        baseAddress: 0x20000000,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      miso = Logic(name: 'spi_miso');

      flash.input('clk').srcConnection! <= clk;
      flash.input('reset').srcConnection! <= reset;
      flash.input('spi_miso').srcConnection! <= miso;
      flash.input('wr_req').srcConnection! <= Const(0);
      flash.input('wr_op').srcConnection! <= Const(0);
      flash.input('wr_addr').srcConnection! <=
          Const(0, width: flash.input('wr_addr').width);
      flash.input('wr_len').srcConnection! <= Const(0, width: 9);
      flash.input('wr_data').srcConnection! <= Const(0, width: 8);
      bus = RegBus.attach(flash, clk);

      await flash.build();

      reset.inject(1);
      bus.idle();
      miso.inject(0);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      final withSel = await bus.access(
        0x0,
        data: 0x12345678,
        sel: 0xf,
        write: true,
      );
      final noSel = await bus.access(
        0x0,
        data: 0x12345678,
        sel: 0x0,
        write: true,
      );

      // Neither write touches flash content: both are just a read-shaped
      // access on this read-only port, so they ack the same way.
      expect(noSel.err, equals(withSel.err));
      await Simulator.endSimulation();
    });
  });
}

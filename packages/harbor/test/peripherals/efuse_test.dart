import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// Register byte offsets: each register in its own 8-byte slot.
const _ctrl = 0x00;
const _addr = 0x10;
const _wdata = 0x20;
const _timing = 0x30;

void main() {
  group('HarborEfuseConfig', () {
    test('default values', () {
      const config = HarborEfuseConfig();
      expect(config.totalBits, equals(256));
      expect(config.bitsPerWord, equals(32));
      expect(config.regions, equals(4));
      expect(config.hasEcc, isFalse);
    });

    test('words computed correctly', () {
      const config = HarborEfuseConfig();
      expect(config.words, equals(8)); // 256 / 32

      const config2 = HarborEfuseConfig(totalBits: 512, bitsPerWord: 64);
      expect(config2.words, equals(8)); // 512 / 64

      const config3 = HarborEfuseConfig(totalBits: 128, bitsPerWord: 32);
      expect(config3.words, equals(4)); // 128 / 32
    });
  });

  group('HarborEfuseBlock', () {
    test('creates with config', () {
      const config = HarborEfuseConfig();
      final block = HarborEfuseBlock(config: config);
      expect(block.config.totalBits, equals(256));
    });

    test('has addr output', () {
      final block = HarborEfuseBlock(config: const HarborEfuseConfig());
      expect(block.addr.width, greaterThan(0));
    });

    test('has wdata output', () {
      final block = HarborEfuseBlock(config: const HarborEfuseConfig());
      expect(block.wdata.width, equals(32));
    });

    test('has read output', () {
      final block = HarborEfuseBlock(config: const HarborEfuseConfig());
      expect(block.read_.width, equals(1));
    });

    test('has program output', () {
      final block = HarborEfuseBlock(config: const HarborEfuseConfig());
      expect(block.pgm.width, equals(1));
    });

    test('has rdata input', () {
      final block = HarborEfuseBlock(config: const HarborEfuseConfig());
      expect(block.rdata.width, equals(32));
    });

    test('has done input', () {
      final block = HarborEfuseBlock(config: const HarborEfuseConfig());
      expect(block.done.width, equals(1));
    });

    test('has busy output', () {
      final block = HarborEfuseBlock(config: const HarborEfuseConfig());
      expect(block.output('busy').width, equals(1));
    });
  });

  group('HarborEfuseDevice', () {
    test('creates with config', () {
      final device = HarborEfuseDevice(baseAddress: 0x20000000);
      expect(device.config.totalBits, equals(256));
    });

    test('has bus', () {
      final device = HarborEfuseDevice(baseAddress: 0x20000000);
      expect(device.bus, isNotNull);
    });

    test('has interrupt output', () {
      final device = HarborEfuseDevice(baseAddress: 0x20000000);
      expect(device.interrupt.width, equals(1));
    });

    test('has fuse_addr output', () {
      final device = HarborEfuseDevice(baseAddress: 0x20000000);
      expect(device.output('fuse_addr').width, greaterThan(0));
    });

    test('has fuse_read output', () {
      final device = HarborEfuseDevice(baseAddress: 0x20000000);
      expect(device.output('fuse_read').width, equals(1));
    });

    test('has fuse_pgm output', () {
      final device = HarborEfuseDevice(baseAddress: 0x20000000);
      expect(device.output('fuse_pgm').width, equals(1));
    });

    test('DT node has correct compatible', () {
      final device = HarborEfuseDevice(baseAddress: 0x20000000);
      final dt = device.dtNode;
      expect(dt.compatible, contains('harbor,efuse'));
      expect(dt.compatible, contains('harbor,otp'));
    });

    test('DT node has correct properties', () {
      final device = HarborEfuseDevice(baseAddress: 0x20000000);
      final dt = device.dtNode;
      expect(dt.properties['harbor,total-bits'], equals(256));
      expect(dt.properties['harbor,bits-per-word'], equals(32));
      expect(dt.properties['harbor,regions'], equals(4));
      expect(dt.properties['harbor,unlock-key'], equals(0x4F545021));
    });

    test('custom unlock key works', () {
      final device = HarborEfuseDevice(
        baseAddress: 0x20000000,
        programUnlockKey: 0xDEADBEEF,
      );
      expect(device.programUnlockKey, equals(0xDEADBEEF));
      expect(device.dtNode.properties['harbor,unlock-key'], equals(0xDEADBEEF));
    });

    test('two different parameter sets get different definition names', () {
      final a = HarborEfuseDevice(baseAddress: 0x20000000);
      final b = HarborEfuseDevice(
        baseAddress: 0x20000000,
        config: const HarborEfuseConfig(totalBits: 512),
      );
      expect(a.definitionName, isNot(equals(b.definitionName)));

      final c = HarborEfuseDevice(
        baseAddress: 0x20000000,
        programUnlockKey: 0xDEADBEEF,
      );
      expect(a.definitionName, isNot(equals(c.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    _registerTests(kind);
  }
}

void _registerTests(HarborFabricKind kind) {
  group('HarborEfuseDevice register access (${kind.name})', () {
    late HarborEfuseDevice device;
    late Logic clk, reset;
    late RegBus bus;

    Future<void> setUpDut() async {
      device = HarborEfuseDevice(baseAddress: 0x20000000, fabricKind: kind);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');

      device.input('clk').srcConnection! <= clk;
      device.input('reset').srcConnection! <= reset;
      device.input('fuse_rdata').srcConnection! <=
          Const(0, width: device.config.bitsPerWord);
      device.input('fuse_done').srcConnection! <= Const(0);
      bus = RegBus.attach(device, clk);

      await device.build();

      reset.inject(1);
      bus.idle();
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

      // ADDR is only config.words.bitLength wide (4 bits for the default
      // config), so its readback is the low nibble of the written word.
      await bus.write(_addr, 0x5);
      await bus.write(_wdata, 0x55667788);
      await bus.write(_timing, 0x0099);

      await bus.write(_addr, 0xffffffff, sel: 0x0);
      await bus.write(_wdata, 0xffffffff, sel: 0x0);
      await bus.write(_timing, 0xffffffff, sel: 0x0);
      await bus.write(_ctrl, 0x3, sel: 0x0);

      expect(await bus.read(_addr), equals(0x5));
      expect(await bus.read(_wdata), equals(0x55667788));
      expect(await bus.read(_timing), equals(0x0099));
      await Simulator.endSimulation();
    });
  });
}

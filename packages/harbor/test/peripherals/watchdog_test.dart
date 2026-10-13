import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// Register byte offsets: each register in its own 8-byte slot.
const _ctrl = 0x00;
const _timeout = 0x10;
const _window = 0x18;
const _kick = 0x20;

void main() {
  group('HarborWatchdog', () {
    test('creates with correct outputs', () {
      final wdt = HarborWatchdog(baseAddress: 0x10005000);
      expect(wdt.bus, isNotNull);
      expect(wdt.resetOut.width, equals(1));
      expect(wdt.interrupt.width, equals(1));
    });

    test('kick magic value', () {
      expect(HarborWatchdog.kickMagic, equals(0x4B494B));
    });

    test('DT node', () {
      final wdt = HarborWatchdog(baseAddress: 0x10005000);
      final dt = wdt.dtNode;
      expect(dt.compatible.first, equals('harbor,watchdog'));
      expect(dt.reg.start, equals(0x10005000));
    });

    test('supports both protocols', () {
      final wb = HarborWatchdog(
        baseAddress: 0x1000,
        fabricKind: HarborFabricKind.wishbone,
      );
      final tl = HarborWatchdog(
        baseAddress: 0x1000,
        fabricKind: HarborFabricKind.tilelink,
      );
      expect(wb.bus.kind, equals(HarborFabricKind.wishbone));
      expect(tl.bus.kind, equals(HarborFabricKind.tilelink));
    });

    test('different counter widths get different definition names', () {
      final a = HarborWatchdog(baseAddress: 0x1000, counterWidth: 32);
      final b = HarborWatchdog(baseAddress: 0x1000, counterWidth: 16);
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    registerTests(kind);
  }
}

void registerTests(HarborFabricKind kind) {
  group('HarborWatchdog register access (${kind.name})', () {
    late HarborWatchdog wdt;
    late Logic clk, reset;
    late RegBus bus;

    Future<void> setUpDut() async {
      wdt = HarborWatchdog(baseAddress: 0x10005000, fabricKind: kind);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');

      wdt.input('clk').srcConnection! <= clk;
      wdt.input('reset').srcConnection! <= reset;
      bus = RegBus.attach(wdt, clk);

      await wdt.build();

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

    test('TIMEOUT and WINDOW read back what was written', () async {
      await setUpDut();

      await bus.write(_timeout, 0x1234);
      expect(await bus.read(_timeout), equals(0x1234));

      await bus.write(_window, 0x5678);
      expect(await bus.read(_window), equals(0x5678));
      await Simulator.endSimulation();
    });

    test('KICK with the magic value resets the counter', () async {
      await setUpDut();

      await bus.write(_ctrl, 0x1); // enable
      await bus.write(_timeout, 1000);
      for (var i = 0; i < 20; i++) {
        await clk.nextPosedge;
      }
      await bus.write(_kick, HarborWatchdog.kickMagic);
      final status = await bus.read(0x08);
      expect(status & 0x2, equals(0), reason: 'expired should still be low');
      await Simulator.endSimulation();
    });

    // A write with no byte selected must not change any register, including
    // the KICK side effect.
    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      await bus.write(_timeout, 0x1234);
      await bus.write(_window, 0x5678);
      await bus.write(_timeout, 0xffffffff, sel: 0x0);
      await bus.write(_window, 0xffffffff, sel: 0x0);
      await bus.write(_kick, HarborWatchdog.kickMagic, sel: 0x0);

      expect(await bus.read(_timeout), equals(0x1234));
      expect(await bus.read(_window), equals(0x5678));
      await Simulator.endSimulation();
    });
  });
}

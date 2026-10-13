import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

void main() {
  group('HarborPwmTimer', () {
    test('creates with default channels', () {
      final pwm = HarborPwmTimer(baseAddress: 0x10004000);
      expect(pwm.bus, isNotNull);
      expect(pwm.channels, equals(4));
      expect(pwm.pwmOut, hasLength(4));
    });

    test('creates with custom channel count', () {
      final pwm = HarborPwmTimer(baseAddress: 0x10004000, channels: 8);
      expect(pwm.pwmOut, hasLength(8));
    });

    test('DT node', () {
      final pwm = HarborPwmTimer(baseAddress: 0x10004000, channels: 2);
      final dt = pwm.dtNode;
      expect(dt.compatible.first, equals('harbor,pwm-timer'));
      expect(dt.properties['num-channels'], equals(2));
    });

    test('interrupt output exists', () {
      final pwm = HarborPwmTimer(baseAddress: 0x10004000);
      expect(pwm.interrupt.width, equals(1));
    });

    test('different channel counts get different definition names', () {
      final a = HarborPwmTimer(baseAddress: 0x10004000, channels: 4);
      final b = HarborPwmTimer(baseAddress: 0x10004000, channels: 8);
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    registerTests(kind);
  }
}

void registerTests(HarborFabricKind kind) {
  group('HarborPwmTimer register access (${kind.name})', () {
    late HarborPwmTimer pwm;
    late Logic clk, reset;
    late RegBus bus;

    Future<void> setUpDut() async {
      pwm = HarborPwmTimer(
        baseAddress: 0x10004000,
        channels: 2,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');

      pwm.input('clk').srcConnection! <= clk;
      pwm.input('reset').srcConnection! <= reset;
      bus = RegBus.attach(pwm, clk);

      await pwm.build();

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

    test('channel COMPARE and DUTY read back what was written', () async {
      await setUpDut();

      // Channel 0: COMPARE at 0x20+0x10, DUTY at 0x20+0x18.
      await bus.write(0x30, 1000);
      expect(await bus.read(0x30), equals(1000));

      await bus.write(0x38, 500);
      expect(await bus.read(0x38), equals(500));
      await Simulator.endSimulation();
    });

    // A write with no byte selected must not change the global registers or
    // any per-channel register.
    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      await bus.write(0x30, 1000);
      await bus.write(0x38, 500);
      await bus.write(0x30, 0xffffffff, sel: 0x0);
      await bus.write(0x38, 0xffffffff, sel: 0x0);

      expect(await bus.read(0x30), equals(1000));
      expect(await bus.read(0x38), equals(500));
      await Simulator.endSimulation();
    });
  });
}

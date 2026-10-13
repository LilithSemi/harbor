import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final kind in HarborFabricKind.values) {
    sensorTests(kind);
  }
}

void sensorTests(HarborFabricKind kind) {
  group('Temperature sensor sim (${kind.name})', () {
    late HarborTemperatureSensor temp;
    late Logic clk, reset;
    late RegBus bus;

    Future<void> setUpDut() async {
      temp = HarborTemperatureSensor(baseAddress: 0x13000, fabricKind: kind);
      temp.port('temp_raw_in').getsLogic(Const(0, width: 12));
      temp.port('temp_valid_in').getsLogic(Const(0));

      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      temp.input('clk').srcConnection! <= clk;
      temp.input('reset').srcConnection! <= reset;
      bus = RegBus.attach(temp, clk);

      await temp.build();

      reset.inject(1);
      bus.idle();
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    test('write CTRL enable+continuous and read back', () async {
      await setUpDut();

      // CTRL byte offset 0x00: bit 0=enable, bit 1=continuous
      await bus.write(0x00, 0x03);
      final val = await bus.read(0x00);
      expect(val & 0x03, equals(0x03));

      await Simulator.endSimulation();
    });

    test('write ALARM_HI and read back', () async {
      await setUpDut();

      // ALARM_HI byte offset 0x20
      await bus.write(0x20, 95000);
      final val = await bus.read(0x20);
      expect(val, equals(95000));

      await Simulator.endSimulation();
    });

    test('write ALARM_LO and read back', () async {
      await setUpDut();

      // ALARM_LO byte offset 0x28
      await bus.write(0x28, 10000);
      final val = await bus.read(0x28);
      expect(val, equals(10000));

      await Simulator.endSimulation();
    });

    test('write INT_ENABLE and read back', () async {
      await setUpDut();

      // INT_ENABLE byte offset 0x38
      await bus.write(0x38, 0x07);
      final val = await bus.read(0x38);
      expect(val & 0x07, equals(0x07));

      await Simulator.endSimulation();
    });

    test('read STATUS register', () async {
      await setUpDut();

      // STATUS byte offset 0x08
      final val = await bus.read(0x08);
      // After reset: data_valid=0, over_temp=0
      expect(val & 0x03, equals(0));

      await Simulator.endSimulation();
    });

    // A write with no byte selected must not change any register.
    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      await bus.write(0x20, 95000);
      await bus.write(0x28, 10000);
      await bus.write(0x20, 0xffffffff, sel: 0x0);
      await bus.write(0x28, 0xffffffff, sel: 0x0);

      expect(await bus.read(0x20), equals(95000));
      expect(await bus.read(0x28), equals(10000));

      await Simulator.endSimulation();
    });
  });
}

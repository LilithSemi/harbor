import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

void main() {
  group('HarborAplic', () {
    test('creates with defaults', () {
      final aplic = HarborAplic(baseAddress: 0x0D000000);
      expect(aplic.externalInterrupt, hasLength(1));
      expect(aplic.sourceInterrupt, hasLength(32));
    });

    test('creates with multiple harts', () {
      final aplic = HarborAplic(baseAddress: 0x0D000000, sources: 64, harts: 4);
      expect(aplic.externalInterrupt, hasLength(4));
      expect(aplic.sourceInterrupt, hasLength(64));
    });

    test('has bus interface', () {
      final aplic = HarborAplic(baseAddress: 0x0D000000);
      expect(aplic.bus, isNotNull);
    });

    test('DT node is correct', () {
      final aplic = HarborAplic(baseAddress: 0x0D000000, sources: 128);
      final dt = aplic.dtNode;
      expect(dt.compatible.first, equals('riscv,aplic'));
      expect(dt.interruptController, isTrue);
      expect(dt.interruptCells, equals(2));
    });

    test('different params get different definition names', () {
      final a = HarborAplic(baseAddress: 0x0D000000, sources: 32);
      final b = HarborAplic(baseAddress: 0x0D000000, sources: 64);
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    registerTests(kind);
  }
}

void registerTests(HarborFabricKind kind) {
  group('HarborAplic register access (${kind.name})', () {
    late HarborAplic aplic;
    late Logic clk, reset;
    late RegBus bus;

    Future<void> setUpDut() async {
      aplic = HarborAplic(
        baseAddress: 0x0D000000,
        sources: 4,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');

      aplic.input('clk').srcConnection! <= clk;
      aplic.input('reset').srcConnection! <= reset;
      for (var i = 0; i < 4; i++) {
        aplic.input('src_irq_$i').srcConnection! <= Const(0);
      }
      bus = RegBus.attach(aplic, clk);

      await aplic.build();

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

    test('domaincfg and sourcecfg read back what was written', () async {
      await setUpDut();

      await bus.write(0x0000, 0x1);
      expect(await bus.read(0x0000), equals(0x1));

      await bus.write(0x0004, 0x3ff);
      expect(await bus.read(0x0004), equals(0x3ff));
      await Simulator.endSimulation();
    });

    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      await bus.write(0x0000, 0x1);
      await bus.write(0x0004, 0x100);
      await bus.write(0x0000, 0xff, sel: 0x0);
      await bus.write(0x0004, 0xff, sel: 0x0);

      expect(await bus.read(0x0000), equals(0x1));
      expect(await bus.read(0x0004), equals(0x100));
      await Simulator.endSimulation();
    });
  });
}

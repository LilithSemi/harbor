import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

/// Raises source 1, then claims and completes it. Returns the cycles from
/// the raise to the interrupt, and from the claim read to the drop.
Future<(int, int)> _irqLatency({required bool registered}) async {
  final src = Logic(name: 'src')..put(0);
  final plic = HarborPlic(
    baseAddress: 0x9000,
    sources: 4,
    registeredOutput: registered,
  );
  plic.port('src_irq_1').getsLogic(src);
  for (final i in [0, 2, 3]) {
    plic.port('src_irq_$i').getsLogic(Const(0));
  }
  final tb = PeripheralTestBench(plic);
  await tb.init();
  await tb.write(4, 1);
  await tb.write(0x2000, 2);
  await tb.waitCycles(3);
  expect(plic.externalInterrupt[0].value.toInt(), 0);

  src.put(1);
  var raise = 0;
  while (plic.externalInterrupt[0].value.toInt() == 0 && raise < 10) {
    await tb.clk.nextPosedge;
    raise++;
  }
  src.put(0);
  await tb.waitCycles(3);
  expect(plic.externalInterrupt[0].value.toInt(), 1);

  tb.input('cyc').put(1);
  tb.input('stb').put(1);
  tb.input('we').put(0);
  tb.input('adr').put(0x200004);
  while (!(tb.ack.value.isValid && tb.ack.value.toInt() == 1)) {
    await tb.clk.nextPosedge;
  }
  expect(tb.datIn.value.toInt(), 1, reason: 'claim returns source 1');
  tb.input('cyc').put(0);
  tb.input('stb').put(0);
  var drop = 0;
  while (plic.externalInterrupt[0].value.toInt() == 1 && drop < 10) {
    await tb.clk.nextPosedge;
    drop++;
  }
  expect(plic.externalInterrupt[0].value.toInt(), 0);

  await tb.write(0x200004, 1);
  await tb.waitCycles(4);
  expect(plic.externalInterrupt[0].value.toInt(), 0, reason: 'completed');
  await Simulator.endSimulation();
  return (raise, drop);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('PLIC registered output', () {
    test('rises and drops one cycle later than the default', () async {
      final plain = await _irqLatency(registered: false);
      await Simulator.reset();
      final reg = await _irqLatency(registered: true);
      expect(plain, (1, 0), reason: 'default raise and drop');
      expect(reg, (2, 1), reason: 'registered raise and drop');
      expect(reg.$1, plain.$1 + 1, reason: 'raise');
      expect(reg.$2, plain.$2 + 1, reason: 'drop after claim');
    });
  });

  group('PLIC sim', () {
    test('write source priority and read back', () async {
      final plic = HarborPlic(baseAddress: 0x9000, sources: 4, contexts: 1);
      for (var i = 0; i < 4; i++) {
        plic.port('src_irq_$i').getsLogic(Const(0));
      }

      final tb = PeripheralTestBench(plic);
      await tb.init();

      // Source 1 priority at byte addr 4 (source*4)
      await tb.write(4, 5);
      final val = await tb.read(4);
      expect(val, equals(5));

      await Simulator.endSimulation();
    });

    test('no interrupt when all sources low', () async {
      final plic = HarborPlic(baseAddress: 0x9000, sources: 4, contexts: 1);
      for (var i = 0; i < 4; i++) {
        plic.port('src_irq_$i').getsLogic(Const(0));
      }

      final tb = PeripheralTestBench(plic);
      await tb.init();

      await tb.waitCycles(5);
      expect(plic.externalInterrupt[0].value.toInt(), equals(0));

      await Simulator.endSimulation();
    });

    test('write enable register and read back', () async {
      final plic = HarborPlic(baseAddress: 0x9000, sources: 4, contexts: 1);
      for (var i = 0; i < 4; i++) {
        plic.port('src_irq_$i').getsLogic(Const(0));
      }

      final tb = PeripheralTestBench(plic);
      await tb.init();

      // Enable register for context 0 at byte addr 0x2000
      // Enable sources 0 and 2 (bits 0 and 2)
      await tb.write(0x2000, 0x05);
      final val = await tb.read(0x2000);
      expect(val & 0x0F, equals(0x05));

      await Simulator.endSimulation();
    });

    test('write threshold and read back', () async {
      final plic = HarborPlic(baseAddress: 0x9000, sources: 4, contexts: 1);
      for (var i = 0; i < 4; i++) {
        plic.port('src_irq_$i').getsLogic(Const(0));
      }

      final tb = PeripheralTestBench(plic);
      await tb.init();

      // Threshold for context 0 at byte addr 0x200000
      await tb.write(0x200000, 3);
      final val = await tb.read(0x200000);
      expect(val, equals(3));

      await Simulator.endSimulation();
    });
  });
}

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UART sim', () {
    test('set DLAB in LCR', () async {
      final uart = HarborUart(baseAddress: 0x4000);
      uart.port('rx').getsLogic(Const(1));

      final tb = PeripheralTestBench(uart);
      await tb.init();

      // LCR is word addr 3, set DLAB bit (bit 7)
      await tb.write(3, 0x80);
      final val = await tb.read(3);
      expect(val & 0x80, equals(0x80));

      await Simulator.endSimulation();
    });

    test('an address above the registers does not alias one', () async {
      final uart = HarborUart(baseAddress: 0x4000);
      uart.port('rx').getsLogic(Const(1));

      final tb = PeripheralTestBench(uart);
      await tb.init();

      // 0x103 would alias LCR at 3 with a 3-bit decode.
      await tb.write(0x103, 0x80);
      expect(await tb.read(3) & 0x80, equals(0));
      expect(await tb.read(0x103), equals(0));

      await Simulator.endSimulation();
    });

    test('write baud divisor via DLL when DLAB set', () async {
      final uart = HarborUart(baseAddress: 0x4000);
      uart.port('rx').getsLogic(Const(1));

      final tb = PeripheralTestBench(uart);
      await tb.init();

      // Set DLAB
      await tb.write(3, 0x80);

      // Write DLL (word addr 0 when DLAB=1)
      await tb.write(0, 0x1A);
      final val = await tb.read(0);
      expect(val, equals(0x1A));

      await Simulator.endSimulation();
    });

    test('set 8N1 line control', () async {
      final uart = HarborUart(baseAddress: 0x4000);
      uart.port('rx').getsLogic(Const(1));

      final tb = PeripheralTestBench(uart);
      await tb.init();

      // LCR word addr 3, 0x03 = 8N1 (8 data bits, no parity, 1 stop)
      await tb.write(3, 0x03);
      final val = await tb.read(3);
      expect(val & 0x3F, equals(0x03));

      await Simulator.endSimulation();
    });

    test('TX pin idles high after reset', () async {
      final uart = HarborUart(baseAddress: 0x4000);
      uart.port('rx').getsLogic(Const(1));

      final tb = PeripheralTestBench(uart);
      await tb.init();

      await tb.waitCycles(2);
      expect(uart.tx.value.toInt(), equals(1));

      await Simulator.endSimulation();
    });

    test('TX goes low (start bit) after writing to THR', () async {
      final uart = HarborUart(baseAddress: 0x4000);
      uart.port('rx').getsLogic(Const(1));

      final tb = PeripheralTestBench(uart);
      await tb.init();

      // Ensure DLAB is clear (write 8N1 to LCR)
      await tb.write(3, 0x03);

      // Write THR (word addr 0 when DLAB=0)
      await tb.write(0, 0x55);

      // Wait for TX to start shifting: start bit is low
      var sawLow = false;
      for (var i = 0; i < 100; i++) {
        await tb.waitCycles(1);
        if (uart.tx.value.isValid && uart.tx.value.toInt() == 0) {
          sawLow = true;
          break;
        }
      }
      expect(sawLow, isTrue, reason: 'TX should go low for start bit');

      await Simulator.endSimulation();
    });
  });
}

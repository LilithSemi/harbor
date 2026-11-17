import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/uart_dut.dart';

// Register indexes.
const _rbr = 0, _thr = 0, _ier = 1, _iir = 2, _fcr = 2;
const _mcr = 4, _lsr = 5, _msr = 6, _scr = 7;

// Plays the startup of drivers/tty/serial/8250/8250_port.c against the UART.
// [fifo] is the FCR value the driver writes to enable the FIFOs, or 0.
Future<void> _linuxSequence(UartDut d, {required bool fifo}) async {
  // Scratch register test of autoconfig.
  await d.write(_scr, 0xa5);
  expect(await d.read(_scr), equals(0xa5));
  await d.write(_scr, 0x5a);
  expect(await d.read(_scr), equals(0x5a));

  // IER existence test.
  await d.write(_ier, 0);
  expect(await d.read(_ier) & 0x0f, equals(0));
  await d.write(_ier, 0x0f);
  expect(await d.read(_ier) & 0x0f, equals(0x0f));
  await d.write(_ier, 0);
  expect(await d.irq(), isFalse);

  // FIFO detection.
  await d.write(_fcr, fifo ? 0x01 : 0x00);
  expect(await d.read(_iir) >> 6, equals(fifo ? 3 : 0));
  await d.write(_fcr, fifo ? 0x07 : 0x00);
  await d.write(_fcr, fifo ? 0x01 : 0x00);

  // Clear stale state.
  await d.read(_lsr);
  await d.read(_rbr);
  await d.read(_iir);
  await d.read(_msr);

  // Line setup: divisor, 8N1, OUT2.
  await d.setDivisor(1);
  await d.write(_mcr, 0x08);
  expect(await d.irq(), isFalse);

  // IER = RDI | RLSI with nothing pending.
  await d.write(_ier, 0x05);
  expect(await d.irq(), isFalse);
  expect(await d.read(_iir) & 0x0f, equals(0x01));

  // THRE probe: enabling THRI with an empty transmitter raises the
  // interrupt once and an IIR read clears it.
  await d.write(_ier, 0);
  await d.write(_ier, 0x02);
  expect(await d.read(_lsr) & 0x60, equals(0x60));
  expect(await d.irq(), isTrue);
  expect(await d.read(_iir) & 0x0f, equals(0x02));
  expect(await d.irq(), isFalse);
  expect(await d.read(_iir) & 0x0f, equals(0x01));
  await d.write(_ier, 0);
  expect(await d.irq(), isFalse);
  // Enabling again raises it again.
  await d.write(_ier, 0x02);
  expect(await d.irq(), isTrue);
  await d.write(_ier, 0);
  expect(await d.irq(), isFalse);

  // Transmit loop driven by the THRE interrupt.
  const total = 48;
  final perService = fifo ? 16 : 1;
  final expected = [for (var i = 0; i < total; i++) (i * 7 + 3) & 0xff];
  final collected = d.collectTx(total);
  await d.write(_ier, 0x03);
  var sent = 0;
  while (sent < total) {
    expect(await d.waitIrq(), isTrue, reason: 'THRE interrupt at byte $sent');
    final iir = await d.read(_iir);
    expect(iir & 0x0f, equals(0x02));
    expect(iir >> 6, equals(fifo ? 3 : 0));
    expect(await d.irq(), isFalse, reason: 'IIR read drops the line');
    for (var i = 0; i < perService && sent < total; i++) {
      await d.write(_thr, expected[sent++]);
    }
    expect(await d.irq(), isFalse, reason: 'THR write holds the line low');
  }
  // The last THRE interrupt: service it and stop the transmitter.
  expect(await d.waitIrq(), isTrue);
  expect(await d.read(_iir) & 0x0f, equals(0x02));
  expect(await d.irq(), isFalse);
  await d.write(_ier, 0x01);
  expect(await d.irq(), isFalse);
  expect(await collected, equals(expected));

  // IER = 0 keeps the line low with a transmitter that is empty.
  await d.write(_ier, 0);
  expect(await d.irq(), isFalse);
  await d.wait(200);
  expect(await d.irq(), isFalse);
  expect(await d.read(_iir) & 0x0f, equals(0x01));
  expect(await d.read(_lsr) & 0x60, equals(0x60));
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // The transmitter stays gated while the divisor is 0. The byte waits in
  // the holding register with the line idle, and goes out once a divisor is set.
  test(
    'a THR write with divisor 0 sends nothing until a divisor is set',
    () async {
      final d = await UartDut.start();
      await d.write(3, 0x83);
      await d.write(0, 0);
      await d.write(1, 0);
      await d.write(3, 0x03);
      await d.write(_thr, 0xa5);
      for (var i = 0; i < 3000; i++) {
        await d.clk.nextNegedge;
        expect(d.uart.tx.value.toInt(), equals(1));
      }
      expect(await d.read(_lsr) & 0x60, equals(0), reason: 'byte waits');
      final out = d.collectTx(1, maxCycles: 16 + 100);
      await d.setDivisor(1);
      expect(await out, equals([0xa5]), reason: 'goes out within a frame');
      await Simulator.endSimulation();
    },
  );

  // Linux programs the divisor as uartclk / (16 * baud), rounded to the
  // nearest integer, with uartclk from the clock-frequency property.
  test(
    'divisor from clock-frequency gives the bit period of 115200 baud',
    () async {
      const clock = 48000000;
      final d = await UartDut.start(clockFrequency: clock);
      final hz = d.uart.dtNode.properties['clock-frequency']! as int;
      expect(hz, equals(clock));
      final divisor = (hz / (16 * 115200)).round();
      expect(divisor, equals(26));
      await d.setDivisor(divisor);
      await d.write(_thr, 0x55);
      await d.clk.nextNegedge;
      var guard = 0;
      // The byte loads on the next baud tick, so the start bit begins
      // within one divisor period.
      while (d.uart.tx.value.toInt() == 1 && guard++ < divisor + 4) {
        await d.clk.nextNegedge;
      }
      expect(guard < divisor + 4, isTrue);
      // 0x55 sends bit 0 high, so the start bit is the first low run.
      var low = 0;
      while (d.uart.tx.value.toInt() == 0 && low < 2000) {
        low++;
        await d.clk.nextNegedge;
      }
      expect(low, equals(16 * divisor));
      await Simulator.endSimulation();
    },
  );

  test('serial8250 startup and THRE-driven transmit in 16450 mode', () async {
    final d = await UartDut.start();
    await _linuxSequence(d, fifo: false);
    await Simulator.endSimulation();
  });
}

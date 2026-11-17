import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/uart_dut.dart';

const _rbr = 0, _thr = 0, _ier = 1, _iir = 2, _fcr = 2;
const _mcr = 4, _lsr = 5, _msr = 6;

// FCR bits 7:6 for the RX trigger levels 1, 4, 8 and 14.
const _triggers = {1: 0x00, 4: 0x40, 8: 0x80, 14: 0xc0};

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('FCR enable bit sets IIR 7:6, and FIFOs off reads 00', () async {
    final d = await UartDut.start();
    expect(await d.read(_iir) >> 6, equals(0));
    await d.write(_fcr, 0x01);
    expect(await d.read(_iir) >> 6, equals(3));
    await d.write(_fcr, 0xc1);
    expect(await d.read(_iir), equals(0xc1));
    await d.write(_fcr, 0x00);
    expect(await d.read(_iir), equals(0x01));
    // Bit 5 of FCR (64 byte FIFO of the 16750) does not exist.
    await d.write(_fcr, 0x21);
    expect(await d.read(_iir) & 0x20, equals(0));
    await Simulator.endSimulation();
  });

  test('16 byte TX burst leaves in order at a slow baud', () async {
    final d = await UartDut.start();
    await d.setDivisor(4);
    await d.write(_fcr, 0x01);
    final data = [for (var i = 0; i < 16; i++) 0xa0 + i * 3];
    final out = d.collectTx(16);
    for (final b in data) {
      await d.write(_thr, b);
    }
    expect(await d.read(_lsr) & 0x60, equals(0));
    expect(await out, equals(data));
    await d.wait(200);
    expect(await d.read(_lsr) & 0x60, equals(0x60));
    await Simulator.endSimulation();
  });

  test(
    'THRE is set when the FIFO empties and TEMT after the shifter',
    () async {
      final d = await UartDut.start();
      await d.setDivisor(4);
      await d.write(_fcr, 0x01);
      await d.write(_thr, 0x55);
      await d.write(_thr, 0x66);
      await d.wait(1400);
      // Byte one is on the wire, byte two is in the shifter or the FIFO.
      var guard = 0;
      while (await d.read(_lsr) & 0x20 == 0 && guard++ < 200) {
        await d.wait(10);
      }
      expect(guard < 200, isTrue);
      await d.wait(2500);
      expect(await d.read(_lsr) & 0x60, equals(0x60));
      await Simulator.endSimulation();
    },
  );

  for (final e in _triggers.entries) {
    test('RX trigger level ${e.key}', () async {
      final d = await UartDut.start();
      await d.setDivisor(1);
      await d.write(_fcr, 0x01 | e.value);
      await d.write(_ier, 0x01);
      final data = [for (var i = 0; i < e.key; i++) 0x30 + i];
      for (var i = 0; i < e.key - 1; i++) {
        await d.sendByte(data[i]);
      }
      expect(await d.irq(), isFalse, reason: 'below the trigger');
      expect(await d.read(_lsr) & 1, equals(e.key > 1 ? 1 : 0));
      await d.sendByte(data.last);
      expect(await d.irq(), isTrue, reason: 'at the trigger');
      expect(await d.read(_iir), equals(0xc4));
      // Reading below the trigger drops the line.
      expect(await d.read(_rbr), equals(data.first));
      if (e.key > 1) {
        expect(await d.irq(), isFalse, reason: 'one byte below the trigger');
        for (var i = 1; i < e.key; i++) {
          expect(await d.read(_rbr), equals(data[i]));
        }
      }
      expect(await d.read(_lsr) & 1, equals(0));
      await Simulator.endSimulation();
    });
  }

  test('character timeout interrupt after four character times', () async {
    final d = await UartDut.start();
    await d.setDivisor(1);
    await d.write(_fcr, 0xc1);
    await d.write(_ier, 0x01);
    for (var i = 0; i < 3; i++) {
      await d.sendByte(0x41 + i);
    }
    // A character is 10 bits of 16 cycles, so 4 characters are 640 cycles.
    await d.wait(400);
    expect(await d.irq(), isFalse, reason: 'before four character times');
    expect(await d.waitIrq(cycles: 600), isTrue, reason: 'timeout');
    expect(await d.read(_iir), equals(0xcc));
    // A read restarts the timer and drops the line.
    expect(await d.read(_rbr), equals(0x41));
    expect(await d.irq(), isFalse);
    expect(await d.waitIrq(cycles: 1400), isTrue, reason: 'second timeout');
    expect(await d.read(_iir) & 0x0f, equals(0x0c));
    expect(await d.read(_rbr), equals(0x42));
    expect(await d.read(_rbr), equals(0x43));
    // An empty FIFO has no timeout.
    await d.wait(1500);
    expect(await d.irq(), isFalse);
    expect(await d.read(_iir), equals(0xc1));
    await Simulator.endSimulation();
  });

  test('no timeout interrupt with the FIFOs off', () async {
    final d = await UartDut.start();
    await d.setDivisor(1);
    await d.write(_ier, 0x01);
    await d.sendByte(0x41);
    expect(await d.irq(), isTrue);
    expect(await d.read(_iir), equals(0x04));
    await Simulator.endSimulation();
  });

  test('RX overrun sets OE and drops the new byte', () async {
    final d = await UartDut.start();
    await d.setDivisor(1);
    await d.write(_fcr, 0x01);
    await d.write(_ier, 0x04);
    for (var i = 0; i < 17; i++) {
      await d.sendByte(0x80 + i);
    }
    expect(await d.irq(), isTrue);
    expect(await d.read(_iir), equals(0xc6));
    final lsr = await d.read(_lsr);
    expect(lsr & 0x03, equals(0x03), reason: 'DR and OE');
    expect(await d.irq(), isFalse, reason: 'the LSR read clears OE');
    expect(await d.read(_lsr) & 0x02, equals(0));
    for (var i = 0; i < 16; i++) {
      expect(await d.read(_rbr), equals(0x80 + i));
    }
    expect(await d.read(_lsr) & 0x01, equals(0), reason: '17th byte dropped');
    await Simulator.endSimulation();
  });

  test('IIR priorities: line status, data, THRE', () async {
    final d = await UartDut.start();
    await d.setDivisor(1);
    await d.write(_fcr, 0x01);
    for (var i = 0; i < 17; i++) {
      await d.sendByte(i);
    }
    await d.write(_ier, 0x0f);
    expect(await d.read(_iir), equals(0xc6));
    await d.read(_lsr);
    expect(await d.read(_iir), equals(0xc4));
    for (var i = 0; i < 16; i++) {
      await d.read(_rbr);
    }
    expect(await d.read(_iir), equals(0xc2));
    expect(await d.read(_iir), equals(0xc1));
    expect(await d.irq(), isFalse);
    await Simulator.endSimulation();
  });

  test(
    'FIFO resets clear the data and a change of FCR 0 clears both',
    () async {
      final d = await UartDut.start();
      await d.setDivisor(1);
      await d.write(_fcr, 0x01);
      await d.sendByte(0x11);
      await d.sendByte(0x22);
      expect(await d.read(_lsr) & 1, equals(1));
      await d.write(_fcr, 0x03);
      expect(await d.read(_lsr) & 1, equals(0));
      expect(await d.read(_fcr) >> 6, equals(3), reason: 'FIFOs stay on');
      await d.sendByte(0x33);
      expect(await d.read(_rbr), equals(0x33));

      await d.sendByte(0x44);
      await d.write(_fcr, 0x00);
      expect(await d.read(_lsr) & 1, equals(0));
      expect(await d.read(_iir) >> 6, equals(0));

      // A TX reset keeps the byte in the shifter and drops the rest.
      await d.setDivisor(8);
      await d.write(_fcr, 0x01);
      final out = d.collectTx(5, maxCycles: 4000);
      await d.write(_thr, 0xa1);
      await d.wait(20);
      for (var i = 0; i < 4; i++) {
        await d.write(_thr, 0xb0 + i);
      }
      expect(await d.read(_lsr) & 0x20, equals(0));
      await d.write(_fcr, 0x05);
      expect(await d.read(_lsr) & 0x20, equals(0x20));
      expect(await out, equals([0xa1]));
      await Simulator.endSimulation();
    },
  );

  test('16450 mode holds one byte each way', () async {
    final d = await UartDut.start();
    await d.setDivisor(4);
    await d.write(_ier, 0x04);
    await d.sendByte(0x61);
    await d.sendByte(0x62);
    expect(await d.read(_lsr) & 0x03, equals(0x03));
    expect(await d.read(_rbr), equals(0x61));
    expect(await d.read(_lsr) & 0x01, equals(0));
    await d.write(_ier, 0);

    final out = d.collectTx(3, maxCycles: 4000);
    await d.write(_thr, 0x71);
    await d.write(_thr, 0x72);
    await d.write(_thr, 0x73);
    expect(await out, equals([0x71, 0x72]));
    await Simulator.endSimulation();
  });

  test('RX stays framed while TX starts in the middle of the frame', () async {
    final d = await UartDut.start();
    await d.setDivisor(4);
    // The sender is about 1.6% slow: 65 cycles a bit instead of 64.
    Future<void> slowFrame(int byte) async {
      Future<void> bit(int v) async {
        d.rx.inject(v);
        await d.wait(65);
      }

      await bit(0);
      for (var i = 0; i < 8; i++) {
        await bit((byte >> i) & 1);
      }
      await bit(1);
      await d.wait(8);
    }

    // The baud counter runs free, so every sample point of a frame is
    // exactly 16 divisor periods (64 cycles) after the one before it, even
    // when a TX load falls inside the frame.
    final sample = d.uart.signals.firstWhere((s) => s.name == 'rx_sample');
    var cycle = 0;
    final samples = <int>[];
    d.clk.negedge.listen((_) {
      cycle++;
      if (sample.value.isValid && sample.value.toInt() == 1) {
        samples.add(cycle);
      }
    });

    for (final byte in [0xa5, 0x5a, 0xc3]) {
      samples.clear();
      final out = d.collectTx(1, maxCycles: 2000);
      final frame = slowFrame(byte);
      await d.wait(150 + byte % 64);
      await d.write(_thr, byte ^ 0xff);
      await frame;
      expect(await d.read(_lsr) & 0x03, equals(0x01), reason: 'DR, no OE');
      expect(await d.read(_rbr), equals(byte));
      expect(await out, equals([byte ^ 0xff]));
      // Start validation, 8 data bits and the stop bit.
      expect(samples.length, equals(10));
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i] - samples[i - 1], equals(64), reason: 'sample $i');
      }
    }
    await Simulator.endSimulation();
  });

  // A frame that ends in the same cycle as an RBR read that makes room must
  // land in the buffer, with no overrun.
  for (final preload in [(fifo: false, count: 1), (fifo: true, count: 16)]) {
    test('RX push in the cycle of an RBR pop keeps the byte, '
        '${preload.fifo ? 'FIFO full' : '16450'}', () async {
      final d = await UartDut.start();
      await d.setDivisor(1);
      if (preload.fifo) await d.write(_fcr, 0x01);
      final sigs = {for (final s in d.uart.signals) s.name: s};
      var hit = false;
      d.clk.negedge.listen((_) {
        final v = [
          for (final n in ['rx_frame', 'rbr_read', 'rx_has_data'])
            sigs[n]!.value,
        ];
        if (v.every((x) => x.isValid && x.toInt() == 1)) hit = true;
      });
      var coincided = 0;
      for (var delay = 146; delay < 162; delay++) {
        while (await d.read(_lsr) & 1 == 1) {
          await d.read(_rbr);
        }
        for (var i = 0; i < preload.count; i++) {
          await d.sendByte(0xa0 + i);
        }
        hit = false;
        unawaited(() async {
          d.rx.inject(0);
          await d.wait(16);
          for (var i = 0; i < 8; i++) {
            d.rx.inject((0x5b >> i) & 1);
            await d.wait(16);
          }
          d.rx.inject(1);
        }());
        await d.wait(delay);
        final seen = <int>[];
        for (var i = 0; i < preload.count + 3; i++) {
          seen.add(await d.read(_rbr));
        }
        await d.wait(40);
        final lsr = await d.read(_lsr);
        if (hit) {
          coincided++;
          expect(seen, contains(0x5b), reason: 'delay $delay lost the byte');
          expect(lsr & 0x02, equals(0), reason: 'delay $delay set OE');
        }
      }
      expect(coincided, greaterThan(0), reason: 'the sweep never collided');
      await Simulator.endSimulation();
    });
  }

  test('MSR has no modem interrupt and follows MCR in loopback', () async {
    final d = await UartDut.start();
    await d.write(_ier, 0x08);
    expect(await d.read(_msr), equals(0xb0));
    expect(await d.irq(), isFalse);
    // The loopback test of the Linux autoconfig.
    await d.write(_mcr, 0x1a);
    expect(await d.read(_msr) & 0xf0, equals(0x90));
    await d.write(_mcr, 0x00);
    expect(await d.read(_msr), equals(0xb0));
    expect(await d.irq(), isFalse);
    await Simulator.endSimulation();
  });

  for (final fifo in [false, true]) {
    test('loopback returns THR bytes in RBR with FIFOs ${fifo ? 'on' : 'off'},'
        ' holds tx high and ignores rx', () async {
      final d = await UartDut.start(maxSimTime: 8000000);
      await d.setDivisor(2);
      await d.write(_fcr, fifo ? 0x01 : 0x00);
      await d.write(_mcr, 0x10);
      var txLow = 0;
      var watch = true;
      unawaited(() async {
        while (watch) {
          await d.clk.nextNegedge;
          if (d.uart.tx.value.toInt() != 1) txLow++;
        }
      }());
      final data = fifo ? [0xa5, 0x3c, 0x00, 0xff, 0x81] : [0xa5];
      for (final b in data) {
        await d.write(_thr, b);
        if (!fifo) await d.wait(d.cyclesPerBit * 12);
      }
      await d.wait(d.cyclesPerBit * 12 * data.length);
      final got = <int>[];
      for (var i = 0; i < data.length; i++) {
        expect(await d.read(_lsr) & 0x01, equals(1));
        got.add(await d.read(_rbr));
      }
      expect(got, equals(data));
      expect(await d.read(_lsr) & 0x01, equals(0));
      await d.sendByte(0x5a);
      expect(await d.read(_lsr) & 0x01, equals(0));
      watch = false;
      expect(txLow, equals(0));
      await Simulator.endSimulation();
    });
  }

  test('normal TX and RX work again after loopback is cleared', () async {
    final d = await UartDut.start();
    await d.setDivisor(2);
    await d.write(_fcr, 0x01);
    await d.write(_mcr, 0x10);
    await d.write(_thr, 0x42);
    await d.wait(d.cyclesPerBit * 14);
    expect(await d.read(_rbr), equals(0x42));
    await d.write(_mcr, 0x00);
    await d.wait(d.cyclesPerBit * 4);
    expect(await d.read(_lsr) & 0x01, equals(0));
    final out = d.collectTx(1);
    await d.write(_thr, 0x99);
    expect(await out, equals([0x99]));
    await d.sendByte(0x2d);
    expect(await d.read(_lsr) & 0x01, equals(1));
    expect(await d.read(_rbr), equals(0x2d));
    await Simulator.endSimulation();
  });
}

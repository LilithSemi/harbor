import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

void main() {
  group('HarborUart', () {
    test('creates with defaults', () {
      final uart = HarborUart(baseAddress: 0x10000000);
      expect(uart.tx.width, equals(1));
      expect(uart.interrupt.width, equals(1));
    });

    test('has bus interface', () {
      final uart = HarborUart(baseAddress: 0x10000000);
      expect(uart.bus, isNotNull);
    });

    test('clock frequency in DT properties', () {
      final uart = HarborUart(
        baseAddress: 0x10000000,
        clockFrequency: 48000000,
      );
      expect(uart.dtNode.properties['clock-frequency'], equals(48000000));
    });

    test('no clock frequency when zero', () {
      final uart = HarborUart(baseAddress: 0x10000000);
      expect(uart.dtNode.properties.containsKey('clock-frequency'), isFalse);
    });

    test('DT node is correct', () {
      final uart = HarborUart(baseAddress: 0x10000000);
      final dt = uart.dtNode;
      expect(dt.compatible.first, equals('ns16550a'));
      expect(dt.reg.start, equals(0x10000000));
      expect(dt.reg.size, equals(0x1000));
    });

    test('different data widths get different definition names', () {
      final a = HarborUart(baseAddress: 0x10000000, busDataWidth: 8);
      final b = HarborUart(baseAddress: 0x10000000, busDataWidth: 32);
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    registerTests(kind);
  }
}

void registerTests(HarborFabricKind kind) {
  group('HarborUart register access (${kind.name})', () {
    late HarborUart uart;
    late Logic clk, reset, rx;
    late RegBus bus;

    Future<void> setUpDut() async {
      // The ns16550a default: a byte-wide bus, every register at its own
      // byte address with no lane sharing to account for.
      uart = HarborUart(baseAddress: 0x10000000, fabricKind: kind);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      rx = Logic(name: 'rx');

      uart.input('clk').srcConnection! <= clk;
      uart.input('reset').srcConnection! <= reset;
      uart.input('rx').srcConnection! <= rx;
      bus = RegBus.attach(uart, clk);

      await uart.build();

      reset.inject(1);
      bus.idle();
      rx.inject(1);
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

    test('LCR and SCR read back what was written', () async {
      await setUpDut();

      await bus.write(0x3, 0x03);
      expect(await bus.read(0x3), equals(0x03));

      await bus.write(0x7, 0xaa);
      expect(await bus.read(0x7), equals(0xaa));
      await Simulator.endSimulation();
    });

    // A write with no byte selected (AXI4 WSTRB 0) must not change any
    // register, including defaulting to lane 0 of a wide bus.
    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      await bus.write(0x3, 0x03);
      await bus.write(0x4, 0x55);
      await bus.write(0x3, 0xff, sel: 0x0);
      await bus.write(0x4, 0xff, sel: 0x0);

      expect(await bus.read(0x3), equals(0x03));
      expect(await bus.read(0x4), equals(0x55));
      await Simulator.endSimulation();
    });

    // On a wide bus every UART register lands in one access and the RBR
    // pop is gated by SEL bit 0 (see HarborUart), so a read of any other
    // register in that word must leave a pending byte untouched.
    test('RBR pop is gated by its own lane on a 64-bit bus', () async {
      uart = HarborUart(
        baseAddress: 0x10000000,
        fabricKind: kind,
        busDataWidth: 64,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      rx = Logic(name: 'rx');

      uart.input('clk').srcConnection! <= clk;
      uart.input('reset').srcConnection! <= reset;
      uart.input('rx').srcConnection! <= rx;
      bus = RegBus.attach(uart, clk);

      await uart.build();

      reset.inject(1);
      bus.idle();
      rx.inject(1);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Send one byte on RX at the default (divisor = 1) bit rate: two
      // cycles low for the start bit, then each data bit for one cycle,
      // LSB first, then the stop bit.
      const sent = 0xA5;
      rx.inject(0);
      await clk.nextPosedge;
      await clk.nextPosedge;
      for (var i = 0; i < 8; i++) {
        rx.inject((sent >> i) & 1);
        await clk.nextPosedge;
      }
      rx.inject(1);
      await clk.nextPosedge;
      await clk.nextPosedge;

      // Poll LSR (byte 5, bit 40 of the word) until data-ready, reading
      // only its own lane so this does not touch RBR.
      var ready = false;
      for (var i = 0; i < 50 && !ready; i++) {
        final word = await bus.read(0, sel: 0x20);
        ready = (word >> 40) & 1 == 1;
        if (!ready) await clk.nextPosedge;
      }
      expect(ready, isTrue, reason: 'LSR data-ready should assert');

      // Reading LSR again must not have popped RBR.
      final still = await bus.read(0, sel: 0x20);
      expect((still >> 40) & 1, equals(1));

      // Reading RBR (lane 0) pops it and returns the byte.
      final rbr = await bus.read(0, sel: 0x01);
      expect(rbr & 0xff, equals(sent));

      // LSR now shows no data ready.
      final after = await bus.read(0, sel: 0x20);
      expect((after >> 40) & 1, equals(0));

      await Simulator.endSimulation();
    });
  });
}

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register byte offsets within the 8-byte window.
const _rbr = 0x00;
const _iir = 0x02;
const _lcr = 0x03;
const _lsr = 0x05;

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
  });

  group('HarborUart RBR pop only on its byte lane', () {
    late HarborUart uart;
    late Logic clk, stb, we, adr, mosi, sel, rxPin;
    late int lanes;

    // Baud divisor used for every test. Slow enough to clear the 2-cycle RX
    // input synchronizer with margin.
    const cyclesPerBit = 4;

    Future<void> busWrite(int addr, int data, int selMask) async {
      adr.inject(addr);
      mosi.inject(data);
      sel.inject(selMask);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (uart.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    // Reads the bus word at [addr] with [selMask] and returns the byte in
    // [lane].
    Future<int> busReadByte(int addr, int selMask, int lane) async {
      adr.inject(addr);
      sel.inject(selMask);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (uart.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final word = uart.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return (word >> (8 * lane)) & 0xff;
    }

    // Sends one byte on the RX pin, 8N1, LSB first, at [cyclesPerBit] cycles
    // per bit.
    Future<void> sendByte(int value) async {
      Future<void> hold(int level) async {
        rxPin.inject(level);
        for (var i = 0; i < cyclesPerBit; i++) {
          await clk.nextPosedge;
        }
      }

      await hold(0); // start bit
      for (var i = 0; i < 8; i++) {
        await hold((value >> i) & 1);
      }
      await hold(1); // stop bit
      // Margin for the receiver to land the byte and raise data-ready.
      for (var i = 0; i < cyclesPerBit * 3; i++) {
        await clk.nextPosedge;
      }
    }

    Future<void> setUpDut(int dataWidth) async {
      lanes = dataWidth ~/ 8;
      uart = HarborUart(baseAddress: 0x10000000, busDataWidth: dataWidth);
      clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 12);
      mosi = Logic(name: 'mosi', width: dataWidth);
      sel = Logic(name: 'sel', width: lanes);
      rxPin = Logic(name: 'rx_pin');

      uart.input('clk').srcConnection! <= clk;
      uart.input('reset').srcConnection! <= reset;
      uart.input('bus_CYC').srcConnection! <= stb;
      uart.input('bus_STB').srcConnection! <= stb;
      uart.input('bus_WE').srcConnection! <= we;
      uart.input('bus_ADR').srcConnection! <= adr;
      uart.input('bus_DAT_MOSI').srcConnection! <= mosi;
      uart.input('bus_SEL').srcConnection! <= sel;
      uart.input('rx').srcConnection! <= rxPin;

      await uart.build();

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      sel.inject((1 << lanes) - 1);
      rxPin.inject(1);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // Program the baud divisor and drop out of DLAB mode. Write data goes
      // in the byte lane that matches sel, same as a real bus master.
      Future<void> writeReg(int offset, int value) async {
        final lane = offset % lanes;
        await busWrite(offset - lane, value << (8 * lane), 1 << lane);
      }

      await writeReg(_lcr, 0x83); // DLAB=1
      await writeReg(_rbr, cyclesPerBit); // DLL
      await writeReg(_lcr, 0x03); // DLAB=0, 8N1
    }

    tearDown(() async {
      await Simulator.reset();
    });

    for (final dataWidth in [32, 64]) {
      test(
        'reading IIR and LSR alone does not pop RBR ($dataWidth-bit bus)',
        () async {
          await setUpDut(dataWidth);
          await sendByte(0x42);

          final iirLane = _iir % lanes;
          final iirWord = _iir - iirLane;
          await busReadByte(iirWord, 1 << iirLane, iirLane);

          final lsrLane = _lsr % lanes;
          final lsrWord = _lsr - lsrLane;
          final lsr = await busReadByte(lsrWord, 1 << lsrLane, lsrLane);
          expect(lsr & 0x01, equals(1), reason: 'data ready after IIR read');

          final rbrLane = _rbr % lanes;
          final rbrWord = _rbr - rbrLane;
          final rbr = await busReadByte(rbrWord, 1 << rbrLane, rbrLane);
          expect(rbr, equals(0x42));

          final lsrAfter = await busReadByte(lsrWord, 1 << lsrLane, lsrLane);
          expect(lsrAfter & 0x01, equals(0), reason: 'data ready after RBR');

          await Simulator.endSimulation();
        },
      );

      test('a full-word read of RBR still pops it ($dataWidth-bit bus)', () async {
        await setUpDut(dataWidth);
        await sendByte(0x5a);

        final rbrLane = _rbr % lanes;
        final rbrWord = _rbr - rbrLane;
        final fullSel = (1 << lanes) - 1;
        final rbr = await busReadByte(rbrWord, fullSel, rbrLane);
        expect(rbr, equals(0x5a));

        final lsrLane = _lsr % lanes;
        final lsrWord = _lsr - lsrLane;
        final lsrAfter = await busReadByte(lsrWord, fullSel, lsrLane);
        expect(lsrAfter & 0x01, equals(0), reason: 'data ready after RBR');

        await Simulator.endSimulation();
      });
    }
  });
}

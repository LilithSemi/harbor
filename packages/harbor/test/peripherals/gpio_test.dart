import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register byte offsets: each register in its own 8-byte slot.
const _input = 0x00;
const _output = 0x08;
const _dir = 0x10;
const _irqEn = 0x18;
const _irqStatus = 0x20;
const _irqEdge = 0x28;

void main() {
  group('HarborGpio', () {
    test('creates with default pin count', () {
      final gpio = HarborGpio(baseAddress: 0x10001000);
      expect(gpio.bus, isNotNull);
      expect(gpio.gpioOut.width, equals(32));
      expect(gpio.gpioDir.width, equals(32));
      expect(gpio.interrupt.width, equals(1));
    });

    test('creates with custom pin count', () {
      final gpio = HarborGpio(baseAddress: 0x10001000, pinCount: 16);
      expect(gpio.gpioOut.width, equals(16));
      expect(gpio.gpioDir.width, equals(16));
    });

    test('DT node is correct', () {
      final gpio = HarborGpio(baseAddress: 0x10001000, pinCount: 8);
      final dt = gpio.dtNode;
      expect(dt.compatible.first, equals('harbor,gpio'));
      expect(dt.reg.start, equals(0x10001000));
      expect(dt.properties['ngpios'], equals(8));
      expect(dt.properties['gpio-controller'], equals(true));
    });

    test('supports TileLink protocol', () {
      final gpio = HarborGpio(
        baseAddress: 0x10001000,
        protocol: BusProtocol.tilelink,
      );
      expect(gpio.bus.protocol, equals(BusProtocol.tilelink));
    });
  });

  group('HarborGpio register access', () {
    late HarborGpio gpio;
    late Logic clk, reset, stb, we, adr, mosi, sel, pins;

    int allSel() => (1 << sel.width) - 1;

    Future<void> busWrite(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      sel.inject(allSel());
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (gpio.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<int> busRead(int addr) async {
      adr.inject(addr);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (gpio.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = gpio.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> busWriteSel(int addr, int selMask, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      sel.inject(selMask);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (gpio.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      sel.inject(allSel());
      await clk.nextPosedge;
    }

    Future<void> setUpDut({int dataWidth = 32}) async {
      gpio = HarborGpio(baseAddress: 0x10001000, busDataWidth: dataWidth);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 8);
      mosi = Logic(name: 'mosi', width: dataWidth);
      sel = Logic(name: 'sel', width: dataWidth ~/ 8);
      pins = Logic(name: 'gpio_in', width: 32);

      gpio.input('clk').srcConnection! <= clk;
      gpio.input('reset').srcConnection! <= reset;
      gpio.input('bus_CYC').srcConnection! <= stb;
      gpio.input('bus_STB').srcConnection! <= stb;
      gpio.input('bus_WE').srcConnection! <= we;
      gpio.input('bus_ADR').srcConnection! <= adr;
      gpio.input('bus_DAT_MOSI').srcConnection! <= mosi;
      gpio.input('bus_SEL').srcConnection! <= sel;
      gpio.input('gpio_in').srcConnection! <= pins;

      await gpio.build();

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      sel.inject(allSel());
      pins.inject(0);
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

    // Regression: the decode used to match a WORD INDEX (0x04 >> 2) against a
    // byte address, so only register 0 answered. Every write below landed on no
    // case at all, and every read returned zero.
    test('every register decodes at its own 8-byte slot', () async {
      await setUpDut();

      await busWrite(_output, 0xdeadbeef);
      expect(await busRead(_output), equals(0xdeadbeef));
      expect(gpio.gpioOut.value.toInt(), equals(0xdeadbeef));

      await busWrite(_dir, 0x0f0f0f0f);
      expect(await busRead(_dir), equals(0x0f0f0f0f));
      expect(gpio.gpioDir.value.toInt(), equals(0x0f0f0f0f));

      await busWrite(_irqEdge, 0x00ff00ff);
      expect(await busRead(_irqEdge), equals(0x00ff00ff));

      await busWrite(_irqEn, 0x12345678);
      expect(await busRead(_irqEn), equals(0x12345678));

      // The registers are distinct, not aliases of one another.
      expect(await busRead(_output), equals(0xdeadbeef));
      expect(await busRead(_dir), equals(0x0f0f0f0f));
      await Simulator.endSimulation();
    });

    test('INPUT reads the pins and IRQ_STATUS is write-1-to-clear', () async {
      await setUpDut();

      pins.inject(0xa5a5a5a5);
      await clk.nextPosedge;
      expect(await busRead(_input), equals(0xa5a5a5a5));

      // Level-triggered by default, so every high pin latches a status bit.
      expect(await busRead(_irqStatus), equals(0xa5a5a5a5));

      pins.inject(0);
      await clk.nextPosedge;
      await busWrite(_irqStatus, 0xffffffff);
      expect(await busRead(_irqStatus), equals(0));
      await Simulator.endSimulation();
    });

    test('the registers still land in the low word on a 64-bit bus', () async {
      await setUpDut(dataWidth: 64);

      await busWrite(_output, 0xcafef00d);
      expect(await busRead(_output), equals(0xcafef00d));
      await busWrite(_dir, 0x11223344);
      expect(await busRead(_dir), equals(0x11223344));
      expect(await busRead(_output), equals(0xcafef00d));
      await Simulator.endSimulation();
    });

    test('a byte store changes only the selected byte (32-bit bus)', () async {
      await setUpDut();

      await busWrite(_output, 0x11223344);
      // SEL=0b0001: only byte 0 of the write data is live.
      await busWriteSel(_output, 0x1, 0x000000aa);
      expect(await busRead(_output), equals(0x112233aa));
      await Simulator.endSimulation();
    });

    test(
      'a halfword store changes only the selected halfword (32-bit bus)',
      () async {
        await setUpDut();

        await busWrite(_output, 0x11223344);
        // SEL=0b0011: the low halfword of the write data is live.
        await busWriteSel(_output, 0x3, 0x0000beef);
        expect(await busRead(_output), equals(0x1122beef));
        await Simulator.endSimulation();
      },
    );

    test('a byte store changes only the selected byte (64-bit bus)', () async {
      await setUpDut(dataWidth: 64);

      await busWrite(_output, 0x11223344);
      await busWriteSel(_output, 0x1, 0x000000aa);
      expect(await busRead(_output), equals(0x112233aa));
      await Simulator.endSimulation();
    });

    // Regression: River aligns ADR to 8 bytes on a 64-bit bus and puts the
    // byte position of a narrower access in SEL, so a 32-bit store to
    // OUTPUT+4 arrives with ADR=OUTPUT and SEL selecting the upper 4 bytes.
    // OUTPUT itself lives in the low 4 bytes of that 8-byte slot, so this
    // store must leave it alone instead of overwriting it with whatever sat
    // in the unselected low lane of the write data.
    test('a store to the upper lane of a slot does not alias the register '
        'below it (64-bit bus)', () async {
      await setUpDut(dataWidth: 64);

      await busWriteSel(_output, 0x0f, 0x5a5a5a5a);
      final before = await busRead(_output);

      // ADR stays at the OUTPUT slot; only the upper 4 bytes are selected,
      // as a master would present for a store originally aimed at +4.
      await busWriteSel(_output, 0xf0, 0x12345678 << 32);
      final after = await busRead(_output);

      expect(before, equals(0x5a5a5a5a));
      expect(after, equals(before));
      await Simulator.endSimulation();
    });
  });
}

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register byte offsets: each register in its own 8-byte slot.
const _ctrl = 0x00;
const _status = 0x08;
const _data = 0x10;
const _addr = 0x18;
const _prescale = 0x20;
const _cmd = 0x28;

void main() {
  group('HarborI2cController', () {
    test('creates with correct ports', () {
      final i2c = HarborI2cController(baseAddress: 0x10003000);
      expect(i2c.bus, isNotNull);
      expect(i2c.interrupt.width, equals(1));
    });

    test('DT node is correct', () {
      final i2c = HarborI2cController(baseAddress: 0x10003000);
      final dt = i2c.dtNode;
      expect(dt.compatible.first, equals('harbor,i2c'));
      expect(dt.reg.start, equals(0x10003000));
    });

    test('supports TileLink', () {
      final i2c = HarborI2cController(
        baseAddress: 0x10003000,
        protocol: BusProtocol.tilelink,
      );
      expect(i2c.bus.protocol, equals(BusProtocol.tilelink));
    });
  });

  group('HarborI2cController register access', () {
    late HarborI2cController i2c;
    late Logic clk, reset, stb, we, adr, mosi, sel;

    int allSel() => (1 << sel.width) - 1;

    Future<void> busWrite(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      sel.inject(allSel());
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (i2c.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<void> busWriteSel(int addr, int selMask, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      sel.inject(selMask);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (i2c.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      sel.inject(allSel());
      await clk.nextPosedge;
    }

    Future<int> busRead(int addr) async {
      adr.inject(addr);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (i2c.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = i2c.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> setUpDut({int dataWidth = 32}) async {
      i2c = HarborI2cController(
        baseAddress: 0x10003000,
        busDataWidth: dataWidth,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 8);
      mosi = Logic(name: 'mosi', width: dataWidth);
      sel = Logic(name: 'sel', width: dataWidth ~/ 8);

      i2c.input('clk').srcConnection! <= clk;
      i2c.input('reset').srcConnection! <= reset;
      i2c.input('bus_CYC').srcConnection! <= stb;
      i2c.input('bus_STB').srcConnection! <= stb;
      i2c.input('bus_WE').srcConnection! <= we;
      i2c.input('bus_ADR').srcConnection! <= adr;
      i2c.input('bus_DAT_MOSI').srcConnection! <= mosi;
      i2c.input('bus_SEL').srcConnection! <= sel;
      i2c.input('scl_in').srcConnection! <= Const(1);
      i2c.input('sda_in').srcConnection! <= Const(1);

      await i2c.build();

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      sel.inject(allSel());
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

    // Regression: the decode used to match a WORD INDEX (0, 1, 2, ...) against
    // a byte address, so only CTRL answered. PRESCALE and ADDR never took a
    // write, which left the controller clocking SCL at its reset rate and
    // addressing slave 0.
    test('every register decodes at its own 8-byte slot', () async {
      await setUpDut();

      await busWrite(_ctrl, 0x3); // enable + irq enable
      expect(await busRead(_ctrl), equals(0x3));

      await busWrite(_prescale, 0x1234);
      expect(await busRead(_prescale), equals(0x1234));

      await busWrite(_addr, 0x50);
      expect(await busRead(_addr), equals(0x50));

      // The registers are distinct, not aliases of one another.
      expect(await busRead(_ctrl), equals(0x3));
      expect(await busRead(_prescale), equals(0x1234));
      await Simulator.endSimulation();
    });

    test('ADDR keeps 7 bits and PRESCALE keeps 16', () async {
      await setUpDut();

      await busWrite(_addr, 0xff); // only [6:0] is the slave address
      expect(await busRead(_addr), equals(0x7f));

      await busWrite(_prescale, 0xdeadbeef);
      expect(await busRead(_prescale), equals(0xbeef));
      await Simulator.endSimulation();
    });

    test('STATUS reads idle, and DATA is its own register', () async {
      await setUpDut();

      // Nothing has been commanded, so busy and the error flags are clear.
      expect(await busRead(_status), equals(0));

      // A DATA write fills TX and must not disturb the neighbouring slots.
      await busWrite(_prescale, 0x0099);
      await busWrite(_data, 0xa5);
      expect(await busRead(_prescale), equals(0x0099));
      await Simulator.endSimulation();
    });

    test('CMD start sets busy, and it is not an alias of CTRL', () async {
      await setUpDut();

      await busWrite(_ctrl, 0x1); // enable
      await busWrite(_prescale, 0x0004);
      expect(await busRead(_status) & 0x1, equals(0)); // idle

      await busWrite(_cmd, 0x1); // START
      expect(await busRead(_status) & 0x1, equals(0x1)); // busy
      expect(await busRead(_ctrl), equals(0x1)); // CTRL untouched
      await Simulator.endSimulation();
    });

    test('a CMD write while busy is ignored and sets cmd_rejected', () async {
      await setUpDut();
      await busWrite(_ctrl, 0x1);
      await busWrite(_prescale, 0x0004);
      await busWrite(_data, 0xAA);

      await busWrite(_cmd, 0x1 | 0x4); // START|WRITE
      expect(await busRead(_status) & 0x1, equals(0x1)); // busy

      // A stray write while busy must be ignored outright, not applied
      // partway through the byte already in flight.
      await busWrite(_cmd, 0x2); // STOP, which would truncate the byte
      expect(await busRead(_status) & 0x40, equals(0x40)); // cmd_rejected
      expect(await busRead(_status) & 0x1, equals(0x1)); // still busy

      // Any STATUS write clears cmd_rejected, same as cmd_done, without
      // disturbing the in-flight sequence.
      await busWrite(_status, 0x40);
      expect(await busRead(_status) & 0x40, equals(0));
      expect(await busRead(_status) & 0x1, equals(0x1));

      // The original transaction still runs to completion untouched.
      var cmdDone = 0;
      for (var i = 0; i < 2000 && cmdDone == 0; i++) {
        cmdDone = await busRead(_status) & 0x20;
      }
      expect(cmdDone, equals(0x20));
      await Simulator.endSimulation();
    });

    test('a CMD write before enable is rejected, not stuck busy', () async {
      await setUpDut();
      await busWrite(_prescale, 0x0004);

      // enable is still 0 here.
      await busWrite(_cmd, 0x1); // START, while disabled
      expect(await busRead(_status) & 0x40, equals(0x40)); // cmd_rejected
      expect(await busRead(_status) & 0x1, equals(0)); // never went busy

      // Clearing the flag and enabling afterward still works normally.
      await busWrite(_status, 0x40);
      await busWrite(_ctrl, 0x1);
      await busWrite(_data, 0xAA);
      await busWrite(_cmd, 0x1 | 0x4);
      expect(await busRead(_status) & 0x1, equals(0x1));
      await Simulator.endSimulation();
    });

    // Regression: CMD bits used to be independent "If"s in one Sequential,
    // so the last bit checked (read, then write) won the i2cState write. A
    // single CMD write of START|WRITE, exactly what the kmod driver sends
    // for an address byte, landed straight in the data-shift state and
    // never drove a start condition at all.
    test(
      'a combined START|WRITE drives a real START before any data bit',
      () async {
        await setUpDut();
        await busWrite(_ctrl, 0x1); // enable
        await busWrite(_prescale, 0x0004);
        await busWrite(_data, 0xA1); // address byte, read

        final sclOe = i2c.output('scl_oe');
        final sdaOe = i2c.output('sda_oe');

        await busWrite(_cmd, 0x1 | 0x4); // START | WRITE, one write

        int? startEdgeAt;
        int? sclLowAt;
        for (var t = 0; t < 2000; t++) {
          await clk.nextPosedge;
          final scl = sclOe.value.toInt();
          final sda = sdaOe.value.toInt();
          // A real START: SDA driven low while SCL is still released (high).
          if (startEdgeAt == null && scl == 0 && sda == 1) {
            startEdgeAt = t;
          } else if (startEdgeAt != null && scl == 1) {
            sclLowAt = t;
            break;
          }
        }

        expect(
          startEdgeAt,
          isNotNull,
          reason: 'SDA never fell while SCL was released: no START',
        );
        expect(
          sclLowAt,
          isNotNull,
          reason: 'SCL was never driven low to begin the address bits',
        );
        expect(sclLowAt! > startEdgeAt!, isTrue);
        await Simulator.endSimulation();
      },
    );

    // Measures the master's own SCL waveform on a self-loopback bus
    // (scl_in/sda_in wired straight from the controller's own open-drain
    // outputs, as on real silicon with nothing else driving the line):
    // the low and high time, in clk cycles, of a steady data bit, well
    // after the one-off START condition.
    Future<({int low, int high})> measureSclTiming(int prescale) async {
      final dut = HarborI2cController(baseAddress: 0x10003000);
      final lclk = SimpleClockGenerator(10).clk;
      final lreset = Logic(name: 'reset');
      final lstb = Logic(name: 'stb');
      final lwe = Logic(name: 'we');
      final ladr = Logic(name: 'adr', width: 8);
      final lmosi = Logic(name: 'mosi', width: 32);

      dut.input('clk').srcConnection! <= lclk;
      dut.input('reset').srcConnection! <= lreset;
      dut.input('bus_CYC').srcConnection! <= lstb;
      dut.input('bus_STB').srcConnection! <= lstb;
      dut.input('bus_WE').srcConnection! <= lwe;
      dut.input('bus_ADR').srcConnection! <= ladr;
      dut.input('bus_DAT_MOSI').srcConnection! <= lmosi;
      dut.input('bus_SEL').srcConnection! <=
          Const(-1, width: dut.input('bus_SEL').width);
      // Self loopback: nothing else is on this bus, so the line reads
      // exactly the controller's own drive (released reads high).
      dut.input('scl_in').srcConnection! <= ~dut.output('scl_oe');
      dut.input('sda_in').srcConnection! <= ~dut.output('sda_oe');

      await dut.build();

      lreset.inject(1);
      lstb.inject(0);
      lwe.inject(0);
      ladr.inject(0);
      lmosi.inject(0);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await lclk.nextPosedge;
      await lclk.nextPosedge;
      lreset.inject(0);
      await lclk.nextPosedge;

      Future<void> lwrite(int addr, int data) async {
        ladr.inject(addr);
        lmosi.inject(data);
        lwe.inject(1);
        lstb.inject(1);
        await lclk.nextPosedge;
        while (dut.output('bus_ACK').value.toInt() != 1) {
          await lclk.nextPosedge;
        }
        lstb.inject(0);
        lwe.inject(0);
        await lclk.nextPosedge;
      }

      await lwrite(_ctrl, 0x1);
      await lwrite(_prescale, prescale);
      await lwrite(_data, 0xAA);
      await lwrite(_cmd, 0x1 | 0x4); // START|WRITE

      final sclOe = dut.output('scl_oe');
      final levels = <int>[];
      final sampleCount = 16 * (prescale + 4);
      for (var t = 0; t < sampleCount; t++) {
        await lclk.nextPosedge;
        levels.add(sclOe.value.toInt());
      }

      final transitions = <int>[];
      for (var i = 1; i < levels.length; i++) {
        if (levels[i] != levels[i - 1]) transitions.add(i);
      }
      // Transition 0 is the START condition driving SCL low for the
      // first time (a one-off, longer than a steady bit). Read two full
      // steady-state bit periods starting at transition 1.
      final segs = [
        for (var i = 2; i < 6; i++) transitions[i] - transitions[i - 1],
      ];
      final seg1IsLow = levels[transitions[1]] == 1; // scl_oe=1: driving low
      final lowSegs = <int>[
        for (var i = 0; i < segs.length; i++)
          if ((i.isEven) == seg1IsLow) segs[i],
      ];
      final highSegs = <int>[
        for (var i = 0; i < segs.length; i++)
          if ((i.isEven) != seg1IsLow) segs[i],
      ];

      expect(
        lowSegs.toSet().length,
        equals(1),
        reason: 'low time must be constant: $lowSegs',
      );
      expect(
        highSegs.toSet().length,
        equals(1),
        reason: 'high time must be constant: $highSegs',
      );

      await Simulator.endSimulation();
      return (low: lowSegs.first, high: highSegs.first);
    }

    test('SCL period and duty come from PRESCALE, low and high each a fixed '
        'formula (excluding any clock-stretched cycles)', () async {
      // low = 2 x (PRESCALE + 1) cycles. high adds a fixed 3 cycles on
      // top of that: the 2-flop input synchronizer's cost of seeing the
      // controller's own released line read high, plus one further
      // cycle of the usual one-tick register latency. Measured and
      // pinned here for PRESCALE = 4 and 9; see the class doc.
      final p4 = await measureSclTiming(4);
      expect(p4.low, equals(2 * (4 + 1)));
      expect(p4.high, equals(p4.low + 3));
      expect(p4.low + p4.high, equals(4 * (4 + 1) + 3));

      await Simulator.reset();

      final p9 = await measureSclTiming(9);
      expect(p9.low, equals(2 * (9 + 1)));
      expect(p9.high, equals(p9.low + 3));
      expect(p9.low + p9.high, equals(4 * (9 + 1) + 3));
    });

    test('PRESCALE picked by the kmod formula clears UM10204 low/high '
        'minimums for standard and fast mode', () {
      // Mirrors harbor_i2c_prescale() in harbor_i2c.c: PRESCALE from
      // the slower side's minimum low time for the requested bus
      // speed, so low (and so high, always looser) clears its minimum
      // regardless of the input clock.
      int prescaleFor(int busFreqHz, int inputClockHz) {
        final tLowMinNs = busFreqHz <= 100000
            ? 4700
            : busFreqHz <= 400000
            ? 1300
            : 500;
        const den = 2 * 1000000000;
        final raw = (tLowMinNs * inputClockHz + den - 1) ~/ den;
        return raw < 1 ? 1 : raw;
      }

      // Real low/high in seconds, from the verified HDL formula above.
      ({double low, double high}) realTiming(int prescale, int clockHz) {
        final low = 2 * (prescale + 1) / clockHz;
        return (low: low, high: low + 3 / clockHz);
      }

      const inputClockHz = 10000000; // 10 MHz, a plausible SoC clock
      const standardMins = (low: 4.7e-6, high: 4.0e-6);
      const fastMins = (low: 1.3e-6, high: 0.6e-6);

      final standard = realTiming(
        prescaleFor(100000, inputClockHz),
        inputClockHz,
      );
      expect(standard.low, greaterThanOrEqualTo(standardMins.low));
      expect(standard.high, greaterThanOrEqualTo(standardMins.high));

      final fast = realTiming(prescaleFor(400000, inputClockHz), inputClockHz);
      expect(fast.low, greaterThanOrEqualTo(fastMins.low));
      expect(fast.high, greaterThanOrEqualTo(fastMins.high));
    });

    test('the registers still land in the low word on a 64-bit bus', () async {
      await setUpDut(dataWidth: 64);

      await busWrite(_prescale, 0x4321);
      expect(await busRead(_prescale), equals(0x4321));
      await busWrite(_addr, 0x2a);
      expect(await busRead(_addr), equals(0x2a));
      expect(await busRead(_prescale), equals(0x4321));
      await Simulator.endSimulation();
    });

    test('a byte store changes only the selected byte (32-bit bus)', () async {
      await setUpDut();

      await busWrite(_prescale, 0x1234);
      // SEL=0b0001: only byte 0 of the write data is live.
      await busWriteSel(_prescale, 0x1, 0x00000099);
      expect(await busRead(_prescale), equals(0x1299));
      await Simulator.endSimulation();
    });

    test(
      'a halfword store changes only the selected halfword (32-bit bus)',
      () async {
        await setUpDut();

        await busWrite(_prescale, 0x1234);
        // SEL=0b0011: the low halfword of the write data is live, and that
        // covers the whole 16-bit register.
        await busWriteSel(_prescale, 0x3, 0x0000beef);
        expect(await busRead(_prescale), equals(0xbeef));
        await Simulator.endSimulation();
      },
    );

    // Regression: River aligns ADR to 8 bytes on a 64-bit bus and puts the
    // byte position of a narrower access in SEL, so a 32-bit store to
    // PRESCALE+4 arrives with ADR=PRESCALE and SEL selecting the upper 4
    // bytes. PRESCALE lives in the low 4 bytes of that 8-byte slot, so this
    // store must leave it alone.
    test('a store to the upper lane of a slot does not alias the register '
        'below it (64-bit bus)', () async {
      await setUpDut(dataWidth: 64);

      await busWriteSel(_prescale, 0x0f, 0x1234);
      final before = await busRead(_prescale);

      await busWriteSel(_prescale, 0xf0, 0x5678 << 32);
      final after = await busRead(_prescale);

      expect(before, equals(0x1234));
      expect(after, equals(before));
      await Simulator.endSimulation();
    });
  });
}

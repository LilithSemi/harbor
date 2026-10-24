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

    test('regShift gets its own definition name', () {
      final a = HarborUart(baseAddress: 0x10000000, busDataWidth: 32);
      final b = HarborUart(
        baseAddress: 0x10000000,
        busDataWidth: 32,
        regShift: 2,
      );
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });

    test('rejects a regShift other than 0 or 2', () {
      expect(
        () => HarborUart(baseAddress: 0, busDataWidth: 32, regShift: 1),
        throwsArgumentError,
      );
      expect(
        () => HarborUart(baseAddress: 0, busDataWidth: 32, regShift: 3),
        throwsArgumentError,
      );
    });

    test('rejects regShift 2 on a bus narrower than 32 bits', () {
      expect(
        () => HarborUart(baseAddress: 0, busDataWidth: 8, regShift: 2),
        throwsArgumentError,
      );
    });

    test('DT and ACPI give reg-shift and reg-io-width', () {
      final packed = HarborUart(baseAddress: 0x10000000, busDataWidth: 32);
      final word = HarborUart(
        baseAddress: 0x10000000,
        busDataWidth: 32,
        regShift: 2,
      );
      expect(packed.dtNode.properties['reg-shift'], equals(0));
      expect(packed.dtNode.properties['reg-io-width'], equals(1));
      expect(word.dtNode.properties['reg-shift'], equals(2));
      expect(word.dtNode.properties['reg-io-width'], equals(4));
      expect(word.acpiDevice.properties['reg-shift'], equals(2));
      expect(word.acpiDevice.properties['reg-io-width'], equals(4));
      expect(word.svdPeripheral.registers!.fieldOffset('scr'), equals(0x1c));
    });
  });

  for (final kind in HarborFabricKind.values) {
    registerTests(kind);
    wordRegisterTests(kind);
    packedLaneTests(kind);
    for (final width in [64, 128]) {
      // Wishbone has no 128-bit data width.
      if (kind == HarborFabricKind.wishbone && width > 64) continue;
      wideWordRegisterTests(kind, width);
    }
  }
}

class _Dut {
  final HarborUart uart;
  final Logic clk;
  final RegBus bus;
  final Logic rx;
  _Dut(this.uart, this.clk, this.bus, this.rx);
}

Future<_Dut> _startUart(HarborUart uart) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final rx = Logic(name: 'rx');
  uart.input('clk').srcConnection! <= clk;
  uart.input('reset').srcConnection! <= reset;
  uart.input('rx').srcConnection! <= rx;
  final bus = RegBus.attach(uart, clk);
  await uart.build();
  reset.inject(1);
  bus.idle();
  rx.inject(1);
  Simulator.setMaxSimTime(400000);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);
  await clk.nextPosedge;
  return _Dut(uart, clk, bus, rx);
}

// Samples TX until one 8N1 frame at [cyclesPerBit] arrives.
Future<int?> _receiveByte(Logic tx, Logic clk, int cyclesPerBit) async {
  Future<void> wait(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }

  var guard = 0;
  while (tx.value.toInt() == 1) {
    if (guard++ > 400) return null;
    await wait(1);
  }
  await wait(cyclesPerBit ~/ 2);
  if (tx.value.toInt() != 0) return null;
  var byte = 0;
  for (var i = 0; i < 8; i++) {
    await wait(cyclesPerBit);
    byte |= tx.value.toInt() << i;
  }
  await wait(cyclesPerBit);
  if (tx.value.toInt() != 1) return null;
  return byte;
}

void wordRegisterTests(HarborFabricKind kind) {
  group('HarborUart regShift 2 on a 32-bit bus (${kind.name})', () {
    tearDown(() async {
      await Simulator.reset();
    });

    test('a word access reaches each register at n * 4', () async {
      final d = await _startUart(
        HarborUart(
          baseAddress: 0x10000000,
          busDataWidth: 32,
          regShift: 2,
          fabricKind: kind,
        ),
      );
      final bus = d.bus;
      // Full-word writes with junk above bits 7:0.
      await bus.write(0x0c, 0xdeadbe83);
      await bus.write(0x00, 0xffffff04);
      await bus.write(0x04, 0xffffff00);
      expect(await bus.read(0x00), equals(0x04));
      expect(await bus.read(0x04), equals(0x00));
      expect(await bus.read(0x0c), equals(0x83));
      await bus.write(0x0c, 0x03);
      expect(await bus.read(0x0c), equals(0x03));

      await bus.write(0x04, 0x02);
      expect(await bus.read(0x04), equals(0x02));
      // FCR sets IIR bits 7:6, and the THRE interrupt is pending.
      await bus.write(0x08, 0xc1);
      expect(await bus.read(0x08), equals(0xc2));
      await bus.write(0x04, 0x00);
      await bus.write(0x10, 0x0b);
      expect(await bus.read(0x10), equals(0x0b));
      expect(await bus.read(0x14), equals(0x60));
      expect(await bus.read(0x18), equals(0x00));
      await bus.write(0x1c, 0x5a);
      expect(await bus.read(0x1c), equals(0x5a));

      // A write without byte lane 0 changes nothing.
      await bus.write(0x1c, 0xffffffff, sel: 0xe);
      expect(await bus.read(0x1c), equals(0x5a));

      final rx = _receiveByte(d.uart.tx, d.clk, 4);
      await bus.write(0x00, 0xa5);
      expect(await rx, equals(0xa5));

      await Simulator.endSimulation();
    });
  });
}

void packedLaneTests(HarborFabricKind kind) {
  group('HarborUart packed on a 32-bit bus (${kind.name})', () {
    tearDown(() async {
      await Simulator.reset();
    });

    test('a multi-lane write changes nothing and fails', () async {
      final d = await _startUart(
        HarborUart(baseAddress: 0x10000000, busDataWidth: 32, fabricKind: kind),
      );
      final bus = d.bus;
      // LCR is lane 3 of word 0, SCR is lane 3 of word 4.
      var r = await bus.access(0x0, data: 0x03 << 24, sel: 0x8, write: true);
      expect(r.err, isFalse);
      r = await bus.access(0x4, data: 0x5a << 24, sel: 0x8, write: true);
      expect(r.err, isFalse);
      expect((await bus.read(0x0) >> 24) & 0xff, equals(0x03));
      expect((await bus.read(0x4) >> 24) & 0xff, equals(0x5a));

      r = await bus.access(0x0, data: 0xffffffff, sel: 0xf, write: true);
      expect(r.err, isTrue);
      r = await bus.access(0x4, data: 0xffffffff, sel: 0xc, write: true);
      expect(r.err, isTrue);
      final w0 = await bus.read(0x0);
      expect((w0 >> 24) & 0xff, equals(0x03), reason: 'LCR');
      expect((w0 >> 8) & 0xff, equals(0x00), reason: 'IER');
      expect((await bus.read(0x4) >> 24) & 0xff, equals(0x5a), reason: 'SCR');

      // Reads of the whole word do not fail.
      final read = await bus.access(0x0, write: false);
      expect(read.err, isFalse);

      await Simulator.endSimulation();
    });
  });
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

// Register [n] of a regShift 2 UART on a [width] bit bus: the slot value in
// bits 31:0 of its slot.
final _slotMask = BigInt.from(0xffffffff);

Future<int> _readSlot(RegBus bus, int width, int n, {bool wholeWord = false}) {
  final slots = width ~/ 32;
  final slot = n % slots;
  return _readWord(
    bus,
    width,
    n ~/ slots,
    sel: wholeWord ? null : 0xf << (4 * slot),
  ).then((w) => w[slot]);
}

// The slots of the word [word], each as a 32 bit value.
Future<List<int>> _readWord(RegBus bus, int width, int word, {int? sel}) async {
  final r = await bus.accessWide(word * (width ~/ 8), sel: sel, write: false);
  return [
    for (var s = 0; s < width ~/ 32; s++)
      ((r.data >> (32 * s)) & _slotMask).toInt(),
  ];
}

Future<void> _writeSlots(
  RegBus bus,
  int width,
  int word,
  Map<int, int> slotData, {
  int? sel,
}) async {
  var data = BigInt.zero;
  var strobe = 0;
  slotData.forEach((s, v) {
    data |= BigInt.from(v) << (32 * s);
    strobe |= 0xf << (4 * s);
  });
  await bus.accessWide(
    word * (width ~/ 8),
    data: data,
    sel: sel ?? strobe,
    write: true,
  );
}

Future<void> _writeReg(RegBus bus, int width, int n, int v) {
  final slots = width ~/ 32;
  return _writeSlots(bus, width, n ~/ slots, {n % slots: v});
}

Future<void> _sendRx(Logic rx, Logic clk, int byte) async {
  rx.inject(0);
  await clk.nextPosedge;
  await clk.nextPosedge;
  for (var i = 0; i < 8; i++) {
    rx.inject((byte >> i) & 1);
    await clk.nextPosedge;
  }
  rx.inject(1);
  await clk.nextPosedge;
  await clk.nextPosedge;
}

void wideWordRegisterTests(HarborFabricKind kind, int width) {
  group('HarborUart regShift 2 on a $width-bit bus (${kind.name})', () {
    final slots = width ~/ 32;
    tearDown(() async {
      await Simulator.reset();
    });

    Future<_Dut> start() => _startUart(
      HarborUart(
        baseAddress: 0x10000000,
        busDataWidth: width,
        regShift: 2,
        fabricKind: kind,
      ),
    );

    test('a word write reaches only its own register', () async {
      final d = await start();
      final bus = d.bus;
      // Reset values of registers 0 to 7 as read back.
      final model = [0, 0, 0x01, 0x03, 0, 0x60, 0, 0];
      Future<void> check(String why) async {
        for (var n = 0; n < 8; n++) {
          expect(await _readSlot(bus, width, n), model[n], reason: '$why r$n');
        }
      }

      await check('reset');
      // Junk above bits 7:0 must not reach any register.
      await _writeReg(bus, width, 7, 0xffffff5a);
      model[7] = 0x5a;
      await check('scr');
      await _writeReg(bus, width, 4, 0xabcdef0a);
      model[4] = 0x0a;
      await check('mcr');
      await _writeReg(bus, width, 1, 0x12345602);
      model[1] = 0x02;
      model[2] = 0x02;
      await check('ier');
      await _writeReg(bus, width, 2, 0xffffffc1);
      model[2] = 0xc2;
      await check('fcr');
      await _writeReg(bus, width, 3, 0xffffff83);
      model[3] = 0x83;
      model[0] = 0x01;
      model[1] = 0x00;
      await check('lcr dlab');
      // With DLAB set, register 0 and 1 are the divisor latch.
      await _writeReg(bus, width, 0, 0x04);
      model[0] = 0x04;
      await check('dll');
      await _writeReg(bus, width, 1, 0x00);
      await check('dlm');
      await _writeReg(bus, width, 3, 0x03);
      model[3] = 0x03;
      model[0] = 0;
      model[1] = 0x02;
      await check('lcr');

      // Registers 5 and 6 are read only.
      await _writeReg(bus, width, 5, 0xff);
      await _writeReg(bus, width, 6, 0xff);
      await check('read only');

      // THR sends a character.
      await _writeReg(bus, width, 3, 0x83);
      await _writeReg(bus, width, 0, 0x04);
      await _writeReg(bus, width, 3, 0x03);
      final rx = _receiveByte(d.uart.tx, d.clk, 4);
      await _writeReg(bus, width, 0, 0xa5);
      expect(await rx, equals(0xa5));
      await Simulator.endSimulation();
    });

    test('registers in one bus word are written in one cycle', () async {
      final d = await start();
      final bus = d.bus;
      // The last word holds registers 8 - slots to 7.
      final last = 8 ~/ slots - 1;
      final first = 8 - slots;
      final writes = {
        for (var s = 0; s < slots; s++) s: 0xffffff00 | (0x10 + s),
      };
      await _writeSlots(bus, width, last, writes);
      // Registers 5 and 6 are read only, so they keep their values.
      final read = await _readWord(bus, width, last);
      for (var s = 0; s < slots; s++) {
        final n = first + s;
        final want = switch (n) {
          5 => 0x60,
          6 => 0x00,
          _ => 0x10 + s,
        };
        expect(read[s], want, reason: 'register $n');
      }

      // A slot with lane 0 off keeps its value, a neighbour is written.
      final skipped = slots; // slot 0 of word 1
      final strobed = slots + (slots == 2 ? 1 : 3);
      final before = await _readSlot(bus, width, skipped);
      final strobedSlot = strobed % slots;
      await _writeSlots(bus, width, 1, {
        0: 0xffffffff,
        strobedSlot: 0x00000007,
      }, sel: 0xe | (0xf << (4 * strobedSlot)));
      expect(await _readSlot(bus, width, skipped), before, reason: 'skipped');
      expect(await _readSlot(bus, width, strobed), 0x07, reason: 'strobed');

      // Word 0 has THR, so the same write sends a character.
      await _writeReg(bus, width, 3, 0x83);
      await _writeReg(bus, width, 0, 0x04);
      await _writeReg(bus, width, 3, 0x03);
      final rx = _receiveByte(d.uart.tx, d.clk, 4);
      await _writeSlots(bus, width, 0, {0: 0x5c});
      expect(await rx, equals(0x5c));
      await Simulator.endSimulation();
    });

    test('an RBR read pops once and only for its slot', () async {
      final d = await start();
      final bus = d.bus;
      Future<bool> dataReady() async =>
          (await _readSlot(bus, width, 5)) & 1 == 1;
      Future<void> waitReady() async {
        for (var i = 0; i < 50 && !await dataReady(); i++) {
          await d.clk.nextPosedge;
        }
      }

      await _sendRx(d.rx, d.clk, 0xA5);
      await waitReady();
      expect(await dataReady(), isTrue);

      // A read of another slot in word 0 does not pop.
      await _readSlot(bus, width, 3);
      await _readSlot(bus, width, 1);
      expect(await dataReady(), isTrue);
      // A read of a word that has no RBR does not pop.
      await _readWord(bus, width, 8 ~/ slots - 1);
      expect(await dataReady(), isTrue);

      expect(await _readSlot(bus, width, 0), 0xA5);
      expect(await dataReady(), isFalse);

      // The next byte is not lost by the pop of the first.
      await _sendRx(d.rx, d.clk, 0x3C);
      await waitReady();
      expect(await dataReady(), isTrue);
      expect(await _readSlot(bus, width, 0), 0x3C);
      expect(await dataReady(), isFalse);
      await Simulator.endSimulation();
    });

    test('a full word read returns each register in its slot', () async {
      final d = await start();
      final bus = d.bus;
      await _writeReg(bus, width, 7, 0x6b);
      await _writeReg(bus, width, 4, 0x0c);
      for (var w = 0; w < 8 ~/ slots; w++) {
        final read = await _readWord(bus, width, w);
        for (var s = 0; s < slots; s++) {
          final n = w * slots + s;
          final one = await _readSlot(bus, width, n);
          expect(read[s], one, reason: 'register $n');
          expect(read[s] >> 8, 0, reason: 'register $n upper bits');
        }
      }
      await Simulator.endSimulation();
    });
  });
}

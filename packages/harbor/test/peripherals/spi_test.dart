import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// Byte-address register map (see HarborSpiController): each register is in
// its own 64-bit-aligned slot.
const _ctrl = 0x00;
const _status = 0x08;
const _data = 0x10;
const _divider = 0x18;

void main() {
  group('HarborSpiController', () {
    test('creates with defaults', () {
      final spi = HarborSpiController(baseAddress: 0x10002000);
      expect(spi.bus, isNotNull);
      expect(spi.interrupt.width, equals(1));
    });

    test('creates with multiple chip selects', () {
      final spi = HarborSpiController(baseAddress: 0x10002000, csCount: 4);
      final dt = spi.dtNode;
      expect(dt.properties['num-cs'], equals(4));
    });

    test('DT node is correct', () {
      final spi = HarborSpiController(baseAddress: 0x10002000);
      final dt = spi.dtNode;
      expect(dt.compatible.first, equals('harbor,spi'));
      expect(dt.reg.start, equals(0x10002000));
    });

    test('supports both bus protocols', () {
      final wb = HarborSpiController(
        baseAddress: 0x1000,
        fabricKind: HarborFabricKind.wishbone,
      );
      final tl = HarborSpiController(
        baseAddress: 0x1000,
        fabricKind: HarborFabricKind.tilelink,
      );
      expect(wb.bus.kind, equals(HarborFabricKind.wishbone));
      expect(tl.bus.kind, equals(HarborFabricKind.tilelink));
    });

    test('two different parameter sets get different definition names', () {
      final a = HarborSpiController(baseAddress: 0x1000, csCount: 1);
      final b = HarborSpiController(baseAddress: 0x1000, csCount: 2);
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    _registerTests(kind);
  }
}

void _registerTests(HarborFabricKind kind) {
  group('HarborSpiController register access (${kind.name})', () {
    late HarborSpiController spi;
    late Logic clk, reset, miso;
    late RegBus bus;

    Future<void> setUpDut({int dataWidth = 32}) async {
      spi = HarborSpiController(
        baseAddress: 0x1000,
        busDataWidth: dataWidth,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      miso = Logic(name: 'miso');

      spi.input('clk').srcConnection! <= clk;
      spi.input('reset').srcConnection! <= reset;
      spi.input('spi_miso').srcConnection! <= miso;
      bus = RegBus.attach(spi, clk);

      await spi.build();
      reset.inject(1);
      bus.idle();
      miso.inject(0);
      Simulator.setMaxSimTime(1000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    tearDown(() async => Simulator.reset());

    test(
      'a byte written in loopback returns intact (no bit rotation)',
      () async {
        await setUpDut();

        // At reset STATUS must show tx_empty (bit1) set: proves the byte-address
        // decode reaches the right register (the old word-index decode read 0).
        expect(await bus.read(_status), equals(0x2));

        await bus.write(_divider, 1);
        await bus.write(_ctrl, 0x9); // enable | loopback
        await bus.write(_data, 0xA5); // start a transfer

        var st = await bus.read(_status);
        var guard = 0;
        while (st & 0x1 != 0 && guard < 200) {
          st = await bus.read(_status);
          guard++;
        }
        expect(st & 0x1, equals(0), reason: 'transfer should finish');

        // Loopback feeds MOSI back to MISO: an 8-bit exchange must return the
        // exact byte. A one-bit rotation here is the "capture before the 8th
        // shift" bug.
        expect(await bus.read(_data) & 0xFF, equals(0xA5));

        await Simulator.endSimulation();
      },
    );

    test('a byte store changes only the selected byte (32-bit bus)', () async {
      await setUpDut();

      await bus.write(_divider, 0x1234);
      // SEL=0b0001: only byte 0 of the write data is live.
      await bus.write(_divider, 0x00000099, sel: 0x1);
      expect(await bus.read(_divider), equals(0x1299));
      await Simulator.endSimulation();
    });

    test(
      'a halfword store changes only the selected halfword (32-bit bus)',
      () async {
        await setUpDut();

        await bus.write(_divider, 0x1234);
        await bus.write(_divider, 0x0000beef, sel: 0x3);
        expect(await bus.read(_divider), equals(0xbeef));
        await Simulator.endSimulation();
      },
    );

    // Regression: River aligns ADR to 8 bytes on a 64-bit bus and puts the
    // byte position of a narrower access in SEL, so a 32-bit store to
    // DIVIDER+4 arrives with ADR=DIVIDER and SEL selecting the upper 4
    // bytes. DIVIDER lives in the low 4 bytes of that 8-byte slot, so this
    // store must leave it alone.
    test('a store to the upper lane of a slot does not alias the register '
        'below it (64-bit bus)', () async {
      await setUpDut(dataWidth: 64);

      await bus.write(_divider, 0x1234, sel: 0x0f);
      final before = await bus.read(_divider);

      await bus.write(_divider, 0x5678 << 32, sel: 0xf0);
      final after = await bus.read(_divider);

      expect(before, equals(0x1234));
      expect(after, equals(before));
      await Simulator.endSimulation();
    });

    // DATA's read side effect (the RX pop) must only act on DATA's own
    // lane. A read of the padding upper half of its 8-byte slot (64-bit
    // bus) must leave the received byte in place.
    test('a read of the upper lane of DATA does not pop the RX byte '
        '(64-bit bus)', () async {
      await setUpDut(dataWidth: 64);

      await bus.write(_divider, 1);
      await bus.write(_ctrl, 0x9); // enable | loopback
      await bus.write(_data, 0x5a);

      var st = await bus.read(_status);
      var guard = 0;
      while (st & 0x1 != 0 && guard < 200) {
        st = await bus.read(_status);
        guard++;
      }
      expect(st & 0x4, equals(0x4), reason: 'rx_ready should be set');

      // A read of the upper lane does not pop it.
      await bus.read(_data, sel: 0xf0);
      expect(await bus.read(_status) & 0x4, equals(0x4));

      // Reading DATA's own lane pops it and returns the byte.
      expect(await bus.read(_data, sel: 0x0f) & 0xff, equals(0x5a));
      expect(await bus.read(_status) & 0x4, equals(0));

      await Simulator.endSimulation();
    });

    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      await bus.write(_divider, 1);
      await bus.write(_ctrl, 0x9); // enable | loopback
      await bus.write(_data, 0xaa); // start and finish a transfer

      var st = await bus.read(_status);
      var guard = 0;
      while (st & 0x1 != 0 && guard < 200) {
        st = await bus.read(_status);
        guard++;
      }
      expect(st & 0x1, equals(0));
      expect(await bus.read(_data) & 0xff, equals(0xaa));

      // A write with SEL 0 to DATA must not touch the shift register or
      // start a new transfer: busy stays clear and DATA still reads the
      // byte from the finished transfer above.
      await bus.write(_data, 0x55, sel: 0x0);
      expect(await bus.read(_status) & 0x1, equals(0));
      expect(await bus.read(_data) & 0xff, equals(0xaa));

      // DIVIDER (a plain merge register) must also ignore a SEL-0 write.
      await bus.write(_divider, 0xffffffff, sel: 0x0);
      expect(await bus.read(_divider), equals(1));

      await Simulator.endSimulation();
    });
  });
}

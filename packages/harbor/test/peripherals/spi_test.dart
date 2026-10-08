import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

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
        protocol: BusProtocol.wishbone,
      );
      final tl = HarborSpiController(
        baseAddress: 0x1000,
        protocol: BusProtocol.tilelink,
      );
      expect(wb.bus.protocol, equals(BusProtocol.wishbone));
      expect(tl.bus.protocol, equals(BusProtocol.tilelink));
    });
  });

  // Byte-address register map (see HarborSpiController): each register is in
  // its own 64-bit-aligned slot.
  const ctrl = 0x00;
  const status = 0x08;
  const data = 0x10;
  const divider = 0x18;

  group('HarborSpiController loopback (functional)', () {
    late HarborSpiController spi;
    late Logic clk, reset, cyc, stb, we, adr, mosi, miso;

    Future<void> busWrite(int addr, int value) async {
      adr.inject(addr);
      mosi.inject(value);
      we.inject(1);
      cyc.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (spi.bus.ack.value.toInt() != 1) {
        await clk.nextPosedge;
      }
      cyc.inject(0);
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<int> busRead(int addr) async {
      adr.inject(addr);
      we.inject(0);
      cyc.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (spi.bus.ack.value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final d = spi.bus.dataOut.value.toInt();
      cyc.inject(0);
      stb.inject(0);
      await clk.nextPosedge;
      return d;
    }

    tearDown(() async => Simulator.reset());

    test(
      'a byte written in loopback returns intact (no bit rotation)',
      () async {
        spi = HarborSpiController(baseAddress: 0x1000);
        clk = SimpleClockGenerator(10).clk;
        reset = Logic(name: 'reset');
        cyc = Logic(name: 'cyc');
        stb = Logic(name: 'stb');
        we = Logic(name: 'we');
        adr = Logic(name: 'adr', width: spi.input('bus_ADR').width);
        mosi = Logic(name: 'mosi', width: 32);
        miso = Logic(name: 'miso');

        spi.input('clk').srcConnection! <= clk;
        spi.input('reset').srcConnection! <= reset;
        spi.input('bus_CYC').srcConnection! <= cyc;
        spi.input('bus_STB').srcConnection! <= stb;
        spi.input('bus_WE').srcConnection! <= we;
        spi.input('bus_ADR').srcConnection! <= adr;
        spi.input('bus_DAT_MOSI').srcConnection! <= mosi;
        spi.input('bus_SEL').srcConnection! <=
            Const(0xF, width: spi.input('bus_SEL').width);
        spi.input('spi_miso').srcConnection! <= miso;

        await spi.build();
        reset.inject(1);
        cyc.inject(0);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        miso.inject(0);
        Simulator.setMaxSimTime(1000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        // At reset STATUS must show tx_empty (bit1) set: proves the byte-address
        // decode reaches the right register (the old word-index decode read 0).
        expect(await busRead(status), equals(0x2));

        await busWrite(divider, 1);
        await busWrite(ctrl, 0x9); // enable | loopback
        await busWrite(data, 0xA5); // start a transfer

        var st = await busRead(status);
        var guard = 0;
        while (st & 0x1 != 0 && guard < 200) {
          st = await busRead(status);
          guard++;
        }
        expect(st & 0x1, equals(0), reason: 'transfer should finish');

        // Loopback feeds MOSI back to MISO: an 8-bit exchange must return the
        // exact byte. A one-bit rotation here is the "capture before the 8th
        // shift" bug.
        expect(await busRead(data) & 0xFF, equals(0xA5));

        await Simulator.endSimulation();
      },
    );
  });

  group('HarborSpiController byte-lane writes', () {
    late HarborSpiController spi;
    late Logic clk, reset, cyc, stb, we, adr, mosi, sel, miso;

    int allSel() => (1 << sel.width) - 1;

    Future<void> busWrite(int addr, int value) async {
      adr.inject(addr);
      mosi.inject(value);
      sel.inject(allSel());
      we.inject(1);
      cyc.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (spi.bus.ack.value.toInt() != 1) {
        await clk.nextPosedge;
      }
      cyc.inject(0);
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<void> busWriteSel(int addr, int selMask, int value) async {
      adr.inject(addr);
      mosi.inject(value);
      sel.inject(selMask);
      we.inject(1);
      cyc.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (spi.bus.ack.value.toInt() != 1) {
        await clk.nextPosedge;
      }
      cyc.inject(0);
      stb.inject(0);
      we.inject(0);
      sel.inject(allSel());
      await clk.nextPosedge;
    }

    Future<int> busRead(int addr) async {
      adr.inject(addr);
      we.inject(0);
      cyc.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (spi.bus.ack.value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final d = spi.bus.dataOut.value.toInt();
      cyc.inject(0);
      stb.inject(0);
      await clk.nextPosedge;
      return d;
    }

    Future<void> setUpDut({int dataWidth = 32}) async {
      spi = HarborSpiController(baseAddress: 0x1000, busDataWidth: dataWidth);
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      cyc = Logic(name: 'cyc');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: spi.input('bus_ADR').width);
      mosi = Logic(name: 'mosi', width: dataWidth);
      sel = Logic(name: 'sel', width: dataWidth ~/ 8);
      miso = Logic(name: 'miso');

      spi.input('clk').srcConnection! <= clk;
      spi.input('reset').srcConnection! <= reset;
      spi.input('bus_CYC').srcConnection! <= cyc;
      spi.input('bus_STB').srcConnection! <= stb;
      spi.input('bus_WE').srcConnection! <= we;
      spi.input('bus_ADR').srcConnection! <= adr;
      spi.input('bus_DAT_MOSI').srcConnection! <= mosi;
      spi.input('bus_SEL').srcConnection! <= sel;
      spi.input('spi_miso').srcConnection! <= miso;

      await spi.build();
      reset.inject(1);
      cyc.inject(0);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      sel.inject(allSel());
      miso.inject(0);
      Simulator.setMaxSimTime(1000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    tearDown(() async => Simulator.reset());

    test('a byte store changes only the selected byte (32-bit bus)', () async {
      await setUpDut();

      await busWrite(divider, 0x1234);
      // SEL=0b0001: only byte 0 of the write data is live.
      await busWriteSel(divider, 0x1, 0x00000099);
      expect(await busRead(divider), equals(0x1299));
      await Simulator.endSimulation();
    });

    test(
      'a halfword store changes only the selected halfword (32-bit bus)',
      () async {
        await setUpDut();

        await busWrite(divider, 0x1234);
        await busWriteSel(divider, 0x3, 0x0000beef);
        expect(await busRead(divider), equals(0xbeef));
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

      await busWriteSel(divider, 0x0f, 0x1234);
      final before = await busRead(divider);

      await busWriteSel(divider, 0xf0, 0x5678 << 32);
      final after = await busRead(divider);

      expect(before, equals(0x1234));
      expect(after, equals(before));
      await Simulator.endSimulation();
    });
  });
}

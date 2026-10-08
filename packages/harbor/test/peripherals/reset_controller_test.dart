import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register byte offsets: each register in its own 8-byte slot.
const _ctrl = 0x00;
const _holdTime = 0x10;
const _domainRst = 0x18;
const _wdogEn = 0x28;

void main() {
  group('HarborResetController', () {
    test('creates with defaults', () {
      final rc = HarborResetController(baseAddress: 0x10005000);
      expect(rc.bus, isNotNull);
      expect(rc.domainResets.width, equals(4));
    });

    test('DT node is correct', () {
      final rc = HarborResetController(baseAddress: 0x10005000);
      final dt = rc.dtNode;
      expect(dt.compatible.first, equals('harbor,reset-controller'));
      expect(dt.reg.start, equals(0x10005000));
    });
  });

  group('HarborResetController register access', () {
    late HarborResetController rc;
    late Logic clk, por, stb, we, adr, mosi, sel;

    int allSel() => (1 << sel.width) - 1;

    Future<void> busWrite(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      sel.inject(allSel());
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (rc.output('bus_ACK').value.toInt() != 1) {
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
      while (rc.output('bus_ACK').value.toInt() != 1) {
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
      while (rc.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = rc.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    setUp(() async {
      rc = HarborResetController(baseAddress: 0x10005000);
      clk = SimpleClockGenerator(10).clk;
      por = Logic(name: 'por');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 8);
      mosi = Logic(name: 'mosi', width: 32);
      sel = Logic(name: 'sel', width: 4);

      rc.input('clk').srcConnection! <= clk;
      rc.input('por').srcConnection! <= por;
      rc.input('ext_reset').srcConnection! <= Const(0);
      rc.input('wdog_reset').srcConnection! <= Const(0);
      rc.input('debug_reset').srcConnection! <= Const(0);
      rc.input('bus_CYC').srcConnection! <= stb;
      rc.input('bus_STB').srcConnection! <= stb;
      rc.input('bus_WE').srcConnection! <= we;
      rc.input('bus_ADR').srcConnection! <= adr;
      rc.input('bus_DAT_MOSI').srcConnection! <= mosi;
      rc.input('bus_SEL').srcConnection! <= sel;

      await rc.build();

      por.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      sel.inject(allSel());
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      por.inject(0);
      await clk.nextPosedge;
      // Clear the power-on reset hold so the bus registers are reachable.
      for (var i = 0; i < 300; i++) {
        await clk.nextPosedge;
      }
    });

    tearDown(() async => Simulator.reset());

    // Regression: the decode used to match only the low 6 bits of the byte
    // address inside an 8-bit (256-byte) window, aliasing each register
    // every 0x40 bytes. Confirms distinct registers and full-address decode.
    test('every register decodes at its own 8-byte slot', () async {
      await busWrite(_holdTime, 0x1234);
      expect(await busRead(_holdTime), equals(0x1234));

      await busWrite(_domainRst, 0xa);
      expect(await busRead(_domainRst), equals(0xa));

      // The registers are distinct, not aliases of one another.
      expect(await busRead(_holdTime), equals(0x1234));

      // An address outside the defined map reads 0 and ignores writes.
      await busWrite(0x40, 0xdeadbeef);
      expect(await busRead(0x40), equals(0));
      expect(await busRead(_holdTime), equals(0x1234));
      await Simulator.endSimulation();
    });

    test('a byte store changes only the selected byte', () async {
      await busWrite(_holdTime, 0x1122);
      await busWriteSel(_holdTime, 0x1, 0x99);
      expect(await busRead(_holdTime), equals(0x1199));
      await Simulator.endSimulation();
    });

    test('WDOG_RST_EN is a plain read/write bit, not CTRL', () async {
      await busWrite(_wdogEn, 0x1);
      expect(await busRead(_wdogEn), equals(0x1));
      expect(await busRead(_ctrl), equals(0));
      await Simulator.endSimulation();
    });
  });
}

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

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

    test('different domain counts get different definition names', () {
      final a = HarborResetController(baseAddress: 0x10005000, domainCount: 4);
      final b = HarborResetController(baseAddress: 0x10005000, domainCount: 8);
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  for (final kind in HarborFabricKind.values) {
    registerTests(kind);
  }
}

void registerTests(HarborFabricKind kind) {
  group('HarborResetController register access (${kind.name})', () {
    late HarborResetController rc;
    late Logic clk, por;
    late RegBus bus;

    setUp(() async {
      rc = HarborResetController(baseAddress: 0x10005000, fabricKind: kind);
      clk = SimpleClockGenerator(10).clk;
      por = Logic(name: 'por');

      rc.input('clk').srcConnection! <= clk;
      rc.input('por').srcConnection! <= por;
      rc.input('ext_reset').srcConnection! <= Const(0);
      rc.input('wdog_reset').srcConnection! <= Const(0);
      rc.input('debug_reset').srcConnection! <= Const(0);
      bus = RegBus.attach(rc, clk);

      await rc.build();

      por.inject(1);
      bus.idle();
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
      await bus.write(_holdTime, 0x1234);
      expect(await bus.read(_holdTime), equals(0x1234));

      await bus.write(_domainRst, 0xa);
      expect(await bus.read(_domainRst), equals(0xa));

      // The registers are distinct, not aliases of one another.
      expect(await bus.read(_holdTime), equals(0x1234));

      // An address outside the defined map reads 0 and ignores writes.
      await bus.write(0x40, 0xdeadbeef);
      expect(await bus.read(0x40), equals(0));
      expect(await bus.read(_holdTime), equals(0x1234));
      await Simulator.endSimulation();
    });

    test('a byte store changes only the selected byte', () async {
      await bus.write(_holdTime, 0x1122);
      await bus.write(_holdTime, 0x99, sel: 0x1);
      expect(await bus.read(_holdTime), equals(0x1199));
      await Simulator.endSimulation();
    });

    // A write with no byte selected must not change any register.
    test('a write with no byte selected changes nothing', () async {
      await bus.write(_holdTime, 0x1234);
      await bus.write(_domainRst, 0xa);
      await bus.write(_holdTime, 0xffffffff, sel: 0x0);
      await bus.write(_domainRst, 0xffffffff, sel: 0x0);

      expect(await bus.read(_holdTime), equals(0x1234));
      expect(await bus.read(_domainRst), equals(0xa));
      await Simulator.endSimulation();
    });

    test('WDOG_RST_EN is a plain read/write bit, not CTRL', () async {
      await bus.write(_wdogEn, 0x1);
      expect(await bus.read(_wdogEn), equals(0x1));
      expect(await bus.read(_ctrl), equals(0));
      await Simulator.endSimulation();
    });

    test('an absolute address decodes inside the window', () async {
      // The 12-bit port carries the low bits of 0x10005000 + offset.
      const base = 0x10005000 & 0xFFF;
      await bus.write(base + _holdTime, 0x4321);
      expect(await bus.read(base + _holdTime), equals(0x4321));
      expect(await bus.read(base + 0x100 + _holdTime), equals(0));
      await Simulator.endSimulation();
    });
  });
}

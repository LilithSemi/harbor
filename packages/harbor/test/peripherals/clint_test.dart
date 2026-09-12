import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  group('HarborClint', () {
    test('creates with default hart count', () {
      final clint = HarborClint(baseAddress: 0x02000000);
      expect(clint.timerInterrupt, hasLength(1));
      expect(clint.softwareInterrupt, hasLength(1));
    });

    test('creates with multiple harts', () {
      final clint = HarborClint(baseAddress: 0x02000000, hartCount: 4);
      expect(clint.timerInterrupt, hasLength(4));
      expect(clint.softwareInterrupt, hasLength(4));
    });

    test('has bus interface', () {
      final clint = HarborClint(baseAddress: 0x02000000);
      expect(clint.bus, isNotNull);
    });

    test('DT node is correct', () {
      final clint = HarborClint(baseAddress: 0x02000000);
      final dt = clint.dtNode;
      expect(dt.compatible.first, equals('riscv,clint0'));
      expect(dt.reg.start, equals(0x02000000));
      expect(dt.reg.size, equals(0x10000));
    });
  });

  laneTests();
}

// Bus-lane decode, driven the way the core drives it. The River MMU and the
// debug SBA both put a word-aligned address on the bus and shift the write
// data and SEL into the byte lane of the access (mmu.dart wbAdr/wbDatMosi/
// wbSel, sba_wishbone.dart alignedAddr/wbSel). On a 64-bit bus that means the
// mtimecmp high half arrives in lane 1, never in lane 0.
void laneTests() {
  group('HarborClint bus lane decode', () {
    late HarborClint clint;
    late Logic clk, reset, stb, we, adr, mosi, sel;
    late int busBytes;

    Future<void> setUpDut({required int dataWidth, int hartCount = 1}) async {
      busBytes = dataWidth ~/ 8;
      clint = HarborClint(
        baseAddress: 0x02000000,
        hartCount: hartCount,
        busAddressWidth: 32,
        busDataWidth: dataWidth,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 32);
      mosi = Logic(name: 'mosi', width: dataWidth);
      sel = Logic(name: 'sel', width: busBytes);

      clint.input('clk').srcConnection! <= clk;
      clint.input('reset').srcConnection! <= reset;
      clint.input('bus_CYC').srcConnection! <= stb;
      clint.input('bus_STB').srcConnection! <= stb;
      clint.input('bus_WE').srcConnection! <= we;
      clint.input('bus_ADR').srcConnection! <= adr;
      clint.input('bus_DAT_MOSI').srcConnection! <= mosi;
      clint.input('bus_SEL').srcConnection! <= sel;

      await clint.build();

      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      sel.inject(0);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    BigInt maskOf(int bits) => (BigInt.one << bits) - BigInt.one;

    Future<void> coreWrite(int byteAddr, int bytes, BigInt value) async {
      final lane = byteAddr % busBytes;
      adr.inject(byteAddr - lane);
      mosi.inject(
        LogicValue.ofBigInt(
          (value << (lane * 8)) & maskOf(busBytes * 8),
          busBytes * 8,
        ),
      );
      sel.inject(((1 << bytes) - 1) << lane);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (clint.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<BigInt> coreRead(int byteAddr, int bytes) async {
      final lane = byteAddr % busBytes;
      adr.inject(byteAddr - lane);
      sel.inject(((1 << bytes) - 1) << lane);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (clint.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final raw = clint.output('bus_DAT_MISO').value.toBigInt();
      stb.inject(0);
      await clk.nextPosedge;
      return (raw >> (lane * 8)) & maskOf(bytes * 8);
    }

    // mtime counts one tick per clock, so give it room to pass the compare.
    Future<void> waitTicks(int n) async {
      for (var i = 0; i < n; i++) {
        await clk.nextPosedge;
      }
    }

    tearDown(() async {
      await Simulator.reset();
    });

    // The M-mode firmware arms the timer with one 64-bit store to mtimecmp
    // (conduit clint driver, `mmio.write(u64, MTIMECMP)`). All 8 bytes are
    // selected, so both halves must take the data.
    test(
      '64-bit bus: a doubleword store writes both mtimecmp halves',
      () async {
        await setUpDut(dataWidth: 64);

        // A compare far in the future keeps the timer quiet.
        await coreWrite(0x4000, 8, BigInt.one << 32);
        expect(clint.output('timer_irq_0').value.toInt(), equals(0));

        // A compare mtime has already passed must fire. If the high half keeps
        // its all-ones reset value, this stays low forever.
        await coreWrite(0x4000, 8, BigInt.from(0x10));
        await waitTicks(40);
        expect(clint.output('timer_irq_0').value.toInt(), equals(1));

        await Simulator.endSimulation();
      },
    );

    test(
      '64-bit bus: a word store to mtimecmp+4 writes the high half',
      () async {
        await setUpDut(dataWidth: 64);

        // Clear the high half only. The low half keeps its all-ones reset value,
        // so the timer stays quiet.
        await coreWrite(0x4004, 4, BigInt.zero);
        await clk.nextPosedge;
        expect(clint.output('timer_irq_0').value.toInt(), equals(0));

        // Arm the low half with a value mtime has passed.
        await coreWrite(0x4000, 4, BigInt.from(0x10));
        await waitTicks(40);
        expect(clint.output('timer_irq_0').value.toInt(), equals(1));

        await Simulator.endSimulation();
      },
    );

    test('64-bit bus: mtimecmp reads back in the correct lanes', () async {
      await setUpDut(dataWidth: 64);

      await coreWrite(0x4000, 8, BigInt.parse('123456789abc', radix: 16));
      expect(
        await coreRead(0x4000, 4),
        equals(BigInt.parse('56789abc', radix: 16)),
      );
      expect(await coreRead(0x4004, 4), equals(BigInt.from(0x1234)));
      expect(
        await coreRead(0x4000, 8),
        equals(BigInt.parse('123456789abc', radix: 16)),
      );

      await Simulator.endSimulation();
    });

    test('64-bit bus: msip of hart 1 sits in lane 1', () async {
      await setUpDut(dataWidth: 64, hartCount: 2);

      await coreWrite(0x0004, 4, BigInt.one);
      await clk.nextPosedge;
      expect(clint.output('sw_irq_1').value.toInt(), equals(1));
      expect(clint.output('sw_irq_0').value.toInt(), equals(0));

      await coreWrite(0x0000, 4, BigInt.one);
      await clk.nextPosedge;
      expect(clint.output('sw_irq_0').value.toInt(), equals(1));
      expect(clint.output('sw_irq_1').value.toInt(), equals(1));

      await Simulator.endSimulation();
    });

    test('32-bit bus keeps the plain word behaviour', () async {
      await setUpDut(dataWidth: 32);

      await coreWrite(0x4004, 4, BigInt.zero);
      await clk.nextPosedge;
      expect(clint.output('timer_irq_0').value.toInt(), equals(0));

      await coreWrite(0x4000, 4, BigInt.from(0x10));
      await waitTicks(40);
      expect(clint.output('timer_irq_0').value.toInt(), equals(1));

      expect(await coreRead(0x4000, 4), equals(BigInt.from(0x10)));
      expect(await coreRead(0x4004, 4), equals(BigInt.zero));

      await coreWrite(0x0000, 4, BigInt.one);
      await clk.nextPosedge;
      expect(clint.output('sw_irq_0').value.toInt(), equals(1));

      await Simulator.endSimulation();
    });
  });
}

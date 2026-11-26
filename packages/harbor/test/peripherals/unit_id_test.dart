import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// 57 bit value with bit 56 set and an uneven pattern, so a reversed bit order
// or a shifted result gives a different word.
final _dna = BigInt.parse('15A5C3E7F2B4D96', radix: 16);
final _mask32 = BigInt.from(0xffffffff);

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUnitId clock divide', () {
    test('keeps the DNA_PORT clock at or below the limit', () {
      expect(HarborUnitId.clockDivideFor(50000000), 4);
      expect(HarborUnitId.clockDivideFor(100000000), 4);
      expect(HarborUnitId.clockDivideFor(250000000), 4);
      expect(HarborUnitId.clockDivideFor(300000000), 5);
      for (final hz in [25000000, 75000000, 125000000, 200000000, 333000000]) {
        final divide = HarborUnitId.clockDivideFor(hz);
        expect(divide, greaterThanOrEqualTo(HarborUnitId.minClockDivide));
        expect(hz / divide, lessThanOrEqualTo(HarborUnitId.maxDnaClockHz));
      }
    });

    test('rejects a divide below 4', () {
      expect(
        () => HarborUnitId(baseAddress: 0x1000, clockDivide: 3),
        throwsArgumentError,
      );
    });
  });

  group('HarborUnitId from a target', () {
    test('Xilinx targets get the DNA block', () {
      for (final target in const [
        HarborFpgaTarget.artix7(
          device: 'xc7a100t',
          package: 'csg324',
          useOpenXc7: true,
        ),
        HarborFpgaTarget.spartan7(device: 'xc7s50', package: 'csga324'),
        HarborFpgaTarget.kintex7(device: 'xc7k325t', package: 'ffg900'),
      ]) {
        final unit = HarborUnitId.fromTarget(
          baseAddress: 0x10000,
          target: target,
          busClockHz: 100000000,
        );
        expect(unit, isNotNull, reason: target.name);
        expect(unit!.source, HarborUnitIdSource.dna57);
        expect(unit.clockDivide, 4);
      }
    });

    test('a target without a source has no block', () {
      for (final target in const <HarborDeviceTarget>[
        HarborFpgaTarget.ecp5(device: 'LFE5U-85F', package: 'CABGA381'),
        HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48'),
        HarborSimTarget(topCell: 'soc', frequency: 25000000),
      ]) {
        expect(
          HarborUnitId.fromTarget(
            baseAddress: 0x10000,
            target: target,
            busClockHz: 50000000,
          ),
          isNull,
          reason: target.name,
        );
      }
    });

    test('the device tree node and the SVD peripheral', () {
      final unit = HarborUnitId(baseAddress: 0x10005000);
      final node = unit.dtNode;
      expect(node.compatible, ['harbor,unit-id']);
      expect(node.reg.start, 0x10005000);
      expect(node.reg.size, 0x1000);
      final svd = unit.svdPeripheral;
      expect(svd.name, 'UNIT_ID');
      expect(svd.registers!.fieldNames, ['id_lo', 'id_hi', 'info']);
      expect(svd.registers!.validate(), isEmpty);
    });
  });

  for (final kind in HarborFabricKind.values) {
    for (final width in [32, 64]) {
      unitIdTests(kind, width);
    }
  }
}

void unitIdTests(HarborFabricKind kind, int busDataWidth) {
  group('HarborUnitId sim (${kind.name}, $busDataWidth bit)', () {
    late HarborUnitId unit;
    late Logic clk, reset;
    late RegBus bus;
    final dnaClkTimes = <int>[];

    Future<void> setUpDut(int divide, {BigInt? value}) async {
      unit = HarborUnitId(
        baseAddress: 0x14000,
        clockDivide: divide,
        simDnaValue: value ?? _dna,
        fabricKind: kind,
        busDataWidth: busDataWidth,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      unit.input('clk').srcConnection! <= clk;
      unit.input('reset').srcConnection! <= reset;
      bus = RegBus.attach(unit, clk);
      await unit.build();

      final port = unit.subModules.whereType<XilinxDnaPort>().single;
      dnaClkTimes.clear();
      port.input('CLK').posedge.listen((_) => dnaClkTimes.add(Simulator.time));

      reset.inject(1);
      bus.idle();
      Simulator.setMaxSimTime(1000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
    }

    Future<void> cycles(int n) async {
      for (var i = 0; i < n; i++) {
        await clk.nextPosedge;
      }
    }

    Future<BigInt> readId() async {
      final lo = await bus.read(HarborUnitId.idLowOffset);
      final hi = await bus.read(HarborUnitId.idHighOffset);
      return (BigInt.from(hi) << 32) | BigInt.from(lo);
    }

    for (final divide in [4, 5, 6, 7, 8]) {
      test('divide $divide returns the DNA, MSB first', () async {
        await setUpDut(divide);
        await cycles((57 + 4) * divide);

        final info = await bus.read(HarborUnitId.infoOffset);
        expect(info & 1, 1, reason: 'valid');
        expect((info >> 4) & 0xf, 1, reason: 'source dna57');
        expect((info >> 8) & 0xff, 57, reason: 'width');

        final id = await readId();
        expect(id, _dna);
        expect(
          await bus.read(HarborUnitId.idHighOffset),
          (_dna >> 32).toInt(),
          reason: 'bit 56 is bit 24 of the high word',
        );
        expect(
          await bus.read(HarborUnitId.idLowOffset),
          (_dna & _mask32).toInt(),
        );
        await Simulator.endSimulation();
      });
    }

    test('a value of one comes out in bit 0, not bit 56', () async {
      await setUpDut(4, value: BigInt.one);
      await cycles(70 * 4);
      expect(await readId(), BigInt.one);
      await Simulator.endSimulation();
    });

    test('a value with only bit 56 set comes out in bit 56', () async {
      await setUpDut(4, value: BigInt.one << 56);
      await cycles(70 * 4);
      expect(await bus.read(HarborUnitId.idLowOffset), 0);
      expect(await bus.read(HarborUnitId.idHighOffset), 1 << 24);
      await Simulator.endSimulation();
    });

    test('reads before valid return valid 0 and no ID', () async {
      await setUpDut(4);
      await cycles(2);
      expect(await bus.read(HarborUnitId.infoOffset) & 1, 0);
      expect(await bus.read(HarborUnitId.idLowOffset), 0);
      expect(await bus.read(HarborUnitId.idHighOffset), 0);
      await cycles(30 * 4);
      expect(await bus.read(HarborUnitId.infoOffset) & 1, 0);
      expect(await bus.read(HarborUnitId.idHighOffset), 0);

      await cycles(32 * 4);
      expect(await bus.read(HarborUnitId.infoOffset) & 1, 1);
      expect(await readId(), _dna);
      await Simulator.endSimulation();
    });

    test('the DNA_PORT clock period is the divide', () async {
      await setUpDut(6);
      await cycles(70 * 6);
      // Clock period is 10 time units.
      expect(dnaClkTimes.length, greaterThan(57));
      for (var i = 1; i < dnaClkTimes.length; i++) {
        expect(dnaClkTimes[i] - dnaClkTimes[i - 1], 60);
      }
      await Simulator.endSimulation();
    });

    for (final divide in [4, 5, 6, 7, 8]) {
      test('divide $divide: READ and SHIFT change only while the DNA clock '
          'is low', () async {
        await setUpDut(divide);
        final port = unit.subModules.whereType<XilinxDnaPort>().single;
        final control = <int>[];
        port.input('READ').changed.listen((_) => control.add(Simulator.time));
        port.input('SHIFT').changed.listen((_) => control.add(Simulator.time));
        final clockLevelAtChange = <bool>[];
        port
            .input('READ')
            .changed
            .listen(
              (_) => clockLevelAtChange.add(
                port.input('CLK').value == LogicValue.one,
              ),
            );
        port
            .input('SHIFT')
            .changed
            .listen(
              (_) => clockLevelAtChange.add(
                port.input('CLK').value == LogicValue.one,
              ),
            );
        await cycles(70 * divide);

        // READ rises, falls, SHIFT rises and falls, at least.
        expect(control.length, greaterThanOrEqualTo(4));
        final rises = dnaClkTimes.toSet();
        for (final t in control) {
          expect(rises, isNot(contains(t)), reason: 'control change at $t');
        }
        expect(clockLevelAtChange, everyElement(isFalse));

        // The DNA clock stays low after valid is set.
        final count = dnaClkTimes.length;
        await cycles(20 * divide);
        expect(dnaClkTimes.length, count);
        expect(port.input('CLK').value, LogicValue.zero);
        await Simulator.endSimulation();
      });
    }

    test('writes do not change the ID', () async {
      await setUpDut(4);
      await cycles(70 * 4);
      await bus.write(HarborUnitId.idLowOffset, 0xdeadbeef);
      await bus.write(HarborUnitId.infoOffset, 0);
      expect(await readId(), _dna);
      expect(await bus.read(HarborUnitId.infoOffset) & 1, 1);
      await Simulator.endSimulation();
    });

    test('a reset reads the ID again', () async {
      await setUpDut(4);
      await cycles(70 * 4);
      expect(await readId(), _dna);
      reset.inject(1);
      await cycles(2);
      reset.inject(0);
      await cycles(1);
      expect(await bus.read(HarborUnitId.infoOffset) & 1, 0);
      await cycles(70 * 4);
      expect(await readId(), _dna);
      await Simulator.endSimulation();
    });
  });
}

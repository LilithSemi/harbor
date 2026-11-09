import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborSram', () {
    test('creates with size and baseAddress', () {
      final sram = HarborSram(baseAddress: 0x80000000, size: 4096);
      expect(sram.size, equals(4096));
      expect(sram.baseAddress, equals(0x80000000));
    });

    test('has bus', () {
      final sram = HarborSram(baseAddress: 0x80000000, size: 4096);
      expect(sram.bus, isNotNull);
    });

    test('DT node compatible', () {
      final sram = HarborSram(baseAddress: 0x80000000, size: 4096);
      final dt = sram.dtNode;
      expect(dt.compatible, equals(['harbor,sram', 'mmio-sram']));
    });

    test('DT reg.size matches input size', () {
      final sram = HarborSram(
        baseAddress: 0x80000000,
        size: 8192,
        target: const HarborSimTarget(),
      );
      final dt = sram.dtNode;
      expect(dt.reg.size, equals(8192));
      expect(dt.reg.start, equals(0x80000000));
    });

    test('data width 32 (default)', () {
      final sram = HarborSram(baseAddress: 0x80000000, size: 4096);
      expect(sram.dataWidth, equals(32));
    });

    test('data width 64', () {
      final sram = HarborSram(
        baseAddress: 0x80000000,
        size: 4096,
        dataWidth: 64,
      );
      expect(sram.dataWidth, equals(64));
    });
  });

  group('HarborSram FPGA backends', () {
    test('Spartan 7 emits RAMB36E1 and no Lattice primitives', () async {
      final sram = HarborSram(
        baseAddress: 0x80000000,
        size: 4096,
        target: const HarborFpgaTarget.spartan7(
          device: 's50',
          package: 'csga324',
        ),
      );
      await sram.build();
      final sv = sram.dumpSystemVerilog();
      expect(sv, contains('RAMB36E1'));
      expect(sv, isNot(contains('DP16KD')));
      expect(sv, isNot(contains('SPRAM')));
    });

    test('ECP5 still emits DP16KD, not Xilinx primitives', () async {
      final sram = HarborSram(
        baseAddress: 0x80000000,
        size: 4096,
        target: const HarborFpgaTarget.ecp5(device: '25f', package: 'CABGA256'),
      );
      await sram.build();
      final sv = sram.dumpSystemVerilog();
      expect(sv, contains('DP16KD'));
      expect(sv, isNot(contains('RAMB36E1')));
    });
  });
}

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('RiscVMxlen', () {
    test('sizes', () {
      expect(RiscVMxlen.rv32.size, equals(32));
      expect(RiscVMxlen.rv64.size, equals(64));
      expect(RiscVMxlen.rv128.size, equals(128));
    });

    test('misa XL field', () {
      expect(RiscVMxlen.rv32.misaXl, equals(1));
      expect(RiscVMxlen.rv64.misaXl, equals(2));
    });
  });

  group('RiscVPagingMode', () {
    test('Sv32 only for RV32', () {
      expect(RiscVPagingMode.sv32.isSupported(RiscVMxlen.rv32), isTrue);
      expect(RiscVPagingMode.sv32.isSupported(RiscVMxlen.rv64), isFalse);
    });

    test('Sv39/48/57 for RV64', () {
      expect(RiscVPagingMode.sv39.isSupported(RiscVMxlen.rv64), isTrue);
      expect(RiscVPagingMode.sv48.isSupported(RiscVMxlen.rv64), isTrue);
      expect(RiscVPagingMode.sv57.isSupported(RiscVMxlen.rv64), isTrue);
    });

    test('bare supported everywhere', () {
      for (final mxlen in RiscVMxlen.values) {
        expect(RiscVPagingMode.bare.isSupported(mxlen), isTrue);
      }
    });

    test('supportedBy filters correctly', () {
      final rv32Modes = RiscVPagingMode.supportedBy(RiscVMxlen.rv32);
      expect(rv32Modes, contains(RiscVPagingMode.bare));
      expect(rv32Modes, contains(RiscVPagingMode.sv32));
      expect(rv32Modes, isNot(contains(RiscVPagingMode.sv39)));

      final rv64Modes = RiscVPagingMode.supportedBy(RiscVMxlen.rv64);
      expect(rv64Modes, contains(RiscVPagingMode.bare));
      expect(rv64Modes, contains(RiscVPagingMode.sv39));
      expect(rv64Modes, isNot(contains(RiscVPagingMode.sv32)));
    });

    test('virtualBits', () {
      expect(RiscVPagingMode.sv32.virtualBits, equals(32));
      expect(RiscVPagingMode.sv39.virtualBits, equals(39));
      expect(RiscVPagingMode.sv48.virtualBits, equals(48));
      expect(RiscVPagingMode.sv57.virtualBits, equals(57));
    });
  });

  group('Resource', () {
    test('RfResource describes register access', () {
      const r = RfResource(RiscVIntRegFile(32), rs1);
      expect(r.access, equals(rs1));
      expect(r.toString(), contains('RS1'));
    });

    test('MemoryResource', () {
      const load = MemoryResource.load();
      const store = MemoryResource.store();
      expect(load.isLoad, isTrue);
      expect(store.isLoad, isFalse);
    });
  });

  group('RV32I extension', () {
    test('has correct number of operations', () {
      // lui, auipc, jal, jalr, 6 branches, 5 loads, 3 stores,
      // 6 alu-imm, 3 shifts, 10 alu-reg, fence, ecall, ebreak = 37
      expect(rv32i.operations.length, greaterThanOrEqualTo(35));
    });

    test('findOperation matches ADD', () {
      final add = rv32i.findOperation(0x00000033);
      expect(add, isNotNull);
      expect(add!.mnemonic, equals('add'));
    });

    test('findOperation matches SUB', () {
      final sub = rv32i.findOperation(0x40000033);
      expect(sub, isNotNull);
      expect(sub!.mnemonic, equals('sub'));
    });

    test('ADD has correct resources', () {
      final add = rv32i.findOperation(0x00000033)!;
      expect(
        add.resources.whereType<RfResource>(),
        hasLength(3),
      ); // rs1, rs2, rd
    });

    test('LW has memory resource', () {
      final lw = rv32i.findOperation(0x00002003);
      expect(lw, isNotNull);
      expect(lw!.resources.whereType<MemoryResource>(), hasLength(1));
    });

    test('all operations have microcode', () {
      for (final op in rv32i.operations) {
        expect(
          op.microcode,
          isNotEmpty,
          reason: '${op.mnemonic} has no microcode',
        );
      }
    });
  });

  group('RV64I extension', () {
    test('operations are XLEN-constrained', () {
      for (final op in rv64i.operations) {
        expect(op.isValidFor(RiscVMxlen.rv64), isTrue);
        expect(op.isValidFor(RiscVMxlen.rv32), isFalse);
      }
    });

    test('has word-width ops', () {
      final addw = rv64i.findOperation(0x0000003B);
      expect(addw, isNotNull);
      expect(addw!.mnemonic, equals('addw'));
    });
  });

  group('M extension', () {
    test('has mul/div operations', () {
      expect(rvM.findOperation(0x02000033)?.mnemonic, equals('mul'));
      expect(rvM.findOperation(0x02004033)?.mnemonic, equals('div'));
    });

    test('mul/div are microcoded by default', () {
      final div = rvM.findOperation(0x02004033)!;
      expect(div.executionMode, equals(RiscVExecutionMode.microcoded));
    });
  });

  group('C extension', () {
    test('has compressed operations', () {
      expect(rvC.operations, isNotEmpty);
      // Check c.addi exists
      final caddi = rvC.operations.firstWhere((o) => o.mnemonic == 'c.addi');
      expect(caddi.microcode, isNotEmpty);
    });
  });

  group('V extension', () {
    test('has vector operations', () {
      expect(rvV.operations, isNotEmpty);
      expect(rvV.operations.any((o) => o.mnemonic == 'vadd.vv'), isTrue);
      expect(rvV.operations.any((o) => o.mnemonic == 'vsetvli'), isTrue);
    });

    test('vector ops have VectorResource', () {
      final vadd = rvV.operations.firstWhere((o) => o.mnemonic == 'vadd.vv');
      expect(vadd.resources.whereType<VectorResource>(), hasLength(1));
    });
  });

  group('H extension', () {
    test('has hypervisor operations', () {
      expect(rvH.operations, isNotEmpty);
      expect(rvH.operations.any((o) => o.mnemonic == 'hfence.vvma'), isTrue);
      expect(rvH.operations.any((o) => o.mnemonic == 'hlv.w'), isTrue);
    });

    test('hypervisor ops require privilege', () {
      final hlv = rvH.operations.firstWhere((o) => o.mnemonic == 'hlv.w');
      expect(hlv.privilegeLevel, equals(1)); // S-mode
    });
  });

  group('RiscVIsaConfig', () {
    test('implementsString for RV64IMAC', () {
      final isa = RiscVIsaConfig(
        mxlen: RiscVMxlen.rv64,
        extensions: [rv32i, rv64i, rvM, rvA, rvC],
      );
      expect(isa.implementsString, equals('RV64IMAC'));
    });

    test('implementsString with all extensions', () {
      final isa = RiscVIsaConfig(
        mxlen: RiscVMxlen.rv64,
        extensions: [rv32i, rv64i, rvM, rvA, rvF, rvD, rvV, rvC, rvH],
        hasSupervisor: true,
        hasUser: true,
      );
      expect(isa.implementsString, contains('RV64I'));
      expect(isa.implementsString, contains('M'));
      expect(isa.implementsString, contains('A'));
      expect(isa.implementsString, contains('F'));
      expect(isa.implementsString, contains('D'));
      expect(isa.implementsString, contains('V'));
      expect(isa.implementsString, contains('C'));
      expect(isa.implementsString, contains('H'));
      expect(isa.implementsString, contains('S'));
      expect(isa.implementsString, contains('U'));
    });

    test('allOperations filters by XLEN', () {
      final isa32 = RiscVIsaConfig(
        mxlen: RiscVMxlen.rv32,
        extensions: [rv32i, rv64i],
      );
      // RV64I ops should be filtered out
      expect(isa32.allOperations.any((o) => o.mnemonic == 'addw'), isFalse);
      expect(isa32.allOperations.any((o) => o.mnemonic == 'add'), isTrue);

      final isa64 = RiscVIsaConfig(
        mxlen: RiscVMxlen.rv64,
        extensions: [rv32i, rv64i],
      );
      expect(isa64.allOperations.any((o) => o.mnemonic == 'addw'), isTrue);
      expect(isa64.allOperations.any((o) => o.mnemonic == 'add'), isTrue);
    });

    test('executionOverrides work', () {
      final isa = RiscVIsaConfig(
        mxlen: RiscVMxlen.rv64,
        extensions: [rv32i, rvM],
        executionOverrides: {'mul': RiscVExecutionMode.hardcoded},
      );

      final mul = isa.allOperations.firstWhere((o) => o.mnemonic == 'mul');
      expect(isa.executionModeFor(mul), equals(RiscVExecutionMode.hardcoded));
      // Default is microcoded
      expect(mul.executionMode, equals(RiscVExecutionMode.microcoded));
    });

    test('findOperation decodes instruction', () {
      final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv32, extensions: [rv32i]);

      // ADD x1, x2, x3 = 0x003100B3
      final add = isa.findOperation(0x003100B3);
      expect(add, isNotNull);
      expect(add!.mnemonic, equals('add'));
    });

    test('misaValue includes extensions', () {
      final isa = RiscVIsaConfig(
        mxlen: RiscVMxlen.rv64,
        extensions: [rv32i, rvM, rvA, rvC],
        hasSupervisor: true,
        hasUser: true,
      );

      final misa = isa.misaValue;
      // Check I bit (8), M bit (12), A bit (0), C bit (2), S bit (18), U bit (20)
      expect(misa & (1 << 8), isNot(0)); // I
      expect(misa & (1 << 12), isNot(0)); // M
      expect(misa & (1 << 0), isNot(0)); // A
      expect(misa & (1 << 2), isNot(0)); // C
      expect(misa & (1 << 18), isNot(0)); // S
      expect(misa & (1 << 20), isNot(0)); // U
    });

    test('paging modes default from XLEN', () {
      final isa = RiscVIsaConfig(mxlen: RiscVMxlen.rv64, extensions: [rv32i]);

      expect(isa.effectivePagingModes, contains(RiscVPagingMode.sv39));
      expect(isa.effectivePagingModes, isNot(contains(RiscVPagingMode.sv32)));
    });
  });
}

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

/// Reference 16-bit words from GNU as (`riscv64-none-elf-as -march=rv64gc`).
/// The comment on each line is the instruction that the assembler encoded.
const _cFld24 = 0x2D18; // c.fld f14, 24(x10)
const _cFld200 = 0x25E4; // c.fld f9, 200(x11)
const _cFsd24 = 0xAD10; // c.fsd f12, 24(x10)
const _cFsd200 = 0xA6FC; // c.fsd f15, 200(x13)
const _cFldsp8 = 0x2122; // c.fldsp f2, 8(sp)
const _cFldsp264 = 0x2FB2; // c.fldsp f31, 264(sp)
const _cFsdsp16 = 0xA822; // c.fsdsp f8, 16(sp)
const _cFsdsp320 = 0xA282; // c.fsdsp f0, 320(sp)

RiscVOperation _op(String mnemonic) =>
    rvZcd.operations.firstWhere((o) => o.mnemonic == mnemonic);

RiscVOperation? _find(RiscVExtension ext, int word, {RiscVMxlen? mxlen}) =>
    ext.findOperation(word, mxlen: mxlen ?? RiscVMxlen.rv64);

void main() {
  group('Zcd extension shape', () {
    test('defines the four compressed double-precision memory operations', () {
      expect(rvZcd.operations.map((o) => o.mnemonic), [
        'c.fld',
        'c.fsd',
        'c.fldsp',
        'c.fsdsp',
      ]);
    });

    test('has no misa bit of its own', () {
      // Zcd is reported through C and D, not through a bit of its own.
      expect(rvZcd.key, isNull);
      expect(rvZcd.misaBit, isNull);
      expect(rvZcd.mask, equals(0));
    });

    test('is valid on RV32 and RV64', () {
      for (final op in rvZcd.operations) {
        expect(op.isValidFor(RiscVMxlen.rv64), isTrue, reason: op.mnemonic);
        expect(op.isValidFor(RiscVMxlen.rv32), isTrue, reason: op.mnemonic);
      }
    });

    test('the C extension alone does not supply them', () {
      // A core with C but no D must trap c.fld and friends as illegal, so rvC
      // must not carry them.
      expect(rvC.operations.map((o) => o.mnemonic), isNot(contains('c.fld')));
      expect(rvC.operations.map((o) => o.mnemonic), isNot(contains('c.fsd')));
      expect(rvC.operations.map((o) => o.mnemonic), isNot(contains('c.fldsp')));
      expect(rvC.operations.map((o) => o.mnemonic), isNot(contains('c.fsdsp')));
      for (final word in [_cFld24, _cFsd24, _cFldsp8, _cFsdsp16]) {
        expect(_find(rvC, word), isNull);
      }
    });

    test('RV64 keeps funct3 011 and 111 for the integer forms', () {
      // There is no c.flw or c.fsw on RV64. Those encodings are c.ld / c.sd
      // and c.ldsp / c.sdsp.
      expect(_find(rvC, 0x6118)!.mnemonic, equals('c.ld')); // funct3 011, q0
      expect(_find(rvC, 0xE118)!.mnemonic, equals('c.sd')); // funct3 111, q0
      for (final op in rvZcd.operations) {
        expect(op.funct3, anyOf(equals(0x1), equals(0x5)));
      }
    });
  });

  group('Zcd encodings', () {
    test('c.fld uses quadrant 0, funct3 001, CL format', () {
      final op = _op('c.fld');
      expect(op.opcode, equals(CompressedOp.c0));
      expect(op.funct3, equals(C0Funct3.cFld));
      expect(op.funct3, equals(0x1));
      expect(op.format, same(clType));
      expect(op.immKind, equals(RvcImm.cldsd));
    });

    test('c.fsd uses quadrant 0, funct3 101, CS format', () {
      final op = _op('c.fsd');
      expect(op.opcode, equals(CompressedOp.c0));
      expect(op.funct3, equals(C0Funct3.cFsd));
      expect(op.funct3, equals(0x5));
      expect(op.format, same(csType));
      expect(op.immKind, equals(RvcImm.cldsd));
    });

    test('c.fldsp uses quadrant 2, funct3 001, CI format, sp base', () {
      final op = _op('c.fldsp');
      expect(op.opcode, equals(CompressedOp.c2));
      expect(op.funct3, equals(C2Funct3.cFldsp));
      expect(op.funct3, equals(0x1));
      expect(op.format, same(ciType));
      expect(op.immKind, equals(RvcImm.ciLdsp));
      expect(op.fixedRs1, equals(2));
    });

    test('c.fsdsp uses quadrant 2, funct3 101, CSS format, sp base', () {
      final op = _op('c.fsdsp');
      expect(op.opcode, equals(CompressedOp.c2));
      expect(op.funct3, equals(C2Funct3.cFsdsp));
      expect(op.funct3, equals(0x5));
      expect(op.format, same(cssType));
      expect(op.immKind, equals(RvcImm.cssSdsp));
      expect(op.fixedRs1, equals(2));
    });

    test('assembler words select the right operation', () {
      expect(_find(rvZcd, _cFld24)!.mnemonic, equals('c.fld'));
      expect(_find(rvZcd, _cFld200)!.mnemonic, equals('c.fld'));
      expect(_find(rvZcd, _cFsd24)!.mnemonic, equals('c.fsd'));
      expect(_find(rvZcd, _cFsd200)!.mnemonic, equals('c.fsd'));
      expect(_find(rvZcd, _cFldsp8)!.mnemonic, equals('c.fldsp'));
      expect(_find(rvZcd, _cFldsp264)!.mnemonic, equals('c.fldsp'));
      expect(_find(rvZcd, _cFsdsp16)!.mnemonic, equals('c.fsdsp'));
      expect(_find(rvZcd, _cFsdsp320)!.mnemonic, equals('c.fsdsp'));
    });

    test('RV32 with D decodes the words too', () {
      for (final word in [_cFld24, _cFsd24, _cFldsp8, _cFsdsp16]) {
        expect(_find(rvZcd, word, mxlen: RiscVMxlen.rv32), isNotNull);
      }
    });
  });

  group('Zcd register fields', () {
    test('c.fld and c.fsd use the prime fields, so f8-f15 and x8-x15', () {
      // c.fld f14, 24(x10)
      var f = clType.decode(_cFld24);
      expect(compressedRegFull(f['rd_prime']!), equals(14));
      expect(compressedRegFull(f['rs1_prime']!), equals(10));

      // c.fld f9, 200(x11)
      f = clType.decode(_cFld200);
      expect(compressedRegFull(f['rd_prime']!), equals(9));
      expect(compressedRegFull(f['rs1_prime']!), equals(11));

      // c.fsd f12, 24(x10)
      f = csType.decode(_cFsd24);
      expect(compressedRegFull(f['rs2_prime']!), equals(12));
      expect(compressedRegFull(f['rs1_prime']!), equals(10));

      // c.fsd f15, 200(x13)
      f = csType.decode(_cFsd200);
      expect(compressedRegFull(f['rs2_prime']!), equals(15));
      expect(compressedRegFull(f['rs1_prime']!), equals(13));
    });

    test('c.fldsp and c.fsdsp use the full 5-bit fields, so f0-f31', () {
      expect(ciType.decode(_cFldsp8)['rd_rs1'], equals(2)); // f2
      expect(ciType.decode(_cFldsp264)['rd_rs1'], equals(31)); // f31
      expect(cssType.decode(_cFsdsp16)['rs2'], equals(8)); // f8
      expect(cssType.decode(_cFsdsp320)['rs2'], equals(0)); // f0
    });
  });

  group('Zcd immediates', () {
    test('c.fld and c.fsd scale the offset by 8', () {
      expect(decodeRvcImm(RvcImm.cldsd, _cFld24), equals(24));
      expect(decodeRvcImm(RvcImm.cldsd, _cFld200), equals(200));
      expect(decodeRvcImm(RvcImm.cldsd, _cFsd24), equals(24));
      expect(decodeRvcImm(RvcImm.cldsd, _cFsd200), equals(200));
    });

    test('c.fldsp and c.fsdsp scale the offset by 8', () {
      expect(decodeRvcImm(RvcImm.ciLdsp, _cFldsp8), equals(8));
      expect(decodeRvcImm(RvcImm.ciLdsp, _cFldsp264), equals(264));
      expect(decodeRvcImm(RvcImm.cssSdsp, _cFsdsp16), equals(16));
      expect(decodeRvcImm(RvcImm.cssSdsp, _cFsdsp320), equals(320));
    });

    test('the offset is unsigned and a multiple of 8', () {
      // Sweep every instruction word: the offset must never go negative, and
      // the low 3 bits must always be zero because the field is scaled by 8.
      for (final op in rvZcd.operations) {
        for (var word = 0; word < 0x10000; word += 1) {
          final imm = decodeRvcImm(op.immKind!, word);
          expect(imm, greaterThanOrEqualTo(0), reason: op.mnemonic);
          expect(imm & 0x7, equals(0), reason: op.mnemonic);
        }
      }
    });
  });

  group('Zcd micro-op sequences', () {
    test('c.fld reads an integer base and writes a float destination', () {
      final mc = _op('c.fld').microcode;
      expect(mc, hasLength(4));

      final base = mc[0] as RiscVReadRegister;
      expect(base.source, equals(RiscVMicroOpField.rs1));
      expect(base.fp, isFalse);

      final load = mc[1] as RiscVMemLoad;
      expect(load.base, equals(RiscVMicroOpField.rs1));
      expect(load.dest, equals(RiscVMicroOpField.rd));
      expect(load.size, equals(RiscVMemSize.dword));

      final write = mc[2] as RiscVWriteRegister;
      expect(write.dest, equals(RiscVMicroOpField.rd));
      expect(write.source, equals(RiscVMicroOpSource.rd));
      expect(write.fp, isTrue);

      expect((mc[3] as RiscVUpdatePc).offset, equals(2));
    });

    test('c.fsd reads an integer base and a float source', () {
      final mc = _op('c.fsd').microcode;
      expect(mc, hasLength(4));

      final base = mc[0] as RiscVReadRegister;
      expect(base.source, equals(RiscVMicroOpField.rs1));
      expect(base.fp, isFalse);

      final data = mc[1] as RiscVReadRegister;
      expect(data.source, equals(RiscVMicroOpField.rs2));
      expect(data.fp, isTrue);

      final store = mc[2] as RiscVMemStore;
      expect(store.base, equals(RiscVMicroOpField.rs1));
      expect(store.src, equals(RiscVMicroOpField.rs2));
      expect(store.size, equals(RiscVMemSize.dword));

      expect((mc[3] as RiscVUpdatePc).offset, equals(2));
    });

    test('c.fldsp matches c.fld with sp as the base', () {
      final mc = _op('c.fldsp').microcode;
      expect(mc, hasLength(4));
      expect((mc[0] as RiscVReadRegister).fp, isFalse);
      expect((mc[1] as RiscVMemLoad).size, equals(RiscVMemSize.dword));
      expect((mc[2] as RiscVWriteRegister).fp, isTrue);
      expect((mc[3] as RiscVUpdatePc).offset, equals(2));
    });

    test('c.fsdsp matches c.fsd with sp as the base', () {
      final mc = _op('c.fsdsp').microcode;
      expect(mc, hasLength(4));
      expect((mc[0] as RiscVReadRegister).fp, isFalse);
      expect((mc[1] as RiscVReadRegister).fp, isTrue);
      expect((mc[2] as RiscVMemStore).size, equals(RiscVMemSize.dword));
      expect((mc[3] as RiscVUpdatePc).offset, equals(2));
    });

    test('exactly one micro-op per operation names a float register', () {
      for (final op in rvZcd.operations) {
        final fpOps = op.microcode.where(
          (m) =>
              (m is RiscVReadRegister && m.fp) ||
              (m is RiscVWriteRegister && m.fp),
        );
        expect(fpOps, hasLength(1), reason: op.mnemonic);
      }
    });
  });

  group('Zcd resources', () {
    test('the base address operand is an integer register', () {
      for (final op in rvZcd.operations) {
        final base = op.resources.whereType<RfResource>().where(
          (r) => r.access == rs1,
        );
        expect(base, hasLength(1), reason: op.mnemonic);
        expect(
          base.single.regfile,
          isA<RiscVIntRegFile>(),
          reason: op.mnemonic,
        );
      }
    });

    test('the data operand is a 64-bit float register', () {
      for (final op in rvZcd.operations) {
        final fp = op.resources.whereType<RfResource>().where(
          (r) => r.regfile is RiscVFloatRegFile,
        );
        expect(fp, hasLength(1), reason: op.mnemonic);
        expect((fp.single.regfile as RiscVFloatRegFile).width, equals(64));
      }
    });

    test('loads declare a load, stores declare a store, all use the FPU', () {
      for (final name in ['c.fld', 'c.fldsp']) {
        final op = _op(name);
        expect(op.resources.whereType<MemoryResource>().single.isLoad, isTrue);
        expect(op.resources.whereType<FpuResource>(), hasLength(1));
      }
      for (final name in ['c.fsd', 'c.fsdsp']) {
        final op = _op(name);
        expect(op.resources.whereType<MemoryResource>().single.isLoad, isFalse);
        expect(op.resources.whereType<FpuResource>(), hasLength(1));
      }
    });
  });
}

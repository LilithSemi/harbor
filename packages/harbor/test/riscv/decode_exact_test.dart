import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

int r(int funct7, int rs2, int rs1, int funct3, int rd, int opcode) =>
    (funct7 << 25) |
    (rs2 << 20) |
    (rs1 << 15) |
    (funct3 << 12) |
    (rd << 7) |
    opcode;

int i(int imm, int rs1, int funct3, int rd, int opcode) =>
    ((imm & 0xFFF) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode;

final rv32 = RiscVIsaConfig(
  mxlen: RiscVMxlen.rv32,
  extensions: [
    rvC,
    rvZcb,
    rvZicsr,
    rvZifencei,
    rvM,
    rvA,
    rvF,
    rvD,
    rvZcd,
    rvZcf,
    rvB,
    rvZbc,
    rvPriv,
    rv32i,
  ],
);

final rv64 = RiscVIsaConfig(
  mxlen: RiscVMxlen.rv64,
  extensions: [...rva23s64.extensions, rvZbc],
);

void expectDecode(RiscVIsaConfig isa, int word, String? mnemonic) {
  final hex = word.toRadixString(16);
  expect(
    isa.findOperation(word)?.mnemonic,
    mnemonic,
    reason: '0x$hex on ${isa.mxlen}',
  );
}

void main() {
  group('rv64 decodes', () {
    final cases = <String, int>{
      'c.li': 0x4285,
      'c.mul': 0x9C45,
      'c.not': 0x9C75,
      'c.zext.b': 0x9C61,
      'c.zext.w': 0x9C71,
      'c.or': 0x8C45,
      'c.srli': 0x9005,
      'c.mop.n': 0x6081,
      'ecall': 0x00000073,
      'ebreak': 0x00100073,
      'sret': 0x10200073,
      'mret': 0x30200073,
      'wfi': 0x10500073,
      'wrs.nto': 0x00D00073,
      'wrs.sto': 0x01D00073,
      'sfence.vma': r(0x09, 2, 1, 0, 0, 0x73),
      'sinval.vma': r(0x0B, 2, 1, 0, 0, 0x73),
      'sfence.w.inval': 0x18000073,
      'sfence.inval.ir': 0x18100073,
      'hinval.vvma': r(0x13, 2, 1, 0, 0, 0x73),
      'hinval.gvma': r(0x33, 2, 1, 0, 0, 0x73),
      'hfence.vvma': r(0x11, 2, 1, 0, 0, 0x73),
      'hfence.gvma': r(0x31, 2, 1, 0, 0, 0x73),
      'hlv.b': r(0x30, 0, 1, 4, 5, 0x73),
      'hlv.bu': r(0x30, 1, 1, 4, 5, 0x73),
      'hlv.hu': r(0x32, 1, 1, 4, 5, 0x73),
      'hlvx.hu': r(0x32, 3, 1, 4, 5, 0x73),
      'hlv.wu': r(0x34, 1, 1, 4, 5, 0x73),
      'hlvx.wu': r(0x34, 3, 1, 4, 5, 0x73),
      'hlv.d': r(0x36, 0, 1, 4, 5, 0x73),
      'hsv.b': 0x6220C073,
      'hsv.h': r(0x33, 2, 1, 4, 0, 0x73),
      'hsv.d': r(0x37, 2, 1, 4, 0, 0x73),
      'mop.r.n': r(0x40, 0x1C, 1, 4, 5, 0x73),
      'mop.rr.n': r(0x41, 3, 1, 4, 5, 0x73),
      'cbo.inval': 0x0000A00F,
      'cbo.clean': 0x0010A00F,
      'cbo.flush': 0x0020A00F,
      'cbo.zero': 0x0040A00F,
      'lr.w': r(0x08, 0, 2, 2, 1, 0x2F),
      'lr.d': r(0x0B, 0, 2, 3, 1, 0x2F),
      'slli': i(0x020, 1, 1, 1, 0x13),
      'slli.uw': 0x0A11109B,
      'rori': i(0x628, 2, 5, 1, 0x13),
      'bseti': i(0x2BF, 2, 1, 1, 0x13),
      'bexti': i(0x4A0, 2, 5, 1, 0x13),
      'rev8': i(0x6B8, 2, 5, 1, 0x13),
      'clz': i(0x600, 2, 1, 1, 0x13),
      'cpop': i(0x602, 2, 1, 1, 0x13),
      'zext.h': r(0x04, 0, 2, 4, 1, 0x3B),
      'clmul': r(0x05, 3, 2, 1, 1, 0x33),
      'clmulr': r(0x05, 3, 2, 2, 1, 0x33),
      'clmulh': r(0x05, 3, 2, 3, 1, 0x33),
      'fsqrt.s': r(0x2C, 0, 2, 0, 1, 0x53),
      'fcvt.s.d': r(0x20, 1, 2, 0, 1, 0x53),
      'fcvt.d.s': r(0x21, 0, 2, 0, 1, 0x53),
      'fcvt.s.h': r(0x20, 2, 2, 0, 1, 0x53),
      'fcvt.h.s': 0x440100D3,
      'fround.s': 0x404100D3,
      'froundnx.s': r(0x20, 5, 2, 0, 1, 0x53),
      'fcvt.w.s': r(0x60, 0, 2, 1, 1, 0x53),
      'fcvt.wu.s': r(0x60, 1, 2, 1, 1, 0x53),
      'fcvt.l.s': r(0x60, 2, 2, 1, 1, 0x53),
      'fcvt.lu.s': r(0x60, 3, 2, 1, 1, 0x53),
      'fcvt.s.wu': r(0x68, 1, 2, 0, 1, 0x53),
      'fcvt.s.lu': r(0x68, 3, 2, 0, 1, 0x53),
      'fcvt.wu.d': r(0x61, 1, 2, 1, 1, 0x53),
      'fcvt.lu.d': r(0x61, 3, 2, 1, 1, 0x53),
      'fcvt.d.l': r(0x69, 2, 2, 0, 1, 0x53),
      'fsgnj.s': r(0x10, 3, 2, 0, 1, 0x53),
      'fsgnjn.s': r(0x10, 3, 2, 1, 1, 0x53),
      'fsgnjx.d': r(0x11, 3, 2, 2, 1, 0x53),
      'fmin.s': r(0x14, 3, 2, 0, 1, 0x53),
      'fmax.d': r(0x15, 3, 2, 1, 1, 0x53),
      'fminm.s': r(0x14, 3, 2, 2, 1, 0x53),
      'fmaxm.s': r(0x14, 3, 2, 3, 1, 0x53),
      'fclass.s': r(0x70, 0, 2, 1, 1, 0x53),
      'fclass.d': r(0x71, 0, 2, 1, 1, 0x53),
      'fmv.x.w': r(0x70, 0, 2, 0, 1, 0x53),
      'fmv.x.d': r(0x71, 0, 2, 0, 1, 0x53),
      'fmv.w.x': r(0x78, 0, 2, 0, 1, 0x53),
      'fmv.d.x': r(0x79, 0, 2, 0, 1, 0x53),
      'fli.s': r(0x78, 1, 2, 0, 1, 0x53),
      'fleq.s': r(0x50, 3, 2, 4, 1, 0x53),
      'fltq.s': r(0x50, 3, 2, 5, 1, 0x53),
      'flh': i(8, 2, 1, 1, 0x07),
      'fmv.x.h': 0xE4000053,
      'fmv.h.x': 0xF4000053,
      'fcvt.d.h': 0x42200053,
      'fcvt.h.d': 0x44100053,
      'fli.d': 0xF2100053,
      'fminm.d': r(0x15, 3, 2, 2, 1, 0x53),
      'fmaxm.d': r(0x15, 3, 2, 3, 1, 0x53),
      'fround.d': 0x42410053,
      'froundnx.d': r(0x21, 5, 2, 0, 1, 0x53),
      'fcvtmod.w.d': 0xC2811053,
      'fleq.d': r(0x51, 3, 2, 4, 1, 0x53),
      'fltq.d': r(0x51, 3, 2, 5, 1, 0x53),
      'vsetivli': 0xC0007057,
      'c.fld': 0x2084,
      'c.fldsp': 0x2082,
      'c.fsdsp': 0xA002,
      'vsetvli': r(0x00, 0, 2, 7, 1, 0x57),
      'vsetvl': r(0x40, 3, 2, 7, 1, 0x57),
      'vsub.vv': r(0x05, 3, 2, 0, 1, 0x57),
      'vand.vv': r(0x13, 3, 2, 0, 1, 0x57),
      'vor.vv': r(0x15, 3, 2, 0, 1, 0x57),
      'vxor.vv': r(0x17, 3, 2, 0, 1, 0x57),
      'vsub.vx': r(0x05, 3, 2, 4, 1, 0x57),
      'vfmul.vv': r(0x49, 3, 2, 1, 1, 0x57),
      'vle8.v': r(0x01, 0, 2, 0, 1, 0x07),
    };
    for (final c in cases.entries) {
      test(c.key, () => expectDecode(rv64, c.value, c.key));
    }

    test('hints run as their base instruction', () {
      expectDecode(rv64, 0x0100000F, 'fence');
      expectDecode(rv64, 0x00200033, 'add');
      expectDecode(rv64, i(0x021, 1, 6, 0, 0x13), 'ori');
    });
  });

  group('rv64 reserved encodings are illegal', () {
    final cases = <String, int>{
      'c.addi16sp imm 0': 0x6101,
      'c.lui imm 0 with even rd': 0x6201,
      'c.jr x0': 0x8002,
      'c.lwsp rd 0': 0x4002,
      'c.ldsp rd 0': 0x6002,
      'c.addiw rd 0': 0x2001,
      'c.sh with bit 6 set': 0x8C40,
      'all zero halfword': 0x0000,
      'ecall with rd': 0x000000F3,
      'system funct12 2': 0x00200073,
      'mret with rs1': 0x30208073,
      'lr.w with rs2': 0x103120AF,
      'sfence.vma with rd': r(0x09, 2, 1, 0, 1, 0x73),
      'sfence.w.inval with rs1': 0x18008073,
      'hlv.b rs2 2': r(0x30, 2, 1, 4, 5, 0x73),
      'hsv.b with rd': r(0x31, 2, 1, 4, 1, 0x73),
      'cbo imm 3': 0x0030A00F,
      'cbo.zero with rd': 0x0040A08F,
      'fsqrt.s rs2 1': r(0x2C, 1, 2, 0, 1, 0x53),
      'fcvt.s.d rs2 3': r(0x20, 3, 2, 0, 1, 0x53),
      'fcvt.w.s rs2 4': r(0x60, 4, 2, 0, 1, 0x53),
      'fmv.x.w rs2 1': r(0x70, 1, 2, 0, 1, 0x53),
      'fclass.s funct3 2': r(0x70, 0, 2, 2, 1, 0x53),
      'fli.s rs2 2': r(0x78, 2, 2, 0, 1, 0x53),
      'slli.uw funct6 3': r(0x06, 1, 2, 1, 1, 0x1B),
      'clz with bit 25': i(0x620, 2, 1, 1, 0x13),
      'rev8 rv32 form': i(0x698, 2, 5, 1, 0x13),
      'vle8.v nf 1': r(0x21, 0, 2, 0, 1, 0x07),
      'vsetvl with bit 25': r(0x41, 3, 2, 7, 1, 0x57),
      'fcvtmod.w.d with rm 0': 0xC2810053,
      'fmv.x.h rs2 1': 0xE4100053,
    };
    for (final c in cases.entries) {
      test(c.key, () => expectDecode(rv64, c.value, null));
    }
  });

  group('rv32', () {
    test('decodes', () {
      expectDecode(rv32, 0x4285, 'c.li');
      expectDecode(rv32, i(0x29F, 1, 1, 1, 0x13), 'bseti');
      expectDecode(rv32, i(0x01F, 1, 1, 1, 0x13), 'slli');
      expectDecode(rv32, i(0x698, 2, 5, 1, 0x13), 'rev8');
      expectDecode(rv32, r(0x04, 0, 2, 4, 1, 0x33), 'zext.h');
      expectDecode(rv32, r(0x60, 1, 2, 1, 1, 0x53), 'fcvt.wu.s');
      expectDecode(rv32, 0x2001, 'c.jal');
      expectDecode(rv32, 0x2084, 'c.fld');
      expectDecode(rv32, 0x6084, 'c.flw');
      expectDecode(rv32, 0xE084, 'c.fsw');
      expectDecode(rv32, 0x6002, 'c.flwsp');
      expectDecode(rv32, 0xE002, 'c.fswsp');
    });

    test('reserved and RV64 only encodings are illegal', () {
      for (final w in [
        0x02009093, // slli shamt 32
        i(0x6B8, 2, 5, 1, 0x13), // rev8 rv64 form
        i(0x2BF, 2, 1, 1, 0x13), // bseti shamt 63
        0x1002, // c.slli shamt[5]
        0x9005, // c.srli shamt[5]
        0x9405, // c.srai shamt[5]
        0x9C71, // c.zext.w
        0x6081, // c.lui imm 0 without Zcmop
        r(0x60, 2, 2, 1, 1, 0x53), // fcvt.l.s
        r(0x71, 0, 2, 0, 1, 0x53), // fmv.x.d
        0x0A11109B, // slli.uw
      ]) {
        expectDecode(rv32, w, null);
      }
    });
  });

  test('czero.nez with imm only sees a nonzero I-type immediate', () {
    // A decoder takes the immediate from the format, so these ops must be
    // I-type and bits 31:20 must be nonzero for every word they match.
    final ops = rv64.allOperations.where(
      (op) => op.microcode.any(
        (m) =>
            m is RiscVAlu &&
            m.funct == RiscVAluFunct.czeroNez &&
            m.b == RiscVMicroOpField.imm,
      ),
    );
    expect(ops.map((op) => op.mnemonic), containsAll(['mop.r.n', 'mop.rr.n']));
    for (final op in ops) {
      expect(op.format.name, 'IType', reason: op.mnemonic);
      final free = [
        for (var b = 20; b < 32; b++)
          if (op.decodeMask & (1 << b) == 0) b,
      ];
      for (var n = 0; n < 1 << free.length; n++) {
        var w = op.decodeValue;
        for (final (k, b) in free.indexed) {
          if (n & (1 << k) != 0) w |= 1 << b;
        }
        expect((w >> 20) & 0xFFF, isNot(0), reason: op.mnemonic);
      }
    }
  });

  group('HDL decoder', () {
    for (final isa in [rv32, rv64]) {
      test('matches findOperation on ${isa.mxlen}', () async {
        final instr = Logic(name: 'instr', width: 32);
        final dec = RiscVInstructionDecoder(isa, instructionInput: instr);
        await dec.build();
        final ops = isa.allOperations;
        final words = [
          for (final op in ops) op.decodeValue | (op.nonZeroMask ?? 0),
          0x0000,
          0x6101,
          0x8002,
          0x00200073,
          0x103120AF,
        ];
        for (final w in words) {
          instr.put(w);
          final sw = isa.findOperation(w);
          final hex = w.toRadixString(16);
          expect(
            dec.illegal.value.toInt(),
            sw == null ? 1 : 0,
            reason: '0x$hex',
          );
          if (sw != null) {
            expect(
              ops[dec.operationIndex.value.toInt()],
              same(sw),
              reason: '0x$hex',
            );
          }
        }
      });
    }
  });
}

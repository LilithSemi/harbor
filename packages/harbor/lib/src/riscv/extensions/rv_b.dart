import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../mxlen.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);
const _rv64 = {RiscVMxlen.rv64, RiscVMxlen.rv128};
const _rv32 = {RiscVMxlen.rv32};

// R-type bit-manip: rd = f(rs1, rs2).
RiscVOperation _reg(
  String m,
  int f3,
  int f7,
  RiscVAluFunct f, {
  Set<RiscVMxlen>? xlen,
  int op = RiscvOpcode.op,
}) => RiscVOperation(
  mnemonic: m,
  opcode: op,
  funct3: f3,
  funct7: f7,
  format: rType,
  xlenConstraint: xlen,
  resources: [
    RfResource(_int, rs1),
    RfResource(_int, rs2),
    RfResource(_int, rd),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVReadRegister(RiscVMicroOpField.rs2),
    RiscVAlu(f, RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

// Shift-immediate bit-manip: rd = f(rs1, imm).
RiscVOperation _imm(
  String m,
  int f3,
  int f7,
  RiscVAluFunct f, {
  Set<RiscVMxlen>? xlen,
  int op = RiscvOpcode.opImm,
}) => RiscVOperation(
  mnemonic: m,
  opcode: op,
  funct3: f3,
  funct7: f7,
  format: iType,
  xlenConstraint: xlen,
  resources: [RfResource(_int, rs1), RfResource(_int, rd)],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVAlu(f, RiscVMicroOpField.rs1, RiscVMicroOpField.imm),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

// Shift-immediate with a funct6 selector. RV64 has a 6-bit shamt, so bit 25
// is free. RV32 has a 5-bit shamt, so bit 25 must be zero.
List<RiscVOperation> _shamt(
  String m,
  int f3,
  int funct6,
  RiscVAluFunct f, {
  int op = RiscvOpcode.opImm,
  bool rv32 = true,
}) => [
  for (final xlen in [_rv64, if (rv32) _rv32])
    RiscVOperation(
      mnemonic: m,
      opcode: op,
      funct3: f3,
      format: iType,
      xlenConstraint: xlen,
      matchMask: xlen == _rv32 ? 0xFE000000 : 0xFC000000,
      matchValue: funct6 << 26,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(f, RiscVMicroOpField.rs1, RiscVMicroOpField.imm),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
];

// Unary op: rd = f(rs1). clz/ctz/cpop/sext.b/sext.h share
// opcode+funct3+funct7 and are distinguished by the rs2 field (bits 24:20).
// The match also pins bits 31:20 because some decoders only look at funct6
// for OP-IMM shifts.
RiscVOperation _unary(
  String m,
  int f3,
  int f7,
  int rs2sel,
  RiscVAluFunct f, {
  Set<RiscVMxlen>? xlen,
  int op = RiscvOpcode.opImm,
}) => RiscVOperation(
  mnemonic: m,
  opcode: op,
  funct3: f3,
  funct7: f7,
  format: rType,
  xlenConstraint: xlen,
  matchMask: 0xFFF00000,
  matchValue: (f7 << 25) | (rs2sel << 20),
  resources: [RfResource(_int, rs1), RfResource(_int, rd)],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVAlu(f, RiscVMicroOpField.rs1, RiscVMicroOpField.rs1),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

/// Zba: Address generation (shift-add).
final rvZba = RiscVExtension(
  name: 'Zba',
  key: null,
  misaBit: null,
  operations: [
    _reg('sh1add', 0x2, 0x10, RiscVAluFunct.sh1add),
    _reg('sh2add', 0x4, 0x10, RiscVAluFunct.sh2add),
    _reg('sh3add', 0x6, 0x10, RiscVAluFunct.sh3add),
    _reg(
      'add.uw',
      0x0,
      0x04,
      RiscVAluFunct.adduw,
      xlen: _rv64,
      op: RiscvOpcode.op32,
    ),
    _reg(
      'sh1add.uw',
      0x2,
      0x10,
      RiscVAluFunct.sh1adduw,
      xlen: _rv64,
      op: RiscvOpcode.op32,
    ),
    _reg(
      'sh2add.uw',
      0x4,
      0x10,
      RiscVAluFunct.sh2adduw,
      xlen: _rv64,
      op: RiscvOpcode.op32,
    ),
    _reg(
      'sh3add.uw',
      0x6,
      0x10,
      RiscVAluFunct.sh3adduw,
      xlen: _rv64,
      op: RiscvOpcode.op32,
    ),
    ..._shamt(
      'slli.uw',
      0x1,
      0x02,
      RiscVAluFunct.slliUw,
      op: RiscvOpcode.opImm32,
      rv32: false,
    ),
  ],
);

/// Zbb: Basic bit manipulation.
final rvZbb = RiscVExtension(
  name: 'Zbb',
  key: null,
  misaBit: null,
  operations: [
    // Logical with negate.
    _reg('andn', 0x7, 0x20, RiscVAluFunct.andn),
    _reg('orn', 0x6, 0x20, RiscVAluFunct.orn),
    _reg('xnor', 0x4, 0x20, RiscVAluFunct.xnor),
    // Min / max.
    _reg('max', 0x6, 0x05, RiscVAluFunct.maxOp),
    _reg('maxu', 0x7, 0x05, RiscVAluFunct.maxuOp),
    _reg('min', 0x4, 0x05, RiscVAluFunct.minOp),
    _reg('minu', 0x5, 0x05, RiscVAluFunct.minuOp),
    // Rotates.
    _reg('rol', 0x1, 0x30, RiscVAluFunct.rol),
    _reg('ror', 0x5, 0x30, RiscVAluFunct.ror),
    _reg(
      'rolw',
      0x1,
      0x30,
      RiscVAluFunct.rolw,
      xlen: _rv64,
      op: RiscvOpcode.op32,
    ),
    _reg(
      'rorw',
      0x5,
      0x30,
      RiscVAluFunct.rorw,
      xlen: _rv64,
      op: RiscvOpcode.op32,
    ),
    ..._shamt('rori', 0x5, 0x18, RiscVAluFunct.ror),
    _imm(
      'roriw',
      0x5,
      0x30,
      RiscVAluFunct.rorw,
      xlen: _rv64,
      op: RiscvOpcode.opImm32,
    ),
    // Counts, sign/zero extend, byte ops (unary, rs2-field discriminated).
    _unary('clz', 0x1, 0x30, 0x00, RiscVAluFunct.clz),
    _unary('ctz', 0x1, 0x30, 0x01, RiscVAluFunct.ctz),
    _unary('cpop', 0x1, 0x30, 0x02, RiscVAluFunct.cpop),
    _unary('sext.b', 0x1, 0x30, 0x04, RiscVAluFunct.sextb),
    _unary('sext.h', 0x1, 0x30, 0x05, RiscVAluFunct.sexth),
    _unary(
      'clzw',
      0x1,
      0x30,
      0x00,
      RiscVAluFunct.clzw,
      xlen: _rv64,
      op: RiscvOpcode.opImm32,
    ),
    _unary(
      'ctzw',
      0x1,
      0x30,
      0x01,
      RiscVAluFunct.ctzw,
      xlen: _rv64,
      op: RiscvOpcode.opImm32,
    ),
    _unary(
      'cpopw',
      0x1,
      0x30,
      0x02,
      RiscVAluFunct.cpopw,
      xlen: _rv64,
      op: RiscvOpcode.opImm32,
    ),
    // zext.h is OP-32 on RV64 and OP on RV32.
    _unary(
      'zext.h',
      0x4,
      0x04,
      0x00,
      RiscVAluFunct.zexth,
      xlen: _rv64,
      op: RiscvOpcode.op32,
    ),
    _unary(
      'zext.h',
      0x4,
      0x04,
      0x00,
      RiscVAluFunct.zexth,
      xlen: _rv32,
      op: RiscvOpcode.op,
    ),
    // rev8: imm 0x6B8 on RV64 and 0x698 on RV32.
    _unary('rev8', 0x5, 0x35, 0x18, RiscVAluFunct.rev8, xlen: _rv64),
    _unary('rev8', 0x5, 0x34, 0x18, RiscVAluFunct.rev8, xlen: _rv32),
    // orc.b: imm 0x287 → funct7 0x14, rs2 field 0x07.
    _unary('orc.b', 0x5, 0x14, 0x07, RiscVAluFunct.orcb),
  ],
);

/// Zbc: Carry-less multiplication.
final rvZbc = RiscVExtension(
  name: 'Zbc',
  key: null,
  misaBit: null,
  operations: [
    _reg('clmul', 0x1, 0x05, RiscVAluFunct.clmul),
    _reg('clmulh', 0x3, 0x05, RiscVAluFunct.clmulh),
    _reg('clmulr', 0x2, 0x05, RiscVAluFunct.clmulr),
  ],
);

/// Zbs: Single-bit operations.
final rvZbs = RiscVExtension(
  name: 'Zbs',
  key: null,
  misaBit: null,
  operations: [
    _reg('bclr', 0x1, 0x24, RiscVAluFunct.bclr),
    _reg('bext', 0x5, 0x24, RiscVAluFunct.bext),
    _reg('binv', 0x1, 0x34, RiscVAluFunct.binv),
    _reg('bset', 0x1, 0x14, RiscVAluFunct.bset),
    ..._shamt('bclri', 0x1, 0x12, RiscVAluFunct.bclr),
    ..._shamt('bexti', 0x5, 0x12, RiscVAluFunct.bext),
    ..._shamt('binvi', 0x1, 0x1A, RiscVAluFunct.binv),
    ..._shamt('bseti', 0x1, 0x0A, RiscVAluFunct.bset),
  ],
);

/// Combined B extension: Zba + Zbb + Zbs. Zbc is not part of B.
final rvB = RiscVExtension(
  name: 'B',
  key: 'B',
  misaBit: 1,
  operations: [...rvZba.operations, ...rvZbb.operations, ...rvZbs.operations],
);

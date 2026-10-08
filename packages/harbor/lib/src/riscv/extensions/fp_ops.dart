import '../../encoding/riscv_formats.dart';
import '../micro_op.dart';
import '../mxlen.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);
const _rv64 = {RiscVMxlen.rv64, RiscVMxlen.rv128};

// The rs2 field (bits 24:20).
const _rs2Mask = 0x01F00000;

/// Float to integer convert. [rs2sel] selects W (0), WU (1), L (2) or LU (3).
/// The L forms are RV64 only.
RiscVOperation fpToIntCvt(
  String mnemonic,
  int funct7,
  int rs2sel,
  RiscVFpuFunct funct,
  RiscVFloatRegFile fp, {
  bool doublePrecision = false,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  format: rType,
  matchMask: _rs2Mask,
  matchValue: rs2sel << 20,
  xlenConstraint: rs2sel >= 2 ? _rv64 : null,
  resources: [RfResource(fp, rs1), RfResource(_int, rd), FpuResource()],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
    RiscVFpuOp(
      funct,
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      doublePrecision: doublePrecision,
    ),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

/// Integer to float convert. [rs2sel] selects W (0), WU (1), L (2) or LU (3).
/// The L forms are RV64 only.
RiscVOperation intToFpCvt(
  String mnemonic,
  int funct7,
  int rs2sel,
  RiscVFpuFunct funct,
  RiscVFloatRegFile fp,
) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  format: rType,
  matchMask: _rs2Mask,
  matchValue: rs2sel << 20,
  xlenConstraint: rs2sel >= 2 ? _rv64 : null,
  resources: [RfResource(_int, rs1), RfResource(fp, rd), FpuResource()],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVFpuOp(funct, RiscVMicroOpField.rs1, RiscVMicroOpField.rd),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd, fp: true),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

/// Two float sources and a float destination (fsgnj, fmin, fmax).
RiscVOperation fpBinary(
  String mnemonic,
  int funct7,
  int funct3,
  RiscVFpuFunct funct,
  RiscVFloatRegFile fp, {
  bool doublePrecision = false,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  funct3: funct3,
  format: rType,
  resources: [
    RfResource(fp, rs1),
    RfResource(fp, rs2),
    RfResource(fp, rd),
    FpuResource(),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
    RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
    RiscVFpuOp(
      funct,
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      b: RiscVMicroOpField.rs2,
      doublePrecision: doublePrecision,
    ),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd, fp: true),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

/// Float source to integer destination with rs2 = 0 (fclass, fmv.x.w).
RiscVOperation fpToIntUnary(
  String mnemonic,
  int funct7,
  int funct3,
  RiscVFpuFunct funct,
  RiscVFloatRegFile fp, {
  bool doublePrecision = false,
  Set<RiscVMxlen>? xlen,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  funct3: funct3,
  format: rType,
  matchMask: _rs2Mask,
  matchValue: 0,
  xlenConstraint: xlen,
  resources: [RfResource(fp, rs1), RfResource(_int, rd), FpuResource()],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
    RiscVFpuOp(
      funct,
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      doublePrecision: doublePrecision,
    ),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

/// Raw bit move from an integer register to a float register with rs2 = 0
/// (fmv.w.x, fmv.d.x).
RiscVOperation intToFpMove(
  String mnemonic,
  int funct7,
  RiscVFloatRegFile fp, {
  bool doublePrecision = false,
  Set<RiscVMxlen>? xlen,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  funct3: 0x0,
  format: rType,
  matchMask: _rs2Mask,
  matchValue: 0,
  xlenConstraint: xlen,
  resources: [RfResource(_int, rs1), RfResource(fp, rd), FpuResource()],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVFpuOp(
      RiscVFpuFunct.fmv,
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      doublePrecision: doublePrecision,
    ),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd, fp: true),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _fp64 = RiscVFloatRegFile(64);
const _fp32 = RiscVFloatRegFile(32);
const _int = RiscVIntRegFile(32);

// Shared resources for the double-precision fused multiply-add ops (3 FP64
// source reads + FP64 dest). Microcode inlined per op (const list, no helpers).
const _fmaResD = [
  RfResource(_fp64, rs1),
  RfResource(_fp64, rs2),
  RfResource(_fp64, rs3),
  RfResource(_fp64, rd),
  FpuResource(),
];

const rvD = RiscVExtension(
  name: 'D',
  key: 'D',
  misaBit: 3,
  operations: [
    RiscVOperation(
      mnemonic: 'fld',
      opcode: 0x07,
      funct3: 0x3,
      format: iType,
      resources: [
        RfResource(_int, rs1),
        RfResource(_fp64, rd),
        MemoryResource.load(),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.dword,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fsd',
      opcode: 0x27,
      funct3: 0x3,
      format: sType,
      resources: [
        RfResource(_int, rs1),
        RfResource(_fp64, rs2),
        MemoryResource.store(),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.dword,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fadd.d',
      opcode: 0x53,
      funct7: 0x01,
      format: rType,
      resources: [
        RfResource(_fp64, rs1),
        RfResource(_fp64, rs2),
        RfResource(_fp64, rd),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fadd,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    // Fused multiply-add (R4-type, double precision). Same opcodes as single but
    // fmt=01 (matchMask on bits[26:25]) selects double.
    RiscVOperation(
      mnemonic: 'fmadd.d',
      opcode: 0x43,
      format: r4Type,
      matchMask: 0x06000000, // fmt bits[26:25]
      matchValue: 0x02000000, // fmt = 01 (double)
      resources: _fmaResD,
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs3, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fmadd,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          c: RiscVMicroOpField.rs3,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fmsub.d',
      opcode: 0x47,
      format: r4Type,
      matchMask: 0x06000000,
      matchValue: 0x02000000,
      resources: _fmaResD,
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs3, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fmsub,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          c: RiscVMicroOpField.rs3,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fnmsub.d',
      opcode: 0x4B,
      format: r4Type,
      matchMask: 0x06000000,
      matchValue: 0x02000000,
      resources: _fmaResD,
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs3, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fnmsub,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          c: RiscVMicroOpField.rs3,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fnmadd.d',
      opcode: 0x4F,
      format: r4Type,
      matchMask: 0x06000000,
      matchValue: 0x02000000,
      resources: _fmaResD,
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs3, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fnmadd,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          c: RiscVMicroOpField.rs3,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fsub.d',
      opcode: 0x53,
      funct7: 0x05,
      format: rType,
      resources: [
        RfResource(_fp64, rs1),
        RfResource(_fp64, rs2),
        RfResource(_fp64, rd),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fsub,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fmul.d',
      opcode: 0x53,
      funct7: 0x09,
      format: rType,
      resources: [
        RfResource(_fp64, rs1),
        RfResource(_fp64, rs2),
        RfResource(_fp64, rd),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fmul,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fdiv.d',
      opcode: 0x53,
      funct7: 0x0D,
      format: rType,
      resources: [
        RfResource(_fp64, rs1),
        RfResource(_fp64, rs2),
        RfResource(_fp64, rd),
        FpuResource(),
      ],
      executionMode: RiscVExecutionMode.microcoded,
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fdiv,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fsqrt.d',
      opcode: 0x53,
      funct7: 0x2D,
      format: rType,
      resources: [RfResource(_fp64, rs1), RfResource(_fp64, rd), FpuResource()],
      executionMode: RiscVExecutionMode.microcoded,
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fsqrt,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fcvt.s.d',
      opcode: 0x53,
      funct7: 0x20,
      format: rType,
      resources: [RfResource(_fp64, rs1), RfResource(_fp32, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fcvtSD,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fcvt.d.s',
      opcode: 0x53,
      funct7: 0x21,
      format: rType,
      resources: [RfResource(_fp32, rs1), RfResource(_fp64, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fcvtDS,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fcvt.w.d',
      opcode: 0x53,
      funct7: 0x61,
      format: rType,
      resources: [RfResource(_fp64, rs1), RfResource(_int, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fcvtWD,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          doublePrecision: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fcvt.d.w',
      opcode: 0x53,
      funct7: 0x69,
      format: rType,
      resources: [RfResource(_int, rs1), RfResource(_fp64, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVFpuOp(
          RiscVFpuFunct.fcvtDW,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'feq.d',
      opcode: 0x53,
      funct7: 0x51,
      funct3: 0x2,
      format: rType,
      resources: [
        RfResource(_fp64, rs1),
        RfResource(_fp64, rs2),
        RfResource(_int, rd),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.feq,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          doublePrecision: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'flt.d',
      opcode: 0x53,
      funct7: 0x51,
      funct3: 0x1,
      format: rType,
      resources: [
        RfResource(_fp64, rs1),
        RfResource(_fp64, rs2),
        RfResource(_int, rd),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.flt,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          doublePrecision: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fle.d',
      opcode: 0x53,
      funct7: 0x51,
      funct3: 0x0,
      format: rType,
      resources: [
        RfResource(_fp64, rs1),
        RfResource(_fp64, rs2),
        RfResource(_int, rd),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fle,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          b: RiscVMicroOpField.rs2,
          doublePrecision: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);

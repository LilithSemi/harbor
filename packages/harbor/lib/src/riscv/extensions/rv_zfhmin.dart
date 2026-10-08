import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);
const _fp32 = RiscVFloatRegFile(32);
const _fp16 = RiscVFloatRegFile(16);
const _fp64 = RiscVFloatRegFile(64);

/// Zfhmin: Minimal half-precision floating-point support.
///
/// The D forms (fcvt.d.h, fcvt.h.d) are in [rvZfhminD].
final rvZfhmin = RiscVExtension(
  name: 'Zfhmin',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'flh',
      opcode: 0x07,
      funct3: 0x1,
      format: iType,
      resources: [
        RfResource(_int, rs1),
        RfResource(_fp16, rd),
        MemoryResource.load(),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.half,
          unsigned: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
          nanBox: true,
          nanBoxHalf: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fsh',
      opcode: 0x27,
      funct3: 0x1,
      format: sType,
      resources: [
        RfResource(_int, rs1),
        RfResource(_fp16, rs2),
        MemoryResource.store(),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.half,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    // fcvt.s.h is funct7 0x20 with rs2 = 2 (source fmt H).
    RiscVOperation(
      mnemonic: 'fcvt.s.h',
      opcode: 0x53,
      funct7: 0x20,
      format: rType,
      matchMask: 0x01F00000,
      matchValue: 0x00200000,
      resources: [RfResource(_fp16, rs1), RfResource(_fp32, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fcvtSH,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
          nanBox: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    // fcvt.h.s is funct7 0x22 with rs2 = 0 (source fmt S).
    RiscVOperation(
      mnemonic: 'fcvt.h.s',
      opcode: 0x53,
      funct7: 0x22,
      format: rType,
      matchMask: 0x01F00000,
      matchValue: 0x00000000,
      resources: [RfResource(_fp32, rs1), RfResource(_fp16, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fcvtHS,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
          nanBox: true,
          nanBoxHalf: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fmv.x.h',
      opcode: 0x53,
      funct7: 0x72,
      funct3: 0x0,
      format: rType,
      matchMask: 0x01F00000,
      matchValue: 0x00000000,
      resources: [RfResource(_fp16, rs1), RfResource(_int, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fmvXH,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fmv.h.x',
      opcode: 0x53,
      funct7: 0x7A,
      funct3: 0x0,
      format: rType,
      matchMask: 0x01F00000,
      matchValue: 0x00000000,
      resources: [RfResource(_int, rs1), RfResource(_fp16, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVFpuOp(
          RiscVFpuFunct.fmv,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
          nanBox: true,
          nanBoxHalf: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);

/// Zfhmin double-precision forms. Add next to [rvZfhmin] when `rvD` is
/// present.
final rvZfhminD = RiscVExtension(
  name: 'Zfhmin.D',
  key: null,
  misaBit: null,
  operations: [
    // fcvt.d.h is funct7 0x21 with rs2 = 2 (source fmt H).
    RiscVOperation(
      mnemonic: 'fcvt.d.h',
      opcode: 0x53,
      funct7: 0x21,
      format: rType,
      matchMask: 0x01F00000,
      matchValue: 0x00200000,
      resources: [RfResource(_fp16, rs1), RfResource(_fp64, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fcvtDH,
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
    // fcvt.h.d is funct7 0x22 with rs2 = 1 (source fmt D).
    RiscVOperation(
      mnemonic: 'fcvt.h.d',
      opcode: 0x53,
      funct7: 0x22,
      format: rType,
      matchMask: 0x01F00000,
      matchValue: 0x00100000,
      resources: [RfResource(_fp64, rs1), RfResource(_fp16, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fcvtHD,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          doublePrecision: true,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
          nanBox: true,
          nanBoxHalf: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);

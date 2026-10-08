import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';
import 'fp_ops.dart';

const _fp32 = RiscVFloatRegFile(32);
const _int = RiscVIntRegFile(32);

// Shared resources for the single-precision fused multiply-add ops (3 FP source
// reads + FP dest). The microcode is inlined per op because the fused funct
// differs and Harbor's op list is const (no helper calls allowed).
const _fmaResS = [
  RfResource(_fp32, rs1),
  RfResource(_fp32, rs2),
  RfResource(_fp32, rs3),
  RfResource(_fp32, rd),
  FpuResource(),
];

final rvF = RiscVExtension(
  name: 'F',
  key: 'F',
  misaBit: 5,
  operations: [
    RiscVOperation(
      mnemonic: 'flw',
      opcode: 0x07,
      funct3: 0x2,
      format: iType,
      resources: [
        RfResource(_int, rs1),
        RfResource(_fp32, rd),
        MemoryResource.load(),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVMemLoad(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          RiscVMemSize.word,
        ),
        // The load gives 32 bits and the register keeps 64, so the write must
        // NaN-box the value (all upper bits set).
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
          nanBox: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fsw',
      opcode: 0x27,
      funct3: 0x2,
      format: sType,
      resources: [
        RfResource(_int, rs1),
        RfResource(_fp32, rs2),
        MemoryResource.store(),
        FpuResource(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2, fp: true),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.word,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fadd.s',
      opcode: 0x53,
      funct7: 0x00,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
        RfResource(_fp32, rd),
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
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    // Fused multiply-add (R4-type, single precision). opcode distinguishes the
    // four ops. fmt=00 (matchMask on bits[26:25]) selects single. Three FP source
    // reads (rs1/rs2/rs3) feed the fused op rd = +-(rs1*rs2) +- rs3.
    RiscVOperation(
      mnemonic: 'fmadd.s',
      opcode: 0x43,
      format: r4Type,
      matchMask: 0x06000000, // fmt bits[26:25]
      matchValue: 0x00000000, // fmt = 00 (single)
      resources: _fmaResS,
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
      mnemonic: 'fmsub.s',
      opcode: 0x47,
      format: r4Type,
      matchMask: 0x06000000,
      matchValue: 0x00000000,
      resources: _fmaResS,
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
      mnemonic: 'fnmsub.s',
      opcode: 0x4B,
      format: r4Type,
      matchMask: 0x06000000,
      matchValue: 0x00000000,
      resources: _fmaResS,
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
      mnemonic: 'fnmadd.s',
      opcode: 0x4F,
      format: r4Type,
      matchMask: 0x06000000,
      matchValue: 0x00000000,
      resources: _fmaResS,
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
      mnemonic: 'fsub.s',
      opcode: 0x53,
      funct7: 0x04,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
        RfResource(_fp32, rd),
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
      mnemonic: 'fmul.s',
      opcode: 0x53,
      funct7: 0x08,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
        RfResource(_fp32, rd),
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
      mnemonic: 'fdiv.s',
      opcode: 0x53,
      funct7: 0x0C,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
        RfResource(_fp32, rd),
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
      mnemonic: 'fsqrt.s',
      opcode: 0x53,
      funct7: 0x2C,
      format: rType,
      matchMask: 0x01F00000, // rs2 = 0
      matchValue: 0x00000000,
      resources: [RfResource(_fp32, rs1), RfResource(_fp32, rd), FpuResource()],
      executionMode: RiscVExecutionMode.microcoded,
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fsqrt,
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
    fpToIntCvt('fcvt.w.s', 0x60, 0, RiscVFpuFunct.fcvtWS, _fp32),
    fpToIntCvt('fcvt.wu.s', 0x60, 1, RiscVFpuFunct.fcvtWS, _fp32),
    fpToIntCvt('fcvt.l.s', 0x60, 2, RiscVFpuFunct.fcvtWS, _fp32),
    fpToIntCvt('fcvt.lu.s', 0x60, 3, RiscVFpuFunct.fcvtWS, _fp32),
    intToFpCvt('fcvt.s.w', 0x68, 0, RiscVFpuFunct.fcvtSW, _fp32),
    intToFpCvt('fcvt.s.wu', 0x68, 1, RiscVFpuFunct.fcvtSW, _fp32),
    intToFpCvt('fcvt.s.l', 0x68, 2, RiscVFpuFunct.fcvtSW, _fp32),
    intToFpCvt('fcvt.s.lu', 0x68, 3, RiscVFpuFunct.fcvtSW, _fp32),
    RiscVOperation(
      mnemonic: 'feq.s',
      opcode: 0x53,
      funct7: 0x50,
      funct3: 0x2,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
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
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'flt.s',
      opcode: 0x53,
      funct7: 0x50,
      funct3: 0x1,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
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
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'fle.s',
      opcode: 0x53,
      funct7: 0x50,
      funct3: 0x0,
      format: rType,
      resources: [
        RfResource(_fp32, rs1),
        RfResource(_fp32, rs2),
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
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    fpBinary('fsgnj.s', 0x10, 0x0, RiscVFpuFunct.fsgnj, _fp32),
    fpBinary('fsgnjn.s', 0x10, 0x1, RiscVFpuFunct.fsgnjn, _fp32),
    fpBinary('fsgnjx.s', 0x10, 0x2, RiscVFpuFunct.fsgnjx, _fp32),
    fpBinary('fmin.s', 0x14, 0x0, RiscVFpuFunct.fmin, _fp32),
    fpBinary('fmax.s', 0x14, 0x1, RiscVFpuFunct.fmax, _fp32),
    fpToIntUnary('fclass.s', 0x70, 0x1, RiscVFpuFunct.fclass, _fp32),
    fpToIntUnary('fmv.x.w', 0x70, 0x0, RiscVFpuFunct.fmv, _fp32),
    intToFpMove('fmv.w.x', 0x78, _fp32),
  ],
);

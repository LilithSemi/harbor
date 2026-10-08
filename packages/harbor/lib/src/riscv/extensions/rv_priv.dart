import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);

final rvPriv = RiscVExtension(
  name: 'Priv',
  key: null,
  misaBit: null,
  operations: [
    // sret, mret and wfi have no operands, so all 32 bits are fixed. sret and
    // wfi share funct7 0x08 and differ only in rs2.
    RiscVOperation(
      mnemonic: 'sret',
      opcode: RiscvOpcode.system,
      funct7: 0x08,
      funct3: 0,
      format: rType,
      matchMask: 0xFFFFFFFF,
      matchValue: 0x10200073,
      privilegeLevel: 1,
      microcode: [RiscVReturnOp(1)],
    ),
    RiscVOperation(
      mnemonic: 'mret',
      opcode: RiscvOpcode.system,
      funct7: 0x18,
      funct3: 0,
      format: rType,
      matchMask: 0xFFFFFFFF,
      matchValue: 0x30200073,
      privilegeLevel: 3,
      microcode: [RiscVReturnOp(3)],
    ),
    RiscVOperation(
      mnemonic: 'wfi',
      opcode: RiscvOpcode.system,
      funct7: 0x08,
      funct3: 0,
      format: rType,
      matchMask: 0xFFFFFFFF,
      matchValue: 0x10500073,
      // wfi is a hint: wait for interrupt, then RETIRE and advance to pc+4 (so an
      // interrupt taken while stalled resumes at the instruction after wfi, and
      // the core never wedges on it). The UpdatePc mirrors Zawrs wrs.nto/wrs.sto,
      // it was missing here, so wfi never advanced and stalled the dynamic
      // microcode interpreter (creek) forever.
      microcode: [
        RiscVWaitForInterrupt(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'sfence.vma',
      opcode: RiscvOpcode.system,
      funct7: 0x09,
      funct3: 0,
      format: rType,
      matchMask: 0x00000F80, // rd = x0
      matchValue: 0x00000000,
      privilegeLevel: 1,
      resources: [RfResource(_int, rs1), RfResource(_int, rs2)],
      microcode: [
        RiscVTlbFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);

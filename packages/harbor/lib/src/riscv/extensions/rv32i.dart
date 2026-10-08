import '../../encoding/riscv_formats.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../mxlen.dart';
import '../operation.dart';
import '../resource.dart';

// Shared register file spec (width doesn't matter for resource declarations,
// it's determined by RiscVMxlen at elaboration time)
const _int = RiscVIntRegFile(32);

/// RV32I base integer instruction set.
final rv32i = RiscVExtension(
  name: 'RV32I',
  key: 'I',
  misaBit: 8,
  operations: [
    // Upper immediate.
    RiscVOperation(
      mnemonic: 'lui',
      opcode: RiscvOpcode.lui,
      format: uType,
      resources: [RfResource(_int, rd)],
      microcode: [
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.imm),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'auipc',
      opcode: RiscvOpcode.auipc,
      format: uType,
      resources: [RfResource(_int, rd), PcResource()],
      microcode: [
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.pc,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),

    // Jumps.
    RiscVOperation(
      mnemonic: 'jal',
      opcode: RiscvOpcode.jal,
      format: jType,
      resources: [RfResource(_int, rd), PcResource()],
      microcode: [
        RiscVWriteLinkRegister(RiscVMicroOpField.rd, pcOffset: 4),
        RiscVUpdatePc(
          RiscVMicroOpField.pc,
          offsetField: RiscVMicroOpField.imm,
          align: true,
        ),
      ],
    ),
    RiscVOperation(
      mnemonic: 'jalr',
      opcode: RiscvOpcode.jalr,
      funct3: 0x0,
      format: iType,
      resources: [RfResource(_int, rs1), RfResource(_int, rd), PcResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.add,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteLinkRegister(RiscVMicroOpField.rd, pcOffset: 4),
        RiscVUpdatePc(
          RiscVMicroOpField.pc,
          offsetSource: RiscVMicroOpSource.alu,
          absolute: true,
          align: true,
        ),
      ],
    ),

    // Branches.
    _branch('beq', BranchFunct3.beq, RiscVBranchCondition.eq),
    _branch('bne', BranchFunct3.bne, RiscVBranchCondition.ne),
    _branch('blt', BranchFunct3.blt, RiscVBranchCondition.lt),
    _branch('bge', BranchFunct3.bge, RiscVBranchCondition.ge),
    _branch('bltu', BranchFunct3.bltu, RiscVBranchCondition.ltu),
    _branch('bgeu', BranchFunct3.bgeu, RiscVBranchCondition.geu),

    // Loads.
    _load('lb', LoadFunct3.lb, RiscVMemSize.byte1, false),
    _load('lh', LoadFunct3.lh, RiscVMemSize.half, false),
    _load('lw', LoadFunct3.lw, RiscVMemSize.word, false),
    _load('lbu', LoadFunct3.lbu, RiscVMemSize.byte1, true),
    _load('lhu', LoadFunct3.lhu, RiscVMemSize.half, true),

    // Stores.
    _store('sb', StoreFunct3.sb, RiscVMemSize.byte1),
    _store('sh', StoreFunct3.sh, RiscVMemSize.half),
    _store('sw', StoreFunct3.sw, RiscVMemSize.word),

    // ALU immediate.
    _aluImm('addi', AluImmFunct3.addi, RiscVAluFunct.add),
    _aluImm('slti', AluImmFunct3.slti, RiscVAluFunct.slt),
    _aluImm('sltiu', AluImmFunct3.sltiu, RiscVAluFunct.sltu),
    _aluImm('xori', AluImmFunct3.xori, RiscVAluFunct.xor_),
    _aluImm('ori', AluImmFunct3.ori, RiscVAluFunct.or_),
    _aluImm('andi', AluImmFunct3.andi, RiscVAluFunct.and_),

    // Shifts with funct7.
    RiscVOperation(
      mnemonic: 'slli',
      opcode: RiscvOpcode.opImm,
      funct3: AluImmFunct3.slli,
      funct7: 0x00,
      // RV32 has a 5-bit shamt, so bit 25 must be zero. RV64 uses rv64i.
      xlenConstraint: {RiscVMxlen.rv32},
      matchMask: 0x02000000,
      matchValue: 0x00000000,
      format: iType,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sll,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'srli',
      opcode: RiscvOpcode.opImm,
      funct3: AluImmFunct3.srli,
      funct7: 0x00,
      // RV32 has a 5-bit shamt, so bit 25 must be zero. RV64 uses rv64i.
      xlenConstraint: {RiscVMxlen.rv32},
      matchMask: 0x02000000,
      matchValue: 0x00000000,
      format: iType,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.srl,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'srai',
      opcode: RiscvOpcode.opImm,
      funct3: AluImmFunct3.srli,
      funct7: 0x20,
      // RV32 has a 5-bit shamt, so bit 25 must be zero. RV64 uses rv64i.
      xlenConstraint: {RiscVMxlen.rv32},
      matchMask: 0x02000000,
      matchValue: 0x00000000,
      format: iType,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sra,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.imm,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),

    // ALU register-register.
    _aluReg('add', AluRegFunct3.add, 0x00, RiscVAluFunct.add),
    _aluReg('sub', AluRegFunct3.add, 0x20, RiscVAluFunct.sub),
    _aluReg('sll', AluRegFunct3.sll, 0x00, RiscVAluFunct.sll),
    _aluReg('slt', AluRegFunct3.slt, 0x00, RiscVAluFunct.slt),
    _aluReg('sltu', AluRegFunct3.sltu, 0x00, RiscVAluFunct.sltu),
    _aluReg('xor', AluRegFunct3.xor, 0x00, RiscVAluFunct.xor_),
    _aluReg('srl', AluRegFunct3.srl, 0x00, RiscVAluFunct.srl),
    _aluReg('sra', AluRegFunct3.srl, 0x20, RiscVAluFunct.sra),
    _aluReg('or', AluRegFunct3.or, 0x00, RiscVAluFunct.or_),
    _aluReg('and', AluRegFunct3.and, 0x00, RiscVAluFunct.and_),

    // System.
    RiscVOperation(
      mnemonic: 'fence',
      opcode: RiscvOpcode.fence,
      funct3: 0x0,
      format: iType,
      microcode: [
        RiscVFenceOp(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    // ecall and ebreak have no operands. All 32 bits are fixed.
    RiscVOperation(
      mnemonic: 'ecall',
      opcode: RiscvOpcode.system,
      funct3: 0x0,
      funct7: 0x00,
      matchMask: 0xFFFFFFFF,
      matchValue: 0x00000073,
      format: iType,
      // Environment call: cause is the originating privilege (U=8/S=9/VS=10/
      // M=11), so it re-encodes by mode at trap time, not a fixed 8.
      microcode: [RiscVTrapOp(8, modeCause: true)],
    ),
    RiscVOperation(
      mnemonic: 'ebreak',
      opcode: RiscvOpcode.system,
      funct3: 0x0,
      funct7: 0x00,
      matchMask: 0xFFFFFFFF,
      matchValue: 0x00100073,
      format: iType,
      microcode: [RiscVTrapOp(3)], // Breakpoint
    ),
  ],
);

// Helper constructors for repetitive patterns.

RiscVOperation _branch(
  String mnemonic,
  int funct3,
  RiscVBranchCondition cond,
) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: RiscvOpcode.branch,
  funct3: funct3,
  format: bType,
  resources: [RfResource(_int, rs1), RfResource(_int, rs2), PcResource()],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVReadRegister(RiscVMicroOpField.rs2),
    RiscVBranch(
      cond,
      RiscVMicroOpSource.alu,
      offsetField: RiscVMicroOpField.imm,
    ),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

RiscVOperation _load(
  String mnemonic,
  int funct3,
  RiscVMemSize size,
  bool unsigned,
) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: RiscvOpcode.load,
  funct3: funct3,
  format: iType,
  resources: [
    RfResource(_int, rs1),
    RfResource(_int, rd),
    MemoryResource.load(),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVMemLoad(
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      size,
      unsigned: unsigned,
    ),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

RiscVOperation _store(String mnemonic, int funct3, RiscVMemSize size) =>
    RiscVOperation(
      mnemonic: mnemonic,
      opcode: RiscvOpcode.store,
      funct3: funct3,
      format: sType,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVMemStore(RiscVMicroOpField.rs1, RiscVMicroOpField.rs2, size),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    );

RiscVOperation _aluImm(String mnemonic, int funct3, RiscVAluFunct funct) =>
    RiscVOperation(
      mnemonic: mnemonic,
      opcode: RiscvOpcode.opImm,
      funct3: funct3,
      format: iType,
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(funct, RiscVMicroOpField.rs1, RiscVMicroOpField.imm),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    );

RiscVOperation _aluReg(
  String mnemonic,
  int funct3,
  int funct7,
  RiscVAluFunct funct,
) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: RiscvOpcode.op,
  funct3: funct3,
  funct7: funct7,
  format: rType,
  resources: [
    RfResource(_int, rs1),
    RfResource(_int, rs2),
    RfResource(_int, rd),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVReadRegister(RiscVMicroOpField.rs2),
    RiscVAlu(funct, RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

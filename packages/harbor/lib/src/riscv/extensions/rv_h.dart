import '../../encoding/riscv_formats.dart';
import '../../encoding/riscv_hypervisor.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../mxlen.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);
const _rv64 = {RiscVMxlen.rv64, RiscVMxlen.rv128};

// Hypervisor fence: funct3 = 0 and rd = x0.
RiscVOperation _hfence(String mnemonic, int funct7, {required bool gstage}) =>
    RiscVOperation(
      mnemonic: mnemonic,
      opcode: RiscvOpcode.system,
      funct3: 0x0,
      funct7: funct7,
      format: rType,
      matchMask: 0x00000F80,
      matchValue: 0x00000000,
      privilegeLevel: 1,
      resources: [RfResource(_int, rs1), RfResource(_int, rs2)],
      microcode: [
        RiscVHypervisorFenceOp(isGstage: gstage),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    );

// Hypervisor virtual load: funct3 = 4, rs2 selects the variant. The mem op
// writes rd itself (see RiscVHypervisorMemOp).
RiscVOperation _hlv(
  String mnemonic,
  int funct7,
  int rs2sel,
  RiscVMemSize size, {
  bool unsigned = false,
  Set<RiscVMxlen>? xlen,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: RiscvOpcode.system,
  funct3: 0x4,
  funct7: funct7,
  format: rType,
  matchMask: 0x01F00000,
  matchValue: rs2sel << 20,
  xlenConstraint: xlen,
  privilegeLevel: 1,
  resources: [
    RfResource(_int, rs1),
    RfResource(_int, rd),
    MemoryResource.load(),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVHypervisorMemOp(
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      size,
      unsigned: unsigned,
    ),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

// Hypervisor virtual store: funct3 = 4 and rd = x0.
RiscVOperation _hsv(
  String mnemonic,
  int funct7,
  RiscVMemSize size, {
  Set<RiscVMxlen>? xlen,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: RiscvOpcode.system,
  funct3: 0x4,
  funct7: funct7,
  format: rType,
  matchMask: 0x00000F80,
  matchValue: 0x00000000,
  xlenConstraint: xlen,
  privilegeLevel: 1,
  resources: [
    RfResource(_int, rs1),
    RfResource(_int, rs2),
    MemoryResource.store(),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1),
    RiscVReadRegister(RiscVMicroOpField.rs2),
    RiscVHypervisorMemOp(
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rs2,
      size,
      isStore: true,
    ),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

/// H extension: Hypervisor.
///
/// Adds hypervisor fence and virtual load/store instructions. sret, mret and
/// wfi come from `rvPriv`.
///
/// The hlvx forms need execute permission instead of read permission.
/// [RiscVHypervisorMemOp] cannot express that yet, so they run as hlv.
final rvH = RiscVExtension(
  name: 'H',
  key: 'H',
  misaBit: 7,
  operations: [
    _hfence('hfence.vvma', HypervisorFunct7.hfenceVvma, gstage: false),
    _hfence('hfence.gvma', HypervisorFunct7.hfenceGvma, gstage: true),

    _hlv('hlv.b', HypervisorFunct7.hlvB, 0x0, RiscVMemSize.byte1),
    _hlv(
      'hlv.bu',
      HypervisorFunct7.hlvBu,
      0x1,
      RiscVMemSize.byte1,
      unsigned: true,
    ),
    _hlv('hlv.h', HypervisorFunct7.hlvH, 0x0, RiscVMemSize.half),
    _hlv(
      'hlv.hu',
      HypervisorFunct7.hlvHu,
      0x1,
      RiscVMemSize.half,
      unsigned: true,
    ),
    _hlv(
      'hlvx.hu',
      HypervisorFunct7.hlvxHu,
      0x3,
      RiscVMemSize.half,
      unsigned: true,
    ),
    _hlv('hlv.w', HypervisorFunct7.hlvW, 0x0, RiscVMemSize.word),
    _hlv(
      'hlv.wu',
      HypervisorFunct7.hlvWu,
      0x1,
      RiscVMemSize.word,
      unsigned: true,
      xlen: _rv64,
    ),
    _hlv(
      'hlvx.wu',
      HypervisorFunct7.hlvxWu,
      0x3,
      RiscVMemSize.word,
      unsigned: true,
    ),
    _hlv('hlv.d', HypervisorFunct7.hlvD, 0x0, RiscVMemSize.dword, xlen: _rv64),

    _hsv('hsv.b', HypervisorFunct7.hsvB, RiscVMemSize.byte1),
    _hsv('hsv.h', HypervisorFunct7.hsvH, RiscVMemSize.half),
    _hsv('hsv.w', HypervisorFunct7.hsvW, RiscVMemSize.word),
    _hsv('hsv.d', HypervisorFunct7.hsvD, RiscVMemSize.dword, xlen: _rv64),
  ],
);

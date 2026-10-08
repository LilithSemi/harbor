import '../../encoding/riscv_formats.dart';
import '../../encoding/riscv_compressed.dart';
import '../../encoding/rvc_immediate.dart';
import '../extension.dart';
import '../micro_op.dart';
import '../mxlen.dart';
import '../operation.dart';
import '../resource.dart';

const _int = RiscVIntRegFile(32);
const _fp32 = RiscVFloatRegFile(32);
const _fp64 = RiscVFloatRegFile(64);

/// Zicntr: Base counters and timers (cycle, time, instret CSRs).
const rvZicntr = RiscVExtension(name: 'Zicntr', key: null, misaBit: null);

/// Zihpm: Hardware performance counters (hpmcounter3-31).
const rvZihpm = RiscVExtension(name: 'Zihpm', key: null, misaBit: null);

/// Zihintpause: PAUSE hint. pause is `fence w, 0` and decodes as fence, so
/// this extension has no ops of its own.
const rvZihintpause = RiscVExtension(
  name: 'Zihintpause',
  key: null,
  misaBit: null,
);

/// Zihintntl: Non-temporal locality hints. Each is `add x0, x0, xN` for N in
/// 2 to 5 and decodes as add, so this extension has no ops of its own.
const rvZihintntl = RiscVExtension(name: 'Zihintntl', key: null, misaBit: null);

// A may-be-operation writes zero to rd. Bit 31 is set in both forms, so imm
// is not zero and czero.nez gives 0 for any rs1 value. The latch and the
// register give the same result.
const _mopMicrocode = [
  RiscVAlu(
    RiscVAluFunct.czeroNez,
    RiscVMicroOpField.rs1,
    RiscVMicroOpField.imm,
  ),
  RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
  RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
];

/// Zimop: May-be-operations. Each op stands for all values of n.
final rvZimop = RiscVExtension(
  name: 'Zimop',
  key: null,
  misaBit: null,
  operations: [
    // 1 n4 00 n3:2 0111 n1:0 rs1 100 rd 1110011
    RiscVOperation(
      mnemonic: 'mop.r.n',
      opcode: RiscvOpcode.system,
      funct3: 0x4,
      format: iType,
      matchMask: 0xB3C00000,
      matchValue: 0x81C00000,
      resources: [RfResource(_int, rd)],
      microcode: _mopMicrocode,
    ),
    // 1 n2 00 n1:0 1 rs2 rs1 100 rd 1110011
    RiscVOperation(
      mnemonic: 'mop.rr.n',
      opcode: RiscvOpcode.system,
      funct3: 0x4,
      // I-type so that decoders give it a nonzero immediate (bits 31:20).
      format: iType,
      matchMask: 0xB2000000,
      matchValue: 0x82000000,
      resources: [RfResource(_int, rd)],
      microcode: _mopMicrocode,
    ),
  ],
);

/// Zcmop: Compressed may-be-operations. c.mop.n uses the reserved c.lui
/// encoding with imm = 0 and rd = 2m + 1. It does not write a register.
final rvZcmop = RiscVExtension(
  name: 'Zcmop',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'c.mop.n',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cLui,
      format: ciType,
      matchMask: 0x18FC, // bit 12, rd bits 11 and 7, imm bits 6:2
      matchValue: 0x0080,
      microcode: [RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2)],
    ),
  ],
);

/// Zawrs: Wait-on-reservation-set instructions.
final rvZawrs = RiscVExtension(
  name: 'Zawrs',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'wrs.nto',
      opcode: RiscvOpcode.system,
      format: iType,
      matchMask: 0xFFFFFFFF,
      matchValue: 0x00D00073,
      microcode: [
        RiscVWaitForInterrupt(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    RiscVOperation(
      mnemonic: 'wrs.sto',
      opcode: RiscvOpcode.system,
      format: iType,
      matchMask: 0xFFFFFFFF,
      matchValue: 0x01D00073,
      microcode: [
        RiscVWaitForInterrupt(),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
  ],
);

/// Zkt: Data-independent execution latency (constant-time crypto).
const rvZkt = RiscVExtension(name: 'Zkt', key: null, misaBit: null);

/// Zvfhmin: Vector minimal half-precision floating-point.
const rvZvfhmin = RiscVExtension(name: 'Zvfhmin', key: null, misaBit: null);

/// Zvfh: Vector half-precision floating-point (SEW=16 FP arithmetic). A marker
/// extension: the OP-FP-V ops (vfadd.vv etc.) are SEW-generic and decode the same
/// for any SEW, so the half-precision capability is signalled by including this
/// in the ISA config rather than by distinct operations.
const rvZvfh = RiscVExtension(name: 'Zvfh', key: null, misaBit: null);

/// Zvbb: Vector basic bit-manipulation instructions.
const rvZvbb = RiscVExtension(name: 'Zvbb', key: null, misaBit: null);

/// Zvkt: Vector data-independent execution latency.
const rvZvkt = RiscVExtension(name: 'Zvkt', key: null, misaBit: null);

// Cache-block op: funct3 = 2, rd = x0, and imm[11:0] selects the op.
RiscVOperation _cbo(
  String mnemonic,
  int funct12,
  List<RiscVMicroOp> microcode, {
  bool store = false,
  Set<RiscVMxlen>? xlen,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: RiscvOpcode.fence,
  funct3: 0x2,
  format: iType,
  matchMask: 0xFFF00F80,
  matchValue: funct12 << 20,
  xlenConstraint: xlen,
  resources: [RfResource(_int, rs1), if (store) MemoryResource.store()],
  microcode: microcode,
);

const _cboFence = [
  RiscVReadRegister(RiscVMicroOpField.rs1),
  RiscVFenceOp(),
  RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
];

/// Zicbom: Cache-block management instructions. There is no cache to manage
/// here, so each op is a fence.
final rvZicbom = RiscVExtension(
  name: 'Zicbom',
  key: null,
  misaBit: null,
  operations: [
    _cbo('cbo.clean', 0x001, _cboFence),
    _cbo('cbo.flush', 0x002, _cboFence),
    _cbo('cbo.inval', 0x000, _cboFence),
  ],
);

/// Zicbop: Cache-block prefetch hints. Each is `ori x0, rs1, imm` with
/// imm[4:0] selecting the kind and decodes as ori, so this extension has no
/// ops of its own.
const rvZicbop = RiscVExtension(name: 'Zicbop', key: null, misaBit: null);

// Writes zero to the 64-byte block that holds rs1, with [count] stores of
// [size]. The rd latch starts at 0 because rd is x0, and imm is 4. Only the
// rd, rs1, rs2 and imm latches are used.
List<RiscVMicroOp> _cboZero(RiscVMemSize size, int count) => [
  RiscVReadRegister(RiscVMicroOpField.rs1),
  // rd = 1, then rs2 = 4 + 1 + 1 = 6.
  RiscVAlu(RiscVAluFunct.sltu, RiscVMicroOpField.rd, RiscVMicroOpField.imm),
  RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rd),
  RiscVAlu(RiscVAluFunct.add, RiscVMicroOpField.imm, RiscVMicroOpField.rd),
  RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rs2),
  RiscVAlu(RiscVAluFunct.add, RiscVMicroOpField.rs2, RiscVMicroOpField.rd),
  RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rs2),
  // Align rs1 down to 64 bytes, then take off imm, which each store adds.
  RiscVAlu(RiscVAluFunct.srl, RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
  RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rs1),
  RiscVAlu(RiscVAluFunct.sll, RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
  RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rs1),
  RiscVAlu(RiscVAluFunct.sub, RiscVMicroOpField.rs1, RiscVMicroOpField.imm),
  RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rs1),
  // rd back to 0, the store data.
  RiscVAlu(RiscVAluFunct.xor_, RiscVMicroOpField.rd, RiscVMicroOpField.rd),
  RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rd),
  // rs2 = store size in bytes.
  if (size == RiscVMemSize.word)
    RiscVSetField(RiscVMicroOpSource.imm, RiscVMicroOpField.rs2)
  else ...[
    RiscVAlu(RiscVAluFunct.add, RiscVMicroOpField.imm, RiscVMicroOpField.imm),
    RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rs2),
  ],
  for (var i = 0; i < count; i++) ...[
    RiscVMemStore(RiscVMicroOpField.rs1, RiscVMicroOpField.rd, size),
    if (i < count - 1) ...[
      RiscVAlu(RiscVAluFunct.add, RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
      RiscVSetField(RiscVMicroOpSource.alu, RiscVMicroOpField.rs1),
    ],
  ],
  RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
];

/// Zicboz: Cache-block zero instructions, for 64-byte blocks (Zic64b).
final rvZicboz = RiscVExtension(
  name: 'Zicboz',
  key: null,
  misaBit: null,
  operations: [
    _cbo(
      'cbo.zero',
      0x004,
      _cboZero(RiscVMemSize.dword, 8),
      store: true,
      xlen: {RiscVMxlen.rv64, RiscVMxlen.rv128},
    ),
    _cbo(
      'cbo.zero',
      0x004,
      _cboZero(RiscVMemSize.word, 16),
      store: true,
      xlen: {RiscVMxlen.rv32},
    ),
  ],
);

// Zcb unary ops: bits 12:10 = 111, bits 6:5 = 11, and bits 4:2 select the op.
const _zcbUnaryMask = 0x1C7C;
const _zcbUnary = 0x1C00;

/// Zcb: Additional 16-bit compressed instructions.
final rvZcb = RiscVExtension(
  name: 'Zcb',
  key: null,
  misaBit: null,
  operations: [
    RiscVOperation(
      mnemonic: 'c.lbu',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: clType,
      matchMask: 0x7 << 10, // inst[12:10] = 000
      immKind: RvcImm.clb,
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
          RiscVMemSize.byte1,
          unsigned: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.lhu',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: clType,
      matchMask: (0x7 << 10) | (1 << 6), // inst[12:10]=001, inst[6]=0
      matchValue: 1 << 10,
      immKind: RvcImm.clh,
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
          RiscVMemSize.half,
          unsigned: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.lh',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: clType,
      matchMask: (0x7 << 10) | (1 << 6), // inst[12:10]=001, inst[6]=1
      matchValue: (1 << 10) | (1 << 6),
      immKind: RvcImm.clh,
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
          RiscVMemSize.half,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sb',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: csType,
      matchMask: 0x7 << 10, // inst[12:10] = 010
      matchValue: 2 << 10,
      immKind: RvcImm.clb,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.byte1,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sh',
      opcode: CompressedOp.c0,
      funct3: 0x4,
      format: csType,
      matchMask: (0x7 << 10) | (1 << 6), // inst[12:10]=011, inst[6]=0
      matchValue: 3 << 10,
      immKind: RvcImm.clh,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        MemoryResource.store(),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVMemStore(
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
          RiscVMemSize.half,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.zext.b',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: _zcbUnaryMask,
      matchValue: _zcbUnary | (0x18 << 2),
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.zextb,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sext.b',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: _zcbUnaryMask,
      matchValue: _zcbUnary | (0x19 << 2),
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sextb,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.zext.h',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: _zcbUnaryMask,
      matchValue: _zcbUnary | (0x1A << 2),
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.zexth,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.sext.h',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: _zcbUnaryMask,
      matchValue: _zcbUnary | (0x1B << 2),
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.sexth,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.zext.w',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: _zcbUnaryMask,
      matchValue: _zcbUnary | (0x1C << 2),
      xlenConstraint: {RiscVMxlen.rv64, RiscVMxlen.rv128},
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.zextw,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.not',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      matchMask: _zcbUnaryMask,
      matchValue: _zcbUnary | (0x1D << 2),
      resources: [RfResource(_int, rs1), RfResource(_int, rd)],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVAlu(
          RiscVAluFunct.notOp,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs1,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
    RiscVOperation(
      mnemonic: 'c.mul',
      opcode: CompressedOp.c1,
      funct3: C1Funct3.cMisc,
      format: caType,
      // bits 12:10 = 111 and bits 6:5 = 10.
      matchMask: 0x1C60,
      matchValue: 0x1C40,
      resources: [
        RfResource(_int, rs1),
        RfResource(_int, rs2),
        RfResource(_int, rd),
      ],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1),
        RiscVReadRegister(RiscVMicroOpField.rs2),
        RiscVAlu(
          RiscVAluFunct.mul,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rs2,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 2),
      ],
    ),
  ],
);

// Zfa op on two float sources.
RiscVOperation _zfaBin(
  String mnemonic,
  int funct7,
  int funct3,
  RiscVFpuFunct funct, {
  bool intDest = false,
  bool double = false,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  funct3: funct3,
  format: rType,
  resources: [
    RfResource(double ? _fp64 : _fp32, rs1),
    RfResource(double ? _fp64 : _fp32, rs2),
    RfResource(intDest ? _int : (double ? _fp64 : _fp32), rd),
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
      doublePrecision: double,
    ),
    RiscVWriteRegister(
      RiscVMicroOpField.rd,
      RiscVMicroOpSource.rd,
      fp: !intDest,
    ),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

// Zfa op on one float source, with rs2 selecting the op and rm free.
RiscVOperation _zfaUnary(
  String mnemonic,
  int funct7,
  int rs2sel,
  RiscVFpuFunct funct, {
  bool double = false,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: 0x53,
  funct7: funct7,
  format: rType,
  matchMask: 0x01F00000,
  matchValue: rs2sel << 20,
  resources: [
    RfResource(double ? _fp64 : _fp32, rs1),
    RfResource(double ? _fp64 : _fp32, rd),
    FpuResource(),
  ],
  microcode: [
    RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
    RiscVFpuOp(
      funct,
      RiscVMicroOpField.rs1,
      RiscVMicroOpField.rd,
      doublePrecision: double,
    ),
    RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd, fp: true),
    RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
  ],
);

// fli: rs2 = 1 and funct3 = 0. The rs1 field is the constant index, not a
// register.
RiscVOperation _fli(String mnemonic, int funct7, {bool double = false}) =>
    RiscVOperation(
      mnemonic: mnemonic,
      opcode: 0x53,
      funct7: funct7,
      funct3: 0x0,
      format: rType,
      matchMask: 0x01F00000,
      matchValue: 0x00100000,
      resources: [RfResource(double ? _fp64 : _fp32, rd), FpuResource()],
      microcode: [
        RiscVFpuOp(
          RiscVFpuFunct.fli,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          doublePrecision: double,
        ),
        RiscVWriteRegister(
          RiscVMicroOpField.rd,
          RiscVMicroOpSource.rd,
          fp: true,
        ),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    );

/// Zfa: Additional floating-point instructions, single-precision forms.
final rvZfa = RiscVExtension(
  name: 'Zfa',
  key: null,
  misaBit: null,
  operations: [
    _fli('fli.s', 0x78),
    _zfaBin('fminm.s', 0x14, 0x2, RiscVFpuFunct.fminm),
    _zfaBin('fmaxm.s', 0x14, 0x3, RiscVFpuFunct.fmaxm),
    _zfaUnary('fround.s', 0x20, 0x4, RiscVFpuFunct.fround),
    _zfaUnary('froundnx.s', 0x20, 0x5, RiscVFpuFunct.froundnx),
    _zfaBin('fleq.s', 0x50, 0x4, RiscVFpuFunct.fleq, intDest: true),
    _zfaBin('fltq.s', 0x50, 0x5, RiscVFpuFunct.fltq, intDest: true),
  ],
);

/// Zfa double-precision forms. Add next to [rvZfa] when `rvD` is present.
///
/// fmvh.x.d and fmvp.d.x (RV32 only) are not defined.
final rvZfaD = RiscVExtension(
  name: 'Zfa.D',
  key: null,
  misaBit: null,
  operations: [
    _fli('fli.d', 0x79, double: true),
    _zfaBin('fminm.d', 0x15, 0x2, RiscVFpuFunct.fminm, double: true),
    _zfaBin('fmaxm.d', 0x15, 0x3, RiscVFpuFunct.fmaxm, double: true),
    _zfaUnary('fround.d', 0x21, 0x4, RiscVFpuFunct.fround, double: true),
    _zfaUnary('froundnx.d', 0x21, 0x5, RiscVFpuFunct.froundnx, double: true),
    // fcvtmod.w.d: rs2 = 8 and rm fixed to rtz (funct3 = 1).
    RiscVOperation(
      mnemonic: 'fcvtmod.w.d',
      opcode: 0x53,
      funct7: 0x61,
      funct3: 0x1,
      format: rType,
      matchMask: 0x01F00000,
      matchValue: 0x00800000,
      resources: [RfResource(_fp64, rs1), RfResource(_int, rd), FpuResource()],
      microcode: [
        RiscVReadRegister(RiscVMicroOpField.rs1, fp: true),
        RiscVFpuOp(
          RiscVFpuFunct.fcvtmodWD,
          RiscVMicroOpField.rs1,
          RiscVMicroOpField.rd,
          doublePrecision: true,
        ),
        RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.rd),
        RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
      ],
    ),
    _zfaBin(
      'fleq.d',
      0x51,
      0x4,
      RiscVFpuFunct.fleq,
      intDest: true,
      double: true,
    ),
    _zfaBin(
      'fltq.d',
      0x51,
      0x5,
      RiscVFpuFunct.fltq,
      intDest: true,
      double: true,
    ),
  ],
);

// Svinval op with funct3 = 0 and rd = x0.
RiscVOperation _sysFence(
  String mnemonic,
  int funct7,
  RiscVMicroOp op, {
  int matchMask = 0x00000F80,
  int matchValue = 0x00000000,
  bool operands = true,
}) => RiscVOperation(
  mnemonic: mnemonic,
  opcode: RiscvOpcode.system,
  funct7: funct7,
  funct3: 0x0,
  format: rType,
  matchMask: matchMask,
  matchValue: matchValue,
  privilegeLevel: 1,
  resources: [
    if (operands) RfResource(_int, rs1),
    if (operands) RfResource(_int, rs2),
  ],
  microcode: [op, RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4)],
);

/// Svinval: Fine-grained address-translation cache invalidation.
final rvSvinval = RiscVExtension(
  name: 'Svinval',
  key: null,
  misaBit: null,
  operations: [
    _sysFence(
      'sinval.vma',
      0x0B,
      RiscVTlbInvalidateOp(RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
    ),
    _sysFence(
      'sfence.w.inval',
      0x0C,
      RiscVFenceOp(),
      matchMask: 0xFFFFFFFF,
      matchValue: 0x18000073,
      operands: false,
    ),
    _sysFence(
      'sfence.inval.ir',
      0x0C,
      RiscVFenceOp(),
      matchMask: 0xFFFFFFFF,
      matchValue: 0x18100073,
      operands: false,
    ),
    _sysFence('hinval.vvma', 0x13, RiscVHypervisorFenceOp(isGstage: false)),
    _sysFence('hinval.gvma', 0x33, RiscVHypervisorFenceOp(isGstage: true)),
  ],
);

/// Svnapot: NAPOT translation contiguity.
const rvSvnapot = RiscVExtension(name: 'Svnapot', key: null, misaBit: null);

/// Svpbmt: Page-based memory types.
const rvSvpbmt = RiscVExtension(name: 'Svpbmt', key: null, misaBit: null);

/// Sstc: Supervisor-mode timer interrupts (stimecmp CSR).
const rvSstc = RiscVExtension(name: 'Sstc', key: null, misaBit: null);

/// Sscofpmf: Count overflow and mode-based filtering.
const rvSscofpmf = RiscVExtension(name: 'Sscofpmf', key: null, misaBit: null);

/// Svbare: Bare satp mode support.
const rvSvbare = RiscVExtension(name: 'Svbare', key: null, misaBit: null);

/// Svade: A/D bit page-fault exceptions.
const rvSvade = RiscVExtension(name: 'Svade', key: null, misaBit: null);

/// Svadu: hardware updating of page-table A/D bits (the alternative to Svade,
/// which faults instead). The MMU sets Accessed/Dirty during a successful walk.
const rvSvadu = RiscVExtension(name: 'Svadu', key: null, misaBit: null);

/// Smstateen: machine-level state-enable CSRs (mstateen0-3[h]) gating access to
/// extension state from lower privilege levels.
const rvSmstateen = RiscVExtension(name: 'Smstateen', key: null, misaBit: null);

/// Ssstateen: the supervisor-visible view of the state-enable CSRs
/// (sstateen0-3), requires [rvSmstateen].
const rvSsstateen = RiscVExtension(name: 'Ssstateen', key: null, misaBit: null);

/// Ziccif: Instruction fetch atomicity in coherent cacheable regions.
const rvZiccif = RiscVExtension(name: 'Ziccif', key: null, misaBit: null);

/// Ziccrse: RsrvEventual in coherent cacheable regions.
const rvZiccrse = RiscVExtension(name: 'Ziccrse', key: null, misaBit: null);

/// Ziccamoa: AMOArithmetic in coherent cacheable regions.
const rvZiccamoa = RiscVExtension(name: 'Ziccamoa', key: null, misaBit: null);

/// Zicclsm: Misaligned loads/stores in coherent cacheable regions.
const rvZicclsm = RiscVExtension(name: 'Zicclsm', key: null, misaBit: null);

/// Za64rs: Reservation sets contiguous, aligned, max 64 bytes.
const rvZa64rs = RiscVExtension(name: 'Za64rs', key: null, misaBit: null);

/// Zic64b: Cache blocks 64 bytes, naturally aligned.
const rvZic64b = RiscVExtension(name: 'Zic64b', key: null, misaBit: null);

/// Supm: User-mode pointer masking.
const rvSupm = RiscVExtension(name: 'Supm', key: null, misaBit: null);

/// Sha: Augmented hypervisor extension.
const rvSha = RiscVExtension(name: 'Sha', key: null, misaBit: null);

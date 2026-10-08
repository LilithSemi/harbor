/// Micro-operation types for RISC-V instruction execution.
///
/// Each [RiscVOperation] carries a list of [RiscVMicroOp]s describing its
/// execution steps. These are pure data. The actual hardware
/// implementation is provided by the CPU (e.g., River).
///
/// Each field latch starts with the decoded field value (a register index or
/// the immediate). [RiscVReadRegister] replaces the index with the register
/// value. [RiscVMemLoad] and [RiscVMemStore] use the base field plus the
/// immediate as the address. [RiscVBranch] compares the rs1 and rs2 latches.
///
/// A sequence may use only the rd, rs1, rs2 and imm latches as scratch. The
/// core can read rs3 and pc for other purposes (for example, rs3 as sp).

/// Fields in the micro-op data path.
///
/// Used as references between micro-ops to specify where data
/// comes from and goes to.
enum RiscVMicroOpField {
  rd(0),
  rs1(1),
  rs2(2),
  rs3(3),
  imm(4),
  pc(5);

  final int id;
  const RiscVMicroOpField(this.id);
}

/// Data sources for micro-op operands.
enum RiscVMicroOpSource {
  alu(0),
  imm(1),
  rs1(2),
  rs2(3),
  pc(4),
  rd(5);

  final int id;
  const RiscVMicroOpSource(this.id);
}

/// ALU function codes.
enum RiscVAluFunct {
  add,
  sub,
  and_,
  or_,
  xor_,
  sll,
  srl,
  sra,
  slt,
  sltu,
  mul,
  mulh,
  mulhsu,
  mulhu,
  div,
  divu,
  rem,
  remu,
  // 32-bit variants for RV64
  addw,
  subw,
  sllw,
  srlw,
  sraw,
  mulw,
  divw,
  divuw,
  remw,
  remuw,
  // Zbb: logical-with-negate, min/max, rotates, counts, extends, byte ops
  andn,
  orn,
  xnor,
  minOp,
  maxOp,
  minuOp,
  maxuOp,
  rol,
  ror,
  rolw,
  rorw,
  clz,
  ctz,
  cpop,
  clzw,
  ctzw,
  cpopw,
  sextb,
  sexth,
  zexth,
  orcb,
  rev8,
  // Zba: shift-add (and unsigned-word forms)
  sh1add,
  sh2add,
  sh3add,
  adduw,
  sh1adduw,
  sh2adduw,
  sh3adduw,
  // Zbs: single-bit
  bset,
  bclr,
  binv,
  bext,
  // Zicond: conditional zero
  czeroEqz,
  czeroNez,
  // Zcb unary helpers
  zextb,
  zextw,
  notOp,
  // Zba: zero-extend the low word of a, then shift left by b.
  slliUw,
  // Zbc: carry-less multiply (low, high and reversed products).
  clmul,
  clmulh,
  clmulr,
}

/// RiscVBranch conditions.
enum RiscVBranchCondition { eq, ne, lt, ge, ltu, geu }

/// Memory access sizes.
enum RiscVMemSize {
  byte1(1),
  half(2),
  word(4),
  dword(8),
  qword(16);

  final int bytes;
  const RiscVMemSize(this.bytes);
}

/// Atomic memory operation functions.
// `cas` is Zacas (amocas.w/.d): compare mem against rd, if equal store rs2, rd<-mem.
enum RiscVAtomicFunct { add, swap, xor_, and_, or_, min, max, minu, maxu, cas }

/// Floating-point rounding modes.
enum RiscVFpRoundingMode {
  rne(0), // Round to nearest, ties to even
  rtz(1), // Round towards zero
  rdn(2), // Round down
  rup(3), // Round up
  rmm(4), // Round to nearest, ties to max magnitude
  dyn(7); // Dynamic (from fcsr)

  final int value;
  const RiscVFpRoundingMode(this.value);
}

/// Base class for all micro-operations.
///
/// All concrete types have const constructors and are pure data.
sealed class RiscVMicroOp {
  const RiscVMicroOp();
}

/// Read a value from a register into a micro-op field.
///
/// Set [fp] when the operand names a floating-point register. The micro-op
/// alone does not say which register file an operand belongs to, so a
/// microcoded execution unit reads the integer file unless [fp] tells it
/// otherwise. A static execution unit takes the file from the operation's
/// [RfResource] list instead and ignores this flag.
class RiscVReadRegister extends RiscVMicroOp {
  final RiscVMicroOpField source;
  final int offset;
  final bool fp;

  const RiscVReadRegister(this.source, {this.offset = 0, this.fp = false});
}

/// Write a value to a register.
///
/// Set [fp] when the destination names a floating-point register. See
/// [RiscVReadRegister] for why the flag is necessary. An FP destination also
/// skips the x0 and x2 special cases: f0 is normal storage, and there is no
/// floating-point stack pointer.
///
/// Set [nanBox] when the value is a 32-bit single-precision datum that goes to
/// a 64-bit floating-point register. The register file keeps FLEN bits, and the
/// specification says a narrower value must have all upper bits set (NaN
/// boxing). The micro-op that produced the value does not say how wide it is,
/// so the write carries the flag.
///
/// Set [nanBoxHalf] together with [nanBox] for a 16-bit half-precision datum.
/// Then bits 31:16 are also set.
class RiscVWriteRegister extends RiscVMicroOp {
  final RiscVMicroOpField dest;
  final RiscVMicroOpSource source;
  final int valueOffset;
  final bool fp;
  final bool nanBox;
  final bool nanBoxHalf;

  const RiscVWriteRegister(
    this.dest,
    this.source, {
    this.valueOffset = 0,
    this.fp = false,
    this.nanBox = false,
    this.nanBoxHalf = false,
  });
}

/// Read a CSR value.
class RiscVReadCsr extends RiscVMicroOp {
  final RiscVMicroOpField source;

  const RiscVReadCsr(this.source);
}

/// Write a CSR value.
class RiscVWriteCsr extends RiscVMicroOp {
  final RiscVMicroOpField dest;
  final RiscVMicroOpSource source;

  const RiscVWriteCsr(this.dest, this.source);
}

/// Perform an ALU operation.
class RiscVAlu extends RiscVMicroOp {
  final RiscVAluFunct funct;
  final RiscVMicroOpField a;
  final RiscVMicroOpField b;

  const RiscVAlu(this.funct, this.a, this.b);
}

/// Load from memory.
class RiscVMemLoad extends RiscVMicroOp {
  final RiscVMicroOpField base;
  final RiscVMicroOpField dest;
  final RiscVMemSize size;
  final bool unsigned;

  const RiscVMemLoad(this.base, this.dest, this.size, {this.unsigned = false});
}

/// Store to memory.
class RiscVMemStore extends RiscVMicroOp {
  final RiscVMicroOpField base;
  final RiscVMicroOpField src;
  final RiscVMemSize size;

  const RiscVMemStore(this.base, this.src, this.size);
}

/// Load-reserved (for atomic sequences).
class RiscVLoadReserved extends RiscVMicroOp {
  final RiscVMicroOpField base;
  final RiscVMicroOpField dest;
  final RiscVMemSize size;

  const RiscVLoadReserved(this.base, this.dest, this.size);
}

/// Store-conditional (for atomic sequences).
class RiscVStoreConditional extends RiscVMicroOp {
  final RiscVMicroOpField base;
  final RiscVMicroOpField src;
  final RiscVMicroOpField dest;
  final RiscVMemSize size;

  const RiscVStoreConditional(this.base, this.src, this.dest, this.size);
}

/// Atomic memory operation (AMO).
class RiscVAtomicMemory extends RiscVMicroOp {
  final RiscVAtomicFunct funct;
  final RiscVMicroOpField base;
  final RiscVMicroOpField src;
  final RiscVMicroOpField dest;
  final RiscVMemSize size;

  const RiscVAtomicMemory(
    this.funct,
    this.base,
    this.src,
    this.dest,
    this.size,
  );
}

/// Conditional branch.
///
/// Compares the rs1 and rs2 latches. When the condition is true, the next pc
/// is pc plus [offsetField] (or pc plus [offset] when [offsetField] is null).
/// The core does not read [target].
class RiscVBranch extends RiscVMicroOp {
  final RiscVBranchCondition condition;
  final RiscVMicroOpSource target;
  final RiscVMicroOpField? offsetField;
  final int offset;

  const RiscVBranch(
    this.condition,
    this.target, {
    this.offsetField,
    this.offset = 0,
  });
}

/// Update the program counter.
class RiscVUpdatePc extends RiscVMicroOp {
  final RiscVMicroOpField source;
  final int offset;
  final RiscVMicroOpField? offsetField;
  final RiscVMicroOpSource? offsetSource;
  final bool absolute;
  final bool align;

  const RiscVUpdatePc(
    this.source, {
    this.offset = 0,
    this.offsetField,
    this.offsetSource,
    this.absolute = false,
    this.align = false,
  });
}

/// Raise a trap/exception.
class RiscVTrapOp extends RiscVMicroOp {
  final int causeCode;
  final bool isInterrupt;

  /// When set, the core re-encodes the cause from the originating privilege
  /// mode at trap time instead of using [causeCode] verbatim: ECALL becomes
  /// U/VU=8, HS=9, VS=10, M=11. A trap whose cause does not depend on mode
  /// leaves this false and keeps [causeCode].
  final bool modeCause;

  const RiscVTrapOp(
    this.causeCode, {
    this.isInterrupt = false,
    this.modeCause = false,
  });
}

/// Return from exception handler (MRET, SRET, URET).
class RiscVReturnOp extends RiscVMicroOp {
  final int privilegeLevel; // 0=U, 1=S, 3=M

  const RiscVReturnOp(this.privilegeLevel);
}

/// Memory fence.
class RiscVFenceOp extends RiscVMicroOp {
  const RiscVFenceOp();
}

/// TLB fence (SFENCE.VMA).
class RiscVTlbFenceOp extends RiscVMicroOp {
  const RiscVTlbFenceOp();
}

/// TLB invalidate.
class RiscVTlbInvalidateOp extends RiscVMicroOp {
  final RiscVMicroOpField addrField;
  final RiscVMicroOpField asidField;

  const RiscVTlbInvalidateOp(this.addrField, this.asidField);
}

/// Write link register (for JAL/JALR).
class RiscVWriteLinkRegister extends RiscVMicroOp {
  final RiscVMicroOpField dest;
  final int pcOffset;

  const RiscVWriteLinkRegister(this.dest, {this.pcOffset = 4});
}

/// Hold interrupt processing.
class RiscVInterruptHold extends RiscVMicroOp {
  const RiscVInterruptHold();
}

/// Wait for interrupt (WFI).
class RiscVWaitForInterrupt extends RiscVMicroOp {
  const RiscVWaitForInterrupt();
}

/// Hypervisor fence (HFENCE.VVMA / HFENCE.GVMA).
class RiscVHypervisorFenceOp extends RiscVMicroOp {
  final bool isGstage; // true = GVMA, false = VVMA

  const RiscVHypervisorFenceOp({this.isGstage = false});
}

/// Copy the value of one field latch to another.
class RiscVCopyField extends RiscVMicroOp {
  final RiscVMicroOpField src;
  final RiscVMicroOpField dest;

  const RiscVCopyField(this.src, this.dest);
}

class RiscVSetField extends RiscVMicroOp {
  final RiscVMicroOpSource src;
  final RiscVMicroOpField dest;

  const RiscVSetField(this.src, this.dest);
}

enum RiscVFpuFunct {
  fadd,
  fsub,
  fmul,
  fdiv,
  fsqrt,
  // The W converts also carry the unsigned and L forms. The core reads them
  // from rs2 bit 0 (unsigned) and rs2 bit 1 (64-bit integer).
  fcvtWS,
  fcvtSW,
  fcvtLS,
  fcvtSL,
  fcvtWD,
  fcvtDW,
  fcvtLD,
  fcvtDL,
  fcvtSD,
  fcvtDS,
  feq,
  flt,
  fle,
  fmv,
  fclass,
  fsgnj,
  fsgnjn,
  fsgnjx,
  fmin,
  fmax,
  // Fused multiply-add (R4-type): rd = +-(a*b) +- c. The sign of the product and
  // of the addend distinguish the four ops.
  fmadd, // +(a*b)+c
  fmsub, // +(a*b)-c
  fnmsub, // -(a*b)+c
  fnmadd, // -(a*b)-c
  // Zfhmin: half to single and single to half.
  fcvtSH,
  fcvtHS,
  // Zfa: load constant (rs1 is the table index), min/max with NaN
  // propagation, round to integer, and quiet compares.
  fli,
  fminm,
  fmaxm,
  fround,
  froundnx,
  fleq,
  fltq,
  // Zfa: convert double to a 32-bit integer with modular wrap (fcvtmod.w.d).
  fcvtmodWD,
  // Zfhmin with D: half to double and double to half.
  fcvtDH,
  fcvtHD,
  // Zfhmin: move a half to an integer register, sign-extended from bit 15.
  fmvXH,
}

class RiscVFpuOp extends RiscVMicroOp {
  final RiscVFpuFunct funct;
  final RiscVMicroOpField a;
  final RiscVMicroOpField? b;
  // Third source operand (rs3), used only by the fused multiply-add ops.
  final RiscVMicroOpField? c;
  final RiscVMicroOpField dest;
  final bool doublePrecision;

  const RiscVFpuOp(
    this.funct,
    this.a,
    this.dest, {
    this.b,
    this.c,
    this.doublePrecision = false,
  });
}

/// Hypervisor load/store virtual (HLV/HSV).
///
/// The address is the [base] latch with no immediate. A load writes register
/// [dest] directly, as [RiscVAtomicMemory] does, so no [RiscVWriteRegister]
/// follows it.
class RiscVHypervisorMemOp extends RiscVMicroOp {
  final RiscVMicroOpField base;
  final RiscVMicroOpField dest;
  final RiscVMemSize size;
  final bool isStore;
  final bool unsigned;

  const RiscVHypervisorMemOp(
    this.base,
    this.dest,
    this.size, {
    this.isStore = false,
    this.unsigned = false,
  });
}

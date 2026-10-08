import '../encoding/bit_struct.dart';
import '../encoding/riscv_formats.dart';
import '../encoding/rvc_immediate.dart';
import 'micro_op.dart';
import 'mxlen.dart';
import 'resource.dart';

/// How an instruction should be executed.
enum RiscVExecutionMode {
  /// Implemented directly in hardware (combinational/pipelined).
  hardcoded,

  /// Executed via a microcode sequencer stepping through [RiscVMicroOp]s.
  microcoded,

  /// Both: a hard-coded fast path exists alongside a microcode
  /// fallback. The CPU chooses which to use.
  parallel,
}

/// A single RISC-V instruction definition.
///
/// Declarative and const: describes everything the framework
/// needs to know about an instruction: its encoding, what
/// resources it uses, how it executes, and which XLEN values
/// it's valid for.
///
/// ```dart
/// const add = RiscVOperation(
///   mnemonic: 'add',
///   opcode: 0x33,
///   funct3: 0x0,
///   funct7: 0x00,
///   format: rType,
///   resources: [
///     RfResource(intReg32, rs1),
///     RfResource(intReg32, rs2),
///     RfResource(intReg32, rd),
///   ],
///   microcode: [
///     RiscVReadRegister(RiscVMicroOpField.rs1),
///     RiscVReadRegister(RiscVMicroOpField.rs2),
///     RiscVAlu(RiscVAluFunct.add, RiscVMicroOpField.rs1, RiscVMicroOpField.rs2),
///     RiscVWriteRegister(RiscVMicroOpField.rd, RiscVMicroOpSource.alu),
///     RiscVUpdatePc(RiscVMicroOpField.pc, offset: 4),
///   ],
/// )
/// ```
class RiscVOperation {
  /// Human-readable mnemonic (e.g., `'add'`, `'lw'`, `'beq'`).
  final String mnemonic;

  /// Major opcode (bits 6:0).
  final int opcode;

  /// funct3 field (bits 14:12), if used.
  final int? funct3;

  /// funct7 field (bits 31:25), if used.
  final int? funct7;

  /// funct2 field, if used (e.g., some FP instructions).
  final int? funct2;

  /// Instruction format (HarborBitStruct for field extraction).
  final HarborBitStruct format;

  /// Resources this instruction uses (registers, memory, CSR, etc.).
  final List<Resource> resources;

  /// Micro-operation sequence for execution.
  final List<RiscVMicroOp> microcode;

  /// How this instruction should be executed.
  final RiscVExecutionMode executionMode;

  /// Which XLEN values this instruction is valid for.
  ///
  /// `null` means valid for all XLEN values.
  /// `{RiscVMxlen.rv64, RiscVMxlen.rv128}` means only 64/128-bit.
  final Set<RiscVMxlen>? xlenConstraint;

  /// Minimum privilege level required (0=U, 1=S, 3=M).
  /// `null` means any privilege level.
  final int? privilegeLevel;

  /// For compressed instructions: how to descramble this instruction's
  /// immediate. `null` for non-compressed (immediate comes from [format]'s
  /// contiguous fields) or operations with no immediate.
  final RvcImm? immKind;

  /// Extra fixed-bit discriminator on the raw instruction word, for
  /// disambiguating encodings that share opcode/funct (e.g. c.mv vs c.add
  /// differ only in bit 12). When set, `(instruction & matchMask) ==
  /// matchValue` must hold.
  final int? matchMask;
  final int? matchValue;

  /// A group of raw instruction bits that must be non-zero (e.g. rs2 != 0 for
  /// c.add/c.mv) or zero (e.g. rs2 == 0 for c.jr).
  final int? nonZeroMask;
  final int? zeroMask;

  /// Forces a register operand to a fixed index regardless of the encoding,
  /// for instructions with implicit registers (e.g. c.jal/c.jalr link to x1,
  /// c.lwsp/c.swsp/c.addi16sp/c.addi4spn use x2/sp as the base). Applied at
  /// decode after the format-derived register fields.
  final int? fixedRd;
  final int? fixedRs1;
  final int? fixedRs2;

  const RiscVOperation({
    required this.mnemonic,
    required this.opcode,
    this.funct3,
    this.funct7,
    this.funct2,
    required this.format,
    this.resources = const [],
    this.microcode = const [],
    this.executionMode = RiscVExecutionMode.microcoded,
    this.xlenConstraint,
    this.privilegeLevel,
    this.immKind,
    this.matchMask,
    this.matchValue,
    this.nonZeroMask,
    this.zeroMask,
    this.fixedRd,
    this.fixedRs1,
    this.fixedRs2,
  });

  /// Whether this is a 16-bit compressed encoding (bits 1:0 are not 0b11).
  bool get isCompressed => (opcode & 0x3) != 0x3;

  /// Bits of the instruction word that this operation fixes: the opcode,
  /// funct3, funct7 (funct5 for AMO) and [matchMask].
  int get decodeMask {
    var mask = isCompressed ? 0x3 : 0x7F;
    if (funct3 != null) mask |= 0x7 << (isCompressed ? 13 : 12);
    if (!isCompressed && funct7 != null) {
      mask |= opcode == RiscvOpcode.amo ? 0x1F << 27 : 0x7F << 25;
    }
    return mask | (matchMask ?? 0);
  }

  /// Values of the [decodeMask] bits.
  int get decodeValue {
    var value = opcode & (isCompressed ? 0x3 : 0x7F);
    if (funct3 != null) value |= funct3! << (isCompressed ? 13 : 12);
    if (!isCompressed && funct7 != null) {
      value |= opcode == RiscvOpcode.amo ? (funct7! >> 2) << 27 : funct7! << 25;
    }
    return value | (matchValue ?? 0);
  }

  /// Whether the raw [instruction] word decodes as this operation. A
  /// compressed operation only looks at bits 15:0.
  bool matchesWord(int instruction) {
    if ((instruction & decodeMask) != decodeValue) return false;
    if (nonZeroMask != null && (instruction & nonZeroMask!) == 0) return false;
    if (zeroMask != null && (instruction & zeroMask!) != 0) return false;
    return true;
  }

  /// Whether this instruction is valid for the given [mxlen].
  bool isValidFor(RiscVMxlen mxlen) =>
      xlenConstraint == null || xlenConstraint!.contains(mxlen);

  @override
  String toString() => 'RiscVOperation($mnemonic)';
}

/// RVC (compressed) immediate decoding.
///
/// Each compressed instruction's immediate is a distinct bit-scramble of the
/// 16-bit instruction word (RISC-V spec, "RVC immediate encodings"). The
/// per-format [HarborBitStruct] cannot express these permutations, so the
/// descramble lives here as the single source of truth used by BOTH software
/// decode (the emulator) and hardware decode (the generated HDL decoder via
/// [rvcImmLogic]).
library;

import 'package:rohd/rohd.dart';

/// The immediate scramble used by a compressed instruction.
enum RvcImm {
  /// c.addi, c.li: imm[5|4:0], sign-extended (6-bit).
  ciAddi,

  /// c.slli: shamt[5|4:0], zero-extended.
  ciShamt,

  /// c.lui: imm[17|16:12], sign-extended (the value already sits at bits 17:12).
  ciLui,

  /// c.lwsp: uimm[5|4:2|7:6], zero-extended (×4).
  ciLwsp,

  /// c.addi16sp: imm[9|4|6|8:7|5], sign-extended (×16).
  ciAddi16sp,

  /// c.swsp: uimm[5:2|7:6], zero-extended (×4).
  cssSwsp,

  /// c.addi4spn: uimm[5:4|9:6|2|3], zero-extended (×4).
  ciwAddi4spn,

  /// c.lw / c.sw: uimm[5:3|2|6], zero-extended (×4).
  clwsw,

  /// RV64 c.ld / c.sd: uimm[5:3|7:6], zero-extended (×8).
  cldsd,

  /// RV64 c.ldsp: uimm[5|4:3|8:6], zero-extended (×8).
  ciLdsp,

  /// RV64 c.sdsp: uimm[5:3|8:6], zero-extended (×8).
  cssSdsp,

  /// c.j / c.jal: offset[11|4|9:8|10|6|7|3:1|5], sign-extended.
  cj,

  /// c.beqz / c.bnez: offset[8|4:3|7:6|2:1|5], sign-extended.
  cb,

  /// c.andi: imm[5|4:0], sign-extended (6-bit).
  cbAndi,

  /// c.srli / c.srai: shamt[5|4:0], zero-extended.
  cbShamt,

  /// Zcb c.lbu / c.sb: uimm[1:0] = {inst[5], inst[6]}, zero-extended (byte, ×1).
  clb,

  /// Zcb c.lhu / c.lh / c.sh: uimm[1] = inst[5], zero-extended (halfword, ×2).
  clh,
}

int _signExtend(int value, int bits) {
  final signBit = 1 << (bits - 1);
  return (value & signBit) != 0 ? value | ~((1 << bits) - 1) : value;
}

/// Software decode: extracts and descrambles the immediate for [kind] from the
/// raw 16-bit compressed instruction [inst].
int decodeRvcImm(RvcImm kind, int inst) {
  int b(int i) => (inst >> i) & 1;
  int bits(int hi, int lo) => (inst >> lo) & ((1 << (hi - lo + 1)) - 1);

  switch (kind) {
    case RvcImm.ciAddi:
    case RvcImm.cbAndi:
      return _signExtend((b(12) << 5) | bits(6, 2), 6);
    case RvcImm.ciShamt:
    case RvcImm.cbShamt:
      return (b(12) << 5) | bits(6, 2);
    case RvcImm.clb:
      return (b(5) << 1) | b(6);
    case RvcImm.clh:
      return b(5) << 1;
    case RvcImm.ciLui:
      return _signExtend((b(12) << 17) | (bits(6, 2) << 12), 18);
    case RvcImm.ciLwsp:
      return (b(12) << 5) | (bits(6, 4) << 2) | (bits(3, 2) << 6);
    case RvcImm.ciAddi16sp:
      return _signExtend(
        (b(12) << 9) |
            (b(6) << 4) |
            (b(5) << 6) |
            (bits(4, 3) << 7) |
            (b(2) << 5),
        10,
      );
    case RvcImm.cssSwsp:
      return (bits(12, 9) << 2) | (bits(8, 7) << 6);
    case RvcImm.ciwAddi4spn:
      return (bits(12, 11) << 4) |
          (bits(10, 7) << 6) |
          (b(6) << 2) |
          (b(5) << 3);
    case RvcImm.clwsw:
      return (bits(12, 10) << 3) | (b(6) << 2) | (b(5) << 6);
    case RvcImm.cldsd:
      return (bits(12, 10) << 3) | (bits(6, 5) << 6);
    case RvcImm.ciLdsp:
      return (b(12) << 5) | (bits(6, 5) << 3) | (bits(4, 2) << 6);
    case RvcImm.cssSdsp:
      return (bits(12, 10) << 3) | (bits(9, 7) << 6);
    case RvcImm.cj:
      return _signExtend(
        (b(12) << 11) |
            (b(11) << 4) |
            (b(10) << 9) |
            (b(9) << 8) |
            (b(8) << 10) |
            (b(7) << 6) |
            (b(6) << 7) |
            (b(5) << 3) |
            (b(4) << 2) |
            (b(3) << 1) |
            (b(2) << 5),
        12,
      );
    case RvcImm.cb:
      return _signExtend(
        (b(12) << 8) |
            (b(11) << 4) |
            (b(10) << 3) |
            (b(6) << 7) |
            (b(5) << 6) |
            (b(4) << 2) |
            (b(3) << 1) |
            (b(2) << 5),
        9,
      );
  }
}

/// Hardware decode: builds the descrambled immediate for [kind] as a [Logic] of
/// width [xlen], from the (>=16-bit) instruction signal [instr]. Must produce
/// the same value as [decodeRvcImm] for the same instruction word.
Logic rvcImmLogic(RvcImm kind, Logic instr, int xlen) {
  // Single bit i of the instruction.
  Logic b(int i) => instr.slice(i, i);
  // A descrambled immediate is a list of (destLsb, sourceBits) placed into a
  // zeroed field then sign/zero-extended. We build it by swizzling.

  // Helper: assemble from an explicit MSB-first list of 1-bit slices.
  Logic fromBits(
    List<Logic> msbFirst, {
    required bool signed,
    required int width,
  }) {
    final v = msbFirst.concat();
    return signed ? v.signExtend(xlen) : v.zeroExtend(xlen);
  }

  switch (kind) {
    case RvcImm.ciAddi:
    case RvcImm.cbAndi:
      return fromBits(
        [b(12), b(6), b(5), b(4), b(3), b(2)],
        signed: true,
        width: 6,
      );
    case RvcImm.ciShamt:
    case RvcImm.cbShamt:
      return fromBits(
        [b(12), b(6), b(5), b(4), b(3), b(2)],
        signed: false,
        width: 6,
      );
    case RvcImm.clb:
      // uimm[1:0] = {inst[5], inst[6]} (byte, ×1).
      return fromBits([b(5), b(6)], signed: false, width: 2);
    case RvcImm.clh:
      // uimm[1] = inst[5], uimm[0] = 0 (halfword, ×2).
      return fromBits([b(5), Const(0, width: 1)], signed: false, width: 2);
    case RvcImm.ciLui:
      // imm[17:12] then 12 low zeros.
      return [
        b(12),
        b(6),
        b(5),
        b(4),
        b(3),
        b(2),
        Const(0, width: 12),
      ].concat().signExtend(xlen);
    case RvcImm.ciLwsp:
      // uimm[7:6|5|4:2] high->low, then 2 low zeros.
      return [
        b(3), b(2), // [7:6]
        b(12), // [5]
        b(6), b(5), b(4), // [4:2]
        Const(0, width: 2),
      ].concat().zeroExtend(xlen);
    case RvcImm.ciAddi16sp:
      // imm[9|8:7|6|5|4] high->low, then 4 low zeros.
      return [
        b(12), // [9]
        b(4), b(3), // [8:7]
        b(5), // [6]
        b(2), // [5]
        b(6), // [4]
        Const(0, width: 4),
      ].concat().signExtend(xlen);
    case RvcImm.cssSwsp:
      // uimm[7:6|5:2] high->low, then 2 low zeros.
      return [
        b(8), b(7), // [7:6]
        b(12), b(11), b(10), b(9), // [5:2]
        Const(0, width: 2),
      ].concat().zeroExtend(xlen);
    case RvcImm.ciwAddi4spn:
      // uimm[9:6|5:4|3|2] high->low, then 2 low zeros.
      return [
        b(10), b(9), b(8), b(7), // [9:6]
        b(12), b(11), // [5:4]
        b(5), // [3]
        b(6), // [2]
        Const(0, width: 2),
      ].concat().zeroExtend(xlen);
    case RvcImm.clwsw:
      // uimm[6|5:3|2] high->low, then 2 low zeros.
      return [
        b(5), // [6]
        b(12), b(11), b(10), // [5:3]
        b(6), // [2]
        Const(0, width: 2),
      ].concat().zeroExtend(xlen);
    case RvcImm.cldsd:
      // uimm[7:6|5:3] high->low, then 3 low zeros.
      return [
        b(6), b(5), // [7:6]
        b(12), b(11), b(10), // [5:3]
        Const(0, width: 3),
      ].concat().zeroExtend(xlen);
    case RvcImm.ciLdsp:
      // uimm[8:6|5|4:3] high->low, then 3 low zeros.
      return [
        b(4), b(3), b(2), // [8:6]
        b(12), // [5]
        b(6), b(5), // [4:3]
        Const(0, width: 3),
      ].concat().zeroExtend(xlen);
    case RvcImm.cssSdsp:
      // uimm[8:6|5:3] high->low, then 3 low zeros.
      return [
        b(9), b(8), b(7), // [8:6]
        b(12), b(11), b(10), // [5:3]
        Const(0, width: 3),
      ].concat().zeroExtend(xlen);
    case RvcImm.cj:
      return [
        b(12),
        b(8),
        b(10),
        b(9),
        b(6),
        b(7),
        b(2),
        b(11),
        b(5),
        b(4),
        b(3),
        Const(0, width: 1),
      ].concat().signExtend(xlen);
    case RvcImm.cb:
      return [
        b(12),
        b(6),
        b(5),
        b(2),
        b(11),
        b(10),
        b(4),
        b(3),
        Const(0, width: 1),
      ].concat().signExtend(xlen);
  }
}

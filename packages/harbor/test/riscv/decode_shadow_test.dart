import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

final profiles = <String, RiscVIsaConfig>{
  'rv32 small': RiscVIsaConfig(
    mxlen: RiscVMxlen.rv32,
    extensions: [rvC, rvZicsr, rvZifencei, rvM, rvA, rvPriv, rv32i],
  ),
  'rv32 full': RiscVIsaConfig(
    mxlen: RiscVMxlen.rv32,
    extensions: [
      rv32i,
      rvM,
      rvA,
      rvF,
      rvD,
      rvC,
      rvZcb,
      rvZcd,
      rvZcf,
      rvB,
      rvZbc,
      rvZicond,
      rvZicsr,
      rvZifencei,
      rvZfhmin,
      rvZfhminD,
      rvZfa,
      rvZfaD,
      rvZicbom,
      rvZicbop,
      rvZicboz,
      rvZimop,
      rvZcmop,
      rvPriv,
    ],
  ),
  'rv64 small': RiscVIsaConfig(
    mxlen: RiscVMxlen.rv64,
    extensions: [rvC, rvZicsr, rvZifencei, rvM, rvA, rvPriv, rv64i, rv32i],
  ),
  'rv64 fd': RiscVIsaConfig(
    mxlen: RiscVMxlen.rv64,
    extensions: [
      rvC,
      rvZicsr,
      rvZifencei,
      rvM,
      rvA,
      rvF,
      rvD,
      rvZcd,
      rvPriv,
      rv64i,
      rv32i,
    ],
  ),
  'rva23u64': rva23u64,
  'rva23s64': rva23s64,
  'rva23s64 + zbc': RiscVIsaConfig(
    mxlen: RiscVMxlen.rv64,
    extensions: [...rva23s64.extensions, rvZbc],
  ),
};

// Overlaps that the list order resolves on purpose.
const ordered = {
  // c.lui with rd = x2 is c.addi16sp.
  ('c.lui', 'c.addi16sp'),
};

// River's MicrocodeRom._buildDecodePattern, which must agree with
// RiscVOperation.decodeMask and decodeValue.
(int, int) riverPattern(RiscVOperation op) {
  int mask, value;
  if (op.isCompressed) {
    mask = 0x3;
    value = op.opcode & 0x3;
    if (op.funct3 != null) {
      mask |= 0x7 << 13;
      value |= op.funct3! << 13;
    }
  } else {
    mask = 0x7F;
    value = op.opcode & 0x7F;
    if (op.funct3 != null) {
      mask |= 0x7 << 12;
      value |= op.funct3! << 12;
    }
    if (op.funct7 != null) {
      final shiftImm =
          op.opcode == 0x13 && (op.funct3 == 0x1 || op.funct3 == 0x5);
      if (shiftImm) {
        mask |= 0x3F << 26;
        value |= (op.funct7! >> 1) << 26;
      } else if (op.opcode == 0x2F) {
        mask |= 0x1F << 27;
        value |= (op.funct7! >> 2) << 27;
      } else {
        mask |= 0x7F << 25;
        value |= op.funct7! << 25;
      }
    }
  }
  if (op.matchMask != null) {
    mask |= op.matchMask!;
    value |= op.matchValue ?? 0;
  }
  return (mask, value);
}

// A word that satisfies [op]'s pattern, with the free bits taken from [fill].
int sample(RiscVOperation op, int fill) {
  final width = op.isCompressed ? 0xFFFF : 0xFFFFFFFF;
  var w = ((fill & width) & ~op.decodeMask) | op.decodeValue;
  if (op.zeroMask != null) w &= ~op.zeroMask!;
  final nz = op.nonZeroMask;
  if (nz != null && (w & nz) == 0) w |= nz & -nz;
  return w;
}

const scratch = {
  RiscVMicroOpField.rd,
  RiscVMicroOpField.rs1,
  RiscVMicroOpField.rs2,
  RiscVMicroOpField.imm,
};

bool allowed(RiscVOperation op, RiscVOperation? got) {
  if (got == null) return false;
  return ordered.contains((op.mnemonic, got.mnemonic));
}

void main() {
  for (final entry in profiles.entries) {
    final isa = entry.value;
    final ops = isa.allOperations;

    group(entry.key, () {
      test('each op decodes to itself', () {
        final rng = Random(1);
        final fails = <String>{};
        for (final op in ops) {
          final fills = [0, for (var n = 0; n < 64; n++) rng.nextInt(1 << 32)];
          for (final (n, fill) in fills.indexed) {
            final w = sample(op, fill);
            final got = isa.findOperation(w);
            if (identical(got, op)) continue;
            if (n > 0 && allowed(op, got)) continue;
            fails.add(
              '${op.mnemonic} 0x${w.toRadixString(16)} -> ${got?.mnemonic}',
            );
          }
        }
        expect(fails, isEmpty);
      });

      test('patterns are consistent and match River', () {
        for (final op in ops) {
          final mm = op.matchMask ?? 0;
          expect(
            (op.matchValue ?? 0) & ~mm,
            0,
            reason: '${op.mnemonic} matchValue outside matchMask',
          );
          expect(riverPattern(op), (
            op.decodeMask,
            op.decodeValue,
          ), reason: op.mnemonic);
          // The funct fields and matchMask must agree where they overlap.
          final plain = RiscVOperation(
            mnemonic: op.mnemonic,
            opcode: op.opcode,
            funct3: op.funct3,
            funct7: op.funct7,
            format: op.format,
          );
          expect(
            (plain.decodeValue ^ (op.matchValue ?? 0)) & plain.decodeMask & mm,
            0,
            reason: '${op.mnemonic} funct fields and matchValue disagree',
          );
        }
      });

      test('microcode is well formed', () {
        for (final op in ops) {
          final mc = op.microcode;
          final length = op.isCompressed ? 2 : 4;
          expect(
            mc.last,
            anyOf(
              isA<RiscVUpdatePc>(),
              isA<RiscVTrapOp>(),
              isA<RiscVReturnOp>(),
            ),
            reason: op.mnemonic,
          );
          for (final (n, m) in mc.indexed) {
            if (m is RiscVUpdatePc &&
                !m.absolute &&
                m.offsetField == null &&
                m.offsetSource == null) {
              expect(m.offset, length, reason: op.mnemonic);
            }
            if (m is RiscVWriteLinkRegister) {
              expect(m.pcOffset, length, reason: op.mnemonic);
            }
            // Scratch writes go only to rd, rs1, rs2 and imm.
            if (m is RiscVSetField) {
              expect(
                m.dest,
                isIn(scratch),
                reason: '${op.mnemonic} SetField step $n',
              );
            }
            if (m is RiscVCopyField) {
              expect(
                m.dest,
                isIn(scratch),
                reason: '${op.mnemonic} CopyField step $n',
              );
            }
            // A hypervisor load writes rd itself.
            if (m is RiscVHypervisorMemOp) {
              expect(
                mc.whereType<RiscVWriteRegister>(),
                isEmpty,
                reason: op.mnemonic,
              );
            }
            // Each ALU result is read before the next ALU step.
            if (m is RiscVAlu) {
              var used = false;
              for (final later in mc.skip(n + 1)) {
                if (later is RiscVAlu) break;
                used |= switch (later) {
                  RiscVWriteRegister(:final source) ||
                  RiscVWriteCsr(
                    :final source,
                  ) => source == RiscVMicroOpSource.alu,
                  RiscVSetField(:final src) => src == RiscVMicroOpSource.alu,
                  RiscVUpdatePc(:final offsetSource) =>
                    offsetSource == RiscVMicroOpSource.alu,
                  _ => false,
                };
              }
              expect(used, isTrue, reason: '${op.mnemonic} dead ALU step $n');
            }
          }
        }
      });
    });
  }
}

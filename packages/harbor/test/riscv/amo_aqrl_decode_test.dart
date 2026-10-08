import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The AMO major opcode carries the aq/rl ordering hints in funct7[1:0], while
/// funct7[6:2] (funct5) selects the operation. Those ordering bits are decode
/// irrelevant: sc.w, sc.w.aq, sc.w.rl and sc.w.aqrl must all decode to sc.w.
///
/// HW-observed on delta: Linux relocate_enable_mmu completes, then the kernel
/// faults illegal-instruction (scause=2) on a cmpxchg's `sc.w.rl` (0x1af7262f,
/// funct7=0x0D) inside a cpuhp tracepoint. The decoder matched the full funct7
/// (0x0C, aq=rl=0) so any ordered atomic missed and raised illegal. The first
/// ordered atomic on the boot path is the first to hit it; relaxed atomics
/// (aq=rl=0) got the kernel that far.
void main() {
  // funct5 -> base funct7 (aq=rl=0), the ordering-free encoding.
  const amoBases = <String, int>{
    'lr.w': 0x08,
    'sc.w': 0x0C,
    'amoswap.w': 0x04,
    'amoadd.w': 0x00,
    'amoand.w': 0x30,
    'amoor.w': 0x20,
  };

  RiscVInstructionDecoder mkDecoder(Logic instrIn) => RiscVInstructionDecoder(
    RiscVIsaConfig(mxlen: RiscVMxlen.rv64, extensions: [rv64i, rvM, rvA]),
    instructionInput: instrIn,
  );

  // rType AMO encode: opcode=amo, funct3 (.w=2), funct7 (funct5<<2 | aq<<1 | rl),
  // rs1/rs2/rd arbitrary.
  int encAmo(int funct7, {int rd = 12, int rs1 = 14, int rs2 = 15}) =>
      (funct7 << 25) |
      (rs2 << 20) |
      (rs1 << 15) |
      (0x2 << 12) |
      (rd << 7) |
      0x2F;

  test('the exact delta fault: sc.w.rl 0x1af7262f decodes legal', () async {
    final instrIn = Logic(name: 'instr_in', width: 32);
    final mod = mkDecoder(instrIn);
    await mod.build();

    instrIn.put(0x1af7262f); // sc.w.rl a2,a5,(a4)
    expect(
      mod.output('illegal').value.toInt(),
      equals(0),
      reason: 'sc.w.rl must decode (aq/rl are ordering hints, not opcode)',
    );
  });

  test('aq/rl sweep on all word AMO/LR/SC decodes legal', () async {
    final instrIn = Logic(name: 'instr_in', width: 32);
    final mod = mkDecoder(instrIn);
    await mod.build();

    for (final entry in amoBases.entries) {
      for (var order = 0; order < 4; order++) {
        // order bit1=aq, bit0=rl; base funct7 already has aq=rl=0.
        final funct7 = entry.value | order;
        // lr.w reserves rs2, it must be x0.
        final rs2 = entry.key == 'lr.w' ? 0 : 15;
        instrIn.put(encAmo(funct7, rs2: rs2));
        expect(
          mod.output('illegal').value.toInt(),
          equals(0),
          reason:
              '${entry.key} with aq/rl=$order (funct7=0x'
              '${funct7.toRadixString(16)}) must decode legal',
        );
      }
    }
  });
}

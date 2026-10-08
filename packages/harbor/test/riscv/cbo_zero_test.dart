import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

// Runs a micro-op sequence on plain latches and returns the stores it makes.
// The rs3 and pc latches hold junk, so a sequence that reads them goes wrong.
List<(int, int, int)> run(RiscVOperation op, int word, Map<int, int> regs) {
  const mask = (1 << 64) - 1;
  var imm = (word >> 20) & 0xFFF;
  if (imm & 0x800 != 0) imm -= 0x1000;
  final latch = <RiscVMicroOpField, int>{
    RiscVMicroOpField.rd: (word >> 7) & 0x1F,
    RiscVMicroOpField.rs1: (word >> 15) & 0x1F,
    RiscVMicroOpField.rs2: (word >> 20) & 0x1F,
    RiscVMicroOpField.rs3: 0x80001000,
    RiscVMicroOpField.imm: imm & mask,
    RiscVMicroOpField.pc: 0x12340000,
  };
  var alu = 0;
  final stores = <(int, int, int)>[];
  for (final m in op.microcode) {
    switch (m) {
      case RiscVReadRegister(:final source):
        latch[source] = regs[latch[source]] ?? 0;
      case RiscVAlu(:final funct, :final a, :final b):
        final x = latch[a]!, y = latch[b]!;
        alu =
            switch (funct) {
              RiscVAluFunct.add => x + y,
              RiscVAluFunct.sub => x - y,
              RiscVAluFunct.xor_ => x ^ y,
              RiscVAluFunct.sltu => x < y ? 1 : 0,
              RiscVAluFunct.sll => x << (y & 63),
              RiscVAluFunct.srl => (x & mask) >> (y & 63),
              _ => throw UnsupportedError('$funct'),
            } &
            mask;
      case RiscVSetField(:final src, :final dest):
        latch[dest] = src == RiscVMicroOpSource.alu
            ? alu
            : latch[RiscVMicroOpField.imm]!;
      case RiscVMemStore(:final base, :final src, :final size):
        final addr = (latch[base]! + latch[RiscVMicroOpField.imm]!) & mask;
        stores.add((addr, size.bytes, latch[src]!));
      case RiscVUpdatePc():
        break;
      default:
        throw UnsupportedError('$m');
    }
  }
  return stores;
}

void main() {
  for (final mxlen in [RiscVMxlen.rv64, RiscVMxlen.rv32]) {
    test('cbo.zero (a0) zeroes the aligned block on $mxlen', () {
      final isa = RiscVIsaConfig(mxlen: mxlen, extensions: [rvZicboz]);
      const word = 0x0045200F; // cbo.zero (a0)
      final op = isa.findOperation(word)!;
      final stores = run(op, word, {10: 0x80000830});
      final bytes = <int>{};
      for (final (addr, size, value) in stores) {
        expect(value, 0);
        expect(addr % size, 0);
        for (var b = 0; b < size; b++) {
          bytes.add(addr + b);
        }
      }
      expect(bytes, {for (var a = 0x80000800; a < 0x80000840; a++) a});
    });
  }
}

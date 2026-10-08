import 'mxlen.dart';
import 'operation.dart';

/// A RISC-V ISA extension containing a set of instructions.
///
/// Extensions are const and declarative. They define the
/// instructions they provide and their misa bit.
///
/// ```dart
/// const rv32m = RiscVExtension(
///   name: 'RV32M',
///   key: 'M',
///   misaBit: 12,
///   operations: [mul, mulh, mulhsu, mulhu, div, divu, rem, remu],
/// );
/// ```
class RiscVExtension {
  /// Full extension name (e.g., `'RV32I'`, `'RV64M'`).
  final String name;

  /// Single-letter key for misa (e.g., `'I'`, `'M'`, `'A'`).
  /// Can be longer for named extensions (e.g., `'Zicsr'`).
  final String? key;

  /// Bit position in the misa register (0=A, 1=B, ..., 25=Z).
  /// `null` for sub-extensions like Zicsr that don't have their own bit.
  final int? misaBit;

  /// misa mask value. Computed from [misaBit] if set.
  int get mask => misaBit != null ? (1 << misaBit!) : 0;

  /// All operations defined by this extension.
  final List<RiscVOperation> operations;

  const RiscVExtension({
    required this.name,
    this.key,
    this.misaBit,
    this.operations = const [],
  });

  /// Finds the first operation that decodes [instruction], skipping ops that
  /// are not valid for [mxlen] when it is given.
  RiscVOperation? findOperation(int instruction, {RiscVMxlen? mxlen}) {
    for (final op in operations) {
      if ((mxlen == null || op.isValidFor(mxlen)) &&
          op.matchesWord(instruction)) {
        return op;
      }
    }
    return null;
  }

  /// Operations valid for the given [mxlen].
  List<RiscVOperation> operationsFor(RiscVMxlen mxlen) =>
      operations.where((op) => op.isValidFor(mxlen)).toList();

  @override
  String toString() => 'RiscVExtension($name)';
}

import 'extension.dart';
import 'mxlen.dart';
import 'operation.dart';
import 'paging.dart';

/// Complete RISC-V ISA configuration.
///
/// Combines an XLEN, a set of extensions, privilege mode support,
/// and paging configuration into a single description of what
/// the CPU implements.
///
/// ```dart
/// final isa = RiscVIsaConfig(
///   mxlen: RiscVMxlen.rv64,
///   extensions: [rv64i, rv64m, rv64a, rvD, rvC, rvV, rvH, rvZicsr],
///   hasSupervisor: true,
///   hasUser: true,
///   pagingModes: [RiscVPagingMode.bare, RiscVPagingMode.sv39, RiscVPagingMode.sv48],
///   executionOverrides: {'div': RiscVExecutionMode.microcoded},
/// );
/// ```
class RiscVIsaConfig {
  /// Base integer register width.
  final RiscVMxlen mxlen;

  /// ISA extensions included.
  final List<RiscVExtension> extensions;

  /// Whether supervisor mode is supported.
  final bool hasSupervisor;

  /// Whether user mode is supported.
  final bool hasUser;

  /// Supported paging modes.
  ///
  /// If empty, derived from [mxlen] (all modes supported by the XLEN).
  final List<RiscVPagingMode> pagingModes;

  /// Per-instruction execution mode overrides.
  ///
  /// Keys are instruction mnemonics. Overrides the default
  /// [RiscVExecutionMode] set in each [RiscVOperation].
  final Map<String, RiscVExecutionMode> executionOverrides;

  const RiscVIsaConfig({
    required this.mxlen,
    required this.extensions,
    this.hasSupervisor = false,
    this.hasUser = false,
    this.pagingModes = const [],
    this.executionOverrides = const {},
  });

  /// All paging modes, using defaults if none specified.
  List<RiscVPagingMode> get effectivePagingModes =>
      pagingModes.isNotEmpty ? pagingModes : RiscVPagingMode.supportedBy(mxlen);

  /// All operations from all extensions, filtered by XLEN.
  List<RiscVOperation> get allOperations =>
      extensions.expand((ext) => ext.operationsFor(mxlen)).toList();

  /// Operations that should be hard-coded (fast path).
  List<RiscVOperation> get hardcodedOps => allOperations
      .where(
        (op) =>
            _effectiveMode(op) == RiscVExecutionMode.hardcoded ||
            _effectiveMode(op) == RiscVExecutionMode.parallel,
      )
      .toList();

  /// Operations that should be microcoded.
  List<RiscVOperation> get microcodedOps => allOperations
      .where(
        (op) =>
            _effectiveMode(op) == RiscVExecutionMode.microcoded ||
            _effectiveMode(op) == RiscVExecutionMode.parallel,
      )
      .toList();

  /// Gets the effective execution mode for an operation,
  /// considering overrides.
  RiscVExecutionMode _effectiveMode(RiscVOperation op) =>
      executionOverrides[op.mnemonic] ?? op.executionMode;

  /// The effective execution mode for a specific operation.
  RiscVExecutionMode executionModeFor(RiscVOperation op) => _effectiveMode(op);

  /// Finds the first operation that decodes [instruction].
  ///
  /// A word with bits 1:0 not equal to 0b11 is a 16-bit compressed
  /// instruction, and only its low 16 bits are used.
  RiscVOperation? findOperation(int instruction) {
    for (final ext in extensions) {
      final op = ext.findOperation(instruction, mxlen: mxlen);
      if (op != null) return op;
    }
    return null;
  }

  /// The ISA string (e.g., `"RV64IMACV"`).
  ///
  /// Follows RISC-V naming convention: base + single-letter
  /// extensions in canonical order.
  String get implementsString {
    final hasI = extensions.any((e) => e.key == 'I');
    final hasE = extensions.any((e) => e.key == 'E');
    if (!hasI && !hasE) return 'RV${mxlen.size}';

    final baseLetter = hasE ? 'E' : 'I';
    final buf = StringBuffer('RV${mxlen.size}$baseLetter');

    // Canonical extension order: MAFDQLCBJTPVN + H + S + U
    const order = 'MAFDQLCBJTPVN';
    for (final c in order.split('')) {
      if (extensions.any((e) => e.key == c)) buf.write(c);
    }

    // Hypervisor
    if (extensions.any((e) => e.key == 'H')) buf.write('H');

    // Privilege modes
    if (hasSupervisor) buf.write('S');
    if (hasUser) buf.write('U');

    return buf.toString();
  }

  /// Single-letter order the device tree binding accepts, which also fixes
  /// where a named Z extension sorts: after the letter it extends.
  static const _dtLetterOrder = 'imafdqcbkjpvh';

  /// The base ISA for `riscv,isa-base`, or null when the hart has no I base.
  /// The binding defines a value only for `rv32i` and `rv64i`.
  String? get dtIsaBase =>
      extensions.any((e) => e.key == 'I') ? 'rv${mxlen.size}i' : null;

  /// Extension names for `riscv,isa-extensions`, lowercase and in canonical
  /// order. Zcd needs Zca, so a hart that has both C and Zcd reports Zca as
  /// well, which the binding requires.
  List<String> get dtIsaExtensions {
    final names = <String>{};
    for (final e in extensions) {
      final dt = e.dtName;
      if (dt != null) names.add(dt);
    }
    if (names.contains('zcd') && names.contains('c')) names.add('zca');
    final letters = names.where((n) => n.length == 1).toList()
      ..sort((a, b) => _dtLetterRank(a).compareTo(_dtLetterRank(b)));
    final named = names.where((n) => n.length > 1).toList()
      ..sort(_dtNamedOrder);
    return [...letters, ...named];
  }

  /// The deprecated `riscv,isa` string, e.g. `rv64imafdc_zicsr_zifencei`. ACPI
  /// carries the same string in its RHCT table, where it is the only ISA
  /// report an OS gets, so it has to name every extension.
  ///
  /// The binding's pattern requires `ima` before the optional letters, so a
  /// hart without M or A cannot be written in this form at all. The string
  /// stays honest about what the hart has and [dtIsaExtensions] carries the
  /// same answer in the form that has no such limit.
  String get dtIsaString {
    final base = dtIsaBase;
    if (base == null) return 'rv${mxlen.size}';
    final exts = dtIsaExtensions;
    final letters = exts.where((e) => e.length == 1 && e != 'i').join();
    final named = exts.where((e) => e.length > 1).map((e) => '_$e').join();
    return '$base$letters$named';
  }

  static int _dtLetterRank(String name) {
    final i = _dtLetterOrder.indexOf(name[0]);
    return i < 0 ? _dtLetterOrder.length : i;
  }

  /// Named extensions group by their first letter, Z then S then H then X, and
  /// a Z extension then sorts by the letter it extends.
  static int _dtNamedOrder(String a, String b) {
    const groups = 'zshx';
    final ga = groups.indexOf(a[0]) < 0 ? groups.length : groups.indexOf(a[0]);
    final gb = groups.indexOf(b[0]) < 0 ? groups.length : groups.indexOf(b[0]);
    if (ga != gb) return ga.compareTo(gb);
    if (a[0] == 'z' && a[1] != b[1]) {
      return _dtLetterRank(a[1]).compareTo(_dtLetterRank(b[1]));
    }
    return a.compareTo(b);
  }

  /// Combined misa register value for all extensions.
  int get misaValue {
    var value = mxlen.misa;
    for (final ext in extensions) {
      value |= ext.mask;
    }
    if (hasSupervisor) value |= (1 << 18); // S bit
    if (hasUser) value |= (1 << 20); // U bit
    return value;
  }

  @override
  String toString() => 'RiscVIsaConfig(${implementsString})';
}

import '../util/pretty_string.dart';

/// A CPU hart description shared across all SoC generators.
///
/// This is the single source of truth consumed by the device tree, ACPI and
/// topology graph generators. Generators read these fields and emit them in
/// their own format. There is no conversion between generator-specific CPU
/// types.
class HarborCpu with HarborPrettyString {
  /// Hart ID.
  final int hartId;

  /// ISA string, e.g. `"rv64imac"`.
  final String isa;

  /// Base ISA for the device tree `riscv,isa-base`, e.g. `"rv64i"`. The
  /// binding pairs it with [isaExtensions] and modern Linux reads the pair
  /// first, falling back to [isa] only without it.
  final String? isaBase;

  /// Extension names for the device tree `riscv,isa-extensions`, lowercase.
  /// Unlike [isa] this form has no ordering limit, so it can name every
  /// extension a hart has.
  final List<String> isaExtensions;

  /// MMU type, e.g. `"riscv,sv39"` (optional).
  final String? mmu;

  /// Clock frequency in Hz (optional).
  final int? clockFrequency;

  /// Timer (`mtime`) tick rate in Hz, emitted as the device tree
  /// `timebase-frequency` (optional). The Harbor CLINT increments `mtime`
  /// once per bus clock, so this equals the clock the CLINT runs at. RISC-V
  /// requires it for the timer, so a DTS without it leaves an OS with no
  /// working time source.
  final int? timebaseFrequency;

  /// Product name for the device tree `model` property (optional).
  final String? model;

  /// Vendor compatible strings placed before `"riscv"` in the device tree
  /// `compatible` property, e.g. `["lilith,river-rc1f"]`.
  final List<String> compatible;

  const HarborCpu({
    required this.hartId,
    required this.isa,
    this.isaBase,
    this.isaExtensions = const [],
    this.mmu,
    this.clockFrequency,
    this.timebaseFrequency,
    this.model,
    this.compatible = const [],
  });

  @override
  String toString() => 'HarborCpu(hart$hartId, $isa)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborCpu(\n');
    buf.writeln('${c}hartId: $hartId,');
    buf.writeln('${c}isa: $isa,');
    if (isaBase != null) buf.writeln('${c}isaBase: $isaBase,');
    if (isaExtensions.isNotEmpty)
      buf.writeln('${c}isaExtensions: ${isaExtensions.join(" ")},');
    if (mmu != null) buf.writeln('${c}mmu: $mmu,');
    if (clockFrequency != null)
      buf.writeln('${c}clockFrequency: $clockFrequency,');
    if (timebaseFrequency != null)
      buf.writeln('${c}timebaseFrequency: $timebaseFrequency,');
    if (model != null) buf.writeln('${c}model: $model,');
    if (compatible.isNotEmpty)
      buf.writeln('${c}compatible: ${compatible.join(" ")},');
    buf.write('$p)');
    return buf.toString();
  }
}

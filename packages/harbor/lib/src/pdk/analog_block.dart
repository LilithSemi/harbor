import 'package:rohd/rohd.dart';

import '../util/pretty_string.dart';

/// Describes an analog block's symbol and pin mapping for a specific PDK.
///
/// Used by [PdkProvider] to map canonical Harbor pin names to
/// PDK-specific cell/symbol names.
class AnalogBlock with HarborPrettyString {
  /// Symbol or cell path (e.g., xschem `.sym`, LEF macro name).
  final String symbolPath;

  /// Maps canonical pin names to PDK-specific pin names.
  ///
  /// Keys are Harbor names (e.g., `'refClk'`, `'padIn'`).
  /// Values are the PDK pin names (e.g., `'CLK'`, `'PAD'`).
  final Map<String, String> pinMapping;

  /// Additional instance properties (key=value pairs).
  final Map<String, String> properties;

  /// Harbor pin names whose PDK pin is active low. A driver inverts these,
  /// so each PDK states its own convention.
  final Set<String> activeLow;

  /// Integer parameters of the block. An SRAM with a `writeMask` pin gives
  /// `writeMaskBits`, the data bits that each mask bit covers.
  final Map<String, int> params;

  const AnalogBlock({
    required this.symbolPath,
    required this.pinMapping,
    this.properties = const {},
    this.activeLow = const {},
    this.params = const {},
  });

  /// Drives [active] on Harbor pin [name] at the level the PDK pin wants.
  Logic level(String name, Logic active) =>
      activeLow.contains(name) ? ~active : active;

  @override
  String toString() => 'AnalogBlock($symbolPath)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}AnalogBlock(\n');
    buf.writeln('${c}symbol: $symbolPath,');
    buf.writeln('${c}pins: {');
    for (final entry in pinMapping.entries) {
      final low = activeLow.contains(entry.key) ? ' (active low)' : '';
      buf.writeln(
        '${options.nested().childPrefix}${entry.key} -> ${entry.value}$low,',
      );
    }
    buf.writeln('$c},');
    if (properties.isNotEmpty) {
      buf.writeln('${c}properties: $properties,');
    }
    buf.write('$p)');
    return buf.toString();
  }
}

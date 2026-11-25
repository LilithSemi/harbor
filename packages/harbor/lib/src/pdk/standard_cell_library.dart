import '../util/pretty_string.dart';

/// Describes a standard cell library within a PDK.
///
/// Provides paths to Liberty timing models, LEF abstracts, Verilog
/// models, and cell naming conventions needed for synthesis and P&R.
class StandardCellLibrary with HarborPrettyString {
  /// Human-readable name (e.g., `'sky130_fd_sc_hd'`).
  final String name;

  /// Path to the Liberty timing file (`.lib`).
  final String libertyPath;

  /// Path to the LEF abstract file (`.lef`).
  final String lefPath;

  /// Path to the tech LEF file (`.tlef`).
  final String? techLefPath;

  /// Path to the Verilog behavioral models.
  final String? verilogPath;

  /// Cell name prefix (e.g., `'sky130_fd_sc_hd__'`).
  final String cellPrefix;

  /// Standard site name for placement (e.g., `'unithd'`).
  final String siteName;

  /// Tie-high cell name.
  final String tieHighCell;

  /// Tie-low cell name.
  final String tieLowCell;

  /// Buffer cell names for clock tree synthesis (smallest to largest).
  final List<String> clockBufferCells;

  /// Fill cell names for density fill.
  final List<String> fillCells;

  /// Decap cell names or glob patterns, placed before [fillCells].
  final List<String> decapCells;

  /// Antenna diode cell name for `repair_antennas`.
  final String? antennaCell;

  /// Horizontal routing layer for top-level pins (`place_pins -hor_layers`).
  final String? pinHorizontalLayer;

  /// Vertical routing layer for top-level pins (`place_pins -ver_layers`).
  final String? pinVerticalLayer;

  const StandardCellLibrary({
    required this.name,
    required this.libertyPath,
    required this.lefPath,
    this.techLefPath,
    this.verilogPath,
    required this.cellPrefix,
    required this.siteName,
    required this.tieHighCell,
    required this.tieLowCell,
    this.clockBufferCells = const [],
    this.fillCells = const [],
    this.decapCells = const [],
    this.antennaCell,
    this.pinHorizontalLayer,
    this.pinVerticalLayer,
  });

  @override
  String toString() => 'StandardCellLibrary($name)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}StandardCellLibrary(\n');
    buf.writeln('${c}name: $name,');
    buf.writeln('${c}liberty: $libertyPath,');
    buf.writeln('${c}lef: $lefPath,');
    if (techLefPath != null) buf.writeln('${c}techLef: $techLefPath,');
    buf.writeln('${c}cellPrefix: $cellPrefix,');
    buf.writeln('${c}site: $siteName,');
    buf.writeln('${c}tieHigh: $tieHighCell,');
    buf.writeln('${c}tieLow: $tieLowCell,');
    if (clockBufferCells.isNotEmpty) {
      buf.writeln('${c}clkBufs: [${clockBufferCells.join(", ")}],');
    }
    if (fillCells.isNotEmpty) {
      buf.writeln('${c}fills: [${fillCells.join(", ")}],');
    }
    if (decapCells.isNotEmpty) {
      buf.writeln('${c}decaps: [${decapCells.join(", ")}],');
    }
    if (antennaCell != null) buf.writeln('${c}antenna: $antennaCell,');
    if (pinHorizontalLayer != null && pinVerticalLayer != null) {
      buf.writeln('${c}pins: $pinHorizontalLayer/$pinVerticalLayer,');
    }
    buf.write('$p)');
    return buf.toString();
  }
}

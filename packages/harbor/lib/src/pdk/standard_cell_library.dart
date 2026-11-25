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

  /// Layer for `set_wire_rc` when the flow has no `RC_TCL`.
  final String? wireRcLayer;

  /// Cell pin names that connect to the power net.
  final List<String> powerPins;

  /// Cell pin names that connect to the ground net.
  final List<String> groundPins;

  /// Well tap cell for `tapcell`. Without it, the flow writes no `tapcell`.
  final String? tapCell;

  /// Endcap cell for `tapcell`.
  final String? endcapCell;

  /// Maximum distance between tap cells in a row (um).
  final double tapDistanceUm;

  /// Power grid for the standard cells. Without it, the flow writes no PDN.
  final HarborPdnGrid? pdn;

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
    this.wireRcLayer,
    this.powerPins = const ['VDD'],
    this.groundPins = const ['VSS'],
    this.tapCell,
    this.endcapCell,
    this.tapDistanceUm = 20,
    this.pdn,
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
    if (tapCell != null) buf.writeln('${c}tap: $tapCell,');
    if (endcapCell != null) buf.writeln('${c}endcap: $endcapCell,');
    buf.write('$p)');
    return buf.toString();
  }
}

/// One set of power and ground stripes in a [HarborPdnGrid].
class HarborPdnStripe {
  /// Metal layer name.
  final String layer;

  /// Stripe width (um).
  final double widthUm;

  /// Distance between two stripe pairs (um).
  final double pitchUm;

  /// Distance from the core edge to the first stripe (um).
  final double offsetUm;

  /// Gap between the power stripe and the ground stripe of a pair (um).
  final double spacingUm;

  const HarborPdnStripe({
    required this.layer,
    required this.widthUm,
    required this.pitchUm,
    required this.offsetUm,
    required this.spacingUm,
  });
}

/// Standard cell power grid for OpenROAD `pdngen`.
///
/// The rails follow the cell rows on [railLayer]. Each stripe in [stripes]
/// connects to the layer before it, the first one to the rails. The stripe
/// layers are also the grid pin layers.
class HarborPdnGrid {
  /// Layer of the rails on the cell rows.
  final String railLayer;

  /// Rail width (um).
  final double railWidthUm;

  /// Stripes from the lowest layer to the highest.
  final List<HarborPdnStripe> stripes;

  const HarborPdnGrid({
    required this.railLayer,
    required this.railWidthUm,
    required this.stripes,
  });
}

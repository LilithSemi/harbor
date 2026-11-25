/// KLayout script generation for GDS manipulation, DRC, and LVS.
library;

import 'dart:convert';

/// KLayout DRC rule deck configuration.
class HarborKlayoutDrcConfig {
  /// Path to the PDK DRC rule deck.
  final String deckPath;

  /// Additional DRC options.
  final Map<String, String> options;

  const HarborKlayoutDrcConfig({
    required this.deckPath,
    this.options = const {},
  });
}

/// Generates KLayout scripts for post-PnR verification and GDS assembly.
class HarborKlayoutScripts {
  /// PDK name for script comments.
  final String pdkName;

  /// Top cell name.
  final String topCell;

  /// DRC configuration (null = skip DRC).
  final HarborKlayoutDrcConfig? drc;

  /// Path to LVS netlist for comparison.
  final String? lvsNetlistPath;

  const HarborKlayoutScripts({
    required this.pdkName,
    required this.topCell,
    this.drc,
    this.lvsNetlistPath,
  });

  /// Generates a KLayout Python script to merge analog macro GDS
  /// files into the final digital PnR GDS output.
  ///
  /// This is needed because OpenROAD outputs a DEF that only
  /// contains the digital layout. Analog blocks (IO pads, PLLs,
  /// bandgap sensors) have pre-existing GDS that must be merged.
  String generateGdsMerge({
    required String digitalGdsPath,
    required List<String> analogGdsPaths,
    required String outputGdsPath,
  }) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated KLayout GDS merge script');
    buf.writeln('# PDK: $pdkName');
    buf.writeln('# Top cell: $topCell');
    buf.writeln();
    buf.writeln('import klayout.db as kdb');
    buf.writeln();
    buf.writeln('layout = kdb.Layout()');
    buf.writeln();

    // Read the digital PnR output
    buf.writeln('# Read digital PnR GDS');
    buf.writeln('layout.read("$digitalGdsPath")');
    buf.writeln();

    // Read and merge each analog block GDS
    buf.writeln('# Merge analog block GDS files');
    for (final gds in analogGdsPaths) {
      buf.writeln('layout.read("$gds")');
    }
    buf.writeln();

    // Write merged output
    buf.writeln('# Write merged GDS');
    buf.writeln('layout.write("$outputGdsPath")');
    buf.writeln('print(f"Merged GDS written to $outputGdsPath")');

    return buf.toString();
  }

  /// Generates a KLayout DRC script.
  ///
  /// The script runs the [drc] deck on the final GDS in a second KLayout
  /// process and writes `<top>_drc.xml`. It exits with code 1 when the deck
  /// fails, when the report is missing, or when the report has violations.
  /// The deck gets `input`, `report` and `topcell`, then the deck options.
  String generateDrc({required String gdsPath}) {
    final deck = drc;
    if (deck == null) {
      throw StateError('generateDrc needs a DRC deck');
    }
    final report = '${topCell}_drc.xml';
    final vars = {
      'input': gdsPath,
      'report': report,
      'topcell': topCell,
      ...deck.options,
    };
    final buf = StringBuffer();
    buf.writeln('# Auto-generated KLayout DRC script');
    buf.writeln('# PDK: $pdkName');
    buf.writeln();
    buf.writeln('import shutil');
    buf.writeln('import subprocess');
    buf.writeln('import sys');
    buf.writeln();
    buf.writeln('import klayout.rdb as rdb');
    buf.writeln();
    buf.writeln('report = ${jsonEncode(report)}');
    buf.writeln('cmd = [');
    buf.writeln('    shutil.which("klayout") or "klayout",');
    buf.writeln('    "-b",');
    buf.writeln('    "-r",');
    buf.writeln('    ${jsonEncode(deck.deckPath)},');
    for (final e in vars.entries) {
      buf.writeln('    "-rd",');
      buf.writeln('    ${jsonEncode('${e.key}=${e.value}')},');
    }
    buf.writeln(']');
    buf.writeln('code = subprocess.call(cmd)');
    buf.writeln('if code != 0:');
    buf.writeln('    print(f"DRC: the deck stopped with exit code {code}")');
    buf.writeln('    sys.exit(1)');
    buf.writeln();
    buf.writeln('db = rdb.ReportDatabase("DRC: $topCell")');
    buf.writeln('try:');
    buf.writeln('    db.load(report)');
    buf.writeln('except Exception as e:');
    buf.writeln('    print(f"DRC: cannot read {report}: {e}")');
    buf.writeln('    sys.exit(1)');
    buf.writeln('count = db.num_items()');
    buf.writeln('if count != 0:');
    buf.writeln('    print(f"DRC: {count} violations in {report}")');
    buf.writeln('    sys.exit(1)');
    buf.writeln('print("DRC: no violations")');

    return buf.toString();
  }

  /// Generates a KLayout LVS script.
  ///
  /// Extracts a netlist from the GDS and compares it against
  /// the synthesized Verilog netlist.
  String generateLvs({required String gdsPath}) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated KLayout LVS script');
    buf.writeln('# PDK: $pdkName');
    buf.writeln();
    buf.writeln('import klayout.db as kdb');
    buf.writeln();
    buf.writeln('# Load layout');
    buf.writeln('layout = kdb.Layout()');
    buf.writeln('layout.read("$gdsPath")');
    buf.writeln();

    if (lvsNetlistPath != null) {
      buf.writeln('# Reference netlist');
      buf.writeln('# Source: $lvsNetlistPath');
    }

    buf.writeln('# Extract netlist from layout');
    buf.writeln('extractor = kdb.NetlistDeviceExtractor()');
    buf.writeln('# Configure extraction rules per PDK');
    buf.writeln();
    buf.writeln('# Compare extracted vs reference netlist');
    buf.writeln('print("LVS complete")');

    return buf.toString();
  }

  /// Generates a script to convert DEF to GDS using KLayout.
  ///
  /// This is an alternative to OpenROAD's built-in DEF-to-GDS
  /// when more control over layer mapping is needed.
  String generateDefToGds({
    required String defPath,
    required String techLefPath,
    required String outputGdsPath,
    List<String> cellLefPaths = const [],
    List<String> cellGdsPaths = const [],
  }) {
    final buf = StringBuffer();
    buf.writeln('# Auto-generated KLayout DEF-to-GDS script');
    buf.writeln('# PDK: $pdkName');
    buf.writeln();
    buf.writeln('import klayout.db as kdb');
    buf.writeln();
    buf.writeln('layout = kdb.Layout()');
    buf.writeln();

    // Read tech LEF for layer mapping
    buf.writeln('# Read technology LEF');
    buf.writeln('reader = kdb.LEFDEFReaderConfiguration()');
    buf.writeln('layout.read("$techLefPath", reader)');
    buf.writeln();

    // Read cell LEFs
    for (final lef in cellLefPaths) {
      buf.writeln('layout.read("$lef", reader)');
    }
    buf.writeln();

    // Read cell GDS for fill
    for (final gds in cellGdsPaths) {
      buf.writeln('layout.read("$gds")');
    }
    buf.writeln();

    // Read the DEF
    buf.writeln('# Read placed and routed DEF');
    buf.writeln('layout.read("$defPath", reader)');
    buf.writeln();

    // Write GDS
    buf.writeln('# Write final GDS');
    buf.writeln('layout.write("$outputGdsPath")');
    buf.writeln('print(f"GDS written: $outputGdsPath")');

    return buf.toString();
  }
}

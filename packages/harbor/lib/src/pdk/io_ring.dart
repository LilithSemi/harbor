import '../util/pretty_string.dart';
import 'pdk_provider.dart';

/// Placement edge for IO pads.
enum HarborIoPadEdge { north, east, south, west }

/// An IO pad assignment in the pad ring.
class HarborIoPad {
  /// Signal name this pad connects to.
  final String signalName;

  /// Edge of the die this pad sits on.
  final HarborIoPadEdge edge;

  /// Order index along the edge (0 = first pad on this edge).
  final int position;

  /// Whether this is a power pad (VDD/VSS).
  final bool isPower;

  /// Power net name (if isPower).
  final String? powerNet;

  const HarborIoPad({
    required this.signalName,
    required this.edge,
    this.position = 0,
    this.isPower = false,
    this.powerNet,
  });

  /// VDD power pad.
  const HarborIoPad.vdd({required this.edge, this.position = 0})
    : signalName = 'VDD',
      isPower = true,
      powerNet = 'VDD';

  /// VSS ground pad.
  const HarborIoPad.vss({required this.edge, this.position = 0})
    : signalName = 'VSS',
      isPower = true,
      powerNet = 'VSS';
}

/// Puts an SRAM macro on a core edge of a pad ring flow.
class HarborMacroPin {
  /// Instance name of the macro in the netlist.
  final String inst;

  /// Core edge of the macro. Only [HarborIoPadEdge.south] and
  /// [HarborIoPadEdge.north] are permitted.
  final HarborIoPadEdge edge;

  /// Space from the west core edge to the macro (um). Null puts the macro
  /// on the first free location of the edge.
  final double? offsetUm;

  const HarborMacroPin({required this.inst, required this.edge, this.offsetUm});
}

/// IO ring configuration for an ASIC die.
///
/// Describes the pad ring around the die perimeter, including
/// signal pads, power pads, and corner cells.
///
/// ```dart
/// final ring = HarborIoRing(
///   pads: [
///     HarborIoPad(signalName: 'clk', edge: HarborIoPadEdge.west, position: 0),
///     HarborIoPad(signalName: 'reset', edge: HarborIoPadEdge.west, position: 1),
///     HarborIoPad(signalName: 'uart_tx', edge: HarborIoPadEdge.south, position: 0),
///     HarborIoPad(signalName: 'uart_rx', edge: HarborIoPadEdge.south, position: 1),
///     HarborIoPad.vdd(edge: HarborIoPadEdge.north, position: 0),
///     HarborIoPad.vss(edge: HarborIoPadEdge.north, position: 1),
///   ],
/// );
/// ```
class HarborIoRing with HarborPrettyString {
  /// All pads in the ring.
  final List<HarborIoPad> pads;

  /// Whether to auto-insert corner cells.
  final bool hasCornerCells;

  const HarborIoRing({required this.pads, this.hasCornerCells = true});

  /// Pads on a specific edge, sorted by position.
  List<HarborIoPad> padsOnEdge(HarborIoPadEdge edge) {
    final edgePads = pads.where((p) => p.edge == edge).toList();
    edgePads.sort((a, b) => a.position.compareTo(b.position));
    return edgePads;
  }

  /// All signal (non-power) pads.
  List<HarborIoPad> get signalPads => pads.where((p) => !p.isPower).toList();

  /// All power pads.
  List<HarborIoPad> get powerPads => pads.where((p) => p.isPower).toList();

  /// Total pad count.
  int get totalPads => pads.length;

  /// Generates an xschem-compatible schematic snippet for the IO ring.
  ///
  /// Places PDK IO cells and power pads around the die perimeter,
  /// wired to the digital core signals.
  String generateXschemRing({
    required PdkProvider pdk,
    required String coreName,
    int gridSpacing = 200,
  }) {
    final buf = StringBuffer();
    buf.writeln('# IO Ring for $coreName');

    int padIdx = 0;
    for (final edge in HarborIoPadEdge.values) {
      final edgePads = padsOnEdge(edge);
      for (final pad in edgePads) {
        final block = pad.isPower
            ? pdk.powerPad(net: pad.powerNet!)
            : pdk.ioCell(index: padIdx);
        if (block == null) continue;

        final x = switch (edge) {
          HarborIoPadEdge.north => gridSpacing * (pad.position + 1),
          HarborIoPadEdge.south => gridSpacing * (pad.position + 1),
          HarborIoPadEdge.east => gridSpacing * (edgePads.length + 2),
          HarborIoPadEdge.west => 0,
        };
        final y = switch (edge) {
          HarborIoPadEdge.north => 0,
          HarborIoPadEdge.south => gridSpacing * (edgePads.length + 2),
          HarborIoPadEdge.east => gridSpacing * (pad.position + 1),
          HarborIoPadEdge.west => gridSpacing * (pad.position + 1),
        };

        buf.writeln(
          'C {${block.symbolPath}} $x $y 0 0 '
          '{name=${pad.signalName}_pad}',
        );

        if (!pad.isPower) {
          buf.writeln(
            'N $x $y ${x + gridSpacing} $y '
            '{lab=${pad.signalName}}',
          );
        }
        padIdx++;
      }
    }

    return buf.toString();
  }

  /// Generates OpenROAD TCL commands for IO pad placement.
  ///
  /// Places IO cells from the PDK around the die perimeter with
  /// proper spacing and orientation.
  String generateOpenroadPlacement({
    required double dieWidthUm,
    required double dieHeightUm,
    required double padPitchUm,
    required double padOffsetUm,
  }) {
    final buf = StringBuffer();
    buf.writeln('# IO pad placement');

    for (final edge in HarborIoPadEdge.values) {
      final edgePads = padsOnEdge(edge);
      for (final pad in edgePads) {
        final (x, y, orient) = switch (edge) {
          HarborIoPadEdge.north => (
            padOffsetUm + pad.position * padPitchUm,
            0.0,
            'R180',
          ),
          HarborIoPadEdge.south => (
            padOffsetUm + pad.position * padPitchUm,
            dieHeightUm,
            'R0',
          ),
          HarborIoPadEdge.east => (
            dieWidthUm,
            padOffsetUm + pad.position * padPitchUm,
            'R270',
          ),
          HarborIoPadEdge.west => (
            0.0,
            padOffsetUm + pad.position * padPitchUm,
            'R90',
          ),
        };

        buf.writeln(
          'place_pad -name ${pad.signalName}_pad '
          '-row IO_${edge.name.toUpperCase()} '
          '-location {$x $y} '
          '-orient $orient',
        );
      }
    }

    if (hasCornerCells) {
      buf.writeln();
      buf.writeln('# Corner cells');
      buf.writeln('place_corners');
    }

    buf.writeln();
    buf.writeln('# Connect IO ring power');
    buf.writeln('connect_by_abutment');

    return buf.toString();
  }

  @override
  String toString() => 'HarborIoRing(${pads.length} pads)';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborIoRing(\n');
    for (final edge in HarborIoPadEdge.values) {
      final edgePads = padsOnEdge(edge);
      if (edgePads.isEmpty) continue;
      buf.writeln('${c}${edge.name}:');
      for (final pad in edgePads) {
        buf.writeln(
          '${options.nested().childPrefix}${pad.signalName}'
          '${pad.isPower ? " (${pad.powerNet})" : ""}',
        );
      }
    }
    buf.write('$p)');
    return buf.toString();
  }
}

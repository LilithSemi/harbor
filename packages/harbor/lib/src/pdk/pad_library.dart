/// Function of a pad cell in the pad ring.
enum HarborPadKind {
  input,
  clockInput,
  output,
  bidir,
  analog,
  ioPower,
  ioGround,
  corePower,
  coreGround;

  /// True for the supply and ground pads.
  bool get isPower =>
      this == ioPower ||
      this == ioGround ||
      this == corePower ||
      this == coreGround;
}

/// Pad cells of a PDK I/O library.
class HarborPadLibrary {
  /// I/O library name, which is also the cell name prefix.
  final String libName;

  /// Cell name for each pad kind, without the library prefix.
  final Map<HarborPadKind, String> master;

  /// Pins that get a constant value, as Verilog literals, for each kind.
  final Map<HarborPadKind, Map<String, String>> tieOffs;

  /// Pad pin that goes off the chip.
  final String padPin;

  /// Pin that sends the pad value into the core.
  final String inPin;

  /// Pin that the core drives out through the pad.
  final String outPin;

  /// Output enable pin.
  final String oePin;

  /// Pad pin of the analog cell.
  final String analogPin;

  const HarborPadLibrary({
    required this.libName,
    required this.master,
    required this.tieOffs,
    required this.padPin,
    required this.inPin,
    required this.outPin,
    required this.oePin,
    required this.analogPin,
  });

  /// Full cell name for [kind].
  String cellName(HarborPadKind kind) {
    final m = master[kind];
    if (m == null) {
      throw ArgumentError('$libName has no pad cell for ${kind.name}');
    }
    return '${libName}__$m';
  }
}

/// Core power ring between the pad ring and the core.
class HarborCoreRing {
  /// Space from the core edge to the ring (um).
  final double offsetUm;

  /// Width of each ring wire (um).
  final double widthUm;

  /// Space between the power wire and the ground wire (um).
  final double spaceUm;

  /// Space from the inner edge of the pad cells to the ring (um).
  final double padClearanceUm;

  /// The two ring layers.
  final List<String> layers;

  /// Layer of the pad supply pins that the ring connects to.
  final String padLayer;

  /// Pad cell supply pins on the core power net.
  final List<String> padPowerPins;

  /// Pad cell supply pins on the core ground net.
  final List<String> padGroundPins;

  const HarborCoreRing({
    required this.offsetUm,
    required this.widthUm,
    required this.spaceUm,
    required this.padClearanceUm,
    required this.layers,
    required this.padLayer,
    required this.padPowerPins,
    required this.padGroundPins,
  });
}

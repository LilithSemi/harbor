import 'analog_block.dart';
import 'pad_library.dart';
import 'standard_cell_library.dart';

/// Abstract interface for PDK-specific configuration.
///
/// Each PDK provides standard cell libraries, analog block
/// definitions (IO pads, PLLs, ESD cells), and process-specific
/// parameters needed for synthesis and tapeout.
///
/// Implementations:
/// - [Sky130Provider] - SkyWater 130nm
/// - [Gf180mcuProvider] - GlobalFoundries 180nm
///
/// ```dart
/// final pdk = Sky130Provider(pdkRoot: '/path/to/sky130');
/// final ioCell = pdk.ioCell(index: 0);
/// final lib = pdk.standardCellLibrary;
/// ```
abstract class PdkProvider {
  /// Human-readable PDK name.
  String get name;

  /// Process node description (e.g., `'130nm'`, `'180nm'`).
  String get node;

  /// The primary standard cell library.
  StandardCellLibrary get standardCellLibrary;

  /// Additional standard cell libraries (e.g., high-density, high-speed).
  List<StandardCellLibrary> get additionalLibraries => const [];

  /// Returns an IO pad cell descriptor for pad [index].
  AnalogBlock ioCell({required int index});

  /// Returns a PLL/clock generator descriptor for instance [index].
  AnalogBlock pll({required int index});

  /// Returns an ESD protection cell descriptor for pad [index].
  AnalogBlock? esdCell({required int index}) => null;

  /// Returns a power pad cell descriptor.
  AnalogBlock? powerPad({required String net}) => null;

  /// Pad cells for a generated pad ring. Null when the PDK has no
  /// verified pad cells.
  HarborPadLibrary? get padLibrary => null;

  /// Core power ring for a generated pad ring. Null when [padLibrary] is
  /// null.
  HarborCoreRing? get coreRing => null;

  /// Returns an eFuse macro descriptor for OTP storage.
  ///
  /// [bits] is the number of fuse bits requested. Returns `null`
  /// if the PDK does not provide eFuse macros.
  AnalogBlock? efuse({required int bits}) => null;

  /// Whether this PDK supports eFuse macros.
  bool get hasEfuse => false;

  /// Returns a bandgap temperature sensor descriptor.
  ///
  /// Returns `null` if the PDK does not provide a temperature sensor.
  AnalogBlock? temperatureSensor() => null;

  /// Whether this PDK provides an on-die temperature sensor.
  bool get hasTemperatureSensor => false;

  /// Returns an SRAM macro descriptor for the given configuration.
  ///
  /// [words] is the number of entries, [width] is the data width in bits,
  /// [numPorts] is 1 (single-port) or 2 (dual-port).
  /// Returns `null` if the PDK does not provide SRAM macros.
  AnalogBlock? sramMacro({
    required int words,
    required int width,
    int numPorts = 1,
  }) => null;

  /// Whether this PDK provides SRAM macros.
  bool get hasSramMacro => false;

  /// Library of the [sramMacro] cells. A cell name is the library name,
  /// `__` and the macro name. Null when the cell names have no library
  /// prefix.
  String? get sramLibName => null;

  /// Number of metal layers available for routing.
  int get metalLayers;

  /// Supply voltage in volts.
  double get supplyVoltage;

  /// All available standard cell libraries (primary + additional).
  List<StandardCellLibrary> get allLibraries => [
    standardCellLibrary,
    ...additionalLibraries,
  ];
}

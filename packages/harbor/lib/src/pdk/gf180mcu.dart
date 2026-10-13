import 'analog_block.dart';
import 'pdk_provider.dart';
import 'standard_cell_library.dart';

/// GlobalFoundries 180nm MCU PDK provider.
///
/// ```dart
/// final pdk = Gf180mcuProvider(pdkRoot: '$PDK_ROOT/gf180mcuD')
/// ```
class Gf180mcuProvider extends PdkProvider {
  /// Root path to the GF180MCU PDK installation.
  final String pdkRoot;

  /// Voltage variant.
  final Gf180mcuVoltage voltage;

  Gf180mcuProvider({
    required this.pdkRoot,
    this.voltage = Gf180mcuVoltage.v3_3,
  });

  @override
  String get name => 'GlobalFoundries GF180MCU';

  @override
  String get node => '180nm';

  @override
  int get metalLayers => 5;

  @override
  double get supplyVoltage => switch (voltage) {
    Gf180mcuVoltage.v3_3 => 3.3,
    Gf180mcuVoltage.v5_0 => 5.0,
  };

  String get _libName => switch (voltage) {
    Gf180mcuVoltage.v3_3 => 'gf180mcu_fd_sc_mcu7t5v0',
    Gf180mcuVoltage.v5_0 => 'gf180mcu_fd_sc_mcu9t5v0',
  };

  @override
  StandardCellLibrary get standardCellLibrary => StandardCellLibrary(
    name: _libName,
    libertyPath:
        '$pdkRoot/libs.ref/$_libName/lib/${_libName}__tt_025C_3v30.lib',
    lefPath: '$pdkRoot/libs.ref/$_libName/lef/$_libName.lef',
    techLefPath: '$pdkRoot/libs.ref/$_libName/lef/${_libName}__nom.tlef',
    verilogPath: '$pdkRoot/libs.ref/$_libName/verilog/$_libName.v',
    cellPrefix: '${_libName}__',
    siteName: 'GF018hv5v_mcu_sc7',
    tieHighCell: '${_libName}__tieh',
    tieLowCell: '${_libName}__tiel',
    clockBufferCells: [
      '${_libName}__clkbuf_2',
      '${_libName}__clkbuf_4',
      '${_libName}__clkbuf_8',
      '${_libName}__clkbuf_16',
    ],
    fillCells: [
      '${_libName}__fill_1',
      '${_libName}__fill_2',
      '${_libName}__fill_4',
    ],
  );

  @override
  AnalogBlock ioCell({required int index}) => AnalogBlock(
    symbolPath: '$pdkRoot/libs.ref/gf180mcu_fd_io/lef/gf180mcu_fd_io.lef',
    pinMapping: {
      'padIn': 'PAD',
      'padOut': 'A',
      'padOutputEnable': 'EN',
      'fabricIn': 'DIN',
      'fabricOut': 'DOUT',
    },
    properties: {'name': 'io_$index'},
  );

  @override
  AnalogBlock pll({required int index}) => AnalogBlock(
    symbolPath:
        '$pdkRoot/libs.ref/gf180mcu_fd_pr/cells/pll/gf180mcu_fd_pr__pll.lef',
    pinMapping: {
      'refClk': 'CLK',
      'reset': 'RST',
      'clkOut': 'CLKOUT',
      'locked': 'LOCK',
    },
    properties: {'name': 'pll_$index'},
  );

  @override
  AnalogBlock? powerPad({required String net}) => AnalogBlock(
    symbolPath: '$pdkRoot/libs.ref/gf180mcu_fd_io/lef/gf180mcu_fd_io.lef',
    pinMapping: {'pad': net},
    properties: {'name': '${net.toLowerCase()}_pad', 'net': net},
  );

  @override
  bool get hasTemperatureSensor => true;

  @override
  AnalogBlock? temperatureSensor() => AnalogBlock(
    symbolPath:
        '$pdkRoot/libs.ref/gf180mcu_fd_pr/cells/npn/gf180mcu_fd_pr__npn_10p00x10p00.lef',
    pinMapping: {'vbe': 'B', 'collector': 'C', 'emitter': 'E'},
    properties: {
      'type': 'bandgap_bjt',
      'description': 'BJT for bandgap temp sensing',
    },
  );

  @override
  bool get hasSramMacro => true;

  @override
  AnalogBlock? sramMacro({
    required int words,
    required int width,
    int numPorts = 1,
  }) {
    final macroName = 'gf180mcu_fd_ip_sram__sram${words}x${width}m8wm1';
    return AnalogBlock(
      symbolPath: '$pdkRoot/libs.ref/gf180mcu_fd_ip_sram/lef/$macroName.lef',
      pinMapping: {
        'clk': 'CLK',
        'addr': 'A',
        'dataIn': 'D',
        'dataOut': 'Q',
        'writeEnable': 'GWEN',
        'chipSelect': 'CEN',
        'writeMask': 'WEN',
      },
      // CEN, GWEN and the per bit WEN are all active low.
      activeLow: const {'writeEnable', 'chipSelect', 'writeMask'},
      params: const {'writeMaskBits': 1},
      properties: {
        'name': macroName,
        'words': '$words',
        'width': '$width',
        'ports': '$numPorts',
      },
    );
  }

  @override
  bool get hasEfuse => true;

  @override
  AnalogBlock? efuse({required int bits}) => AnalogBlock(
    symbolPath:
        '$pdkRoot/libs.ref/gf180mcu_fd_pr/cells/efuse/gf180mcu_fd_pr__efuse.lef',
    pinMapping: {'program': 'PGM', 'sense': 'SNS', 'data': 'Q'},
    properties: {'name': 'efuse_${bits}b', 'bits': '$bits'},
  );
}

/// GF180MCU voltage variants.
enum Gf180mcuVoltage {
  /// 3.3V (default).
  v3_3,

  /// 5.0V.
  v5_0,
}

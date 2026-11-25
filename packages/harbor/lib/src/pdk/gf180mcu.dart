import 'analog_block.dart';
import 'pad_library.dart';
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

  @override
  HarborPadLibrary get padLibrary => const HarborPadLibrary(
    libName: 'gf180mcu_fd_io',
    master: {
      HarborPadKind.input: 'in_c',
      HarborPadKind.clockInput: 'in_s',
      HarborPadKind.output: 'bi_24t',
      HarborPadKind.bidir: 'bi_24t',
      HarborPadKind.analog: 'asig_5p0',
      HarborPadKind.ioPower: 'dvdd',
      HarborPadKind.ioGround: 'dvss',
      HarborPadKind.corePower: 'dvdd',
      HarborPadKind.coreGround: 'dvss',
    },
    tieOffs: {
      HarborPadKind.input: {'PU': "1'b0", 'PD': "1'b0"},
      HarborPadKind.clockInput: {'PU': "1'b0", 'PD': "1'b0"},
      HarborPadKind.output: {
        'OE': "1'b1",
        'IE': "1'b0",
        'CS': "1'b0",
        'SL': "1'b0",
        'PU': "1'b0",
        'PD': "1'b0",
      },
      HarborPadKind.bidir: {
        'IE': "1'b1",
        'CS': "1'b0",
        'SL': "1'b0",
        'PU': "1'b0",
        'PD': "1'b0",
      },
    },
    padPin: 'PAD',
    inPin: 'Y',
    outPin: 'A',
    oePin: 'OE',
    analogPin: 'ASIG5V',
  );

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
    decapCells: ['${_libName}__fillcap_*'],
    antennaCell: '${_libName}__antenna',
    pinHorizontalLayer: 'Metal3',
    pinVerticalLayer: 'Metal2',
    wireRcLayer: 'Metal2',
    powerPins: const ['VDD', 'VNW'],
    groundPins: const ['VSS', 'VPW'],
    tapCell: '${_libName}__filltie',
    endcapCell: '${_libName}__endcap',
    tapDistanceUm: 20,
    pdn: const HarborPdnGrid(
      railLayer: 'Metal1',
      railWidthUm: 0.6,
      stripes: [
        HarborPdnStripe(
          layer: 'Metal4',
          widthUm: 1.6,
          pitchUm: 40,
          offsetUm: 10,
          spacingUm: 1.7,
        ),
        HarborPdnStripe(
          layer: 'Metal5',
          widthUm: 1.6,
          pitchUm: 153.18,
          offsetUm: 16.65,
          spacingUm: 1.7,
        ),
      ],
    ),
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

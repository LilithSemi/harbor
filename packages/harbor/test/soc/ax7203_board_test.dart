import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Sites from the AX7203 user manual V1.0 (page in the comment), written out
/// again from the manual tables, not from the preset. The HDMI I2C pair is
/// from LiteX.
const _clkSites = {'clk': 'R4', 'clk_n': 'T4'}; // p.11
const _uartSites = {'uart_tx': 'N15', 'uart_rx': 'P20'}; // p.36
const _ledSites = ['B13', 'C13', 'D14', 'D15']; // p.42
const _keySites = ['J21', 'E13']; // p.41
const _dqSites = [
  'C2', 'G1', 'A1', 'F3', 'B2', 'F1', 'B1', 'E2', //
  'H3', 'G3', 'H2', 'H5', 'J1', 'J5', 'K1', 'H4',
  'L4', 'M3', 'L3', 'J6', 'K3', 'K6', 'J4', 'L5',
  'P1', 'N4', 'R1', 'N2', 'M6', 'N5', 'P6', 'P2',
]; // p.13-14
const _dqsSites = ['E1', 'K2', 'M1', 'P5']; // p.12-13
const _dqsNSites = ['D1', 'J2', 'L1', 'P4'];
const _dmSites = ['D2', 'G2', 'M2', 'M5']; // p.14
const _addrSites = [
  'AA4', 'AB2', 'AA5', 'AB5', 'AB1', 'U3', 'W1', 'T1', //
  'V2', 'U2', 'Y1', 'W2', 'Y2', 'U1', 'V3',
]; // p.14
const _baSites = ['AA3', 'Y3', 'Y4']; // p.15
const _ddrCtl = {
  'sdram_cs_n': 'AB3',
  'sdram_ras_n': 'V4',
  'sdram_cas_n': 'W4',
  'sdram_we_n': 'AA1',
  'sdram_odt': 'U5',
  'sdram_cke': 'T5',
  'sdram_reset_n': 'W6',
  'sdram_ck': 'R3',
  'sdram_ck_n': 'R2',
}; // p.15
const _hdmiCtl = {
  'hdmi_reset_n': 'J19',
  'hdmi_clk': 'M13',
  'hdmi_hsync': 'T15',
  'hdmi_vsync': 'T14',
  'hdmi_de': 'V13',
  'gpdi_scl': 'E16', // LiteX
  'gpdi_sda': 'F16', // LiteX
}; // p.31-32
const _hdmiD = [
  'V14', 'H14', 'J14', 'K13', 'K14', 'L13', 'L19', 'L20', //
  'K17', 'J17', 'L16', 'K16', 'L14', 'L15', 'M15', 'M16',
  'L18', 'M18', 'N18', 'N19', 'M20', 'N20', 'L21', 'M21',
]; // p.32

/// Port -> (site, IO standard) for every pin the test SoC exposes.
Map<String, (String, String)> _expected() {
  final e = <String, (String, String)>{};
  void bus(String name, List<String> sites, String io) {
    for (var i = 0; i < sites.length; i++) {
      e['$name[$i]'] = (sites[i], io);
    }
  }

  _clkSites.forEach((k, v) => e[k] = (v, 'DIFF_SSTL15'));
  e['reset_n'] = ('T6', 'LVCMOS15'); // p.18
  e['som_led'] = ('W5', 'LVCMOS15'); // p.17
  _uartSites.forEach((k, v) => e[k] = (v, 'LVCMOS33'));
  bus('led_n', _ledSites, 'LVCMOS33');
  bus('key_n', _keySites, 'LVCMOS33');
  bus('sdram_dq', _dqSites, 'SSTL15');
  bus('sdram_dqs', _dqsSites, 'SSTL15');
  bus('sdram_dqs_n', _dqsNSites, 'SSTL15');
  bus('sdram_dm', _dmSites, 'SSTL15');
  bus('sdram_addr', _addrSites, 'SSTL15');
  bus('sdram_ba', _baSites, 'SSTL15');
  _ddrCtl.forEach((k, v) => e[k] = (v, 'SSTL15'));
  e['sdram_ck'] = ('R3', 'DIFF_SSTL15');
  e['sdram_ck_n'] = ('R2', 'DIFF_SSTL15');
  e['sdram_reset_n'] = ('W6', 'LVCMOS15');
  _hdmiCtl.forEach((k, v) => e[k] = (v, 'LVCMOS33'));
  bus('hdmi_d', _hdmiD, 'LVCMOS33');
  return e;
}

const _ddrPads = [
  'sdram_ck',
  'sdram_ck_n',
  'sdram_cke',
  'sdram_cs_n',
  'sdram_ras_n',
  'sdram_cas_n',
  'sdram_we_n',
  'sdram_ba',
  'sdram_addr',
  'sdram_dm',
  'sdram_dq',
  'sdram_dqs',
  'sdram_dqs_n',
  'sdram_odt',
  'sdram_reset_n',
];

/// Board IO for the test: a parallel RGB display on the SiI9134 pins, plus
/// the LEDs and keys.
class _BoardIo extends BridgeModule with HarborDeviceTreeNodeProvider {
  late final HarborDualClockDisplay display;

  _BoardIo(HarborDeviceTarget target) : super('Ax7203BoardIo', name: 'io') {
    final clk = createPort('clk', PortDirection.input).port;
    final reset = createPort('reset', PortDirection.input).port;
    createPort('key_n', PortDirection.input, width: 2);
    display = HarborDualClockDisplay(
      timing: const HarborDisplayTiming.vga640x480(),
      pixelClk: clk,
      pixelReset: reset,
      shiftClk: clk,
      shiftReset: reset,
      sysClk: clk,
      sysReset: reset,
      enable: Const(1),
      fbBase: Const(0, width: 32),
      mDataIn: Const(0, width: 32),
      mAck: Const(0),
      outputType: HarborDisplayInterface.parallelRgb,
      target: target,
    );
    addOutput('hdmi_d', width: 24) <= display.rgb;
    addOutput('hdmi_de') <= display.de;
    addOutput('hdmi_hsync') <= display.hsync;
    addOutput('hdmi_vsync') <= display.vsync;
    addOutput('hdmi_clk') <= display.pclk;
    addOutput('hdmi_reset_n') <= ~reset;
    addOutput('gpdi_scl') <= Const(1);
    addOutput('gpdi_sda') <= Const(1);
    addOutput('led_n', width: 4) <= ~display.vsync.replicate(4);
    addOutput('som_led') <= input('key_n')[0];
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,ax7203-io'],
    reg: BusAddressRange(0x20000000, 0x1000),
  );
}

const _ioPorts = [
  'key_n',
  'hdmi_d',
  'hdmi_de',
  'hdmi_hsync',
  'hdmi_vsync',
  'hdmi_clk',
  'hdmi_reset_n',
  'gpdi_scl',
  'gpdi_sda',
  'led_n',
  'som_led',
];

HarborSoC _soc(HarborFpgaTarget target, {bool withDdr = true}) {
  final soc = HarborSoC(
    name: 'Ax7203Soc',
    compatible: 'test,ax7203-soc',
    busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
    target: target,
    externalReset: true,
    clocks: [
      const HarborClockConfig(
        name: 'sys',
        rate: HarborFixedClockRate(100000000),
        sourceFrequency: 200000000,
        providedByDdr3Tree: true,
      ),
    ],
    xilinxDdr3Tree: const XilinxDdr3TreeSpec(
      sourceHz: 200000000,
      ddrCkHz: 400000000,
      coreClkHz: 100000000,
    ),
  );
  final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
  soc.exposePin(uart, 'tx', externalName: 'uart_tx');
  soc.exposePin(uart, 'rx', externalName: 'uart_rx');
  final io = soc.addPeripheral(_BoardIo(target));
  for (final p in _ioPorts) {
    soc.exposePin(io, p, externalName: p);
  }
  if (withDdr) {
    final tree = soc.xilinxDdr3Clocks!;
    final ddr = soc.addPeripheral(
      HarborDdr3(
        config: const HarborDdrConfig.ax7203(),
        baseAddress: 0x80000000,
        clockHz: tree.controllerMhz.round() * 1000000,
        busAddressWidth: 32,
        busDataWidth: 32,
        target: target,
        ckPeriodPs: (1000000 / tree.ddrCkMhz).round(),
        postedWrites: false,
      ),
    );
    ddr.input('ddr_clk').srcConnection! <= tree.controllerClk;
    ddr.input('ddr_reset').srcConnection! <= soc.clockDomain('sys')!.reset;
    ddr.input('ddr_ck_fast').srcConnection! <= tree.ddrCk;
    ddr.input('ddr_ck90_fast').srcConnection! <= tree.ddrCk90;
    ddr.input('ddr_ck_dqs_fast').srcConnection! <= tree.ddrCkDqs;
    ddr.input('ddr_idelay_ref').srcConnection! <= tree.idelayRef;
    for (final pad in _ddrPads) {
      soc.exposePin(ddr, pad, externalName: pad);
    }
  }
  return soc;
}

final _xdcLine = RegExp(
  r'^set_property -dict \{PACKAGE_PIN (\S+) IOSTANDARD (\S+)(.*)\} '
  r'\[get_ports (\S+)\]$',
);

void main() {
  final board = HarborBoard.get('ax7203');

  test('preset part, clock and speed grade', () {
    expect(board.device, 'xc7a200t');
    expect(board.package, 'fbg484');
    expect(board.speedGrade, '2');
    expect(board.vendor, HarborFpgaVendor.openXc7);
    expect(board.oscillatorHz, 200000000);
    expect(board.clockNPortName, 'clk_n');
    expect(board.siteIsClockCapable(board.pins['clk']!), isTrue);
    final t = board.fpgaTarget();
    expect(t.name, 'artix7-xc7a200t');
    expect(t.clockNPortName, 'clk_n');
    expect(
      t.generateMakefile('Top'),
      contains('PART ?= \$(DEVICE)\$(PACKAGE)-2'),
    );
  });

  test('every ball is used once', () {
    final byBall = <String, List<String>>{};
    for (final e in board.pins.entries) {
      byBall.putIfAbsent(e.value.split(' ').first, () => []).add(e.key);
    }
    expect(byBall.values.where((v) => v.length > 1), isEmpty);
  });

  test('PCIe and the GTP reference clock are not wired', () {
    final balls = {for (final v in board.pins.values) v.split(' ').first};
    for (final ball in ['F6', 'E6', 'F10', 'E10', 'J20']) {
      expect(balls, isNot(contains(ball)));
    }
  });

  group('SoC with 32-bit DDR3 and a parallel display', () {
    late Directory dir;
    late Map<String, (String, String)> xdc;
    late Map<String, String> xdcExtra;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('harbor_ax7203_');
      final soc = _soc(board.fpgaTarget());
      await soc.generateAll(dir);
      xdc = {};
      xdcExtra = {};
      for (final line in File('${dir.path}/Ax7203Soc.xdc').readAsLinesSync()) {
        final m = _xdcLine.firstMatch(line);
        if (m == null) continue;
        xdc[m.group(4)!] = (m.group(1)!, m.group(2)!);
        xdcExtra[m.group(4)!] = m.group(3)!.trim();
      }
    });

    tearDownAll(() async {
      dir.deleteSync(recursive: true);
      await Simulator.reset();
    });

    for (final MapEntry(key: port, value: (site, io)) in _expected().entries) {
      test('$port is $site $io', () => expect(xdc[port], (site, io)));
    }

    test('only DQ and DQS carry IN_TERM UNTUNED_SPLIT_50', () {
      for (final MapEntry(key: port, value: extra) in xdcExtra.entries) {
        final term = RegExp(r'^sdram_dqs?(_n)?\[').hasMatch(port);
        expect(extra, term ? 'IN_TERM UNTUNED_SPLIT_50' : '', reason: port);
      }
    });

    test('the XDC constrains nothing else', () {
      expect(xdc.keys.toSet(), _expected().keys.toSet());
    });

    test('the board clock is a 200 MHz create_clock on clk', () {
      expect(
        File('${dir.path}/Ax7203Soc.xdc').readAsStringSync(),
        contains('create_clock -period 5.000 [get_ports clk]'),
      );
    });

    test('the netlist joins clk and clk_n through an IBUFDS', () {
      final rtl = Directory('${dir.path}/rtl')
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .join('\n');
      expect(rtl, contains(RegExp(r'IBUFDS\s+sysclk_ibufds')));
      expect(rtl, contains(RegExp(r'\.IB\(clk_n\)')));
    });

    test('hdmi_clk is the pixel clock forwarded through an ODDR', () {
      final fwd = File(
        '${dir.path}/rtl/HarborPixelClockForward.sv',
      ).readAsStringSync();
      expect(fwd, contains(RegExp(r'ODDR\s')));
    });

    test('the DDR3 controller is four lanes wide', () {
      final rtl = Directory('${dir.path}/rtl')
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .join('\n');
      // The first calibration beat, one byte on each of the four lanes.
      expect(rtl, contains("256'h91919191777777772929292"));
      expect(rtl, contains(RegExp(r'\[255:0\]\s+calib_data')));
    });

    test('the Makefile names the -2 prjxray part', () {
      final mk = File('${dir.path}/Makefile').readAsStringSync();
      expect(mk, contains('PART ?= \$(DEVICE)\$(PACKAGE)-2'));
      expect(
        mk,
        contains('--part_file \$(XRAY_DB)/\$(FAMILY)/\$(PART)/part.yaml'),
      );
      expect(mk, contains('FAMILY = artix7'));
      expect(
        mk,
        contains(
          'CHIPDB ?= \$(NEXTPNR_XILINX_CHIPDB)/\$(DEVICE)\$(PACKAGE).bin',
        ),
      );
    });
  });

  test('a top-level port with no pin fails generation by name', () async {
    final target = board.fpgaTarget(
      pins: board.pins.keys.where((k) => k != 'som_led'),
    );
    final soc = _soc(target, withDdr: false);
    final dir = Directory.systemTemp.createTempSync('harbor_ax7203_miss_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await expectLater(
      soc.generateAll(dir),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('som_led'),
        ),
      ),
    );
    await Simulator.reset();
  });
}

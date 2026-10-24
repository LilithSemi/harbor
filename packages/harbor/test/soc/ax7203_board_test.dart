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

/// KSZ9031 PHY1 and PHY2 (p.28-29): GTXC, TXD0-3, TXEN, RXC, RXD0-3, RXDV,
/// MDC, MDIO, RESET.
const _ethSites = [
  (
    txc: 'E18',
    txd: ['C20', 'D20', 'A19', 'A18'],
    txCtl: 'F18',
    rxc: 'B17',
    rxd: ['A16', 'B18', 'C18', 'C19'],
    rxCtl: 'A15',
    mdc: 'B16',
    mdio: 'B15',
    rst: 'D16',
  ),
  (
    txc: 'A14',
    txd: ['E17', 'C14', 'C15', 'A13'],
    txCtl: 'D17',
    rxc: 'E19',
    rxd: ['A20', 'B20', 'D19', 'C17'],
    rxCtl: 'F19',
    mdc: 'F20',
    mdio: 'C22',
    rst: 'B22',
  ),
];

const _ethPorts = [
  'rgmii_txc',
  'rgmii_txd',
  'rgmii_tx_ctl',
  'rgmii_rxc',
  'rgmii_rxd',
  'rgmii_rx_ctl',
  'mdc',
  'mdio',
];

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
  for (final (n, p) in _ethSites.indexed) {
    e['eth${n}_rgmii_txc'] = (p.txc, 'LVCMOS33');
    bus('eth${n}_rgmii_txd', p.txd, 'LVCMOS33');
    e['eth${n}_rgmii_tx_ctl'] = (p.txCtl, 'LVCMOS33');
    e['eth${n}_rgmii_rxc'] = (p.rxc, 'LVCMOS33');
    bus('eth${n}_rgmii_rxd', p.rxd, 'LVCMOS33');
    e['eth${n}_rgmii_rx_ctl'] = (p.rxCtl, 'LVCMOS33');
    e['eth${n}_mdc'] = (p.mdc, 'LVCMOS33');
    e['eth${n}_mdio'] = (p.mdio, 'LVCMOS33');
    e['eth${n}_rst_n'] = (p.rst, 'LVCMOS33');
  }
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

/// Board IO for the test: a parallel RGB display on the SiI9134 pins, the
/// LEDs and keys, the PHY resets, and a PLL that makes the 125 MHz RGMII
/// clocks from the 100 MHz sys clock.
class _BoardIo extends BridgeModule with HarborDeviceTreeNodeProvider {
  late final HarborDualClockDisplay display;

  Logic get clk125 => output('clk125');
  Logic get clk125_90 => output('clk125_90');

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
      update: Const(1),
      fbBase: Const(0, width: 32),
      memory: _idleMemory(),
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
    for (var n = 0; n < _ethSites.length; n++) {
      addOutput('eth${n}_rst_n') <= ~reset;
    }

    // VCO 1000 MHz, CLKOUT0 and CLKOUT1 are 125 MHz at 0 and 90 degrees.
    final pll = XilinxPlle2Adv(
      clkfboutMult: 10,
      divclkDivide: 1,
      clkinPeriod: 10.0,
      clkout0Divide: 8,
      clkout1Divide: 8,
      clkout1Phase: 90.0,
      name: 'eth_pll',
    );
    pll.input('CLKIN1').srcConnection! <= clk;
    pll.input('CLKIN2').srcConnection! <= Const(0);
    pll.input('CLKINSEL').srcConnection! <= Const(1);
    pll.input('CLKFBIN').srcConnection! <= pll.output('CLKFBOUT');
    pll.input('RST').srcConnection! <= reset;
    pll.input('PWRDWN').srcConnection! <= Const(0);
    for (final (o, n) in [('CLKOUT0', 'clk125'), ('CLKOUT1', 'clk125_90')]) {
      final b = XilinxBufg(name: '${n}_bufg');
      b.input('I').srcConnection! <= pll.output(o);
      addOutput(n) <= b.output('O');
    }
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

HarborSoC _soc(
  HarborFpgaTarget target, {
  bool withDdr = true,
  bool withEth = true,
}) {
  final soc = HarborSoC(
    name: 'Ax7203Soc',
    compatible: 'test,ax7203-soc',
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
  if (withEth) {
    for (var n = 0; n < _ethSites.length; n++) {
      final mac = HarborEthernetMac(
        baseAddress: 0x30000000 + 0x1000 * n,
        config: HarborEthernetConfig.ax7203(),
        fabricKind: HarborFabricKind.wishbone,
        target: target,
        mdioPad: true,
        idelayCtrl: false,
        name: 'eth$n',
      );
      soc.addPeripheral(mac);
      soc.addMaster(
        mac,
        busInterfaceName: 'dma',
        memory: true,
        // A Wishbone fabric port takes one request at a time.
        outstanding: 1,
      );
      mac.input('clk125').srcConnection! <= io.clk125;
      mac.input('clk125_90').srcConnection! <= io.clk125_90;
      for (final p in _ethPorts) {
        soc.exposePin(mac, p, externalName: 'eth${n}_$p');
      }
      soc.exposePin(io, 'eth${n}_rst_n', externalName: 'eth${n}_rst_n');
    }
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

/// A memory master waist with no memory behind it.
HarborMemoryWaist _idleMemory() {
  final w = HarborMemoryWaist(
    const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
  );
  for (final p in w.getPorts([PairDirection.fromConsumer]).values) {
    p <= Const(0, width: p.width);
  }
  return w;
}

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

  test('board target can select Himbächel', () {
    final t = board.fpgaTarget(pins: ['clk', 'reset_n'], useHimbaechel: true);
    expect(t.vendor, HarborFpgaVendor.openXc7);
    expect(t.useHimbaechel, isTrue);
    expect(t.generateMakefile('Top'), contains('nextpnr-himbaechel'));
  });

  test('Himbächel DDR generation emits clocks without legacy hooks', () async {
    final dir = Directory.systemTemp.createTempSync('harbor_ax7203_himb_');
    addTearDown(() async {
      dir.deleteSync(recursive: true);
      await Simulator.reset();
    });
    final target = board.fpgaTarget(useHimbaechel: true);
    await _soc(target, withEth: false).generateAll(dir);

    expect(File('${dir.path}/support/nextpnr/clocks.py').existsSync(), isTrue);
    expect(
      File('${dir.path}/support/nextpnr/constraints.py').existsSync(),
      isFalse,
    );
    expect(
      File('${dir.path}/support/nextpnr/show_bels.py').existsSync(),
      isFalse,
    );
    final ckOddr = File(
      '${dir.path}/rtl/Ddr3Phy.sv',
    ).readAsLinesSync().singleWhere((line) => line.contains(' ck_oddr('));
    expect(ckOddr, contains('.R(sync_rst)'));
    expect(ckOddr, isNot(contains('.S(')));
  });

  test('one leg of the differential clock binds both', () {
    for (final leg in ['clk', 'clk_n']) {
      final t = board.fpgaTarget(pins: [leg, 'led_n[0]']);
      expect(t.pinMap.keys, containsAll(['clk', 'clk_n', 'led_n[0]']));
      expect(t.pinMap, hasLength(3), reason: leg);
    }
    expect(board.fpgaTarget(pins: ['led_n[0]']).pinMap.keys, ['led_n[0]']);
    final se = HarborBoard.get('ulx3s-85f').fpgaTarget(pins: ['clk']);
    expect(se.pinMap.keys, ['clk']);
  });

  test('every ball is used once', () {
    final byBall = <String, List<String>>{};
    for (final e in board.pins.entries) {
      byBall.putIfAbsent(e.value.split(' ').first, () => []).add(e.key);
    }
    expect(byBall.values.where((v) => v.length > 1), isEmpty);
  });

  test('PCIe x4 and both GTP reference clocks are mapped', () {
    const expected = {
      'gtp_refclk_p': 'F6 MGT',
      'gtp_refclk_n': 'E6 MGT',
      'pcie_refclk_p': 'F10 MGT',
      'pcie_refclk_n': 'E10 MGT',
      'pcie_perst_n': 'J20 LVCMOS33 PULLTYPE=PULLUP',
      'pcie_rxp[0]': 'D11 MGT',
      'pcie_rxn[0]': 'C11 MGT',
      'pcie_txp[0]': 'D5 MGT',
      'pcie_txn[0]': 'C5 MGT',
      'pcie_rxp[1]': 'B8 MGT',
      'pcie_rxn[1]': 'A8 MGT',
      'pcie_txp[1]': 'B4 MGT',
      'pcie_txn[1]': 'A4 MGT',
      'pcie_rxp[2]': 'B10 MGT',
      'pcie_rxn[2]': 'A10 MGT',
      'pcie_txp[2]': 'B6 MGT',
      'pcie_txn[2]': 'A6 MGT',
      'pcie_rxp[3]': 'D9 MGT',
      'pcie_rxn[3]': 'C9 MGT',
      'pcie_txp[3]': 'D7 MGT',
      'pcie_txn[3]': 'C7 MGT',
    };
    for (final entry in expected.entries) {
      expect(board.pins[entry.key], entry.value, reason: entry.key);
    }
  });

  test('MGT constraints have package pins and no SelectIO standard', () {
    final target = board.fpgaTarget(
      pins: ['pcie_refclk_p', 'pcie_refclk_n', 'pcie_perst_n', 'pcie_rxp[0]'],
    );
    final xdc = target.generateConstraints();
    for (final port in ['pcie_refclk_p', 'pcie_refclk_n', 'pcie_rxp[0]']) {
      final line = xdc
          .split('\n')
          .singleWhere((l) => l.endsWith('[get_ports $port]'));
      expect(line, contains('PACKAGE_PIN'));
      expect(line, isNot(contains('IOSTANDARD')));
      expect(line, isNot(contains('MGT')));
    }
    final perst = xdc
        .split('\n')
        .singleWhere((l) => l.endsWith('[get_ports pcie_perst_n]'));
    expect(perst, contains('IOSTANDARD LVCMOS33'));
    expect(perst, contains('PULLTYPE PULLUP'));
  });

  test('a pin with a stray bare attribute throws', () {
    const target = HarborFpgaTarget.artix7(
      device: 'xc7a200t',
      package: 'fbg484',
      pinMap: {'p': 'J20 LVCMOS33 PULLUP TRUE'},
    );
    expect(target.generateConstraints, throwsArgumentError);
  });

  test('configuration flash pads are mapped', () {
    const expected = {
      'spi_cs_n': 'T19 LVCMOS33',
      'spi_io[0]': 'P22 LVCMOS33',
      'spi_io[1]': 'R22 LVCMOS33',
      'spi_io[2]': 'P21 LVCMOS33',
      'spi_io[3]': 'R21 LVCMOS33',
    };
    for (final entry in expected.entries) {
      expect(board.pins[entry.key], entry.value, reason: entry.key);
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

    test('the RGMII RX clocks are on clock capable balls', () {
      for (final p in _ethSites) {
        expect(board.siteIsClockCapable(p.rxc), isTrue, reason: p.rxc);
      }
    });

    test('each MAC has its own RGMII clocks and delays', () {
      final text = File('${dir.path}/Ax7203Soc.xdc').readAsStringSync();
      for (var n = 0; n < _ethSites.length; n++) {
        final e = 'eth$n';
        expect(
          text,
          contains(
            'create_clock -name ${e}_rgmii_rxc -period 8.000 '
            '[get_ports ${e}_rgmii_rxc]',
          ),
        );
        expect(
          text,
          contains(
            'create_generated_clock -name ${e}_rgmii_txc -source '
            '[get_pins -hierarchical -filter {NAME =~ *$e/*/txc_oddr/C}] '
            '-multiply_by 1 [get_ports ${e}_rgmii_txc]',
          ),
        );
        // RX data valid 0.04 ns before to 1.86 ns after each RX clock edge,
        // the MAC shifts the TX clock.
        for (final (k, v) in [('max', '3.960'), ('min', '1.860')]) {
          expect(
            text,
            contains(
              'set_input_delay -clock ${e}_rgmii_rxc -$k $v '
              '[get_ports {${e}_rgmii_rxd[*] ${e}_rgmii_rx_ctl}]',
            ),
          );
        }
        expect(
          text,
          contains(
            'create_generated_clock -name ${e}_rgmii_rxc_bufr '
            '-source [get_ports ${e}_rgmii_rxc] -divide_by 1 '
            '[get_pins -hierarchical -filter {NAME =~ *$e/*/rx_bufr/O}]',
          ),
        );
        expect(
          text,
          contains(
            'set_output_delay -clock ${e}_rgmii_txc -min -1.000 '
            '[get_ports {${e}_rgmii_txd[*] ${e}_rgmii_tx_ctl}]',
          ),
        );
      }
      expect(
        RegExp('set_multicycle_path -setup 2').allMatches(text),
        hasLength(1),
        reason: 'one line for both MACs',
      );
    });

    test('each MAC has its clock domain crossing constraints', () {
      final lines = File('${dir.path}/Ax7203Soc.xdc').readAsLinesSync();
      for (var n = 0; n < _ethSites.length; n++) {
        final e = 'eth$n';
        String cells(List<String> c) =>
            '[get_cells -hierarchical -filter {'
            '${c.map((p) => 'NAME =~ *$e/*$p').join(' || ')}}]';
        final rxEn =
            'set_max_delay -datapath_only '
            '-from ${cells(['eth_regs/rx_en_r*'])} '
            '-to ${cells(['rx_en_sync/sync_stage_0*'])} ';
        expect(lines.where((l) => l.startsWith(rxEn)), hasLength(1));
        expect(
          lines.where(
            (l) => l.startsWith('set_bus_skew') && l.contains('*$e/'),
          ),
          hasLength(4),
        );
      }
    });

    test('the device tree has both MACs in rgmii-rxid mode', () {
      final dts = File('${dir.path}/Ax7203Soc.dts').readAsStringSync();
      expect(
        RegExp('"harbor,ethernet-1"').allMatches(dts),
        hasLength(_ethSites.length),
      );
      expect(
        RegExp('phy-mode = "rgmii-rxid"').allMatches(dts),
        hasLength(_ethSites.length),
      );
    });

    test('each MAC has a PHY node at MDIO address 1 and a phy-handle', () {
      final dts = File('${dir.path}/Ax7203Soc.dts').readAsStringSync();
      for (var n = 0; n < _ethSites.length; n++) {
        expect(dts, contains('phy-handle = <&eth${n}_phy>;'));
        expect(
          dts,
          contains(
            RegExp(
              'mdio \\{[^}]*eth${n}_phy: ethernet-phy@1 \\{\\s*'
              'reg = <1>;\\s*rxc-skew-ps = <240>;',
            ),
          ),
        );
      }
    });

    test('the MDIO pads are tristate and RX uses BUFIO and BUFR only', () {
      final rtl = Directory('${dir.path}/rtl')
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .join('\n');
      expect(rtl, contains(RegExp(r'inout\s+(wire\s+)?(logic\s+)?eth0_mdio')));
      // Only the DDR3 PHY has an IDELAYCTRL, the RX pins have no IDELAY.
      expect(
        RegExp(r'^\s*IDELAYCTRL\s', multiLine: true).allMatches(rtl),
        hasLength(1),
      );
      expect(rtl, isNot(contains('rxd_0_idelay')));
      for (final cell in ['BUFIO', 'BUFR']) {
        expect(rtl, contains(RegExp('^\\s*$cell\\s', multiLine: true)));
      }
      expect(
        rtl,
        isNot(contains(RegExp(r'^\s*BUFG\s+rx_bufg', multiLine: true))),
      );
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

  test('a MAC with no PHY address has an empty mdio node', () {
    final mac = HarborEthernetMac(
      baseAddress: 0x30000000,
      config: HarborEthernetConfig.basic(phy: HarborEthPhy.mii),
      fabricKind: HarborFabricKind.wishbone,
      target: const HarborSimTarget(),
    );
    final node = mac.dtNode;
    expect(node.properties.containsKey('phy-handle'), isFalse);
    expect(node.children.single.name, 'mdio');
    expect(node.children.single.children, isEmpty);
    expect(HarborEthernetConfig.ax7203().phyAddress, 1);
    expect(
      () => HarborEthernetConfig(phy: HarborEthPhy.mii, phyAddress: 32),
      throwsArgumentError,
    );
  });

  test('a top-level port with no pin fails generation by name', () async {
    final target = board.fpgaTarget(
      pins: board.pins.keys.where((k) => k != 'som_led'),
    );
    final soc = _soc(target, withDdr: false, withEth: false);
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

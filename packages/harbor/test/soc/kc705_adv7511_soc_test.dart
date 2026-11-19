import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

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

const _hdmiPins = {
  'hdmi_d[0]': 'B23',
  'hdmi_d[1]': 'A23',
  'hdmi_d[2]': 'E23',
  'hdmi_d[3]': 'D23',
  'hdmi_d[4]': 'F25',
  'hdmi_d[5]': 'E25',
  'hdmi_d[6]': 'E24',
  'hdmi_d[7]': 'D24',
  'hdmi_d[8]': 'F26',
  'hdmi_d[9]': 'E26',
  'hdmi_d[10]': 'G23',
  'hdmi_d[11]': 'G24',
  'hdmi_d[12]': 'J19',
  'hdmi_d[13]': 'H19',
  'hdmi_d[14]': 'L17',
  'hdmi_d[15]': 'L18',
  'hdmi_de': 'H17',
  'hdmi_clk': 'K18',
  'hdmi_vsync': 'H20',
  'hdmi_hsync': 'J18',
  'i2c_scl': 'K21',
  'i2c_sda': 'L21',
  'i2c_mux_reset_n': 'P23',
};

HarborSoC _soc(
  HarborFpgaTarget target, {
  HarborDisplayTiming timing = const HarborDisplayTiming.xga1024x768(),
  List<HarborPixelFormat>? formats,
  int? memoryBytesPerSecond,
  int sysHz = 50000000,
}) {
  final soc = HarborSoC(
    name: 'Kc705Adv',
    compatible: 'test,kc705-adv',
    target: target,
    fabricKind: HarborFabricKind.axi4,
    fabricTopology: HarborFabricTopology.crossbar,
    clocks: [
      HarborClockConfig(
        name: 'sys',
        rate: HarborFixedClockRate(sysHz),
        sourceFrequency: 200000000,
        providedByDdr3Tree: true,
      ),
    ],
    xilinxDdr3Tree: XilinxDdr3TreeSpec(
      sourceHz: 200000000,
      ddrCkHz: 400000000,
      coreClkHz: sysHz,
    ),
  );
  final tree = soc.xilinxDdr3Clocks!;
  final ddr = soc.addPeripheral(
    HarborDdr3(
      config: const HarborDdrConfig.ax7203(),
      baseAddress: 0x80000000,
      clockHz: tree.controllerMhz.round() * 1000000,
      busAddressWidth: 32,
      busDataWidth: 32,
      protocol: HarborFabricKind.axi4,
      idWidth: 3,
      readChannels: 2,
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
  soc.addFabricScanoutDisplay(
    memory: BusAddressRange(0x80000000, 1024 * 1024 * 1024),
    timing: timing,
    formats: formats,
    baseAddress: 0x10008000,
    output: HarborDisplayInterface.adv7511,
    adv7511StatusPin: 'led',
    readChannel: 1,
    memoryBytesPerSecond: memoryBytesPerSecond,
  );
  return soc;
}

final _xdcLine = RegExp(
  r'^set_property -dict \{PACKAGE_PIN (\S+) IOSTANDARD (\S+)(.*)\} '
  r'\[get_ports (\S+)\]$',
);

/// The KC705 names the one-rank DDR3 control pads with an index.
const _ddrExtra = {
  'sdram_ck': 'AG10 DIFF_SSTL15',
  'sdram_ck_n': 'AH10 DIFF_SSTL15',
  'sdram_cke': 'AF10 SSTL15',
  'sdram_cs_n': 'AC12 SSTL15',
  'sdram_odt': 'AD8 SSTL15',
};

List<HarborPixelFormat> _scanoutFormats(HarborSoC soc) =>
    soc.peripherals.whereType<HarborScanoutDisplay>().single.formats;

void main() {
  final board = HarborBoard.get('kc705');
  late Directory dir;
  late Map<String, (String, String)> xdc;
  late String xdcText;
  late String rtl;

  setUpAll(() async {
    dir = Directory.systemTemp.createTempSync('harbor_kc705_adv7511_');
    final target = board.fpgaTarget(useHimbaechel: true, extraPins: _ddrExtra);
    await _soc(target).generateAll(dir);
    xdcText = File('${dir.path}/Kc705Adv.xdc').readAsStringSync();
    xdc = {
      for (final line in xdcText.split('\n'))
        if (_xdcLine.firstMatch(line) case final m?)
          m.group(4)!: (m.group(1)!, m.group(2)!),
    };
    rtl = Directory('${dir.path}/rtl')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.sv'))
        .map((f) => f.readAsStringSync())
        .join('\n');
  });

  tearDownAll(() async {
    dir.deleteSync(recursive: true);
    await Simulator.reset();
  });

  test('the HDMI and I2C pins are bound to the sites of UG810', () {
    for (final MapEntry(key: pin, value: site) in _hdmiPins.entries) {
      expect(xdc[pin], (site, 'LVCMOS25'), reason: pin);
    }
  });

  test('no site is used twice', () {
    final bySite = <String, List<String>>{};
    for (final e in xdc.entries) {
      // The extra pins alias pads that the preset already has.
      if (_ddrExtra.containsKey(e.key)) continue;
      bySite.putIfAbsent(e.value.$1, () => []).add(e.key);
    }
    expect(bySite.values.where((v) => v.length > 1), isEmpty);
  });

  test('no other pad of the preset uses an HDMI or I2C site', () {
    final sites = _hdmiPins.values.toSet();
    for (final e in board.pins.entries) {
      if (_hdmiPins.containsKey(e.key)) continue;
      expect(sites.contains(e.value.split(' ').first), isFalse, reason: e.key);
    }
  });

  test('the XDC constrains the 2x clock and the pixel clock', () {
    final clocks = RegExp(r'create_clock -period (\S+) \[get_nets (\S+)\]')
        .allMatches(xdcText)
        .map((m) => (double.parse(m.group(1)!), m.group(2)!))
        .toList();
    expect(
      clocks.where((c) => c.$2.endsWith('clk2x_net') && c.$1 == 7.692),
      hasLength(1),
    );
    expect(
      clocks.where((c) => c.$2.endsWith('pixel_clk_net') && c.$1 == 15.385),
      hasLength(1),
    );
  });

  test('the MMCM takes the shared oscillator buffer', () {
    expect(rtl, isNot(contains('source_bufg')));
    expect(rtl, matches(RegExp(r'\.source\(sysosc_clk\)')));
  });

  test('a SoC without the DDR3 tree has the nets in pll_clocks.py', () async {
    final soc = HarborSoC(
      name: 'Kc705AdvPlain',
      compatible: 'test,kc705-adv',
      target: board.fpgaTarget(),
      fabricKind: HarborFabricKind.axi4,
      clocks: [
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 50000000,
          sourceFrequency: 200000000,
        ),
      ],
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: 0x80000000,
        size: 0x10000,
        busAddressWidth: 32,
        dataWidth: 32,
        protocol: HarborFabricKind.axi4,
        target: board.fpgaTarget(),
      ),
    );
    soc.addFabricScanoutDisplay(
      memory: BusAddressRange(0x80000000, 0x10000),
      timing: const HarborDisplayTiming.svga800x600(),
      baseAddress: 0x10008000,
      output: HarborDisplayInterface.adv7511,
      adv7511StatusPin: 'led',
    );
    final plain = Directory.systemTemp.createTempSync('harbor_kc705_adv_py_');
    addTearDown(() => plain.deleteSync(recursive: true));
    await soc.generateAll(plain);
    final py = File(
      '${plain.path}/support/nextpnr/pll_clocks.py',
    ).readAsStringSync();
    expect(py, contains('adv7511_clocks.clk2x_net'));
    expect(py, contains('adv7511_clocks.pixel_clk_net'));
    expect(py, contains('80.0'));
  });

  test('the display reads the second DRAM port', () {
    expect(rtl, contains('bus_r1_ARVALID'));
    expect(rtl, contains('HarborAdv7511Clocks'));
    expect(rtl, contains('MMCME2_ADV'));
    expect(rtl, contains('HarborOpenDrainPad'));
  });

  test('the pixel clock is 65 MHz and the 2x clock 130 MHz', () {
    final s = HarborAdv7511Clocks.solve(200000000, 130000000);
    expect((s.mult, s.divclk, s.out), (13, 2, 10));
    final v = HarborAdv7511Clocks.solve(200000000, 50000000);
    expect(200 * v.mult / v.divclk / v.out, 50);
    final w = HarborAdv7511Clocks.solve(200000000, 80000000);
    expect(200 * w.mult / w.divclk / w.out, 80);
  });

  group('bandwidth of the memory port', () {
    final target = board.fpgaTarget(useHimbaechel: true, extraPins: _ddrExtra);

    test('xrgb8888 at 1024x768 throws on a 32 bit 50 MHz bus by default', () {
      expect(
        () => _soc(target, formats: const [HarborPixelFormat.xrgb8888]),
        throwsArgumentError,
      );
    });

    test('rgb565 at 1024x768 fits', () {
      expect(() => _soc(target), returnsNormally);
    });

    test('xrgb8888 at 800x600 fits', () {
      expect(
        () => _soc(
          target,
          timing: const HarborDisplayTiming.svga800x600(),
          formats: const [HarborPixelFormat.xrgb8888],
        ),
        returnsNormally,
      );
    });

    test('the default format at 1024x768 is rgb565', () {
      expect(_scanoutFormats(_soc(target)), [HarborPixelFormat.rgb565]);
    });

    test('the default format at 800x600 is xrgb8888', () {
      final soc = _soc(target, timing: const HarborDisplayTiming.svga800x600());
      expect(_scanoutFormats(soc), [HarborPixelFormat.xrgb8888]);
    });

    test('a faster port takes xrgb8888 at 1024x768', () {
      expect(
        () => _soc(
          target,
          formats: const [HarborPixelFormat.xrgb8888],
          memoryBytesPerSecond: 400000000,
        ),
        returnsNormally,
      );
    });
  });

  test('the display master reaches the read channel 1 of the DDR3', () async {
    final soc = _soc(
      board.fpgaTarget(useHimbaechel: true, extraPins: _ddrExtra),
    );
    soc.buildFabric();
    final fabric = soc.fabrics.single as HarborAxi4Fabric;
    final ddrSlave = fabric.slaves.singleWhere((s) => s.readChannels > 1);
    expect(ddrSlave.readChannels, 2);
    final display = fabric.masters.singleWhere(
      (m) => m.name.contains('display'),
    );
    expect(display.readChannel, 1);
    expect(display.reaches(ddrSlave.name), isTrue);
    await soc.build();
    final sv = soc.dumpSystemVerilog();
    // The DDR3 r1 port is wired to the fabric r1 output, and the fabric
    // takes the display fb port as its master.
    expect(sv, contains('.bus_r1_ARVALID(ddr3_r1_ARVALID)'));
    expect(sv, contains('.ddr3_r1_ARVALID(ddr3_r1_ARVALID)'));
    expect(sv, contains('.display_fb_ARVALID(fb_ARVALID)'));
    expect(sv, contains('.bus_r1_ARADDR(ddr3_r1_ARADDR)'));
    expect(sv, contains('assign ddr3_r1_ARVALID = ddr3_r1_ar_pop;'));
  });

  test('the register block has the ADV7511 status register', () {
    expect(rtl, contains("12'h78"));
  });

  test('the clock module names its definition by rate', () {
    expect(rtl, contains('HarborAdv7511Clocks_130000000_200000000_b_18'));
    expect(rtl, contains('.CLKOUT1_DIVIDE'));
  });
}

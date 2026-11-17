import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

const _sdramPins = [
  'sdram_clk',
  'sdram_cke',
  'sdram_cs_n',
  'sdram_ras_n',
  'sdram_cas_n',
  'sdram_we_n',
  'sdram_ba',
  'sdram_addr',
  'sdram_dqm',
  'sdram_dq',
];

HarborFpgaTarget _target() {
  final board = HarborBoard.get('ulx3s-85f');
  return board.fpgaTarget(
    pins: [
      'clk',
      for (var i = 0; i < 4; i++) 'gpdi_dp[$i]',
      ...board.pins.keys.where((k) => k.startsWith('sdram_')),
    ],
  );
}

/// The Delta V1 shape: AXI4 64-bit, 25 MHz sys clock, 32 MiB sdram on the
/// bus clock at 0x80000000 with scanout port 0.
HarborSoC _soc(HarborFpgaTarget target) => HarborSoC(
  name: 'DeltaSoC',
  compatible: 'river,delta',
  target: target,
  fabricKind: HarborFabricKind.axi4,
  clocks: [
    HarborClockConfig.fixed(
      name: 'sys',
      frequency: 25000000,
      sourceFrequency: 25000000,
      isPrimary: true,
    ),
  ],
);

/// The line of 640x480 rgb565 at 25 MHz on a 25 MHz sdram.
final _line = HarborScanoutLine.forMode(
  timing: const HarborDisplayTiming.vga640x480(),
  formats: const [HarborPixelFormat.rgb565],
  pixelClockHz: 25000000,
  sdramClockHz: 25000000,
);

HarborSdram _sdram(
  HarborFpgaTarget target, {
  int scanoutPorts = 1,
  HarborScanoutLine? line,
}) => HarborSdram(
  scanoutLine: scanoutPorts == 0 ? null : (line ?? _line),
  config: const HarborSdramConfig.as4c16m16sb6(),
  baseAddress: 0x80000000,
  clockHz: 25000000,
  busClockSync: true,
  busDataWidth: 64,
  protocol: HarborFabricKind.axi4,
  scanoutPorts: scanoutPorts,
  target: target,
);

({HarborSoC soc, HarborSdram sdram, HarborScanoutDisplay display}) _build({
  List<HarborPixelFormat> formats = const [HarborPixelFormat.rgb565],
}) {
  final target = _target();
  final soc = _soc(target);
  final sdram = soc.addPeripheral(_sdram(target));
  final display = soc.addScanoutDisplay(
    sdram: sdram,
    timing: const HarborDisplayTiming.vga640x480(),
    formats: formats,
    pixelClockHz: 25000000,
    framebufferBase: 0x81e00000,
    baseAddress: 0x10008000,
    busDataWidth: 64,
    enableOnReset: true,
  );
  soc.buildFabric();
  return (soc: soc, sdram: sdram, display: display);
}

const _dts = r'''
/dts-v1/;

/ {
    model = "DeltaSoC";
    compatible = "river,delta";
    #address-cells = <1>;
    #size-cells = <1>;

    memory@80000000 {
        device_type = "memory";
        reg = <0x80000000 0x1e00000>;
    };

    reserved-memory {
        #address-cells = <1>;
        #size-cells = <1>;
        ranges;

        display_fb: framebuffer@81e00000 {
            compatible = "shared-dma-pool";
            reg = <0x81e00000 0x200000>;
            no-map;
        };
    };

    soc {
        compatible = "simple-bus";
        #address-cells = <1>;
        #size-cells = <1>;
        ranges;

        sdram-controller@80000000 {
            compatible = "harbor,sdram-controller", "harbor,sdr-sdram";
            reg = <0x80000000 0x2000000>;
            sdram-type = "sdr";
            data-width = <16>;
            clock-frequency = <25000000>;
            harbor,sdram-part = "AS4C16M16SB-6";
            harbor,sdram-cas-latency = <2>;
            harbor,sdram-banks = <4>;
            harbor,sdram-rows = <13>;
            harbor,sdram-cols = <9>;
            harbor,sdram-address-map = "row-bank-col";
        };

        display@10008000 {
            compatible = "harbor,display";
            reg = <0x10008000 0x1000>;
            interrupts = <0x1>;
            harbor,hactive = <640>;
            harbor,hfront-porch = <16>;
            harbor,hsync-len = <96>;
            harbor,hback-porch = <48>;
            harbor,hsync-active = <0>;
            harbor,vactive = <480>;
            harbor,vfront-porch = <10>;
            harbor,vsync-len = <2>;
            harbor,vback-porch = <33>;
            harbor,vsync-active = <0>;
            harbor,pixel-clock-hz = <25000000>;
            harbor,formats = "r5g6b5";
            harbor,strides = <0x800>;
            memory-region = <&display_fb>;
        };

        simple-framebuffer@81e00000 {
            compatible = "simple-framebuffer";
            reg = <0x81e00000 0x200000>;
            width = <640>;
            height = <480>;
            stride = <2048>;
            format = "r5g6b5";
        };
    };
};
''';

void main() {
  test('the device tree has the display, its reserved region and the '
      'simple-framebuffer node', () {
    final b = _build();
    expect(b.soc.generateDts(), _dts);
  });

  test('a framebuffer pool below the top of the sdram is rejected', () {
    final target = _target();
    final soc = _soc(target);
    final sdram = soc.addPeripheral(_sdram(target));
    expect(
      () => soc.addScanoutDisplay(
        sdram: sdram,
        timing: const HarborDisplayTiming.vga640x480(),
        pixelClockHz: 25000000,
        framebufferBase: 0x81c00000,
        baseAddress: 0x10008000,
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('firmware reads /memory only'),
        ),
      ),
    );
  });

  test('ACPI has a PRP0001 display with the same properties', () {
    final asl = _build().soc.generateAcpi();
    final start = asl.indexOf('Device (D001)');
    final block = asl.substring(start);
    expect(block, contains('Name (_HID, "PRP0001")'));
    expect(
      block,
      contains('Memory32Fixed (ReadWrite, 0x10008000, 0x00001000)'),
    );
    expect(block, isNot(contains('0x81e00000')));
    expect(block, contains('0x1\n'), reason: 'interrupt source 1');
    for (final p in [
      '"compatible", Package () { "harbor,display" }',
      '"harbor,hactive", 0x280',
      '"harbor,hfront-porch", 0x10',
      '"harbor,hsync-len", 0x60',
      '"harbor,hback-porch", 0x30',
      '"harbor,hsync-active", 0x0',
      '"harbor,vactive", 0x1E0',
      '"harbor,vfront-porch", 0xA',
      '"harbor,vsync-len", 0x2',
      '"harbor,vback-porch", 0x21',
      '"harbor,vsync-active", 0x0',
      '"harbor,pixel-clock-hz", 0x17D7840',
      '"harbor,formats", Package () { "r5g6b5" }',
      '"harbor,strides", Package () { 0x800 }',
    ]) {
      expect(block, contains(p));
    }
  });

  test('the SVD has the registers and the interrupt', () {
    final svd = _build().soc.generateSvd();
    final start = svd.indexOf('<name>DISPLAY</name>');
    final end = svd.indexOf('</peripheral>', start);
    final block = svd.substring(start, end);
    expect(block, contains('<baseAddress>0x10008000</baseAddress>'));
    expect(block, contains('<value>1</value>'));
    const regs = {
      'ctrl': 0x00,
      'status': 0x08,
      'fb_base': 0x10,
      'fb_stride': 0x18,
      'h_active': 0x20,
      'h_timing': 0x28,
      'v_active': 0x30,
      'v_timing': 0x38,
      'int_status': 0x40,
      'int_enable': 0x48,
      'pixel_clock': 0x50,
      'format': 0x58,
      'formats': 0x60,
    };
    for (final e in regs.entries) {
      expect(
        block,
        contains(
          '<name>${e.key}</name>\n          <addressOffset>'
          '0x${e.value.toRadixString(16)}</addressOffset>',
        ),
        reason: e.key,
      );
    }
    expect(block, contains('<resetValue>0x81E00000</resetValue>'));
  });

  test(
    'the helper adds the shift and pixel clocks and a gpdi_dp pin',
    () async {
      final b = _build();
      expect(b.soc.clockDomain('shift')!.config.frequency, 125000000);
      expect(b.soc.clockDomain('pixel')!.config.frequency, 25000000);
      expect(b.soc.defaultClock.$1, b.soc.clockDomain('sys')!.clk);
      expect(b.soc.interruptAssignments()[b.display], 1);

      final dir = Directory.systemTemp.createTempSync('harbor_scanout_soc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final soc = b.soc;
      for (final p in _sdramPins) {
        soc.exposePin(b.sdram, p, externalName: p);
      }
      await soc.generateAll(dir);
      final top = File('${dir.path}/rtl/DeltaSoC.sv').readAsStringSync();
      expect(top, matches(RegExp(r'output\s+logic\s+\[3:0\]\s+gpdi_dp\b')));
      final lpf = dir
          .listSync()
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.lpf'))
          .readAsStringSync();
      for (var i = 0; i < 4; i++) {
        expect(lpf, contains('gpdi_dp[$i]'));
      }
      final sv = Directory('${dir.path}/rtl')
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .join('\n');
      expect(RegExp(r'\bEHXPLLL\b\s*#').allMatches(sv), hasLength(1));
    },
  );

  test('the helper takes existing shift and pixel domains', () {
    final target = _target();
    final soc = HarborSoC(
      name: 'DeltaSoC',
      compatible: 'river,delta',
      target: target,
      fabricKind: HarborFabricKind.axi4,
      clocks: [
        HarborClockConfig.fixed(
          name: 'sys',
          frequency: 25000000,
          sourceFrequency: 25000000,
          isPrimary: true,
        ),
        HarborScanoutDisplay.clockConfig(
          pixelClockHz: 25000000,
          sourceClockHz: 25000000,
        ),
      ],
    );
    final sdram = soc.addPeripheral(_sdram(target));
    final display = soc.addScanoutDisplay(
      sdram: sdram,
      timing: const HarborDisplayTiming.vga640x480(),
      framebufferBase: 0x81e00000,
      baseAddress: 0x10008000,
    );
    expect(display.timing.pixelClock, 25000000);
    soc.buildFabric();
  });

  group('bandwidth', () {
    test('rgb565 640x480 at 25 MHz on a 16-bit sdram uses 73%', () {
      final bw = HarborScanoutBandwidth(
        timing: const HarborDisplayTiming(
          hActive: 640,
          hFrontPorch: 16,
          hSyncWidth: 96,
          hBackPorch: 48,
          vActive: 480,
          vFrontPorch: 10,
          vSyncWidth: 2,
          vBackPorch: 33,
          pixelClock: 25175000,
        ),
        format: HarborPixelFormat.rgb565,
        sdramDataBits: 16,
        sdramClockHz: 25000000,
      );
      expect(bw.share, closeTo(0.737, 0.001));
      expect(bw.remainingShare, closeTo(0.263, 0.001));
      bw.check();
    });

    test('the helper rejects xrgb8888 at 25 MHz', () {
      final target = _target();
      final soc = _soc(target);
      final sdram = soc.addPeripheral(_sdram(target));
      expect(
        () => soc.addScanoutDisplay(
          sdram: sdram,
          timing: const HarborDisplayTiming.vga640x480(),
          formats: const [HarborPixelFormat.xrgb8888],
          pixelClockHz: 25000000,
          framebufferBase: 0x81c00000,
          baseAddress: 0x10008000,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('xrgb8888'), contains('146%')),
          ),
        ),
      );
    });

    test('a format list is rejected when any format does not fit', () {
      final target = _target();
      final soc = _soc(target);
      final sdram = soc.addPeripheral(_sdram(target));
      expect(
        () => soc.addScanoutDisplay(
          sdram: sdram,
          timing: const HarborDisplayTiming.vga640x480(),
          formats: const [HarborPixelFormat.rgb565, HarborPixelFormat.xrgb8888],
          pixelClockHz: 25000000,
          framebufferBase: 0x81c00000,
          baseAddress: 0x10008000,
        ),
        throwsArgumentError,
      );
    });

    test('a faster sdram clock takes xrgb8888', () {
      final bw = HarborScanoutBandwidth(
        timing: const HarborDisplayTiming.vga640x480(),
        format: HarborPixelFormat.xrgb8888,
        sdramDataBits: 16,
        sdramClockHz: 100000000,
      );
      bw.check();
    });
  });

  group('scanout guarantee', () {
    test('the bound at 25 MHz fits the line with room', () {
      final target = _target();
      final sdram = _sdram(target);
      final bound = HarborSdram.scanoutLineBound(
        sdram.cycles,
        sdram.config,
        _line.words,
        periodCycles: _line.periodCycles,
      );
      print(
        'line ${_line.words} words in ${_line.periodCycles} cycles, '
        'bound $bound',
      );
      expect(
        HarborSdram.scanoutLineFits(
          sdram.cycles,
          sdram.config,
          _line.words,
          _line.periodCycles,
          syncCycles: _line.syncCycles,
        ),
        isTrue,
      );
      expect(sdram.busWaitBound, greaterThan(bound));
    });

    test('a line period that is too short is rejected by the sdram', () {
      expect(
        () => _sdram(
          _target(),
          line: HarborScanoutLine(
            words: _line.words,
            periodCycles: 700,
            syncCycles: _line.syncCycles,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('the helper needs an sdram that holds the bus port back', () {
      final target = _target();
      final soc = _soc(target);
      final sdram = soc.addPeripheral(
        HarborSdram(
          config: const HarborSdramConfig.as4c16m16sb6(),
          baseAddress: 0x80000000,
          clockHz: 25000000,
          busClockSync: true,
          busDataWidth: 64,
          protocol: HarborFabricKind.axi4,
          scanoutPorts: 1,
          target: target,
        ),
      );
      expect(
        () => soc.addScanoutDisplay(
          sdram: sdram,
          timing: const HarborDisplayTiming.vga640x480(),
          pixelClockHz: 25000000,
          framebufferBase: 0x81e00000,
          baseAddress: 0x10008000,
        ),
        throwsArgumentError,
      );
    });

    test('the helper rejects a mode whose worst line does not fit', () {
      final target = _target();
      final soc = _soc(target);
      final sdram = soc.addPeripheral(_sdram(target));
      const tight = HarborDisplayTiming(
        hActive: 640,
        hFrontPorch: 4,
        hSyncWidth: 8,
        hBackPorch: 8,
        vActive: 480,
        vFrontPorch: 1,
        vSyncWidth: 1,
        vBackPorch: 1,
        pixelClock: 25000000,
      );
      expect(
        () => soc.addScanoutDisplay(
          sdram: sdram,
          timing: tight,
          pixelClockHz: 25000000,
          framebufferBase: 0x81e00000,
          baseAddress: 0x10008000,
        ),
        throwsArgumentError,
      );
    });
  });

  group('build checks', () {
    test('an sdram with no scanout port is rejected', () {
      final target = _target();
      final soc = _soc(target);
      final sdram = soc.addPeripheral(_sdram(target, scanoutPorts: 0));
      expect(
        () => soc.addScanoutDisplay(
          sdram: sdram,
          timing: const HarborDisplayTiming.vga640x480(),
          pixelClockHz: 25000000,
          framebufferBase: 0x81e00000,
          baseAddress: 0x10008000,
        ),
        throwsArgumentError,
      );
    });

    test('a framebuffer outside the sdram or off a page is rejected', () {
      final target = _target();
      final soc = _soc(target);
      final sdram = soc.addPeripheral(_sdram(target));
      for (final base in [0x80100200, 0x7ff00000, 0x81f80000]) {
        expect(
          () => soc.addScanoutDisplay(
            sdram: sdram,
            timing: const HarborDisplayTiming.vga640x480(),
            pixelClockHz: 25000000,
            framebufferBase: base,
            baseAddress: 0x10008000,
          ),
          throwsArgumentError,
          reason: '0x${base.toRadixString(16)}',
        );
      }
    });

    test('a SoC with no sys domain is rejected before it adds clocks', () {
      final target = _target();
      final soc = HarborSoC(
        name: 'NoSys',
        compatible: 'test,nosys',
        target: target,
        fabricKind: HarborFabricKind.axi4,
        clocks: [
          HarborClockConfig.fixed(
            name: 'bus',
            frequency: 25000000,
            sourceFrequency: 25000000,
            isPrimary: true,
          ),
        ],
      );
      final sdram = soc.addPeripheral(_sdram(target));
      expect(
        () => soc.addScanoutDisplay(
          sdram: sdram,
          timing: const HarborDisplayTiming.vga640x480(),
          pixelClockHz: 25000000,
          framebufferBase: 0x81e00000,
          baseAddress: 0x10008000,
        ),
        throwsStateError,
      );
    });
  });
}

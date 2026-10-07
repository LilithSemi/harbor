import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborFpgaTarget.ice40', () {
    late HarborFpgaTarget target;

    setUp(() {
      target = const HarborFpgaTarget.ice40(
        device: 'up5k',
        package: 'sg48',
        frequency: 48000000,
        pinMap: {'clk': '35', 'uart_tx': '1'},
      );
    });

    test('name', () {
      expect(target.name, equals('ice40-up5k'));
    });

    test('vendor', () {
      expect(target.vendor, equals(HarborFpgaVendor.ice40));
    });

    test('constraintExtension is pcf', () {
      expect(target.constraintExtension, equals('pcf'));
    });

    test('hasTemperatureSensor is false', () {
      expect(target.hasTemperatureSensor, isFalse);
    });

    test('hasEfuse is false', () {
      expect(target.hasEfuse, isFalse);
    });
  });

  group('HarborFpgaTarget.ecp5', () {
    late HarborFpgaTarget target;

    setUp(() {
      target = const HarborFpgaTarget.ecp5(
        device: 'lfe5u-45f',
        package: 'CABGA381',
        frequency: 50000000,
        pinMap: {'clk': 'A10'},
      );
    });

    test('name', () {
      expect(target.name, equals('ecp5-lfe5u-45f'));
    });

    test('vendor', () {
      expect(target.vendor, equals(HarborFpgaVendor.ecp5));
    });

    test('constraintExtension is lpf', () {
      expect(target.constraintExtension, equals('lpf'));
    });

    test('hasTemperatureSensor is true', () {
      expect(target.hasTemperatureSensor, isTrue);
    });

    test('hasEfuse is true', () {
      expect(target.hasEfuse, isTrue);
    });
  });

  group('HarborFpgaTarget.spartan7', () {
    test('vivado vendor by default', () {
      const target = HarborFpgaTarget.spartan7(
        device: 'xc7s50',
        package: 'ftgb196',
      );
      expect(target.vendor, equals(HarborFpgaVendor.vivado));
      expect(target.constraintExtension, equals('xdc'));
    });

    test('openXc7 vendor when flag set', () {
      const target = HarborFpgaTarget.spartan7(
        device: 'xc7s50',
        package: 'ftgb196',
        useOpenXc7: true,
      );
      expect(target.vendor, equals(HarborFpgaVendor.openXc7));
      expect(target.constraintExtension, equals('xdc'));
    });
  });

  group('HarborFpgaTarget.artix7', () {
    test('name', () {
      const target = HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
      );
      expect(target.name, equals('artix7-xc7a200t'));
    });

    test('vivado vendor by default', () {
      const target = HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
      );
      expect(target.vendor, equals(HarborFpgaVendor.vivado));
      expect(target.constraintExtension, equals('xdc'));
    });

    test('openXc7 vendor when flag set', () {
      const target = HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
        useOpenXc7: true,
      );
      expect(target.vendor, equals(HarborFpgaVendor.openXc7));
      expect(target.constraintExtension, equals('xdc'));
    });

    test('jtagIrLength is 6, same as every 7-series part', () {
      const target = HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
      );
      expect(target.jtagIrLength, equals(6));
    });

    test('generateYosysTcl targets xilinx synth, not spartan7-specific', () {
      const target = HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
      );
      final result = target.generateYosysTcl('TopCell');
      expect(result, contains('synth_xilinx'));
    });

    test('openXc7 Makefile uses the artix7 prjxray family', () {
      const target = HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
        useOpenXc7: true,
      );
      final mk = target.generateMakefile('TopCell');
      expect(mk, contains('FAMILY = artix7'));
      expect(mk, isNot(contains('FAMILY = spartan7')));
      expect(mk, contains('nextpnr-xilinx'));
    });
  });

  group('HarborFpgaTarget.kintex7', () {
    test('name', () {
      const target = HarborFpgaTarget.kintex7(
        device: 'xc7k325t',
        package: 'ffg676',
      );
      expect(target.name, equals('kintex7-xc7k325t'));
    });

    test('vivado vendor by default', () {
      const target = HarborFpgaTarget.kintex7(
        device: 'xc7k325t',
        package: 'ffg676',
      );
      expect(target.vendor, equals(HarborFpgaVendor.vivado));
      expect(target.constraintExtension, equals('xdc'));
    });

    test('openXc7 vendor when flag set', () {
      const target = HarborFpgaTarget.kintex7(
        device: 'xc7k325t',
        package: 'ffg676',
        useOpenXc7: true,
      );
      expect(target.vendor, equals(HarborFpgaVendor.openXc7));
      expect(target.constraintExtension, equals('xdc'));
    });

    test('jtagIrLength is 6, same as every 7-series part', () {
      const target = HarborFpgaTarget.kintex7(
        device: 'xc7k325t',
        package: 'ffg676',
      );
      expect(target.jtagIrLength, equals(6));
    });

    test('generateYosysTcl targets xilinx synth, not spartan7-specific', () {
      const target = HarborFpgaTarget.kintex7(
        device: 'xc7k325t',
        package: 'ffg676',
      );
      final result = target.generateYosysTcl('TopCell');
      expect(result, contains('synth_xilinx'));
    });

    test('openXc7 Makefile uses the kintex7 prjxray family', () {
      const target = HarborFpgaTarget.kintex7(
        device: 'xc7k325t',
        package: 'ffg676',
        useOpenXc7: true,
      );
      final mk = target.generateMakefile('TopCell');
      expect(mk, contains('FAMILY = kintex7'));
      expect(mk, isNot(contains('FAMILY = spartan7')));
      expect(mk, contains('nextpnr-xilinx'));
    });
  });

  group('HarborFpgaTarget prjxray family fallback (plain constructor)', () {
    // The plain constructor (used by HarborBoard.fpgaTarget, among others)
    // has no family-specific constructor to set the family from, so the
    // family must come from the device part prefix instead of silently
    // going empty.
    test('infers spartan7 from an xc7s device', () {
      const target = HarborFpgaTarget(
        name: 'custom',
        vendor: HarborFpgaVendor.openXc7,
        device: 'xc7s50',
        package: 'csga324',
      );
      expect(target.generateMakefile('TopCell'), contains('FAMILY = spartan7'));
    });

    test('infers artix7 from an xc7a device', () {
      const target = HarborFpgaTarget(
        name: 'custom',
        vendor: HarborFpgaVendor.openXc7,
        device: 'xc7a200t',
        package: 'fbg484',
      );
      expect(target.generateMakefile('TopCell'), contains('FAMILY = artix7'));
    });

    test('infers kintex7 from an xc7k device', () {
      const target = HarborFpgaTarget(
        name: 'custom',
        vendor: HarborFpgaVendor.openXc7,
        device: 'xc7k325t',
        package: 'ffg676',
      );
      expect(target.generateMakefile('TopCell'), contains('FAMILY = kintex7'));
    });

    test('throws for an unrecognised Xilinx device prefix', () {
      const target = HarborFpgaTarget(
        name: 'custom',
        vendor: HarborFpgaVendor.openXc7,
        device: 'xc7v2000t',
        package: 'flg1925',
      );
      expect(() => target.generateMakefile('TopCell'), throwsStateError);
    });
  });

  group('HarborFpgaTarget generation', () {
    test('generateConstraints returns non-empty string', () {
      const target = HarborFpgaTarget.ice40(
        device: 'up5k',
        package: 'sg48',
        pinMap: {'clk': '35'},
      );
      final result = target.generateConstraints();
      expect(result, isNotEmpty);
    });

    test('knownPorts filters board pins the design does not expose', () {
      // A board carries an unused HDMI header, but this SoC has no gpdi port.
      const target = HarborFpgaTarget.spartan7(
        device: 'xc7s50',
        package: 'csga324',
        useOpenXc7: true,
        pinMap: {
          'clk': 'R2',
          'uart_tx': 'R12',
          'sdram_dq[0]': 'K2',
          'gpdi_dp[0]': 'N15',
        },
      );
      // Without knownPorts every pin is emitted (backward compatible).
      final all = target.generateConstraints();
      expect(all, contains('gpdi_dp[0]'));

      // With knownPorts, gpdi is dropped (no gpdi port), but the real ports,
      // including the sdram_dq bus bit whose base name is exposed, are kept.
      final filtered = target.generateConstraints(
        knownPorts: {'clk', 'uart_tx', 'sdram_dq'},
      );
      expect(filtered, contains('get_ports clk'));
      expect(filtered, contains('get_ports uart_tx'));
      expect(filtered, contains('get_ports sdram_dq[0]'));
      expect(filtered, isNot(contains('gpdi')));
    });

    test('generateYosysTcl contains synth target', () {
      const target = HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48');
      final result = target.generateYosysTcl('TopCell');
      expect(result, contains('synth_ice40'));
    });

    test('generateYosysTcl ecp5 contains synth target', () {
      const target = HarborFpgaTarget.ecp5(
        device: 'lfe5u-45f',
        package: 'CABGA381',
      );
      final result = target.generateYosysTcl('TopCell');
      expect(result, contains('synth_ecp5'));
    });

    test('generateNextpnrCommand returns non-null for ice40', () {
      const target = HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48');
      final result = target.generateNextpnrCommand('TopCell');
      expect(result, isNotNull);
      expect(result, contains('nextpnr-ice40'));
    });

    test('generateNextpnrCommand returns non-null for ecp5', () {
      const target = HarborFpgaTarget.ecp5(
        device: 'lfe5u-45f',
        package: 'CABGA381',
      );
      final result = target.generateNextpnrCommand('TopCell');
      expect(result, isNotNull);
      expect(result, contains('nextpnr-ecp5'));
    });

    test('generateMakefile returns string with all: target', () {
      const target = HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48');
      final result = target.generateMakefile('TopCell');
      expect(result, contains('all:'));
    });
  });

  group('HarborFpgaTarget extraConstraints', () {
    // One raw line for every family, in that family's own language. Harbor
    // writes each one without a change, it does not translate between them.
    const lpfLine = 'IOBUF PORT "usb_dp" SLEWRATE=SLOW;';
    const pcfLine = 'set_frequency usb_dp 12.0';
    const xdcLine = 'set_property LOC BUFHCE_X0Y12 [get_cells bufh]';

    test('ECP5 puts the lines in the LPF', () {
      const target = HarborFpgaTarget.ecp5(
        device: 'lfe5u-25f',
        package: 'CSFBGA285',
        frequency: 48000000,
        pinMap: {'clk': 'A9 LVCMOS33', 'usb_dp': 'N1 LVCMOS33'},
        extraConstraints: {'usb_dp_slew': lpfLine},
      );
      final lpf = target.generateConstraints();
      expect(lpf, contains(lpfLine));
      expect(lpf, contains('# BEGIN extraConstraints (raw LPF lines)'));
      expect(lpf, contains('# END extraConstraints'));
      // The pin constraints stay, the block only adds to them, and it comes
      // after the clock constraint at the end of the file.
      expect(lpf, contains('LOCATE COMP "usb_dp" SITE "N1";'));
      expect(
        lpf.indexOf(lpfLine),
        greaterThan(lpf.indexOf('FREQUENCY PORT "clk"')),
      );
    });

    test('iCE40 puts the lines in the PCF', () {
      const target = HarborFpgaTarget.ice40(
        device: 'up5k',
        package: 'sg48',
        frequency: 48000000,
        pinMap: {'clk': '35', 'usb_dp': '37'},
        extraConstraints: {'usb_dp_freq': pcfLine},
      );
      final pcf = target.generateConstraints();
      expect(pcf, contains(pcfLine));
      expect(pcf, contains('# BEGIN extraConstraints (raw PCF lines)'));
      expect(pcf, contains('# END extraConstraints'));
      expect(pcf, contains('set_io usb_dp 37'));
      expect(
        pcf.indexOf(pcfLine),
        greaterThan(pcf.indexOf('set_frequency clk')),
      );
    });

    test('Xilinx still puts the lines in the XDC', () {
      const target = HarborFpgaTarget.spartan7(
        device: 'xc7s50',
        package: 'csga324',
        useOpenXc7: true,
        frequency: 100000000,
        pinMap: {'clk': 'R2'},
        extraConstraints: {'bufh_loc': xdcLine},
      );
      final xdc = target.generateConstraints();
      expect(xdc, contains(xdcLine));
      expect(xdc, contains('# BEGIN extraConstraints (raw XDC lines)'));
      expect(xdc, contains('# END extraConstraints'));
      expect(xdc.indexOf(xdcLine), greaterThan(xdc.indexOf('create_clock')));
    });

    test('the lines keep their order', () {
      const target = HarborFpgaTarget.ecp5(
        device: 'lfe5u-25f',
        package: 'CSFBGA285',
        pinMap: {'clk': 'A9 LVCMOS33'},
        extraConstraints: {
          'first': 'BLOCK RESETPATHS;',
          'second': 'BLOCK ASYNCPATHS;',
        },
      );
      final lpf = target.generateConstraints();
      expect(
        lpf.indexOf('BLOCK RESETPATHS;'),
        lessThan(lpf.indexOf('BLOCK ASYNCPATHS;')),
      );
    });

    test('no block at all when there are no extra constraints', () {
      for (final target in const [
        HarborFpgaTarget.ecp5(
          device: 'lfe5u-25f',
          package: 'CSFBGA285',
          frequency: 48000000,
          pinMap: {'clk': 'A9 LVCMOS33'},
        ),
        HarborFpgaTarget.ice40(
          device: 'up5k',
          package: 'sg48',
          frequency: 48000000,
          pinMap: {'clk': '35'},
        ),
        HarborFpgaTarget.spartan7(
          device: 'xc7s50',
          package: 'csga324',
          useOpenXc7: true,
          frequency: 100000000,
          pinMap: {'clk': 'R2'},
        ),
      ]) {
        expect(
          target.generateConstraints(),
          isNot(contains('extraConstraints')),
          reason: '${target.vendor} emitted a stray block',
        );
      }
    });
  });

  group('HarborAsicTarget', () {
    late Sky130Provider pdk;

    setUp(() {
      pdk = Sky130Provider(pdkRoot: '/pdk/sky130A');
    });

    test('name', () {
      final target = HarborAsicTarget(provider: pdk, topCell: 'MySoC');
      expect(target.name, equals('SkyWater SKY130-130nm'));
    });

    test('isHierarchical false when no macros', () {
      final target = HarborAsicTarget(provider: pdk, topCell: 'MySoC');
      expect(target.isHierarchical, isFalse);
    });

    test('isHierarchical true when macros present', () {
      final target = HarborAsicTarget(
        provider: pdk,
        topCell: 'MySoC',
        macros: const [HarborAsicMacro(moduleName: 'Core')],
      );
      expect(target.isHierarchical, isTrue);
    });

    test('generateSdc contains create_clock', () {
      final target = HarborAsicTarget(
        provider: pdk,
        topCell: 'MySoC',
        frequency: 50000000,
      );
      final sdc = target.generateSdc();
      expect(sdc, contains('create_clock'));
    });

    test('generateYosysTcl contains synth', () {
      final target = HarborAsicTarget(provider: pdk, topCell: 'MySoC');
      final tcl = target.generateYosysTcl();
      expect(tcl, contains('synth'));
    });

    test('generateOpenroadTcl contains read_liberty', () {
      final target = HarborAsicTarget(provider: pdk, topCell: 'MySoC');
      final tcl = target.generateOpenroadTcl();
      expect(tcl, contains('read_liberty'));
    });
  });

  group('HarborAsicMacro', () {
    test('moduleName', () {
      const macro = HarborAsicMacro(moduleName: 'RiverCore');
      expect(macro.moduleName, equals('RiverCore'));
    });

    test('default utilization', () {
      const macro = HarborAsicMacro(moduleName: 'RiverCore');
      expect(macro.utilization, equals(0.6));
    });
  });

  group('HarborFpgaVendor', () {
    test('has 4 values', () {
      expect(HarborFpgaVendor.values, hasLength(4));
      expect(HarborFpgaVendor.values, contains(HarborFpgaVendor.ice40));
      expect(HarborFpgaVendor.values, contains(HarborFpgaVendor.ecp5));
      expect(HarborFpgaVendor.values, contains(HarborFpgaVendor.vivado));
      expect(HarborFpgaVendor.values, contains(HarborFpgaVendor.openXc7));
    });
  });
}

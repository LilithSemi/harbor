import 'package:harbor/harbor.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

/// Minimal peripheral with a configurable register map and block size, used to
/// exercise the SoC register validation paths.
class _RegMockPeripheral extends BridgeModule
    with HarborDeviceTreeNodeProvider, HarborSvdPeripheralProvider {
  final HarborDeviceRegisterMap map;
  final int blockSize;

  _RegMockPeripheral(this.map, this.blockSize, {String? name})
    : super('RegMock', name: name ?? 'regmock') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['test,regmock'],
    reg: BusAddressRange(0x40000000, blockSize),
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'REGMOCK',
    baseAddress: 0x40000000,
    size: blockSize,
    registers: map,
  );
}

void main() {
  group('HarborSoC', () {
    test('creates with peripherals', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      final clint = soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
      final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));

      expect(soc.peripherals, hasLength(2));
      expect(soc.peripherals, contains(clint));
      expect(soc.peripherals, contains(uart));
    });

    test('rejects non-HarborDeviceTreeNodeProvider peripheral', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      // A plain BridgeModule without HarborDeviceTreeNodeProvider
      final badModule = BridgeModule('BadModule', name: 'bad');
      badModule.createPort('clk', PortDirection.input);
      badModule.createPort('reset', PortDirection.input);

      expect(() => soc.addPeripheral(badModule), throwsArgumentError);
    });

    test('generates DTS', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
      );

      soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
      soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000));

      final dts = soc.generateDts();
      expect(dts, contains('/dts-v1/'));
      expect(dts, contains('test,soc-v1'));
      expect(dts, contains('riscv,clint0'));
      expect(dts, contains('sifive,plic-1.0.0'));
    });

    test('renders a boolean property as a bare DTS flag', () {
      final soc = HarborSoC(
        name: 'BoolSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
      );
      // The DMA-enabled SPI controller emits a `harbor,dma` boolean property.
      soc.addPeripheral(
        HarborSpiController(baseAddress: 0x10001000, dma: true),
      );

      final dts = soc.generateDts();
      // A DTS boolean is the bare property name; `harbor,dma = ;` is invalid
      // DTS and dtc rejects it (this was the bug).
      expect(dts, contains('harbor,dma;'));
      expect(dts, isNot(contains('harbor,dma = ')));
    });

    test('generates SVD', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        svdVendor: 'Lilith Semiconductor',
        svdVersion: '3.0',
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
      );

      soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
      soc.addPeripheral(HarborUart(baseAddress: 0x10000000));

      final svd = soc.generateSvd();
      expect(svd, contains('<device schemaVersion="1.3"'));
      expect(svd, contains('<vendor>Lilith Semiconductor</vendor>'));
      expect(svd, contains('<version>3.0</version>'));
      expect(svd, contains('<name>TestSoC</name>'));
      expect(svd, contains('<cpu>'));
      // CLINT carries a register map, so its registers are emitted.
      expect(svd, contains('<name>CLINT</name>'));
      expect(svd, contains('<baseAddress>0x2000000</baseAddress>'));
      expect(svd, contains('<name>mtime</name>'));
      // UART register map flows through too.
      expect(svd, contains('<name>UART</name>'));
      expect(svd, contains('<name>rbr_thr_dll</name>'));
    });

    test('allocates interrupt numbers once for all generators', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      // PLIC is an interrupt controller, so it is not assigned a source.
      soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000));
      final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
      final gpio = soc.addPeripheral(HarborGpio(baseAddress: 0x10060000));

      final assign = soc.interruptAssignments();
      expect(assign[uart], equals(1));
      expect(assign[gpio], equals(2));
      // The controller is skipped entirely.
      expect(assign.values, isNot(contains(0)));
      expect(assign.length, equals(2));

      // The same numbers surface in every generated artifact.
      final dts = soc.generateDts();
      expect(dts, contains('interrupts = <0x1>;'));
      expect(dts, contains('interrupts = <0x2>;'));

      final svd = soc.generateSvd();
      expect(svd, contains('<value>1</value>'));
      expect(svd, contains('<value>2</value>'));

      final acpi = soc.generateAcpi();
      expect(acpi, contains('Interrupt (ResourceConsumer'));
    });

    test('the ACPI GSI base reaches _GSB and the device GSIs', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000));
      final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));

      final acpi = soc.generateAcpi();
      // The PLIC device answers the base Linux matches against the MADT.
      expect(acpi, contains('Name (_HID, "RSCV0001")'));
      expect(acpi, contains('Method (_GSB, 0, NotSerialized)'));
      expect(acpi, contains('Return (0x0)'));
      // The consumer's GSI is its allocator source plus that same base, so a
      // reader gets the source back with gsi - gsiBase.
      expect(soc.interruptAssignments()[uart], equals(1));
      expect(soc.interruptGsiBase, equals(0));
      expect(acpi, contains('0x1'));
    });

    test('a custom GSI base moves _GSB and the device GSIs together', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        interruptGsiBase: 0x40,
      );

      soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000));
      soc.addPeripheral(HarborUart(baseAddress: 0x10000000));

      final acpi = soc.generateAcpi();
      expect(acpi, contains('Return (0x40)'));
      expect(acpi, contains('0x41'));
      // The device tree keeps the raw source number. It has no GSI space.
      expect(soc.generateDts(), contains('interrupts = <0x1>;'));
    });

    test('respects a custom interrupt base', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        interruptBase: 32,
      );

      final uart = soc.addPeripheral(HarborUart(baseAddress: 0x10000000));
      expect(soc.interruptAssignments()[uart], equals(32));
    });

    test('generates Mermaid', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      soc.addPeripheral(HarborUart(baseAddress: 0x10000000));

      final mermaid = soc.generateMermaid();
      expect(mermaid, contains('flowchart TD'));
      expect(mermaid, contains('ns16550a'));
    });

    test('generates DOT', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      soc.addPeripheral(HarborPlic(baseAddress: 0x0C000000));

      final dot = soc.generateDot();
      expect(dot, contains('digraph'));
      expect(dot, contains('sifive,plic-1.0.0'));
    });

    test('validates address overlaps', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
      );

      // Two CLINTs at the same base overlap.
      soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
      soc.addPeripheral(HarborClint(baseAddress: 0x02000000, name: 'clint2'));

      expect(soc.validate(), isNotEmpty);
      expect(soc.buildFabric, throwsStateError);
    });

    group('validate', () {
      test('a consistent SoC reports no problems', () {
        final soc = HarborSoC(
          name: 'TestSoC',
          compatible: 'test,soc-v1',
          busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        );
        soc.addPeripheral(HarborClint(baseAddress: 0x02000000));
        soc.addPeripheral(HarborUart(baseAddress: 0x10000000));

        expect(soc.validate(), isEmpty);
      });

      test('flags a register that overflows its address block', () {
        final soc = HarborSoC(
          name: 'TestSoC',
          compatible: 'test,soc-v1',
          busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        );
        // Block is 0x1000, but the register ends at 0x1002.
        soc.addPeripheral(
          _RegMockPeripheral(
            const HarborDeviceRegisterMap(
              name: 'regmock',
              fields: [HarborDeviceField(name: 'big', width: 4, offset: 0xFFE)],
            ),
            0x1000,
          ),
        );

        final errors = soc.validate();
        expect(errors, hasLength(1));
        expect(errors.single, contains("register 'big'"));
        expect(errors.single, contains('exceeds address block size 0x1000'));
      });

      test('flags overlapping register fields', () {
        final soc = HarborSoC(
          name: 'TestSoC',
          compatible: 'test,soc-v1',
          busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        );
        soc.addPeripheral(
          _RegMockPeripheral(
            const HarborDeviceRegisterMap(
              name: 'regmock',
              fields: [
                HarborDeviceField(name: 'a', width: 4, offset: 0x0),
                HarborDeviceField(name: 'b', width: 4, offset: 0x2),
              ],
            ),
            0x1000,
          ),
        );

        final errors = soc.validate();
        expect(errors, hasLength(1));
        expect(errors.single, contains('REGMOCK:'));
        expect(errors.single, contains('Overlap'));
      });
    });

    test('target can be set', () {
      final soc = HarborSoC(
        name: 'TestSoC',
        compatible: 'test,soc-v1',
        busConfig: const WishboneConfig(addressWidth: 32, dataWidth: 32),
        target: const HarborFpgaTarget.ice40(
          device: 'up5k',
          package: 'sg48',
          frequency: 48000000,
          pinMap: {'clk': '35', 'uart_tx': '14'},
        ),
      );

      expect(soc.target, isA<HarborFpgaTarget>());
    });
  });

  group('HarborDeviceTarget', () {
    group('HarborFpgaTarget', () {
      test('ice40 generates PCF', () {
        const target = HarborFpgaTarget.ice40(
          device: 'up5k',
          package: 'sg48',
          pinMap: {'clk': '35', 'uart_tx': '14', 'uart_rx': '15'},
          frequency: 48000000,
        );

        final pcf = target.generateConstraints();
        expect(pcf, contains('set_io clk 35'));
        expect(pcf, contains('set_io uart_tx 14'));
        expect(pcf, contains('set_io uart_rx 15'));
      });

      test('ecp5 generates LPF', () {
        const target = HarborFpgaTarget.ecp5(
          device: 'lfe5u-45f',
          package: 'CABGA381',
          pinMap: {'clk': 'P3', 'led': 'B2'},
          frequency: 25000000,
        );

        final lpf = target.generateConstraints();
        expect(lpf, contains('LOCATE COMP "clk" SITE "P3"'));
        expect(lpf, contains('IOBUF PORT "clk" IO_TYPE=LVCMOS33'));
        expect(lpf, contains('FREQUENCY'));
      });

      test('spartan7 generates XDC', () {
        const target = HarborFpgaTarget.spartan7(
          device: 'xc7s50',
          package: 'ftgb196',
          pinMap: {'clk': 'L16', 'uart_tx': 'J18'},
          frequency: 100000000,
        );

        final xdc = target.generateConstraints();
        expect(xdc, contains('PACKAGE_PIN L16'));
        expect(xdc, contains('create_clock'));
        expect(xdc, contains('10.000')); // 100MHz = 10ns
      });

      test('openXC7 also generates XDC', () {
        const target = HarborFpgaTarget.spartan7(
          device: 'xc7s50',
          package: 'ftgb196',
          useOpenXc7: true,
        );

        expect(target.vendor, equals(HarborFpgaVendor.openXc7));
        expect(target.generateConstraints(), contains('XDC'));
      });
    });

    group('HarborAsicTarget', () {
      test('sky130 generates SDC', () {
        final target = HarborAsicTarget(
          provider: Sky130Provider(pdkRoot: '/pdk/sky130A'),
          topCell: 'MySoC',
          frequency: 50000000,
        );

        final sdc = target.generateSdc();
        expect(sdc, contains('create_clock'));
        expect(sdc, contains('20.000')); // 50MHz = 20ns
        expect(sdc, contains('set_input_delay'));
        expect(sdc, contains('set_output_delay'));
      });

      test('sky130 generates Yosys TCL', () {
        final target = HarborAsicTarget(
          provider: Sky130Provider(pdkRoot: '/pdk/sky130A'),
          topCell: 'MySoC',
        );

        final tcl = target.generateYosysTcl();
        expect(tcl, contains('synth -top MySoC'));
        expect(tcl, contains('sky130_fd_sc_hd'));
        expect(tcl, contains('dfflibmap'));
      });

      test('sky130 generates OpenROAD TCL', () {
        final target = HarborAsicTarget(
          provider: Sky130Provider(pdkRoot: '/pdk/sky130A'),
          topCell: 'MySoC',
        );

        final tcl = target.generateOpenroadTcl();
        expect(tcl, contains('read_liberty'));
        expect(tcl, contains('global_placement'));
        expect(tcl, contains('clock_tree_synthesis'));
        expect(tcl, contains('detailed_route'));
      });

      test('gf180mcu target', () {
        final target = HarborAsicTarget(
          provider: Gf180mcuProvider(pdkRoot: '/pdk/gf180mcuD'),
          topCell: 'MySoC',
        );

        expect(target.provider.name, contains('GF180MCU'));
        expect(target.provider.node, equals('180nm'));
      });

      test('PDK provides analog blocks', () {
        final pdk = Sky130Provider(pdkRoot: '/pdk/sky130A');
        final io = pdk.ioCell(index: 0);
        final pll = pdk.pll(index: 0);

        expect(io.pinMapping, contains('padIn'));
        expect(pll.pinMapping, contains('refClk'));
        expect(pdk.standardCellLibrary.name, contains('sky130'));
        expect(pdk.metalLayers, equals(5));
        expect(pdk.supplyVoltage, equals(1.8));
      });
    });

    test('sealed type exhaustiveness', () {
      const HarborDeviceTarget target = HarborFpgaTarget.ice40(
        device: 'up5k',
        package: 'sg48',
      );
      final result = switch (target) {
        HarborFpgaTarget() => 'fpga',
        HarborAsicTarget() => 'asic',
        HarborSimTarget() => 'sim',
      };
      expect(result, equals('fpga'));
      expect(switch (const HarborSimTarget() as HarborDeviceTarget) {
        HarborFpgaTarget() => 'fpga',
        HarborAsicTarget() => 'asic',
        HarborSimTarget() => 'sim',
      }, equals('sim'));
    });
  });
}

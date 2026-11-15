import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _MockSvdPeripheral with HarborSvdPeripheralProvider {
  @override
  final HarborSvdPeripheral svdPeripheral;
  _MockSvdPeripheral(this.svdPeripheral);
}

void main() {
  group('HarborSvdGenerator', () {
    test('generates a device header with vendor and version', () {
      final svd = HarborSvdGenerator(
        vendor: 'Lilith Semiconductor',
        name: 'Creek V1',
        version: '2.1',
        description: 'lilithsemi,creek-v1',
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imafdc', mmu: 'riscv,sv39')],
      ).generate();

      expect(svd, contains('<?xml version="1.0" encoding="utf-8"?>'));
      expect(svd, contains('<device schemaVersion="1.3"'));
      expect(svd, contains('<vendor>Lilith Semiconductor</vendor>'));
      // Name is sanitised into a valid identifier.
      expect(svd, contains('<name>Creek_V1</name>'));
      expect(svd, contains('<version>2.1</version>'));
      expect(svd, contains('<addressUnitBits>8</addressUnitBits>'));
      expect(svd, contains('<width>32</width>'));
      expect(svd, contains('</device>'));
    });

    test('emits a cpu block derived from the first hart', () {
      final svd = HarborSvdGenerator(
        vendor: 'Lilith Semiconductor',
        name: 'soc',
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imafdc', mmu: 'riscv,sv39')],
      ).generate();

      expect(svd, contains('<cpu>'));
      expect(svd, contains('<name>other</name>'));
      expect(svd, contains('<endian>little</endian>'));
      expect(svd, contains('<mpuPresent>true</mpuPresent>'));
      expect(svd, contains('<fpuPresent>true</fpuPresent>'));
    });

    test('omits the cpu block and fpu when there is no float extension', () {
      final svd = HarborSvdGenerator(
        vendor: 'Lilith Semiconductor',
        name: 'soc',
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imac')],
      ).generate();

      expect(svd, contains('<mpuPresent>false</mpuPresent>'));
      expect(svd, contains('<fpuPresent>false</fpuPresent>'));
    });

    test('renders a peripheral with an address block', () {
      final dev = _MockSvdPeripheral(
        const HarborSvdPeripheral(
          name: 'GPIO0',
          description: 'general purpose IO',
          baseAddress: 0x10060000,
          size: 0x1000,
          interrupts: [HarborSvdInterrupt(name: 'GPIO0', value: 7)],
        ),
      );

      final svd = HarborSvdGenerator(
        vendor: 'Lilith Semiconductor',
        name: 'soc',
        peripherals: [dev],
      ).generate();

      expect(svd, contains('<peripheral>'));
      expect(svd, contains('<name>GPIO0</name>'));
      expect(svd, contains('<baseAddress>0x10060000</baseAddress>'));
      expect(svd, contains('<size>0x1000</size>'));
      expect(svd, contains('<usage>registers</usage>'));
      expect(svd, contains('<interrupt>'));
      expect(svd, contains('<value>7</value>'));
    });

    test('maps register fields to SVD registers with access', () {
      final dev = _MockSvdPeripheral(
        const HarborSvdPeripheral(
          name: 'UART',
          baseAddress: 0x10000000,
          size: 0x1000,
          registers: StandardRegisters.uart16550,
        ),
      );

      final svd = HarborSvdGenerator(
        vendor: 'Lilith Semiconductor',
        name: 'soc',
        peripherals: [dev],
      ).generate();

      expect(svd, contains('<registers>'));
      expect(svd, contains('<name>rbr_thr_dll</name>'));
      expect(svd, contains('<addressOffset>0x0</addressOffset>'));
      expect(svd, contains('<size>8</size>'));
      // lcr has reset value 0x03.
      expect(svd, contains('<resetValue>0x3</resetValue>'));
      // lsr is read-only.
      expect(svd, contains('<access>read-only</access>'));
      expect(svd, contains('<access>read-write</access>'));
    });

    test('emits SoC-allocated interrupts named after the peripheral', () {
      final dev = _MockSvdPeripheral(
        const HarborSvdPeripheral(
          name: 'SPI0',
          baseAddress: 0x10040000,
          size: 0x1000,
        ),
      );

      final svd = HarborSvdGenerator(
        vendor: 'Lilith Semiconductor',
        name: 'soc',
        peripherals: [dev],
        interrupts: {
          dev: [5],
        },
      ).generate();

      expect(svd, contains('<interrupt>'));
      expect(svd, contains('<name>SPI0</name>'));
      expect(svd, contains('<value>5</value>'));
    });

    test('escapes XML special characters in descriptions', () {
      final dev = _MockSvdPeripheral(
        const HarborSvdPeripheral(
          name: 'X',
          description: 'a & b <c>',
          baseAddress: 0,
          size: 4,
        ),
      );

      final svd = HarborSvdGenerator(
        vendor: 'Lilith Semiconductor',
        name: 'soc',
        peripherals: [dev],
      ).generate();

      expect(svd, contains('a &amp; b &lt;c&gt;'));
    });
  });

  group('HarborSvdPeripheralProvider peripherals', () {
    test('UART exposes its register map', () {
      final uart = HarborUart(baseAddress: 0x10000000);
      final dev = uart.svdPeripheral;
      expect(dev.name, equals('UART'));
      expect(dev.baseAddress, equals(0x10000000));
      expect(dev.registers, isNotNull);
      expect(dev.registers!.fields, isNotEmpty);
    });

    group('HarborSoC model and manufacturer', () {
      tearDown(() async => Simulator.reset());

      test('defaults keep the name, compatible and vendor', () {
        final soc = HarborSoC(name: 'DefSoc', compatible: 'test,def');
        expect(soc.generateDts(), contains('model = "DefSoc";'));
        final svd = soc.generateSvd();
        expect(svd, contains('<vendor>Lilith Semiconductor</vendor>'));
        expect(svd, contains('<description>test,def</description>'));
      });

      test('model and manufacturer reach the DTS and SVD', () {
        final soc = HarborSoC(
          name: 'ModSoc',
          compatible: 'test,mod',
          model: 'Delta V1',
          manufacturer: 'Acme & Co',
          cpus: [
            HarborCpu(
              hartId: 0,
              isa: 'rv64imac',
              model: 'River RC1.f',
              compatible: ['lilith,river-rc1f'],
            ),
          ],
        );
        final dts = soc.generateDts();
        expect(dts, contains('    model = "Delta V1";'));
        expect(dts, contains('model = "River RC1.f";'));
        expect(dts, contains('compatible = "lilith,river-rc1f", "riscv";'));
        final svd = soc.generateSvd();
        expect(svd, contains('<vendor>Acme &amp; Co</vendor>'));
        expect(svd, contains('<description>Delta V1</description>'));
      });
    });
  });
}

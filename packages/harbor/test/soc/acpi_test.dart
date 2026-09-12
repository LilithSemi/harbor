import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

class _MockAcpiDevice with HarborAcpiDeviceProvider {
  @override
  final HarborAcpiDevice acpiDevice;
  _MockAcpiDevice(this.acpiDevice);
}

/// A peripheral that is both an ACPI device and an interrupt controller, the
/// shape the PLIC and the APLIC have.
class _MockIntc with HarborAcpiDeviceProvider, HarborDeviceTreeNodeProvider {
  @override
  final HarborAcpiDevice acpiDevice;

  @override
  final HarborDeviceTreeNode dtNode;

  _MockIntc(this.acpiDevice, this.dtNode);

  factory _MockIntc.plic({int base = 0xC000000, int size = 0x4000000}) =>
      _MockIntc(
        HarborAcpiDevice(
          hid: 'RSCV0001',
          memory: [BusAddressRange(base, size)],
        ),
        HarborDeviceTreeNode(
          compatible: const ['sifive,plic-1.0.0'],
          reg: BusAddressRange(base, size),
          interruptController: true,
          interruptCells: 1,
        ),
      );
}

void main() {
  group('HarborAcpiGenerator', () {
    test('generates a DSDT with CPUs and peripherals', () {
      final uart = _MockAcpiDevice(
        const HarborAcpiDevice(
          hid: 'HISI0031',
          cid: ['PNP0501'],
          uid: 0,
          memory: [BusAddressRange(0x10000000, 0x1000)],
          interrupts: [10],
          names: {'clock-frequency': 48000000},
        ),
      );

      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        cpus: [HarborCpu(hartId: 0, isa: 'rv64imac', mmu: 'riscv,sv39')],
        peripherals: [uart],
      ).generate();

      expect(asl, contains('DefinitionBlock'));
      expect(asl, contains('"DSDT"'));
      expect(asl, contains('"MDSTLL"'));
      expect(asl, contains('"CREEKV1"'));
      expect(asl, contains('Scope (\\_SB)'));

      // CPU as ACPI0007 processor device.
      expect(asl, contains('Device (C000)'));
      expect(asl, contains('Name (_HID, "ACPI0007")'));
      expect(asl, contains('"riscv,isa", "rv64imac"'));
      expect(asl, contains('"mmu-type", "riscv,sv39"'));
      expect(asl, contains('ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301")'));

      // Peripheral device.
      expect(asl, contains('Device (D000)'));
      expect(asl, contains('Name (_HID, "HISI0031")'));
      expect(asl, contains('Name (_CID, "PNP0501")'));
      expect(
        asl,
        contains('Memory32Fixed (ReadWrite, 0x10000000, 0x00001000)'),
      );
      expect(asl, contains('Interrupt (ResourceConsumer, Level, ActiveHigh'));
      expect(asl, contains('0xA'));
      expect(asl, contains('Name (CLOC, 0x2DC6C00)'));
    });

    test('uses QWordMemory for 64-bit ranges', () {
      final dev = _MockAcpiDevice(
        const HarborAcpiDevice(
          hid: 'MEMS0001',
          memory: [BusAddressRange(0x100000000, 0x40000000)],
        ),
      );

      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        peripherals: [dev],
      ).generate();

      expect(asl, contains('QWordMemory'));
      expect(asl, contains('0x0000000100000000, // Range Minimum'));
      expect(asl, contains('0x000000013FFFFFFF, // Range Maximum'));
      expect(asl, contains('0x0000000040000000, // Length'));
      expect(asl, isNot(contains('Memory32Fixed')));
    });

    test('emits multiple compatible IDs as a Package', () {
      final dev = _MockAcpiDevice(
        const HarborAcpiDevice(hid: 'ABCD0001', cid: ['PNP0501', 'PNP0500']),
      );

      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        peripherals: [dev],
      ).generate();

      expect(asl, contains('Name (_CID, Package () { "PNP0501", "PNP0500" })'));
    });

    test('generates a minimal table with no CPUs or peripherals', () {
      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
      ).generate();

      expect(asl, contains('DefinitionBlock'));
      expect(asl, contains('Scope (\\_SB)'));
      expect(asl, isNot(contains('Device (')));
    });

    test('handles multi-hart setups', () {
      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        cpus: [
          HarborCpu(hartId: 0, isa: 'rv64imac'),
          HarborCpu(hartId: 1, isa: 'rv64imac'),
        ],
      ).generate();

      expect(asl, contains('Device (C000)'));
      expect(asl, contains('Device (C001)'));
    });

    test('emits device properties as a _DSD package', () {
      final dev = _MockAcpiDevice(
        const HarborAcpiDevice(
          hid: 'PRP0001',
          memory: [BusAddressRange(0x10000000, 0x1000)],
          properties: {
            'compatible': ['harbor,gpio', 'sifive,gpio0'],
            'ngpios': 32,
            'gpio-controller': true,
          },
        ),
      );

      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        peripherals: [dev],
      ).generate();

      expect(asl, contains('Name (_HID, "PRP0001")'));
      expect(asl, contains('ToUUID ("daffd814-6eba-4d8c-8a91-bc9bbf4aa301")'));
      expect(
        asl,
        contains(
          'Package () { "compatible", Package () { "harbor,gpio", '
          '"sifive,gpio0" } }',
        ),
      );
      expect(asl, contains('Package () { "ngpios", 0x20 }'));
      expect(asl, contains('Package () { "gpio-controller", One }'));
    });
  });

  group('HarborAcpiDeviceProvider peripherals', () {
    test('UART exposes a native ACPI HID', () {
      final uart = HarborUart(
        baseAddress: 0x10000000,
        clockFrequency: 48000000,
      );
      final dev = uart.acpiDevice;
      expect(dev.hid, equals('PNP0501'));
      expect(dev.cid, contains('PNP0501'));
      expect(dev.memory.single.start, equals(0x10000000));
    });

    test('SRAM flows through the generator', () {
      final sram = HarborSram(
        baseAddress: 0x80000000,
        size: 0x10000,
        target: const HarborSimTarget(),
      );
      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        peripherals: [sram],
      ).generate();

      expect(asl, contains('Name (_HID, "PRP0001")'));
      expect(asl, contains('"compatible"'));
      expect(asl, contains('"harbor,sram"'));
    });
  });

  group('_GSB on the interrupt controller', () {
    test('the RSCV0001 PLIC gets a _GSB that returns the GSI base', () {
      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        peripherals: [_MockIntc.plic()],
      ).generate();

      expect(asl, contains('Name (_HID, "RSCV0001")'));
      expect(asl, contains('Method (_GSB, 0, NotSerialized)'));
      expect(asl, contains('Return (0x0)'));
    });

    test('_GSB follows the GSI base and so do the device GSIs', () {
      final uart = _MockAcpiDevice(
        const HarborAcpiDevice(
          hid: 'RSCV0003',
          memory: [BusAddressRange(0x10000000, 0x1000)],
        ),
      );

      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        peripherals: [_MockIntc.plic(), uart],
        interrupts: {
          uart: const [1],
        },
        gsiBase: 0x20,
      ).generate();

      // One base moves both the controller's _GSB and the consumer's GSI, so
      // the OS still reads source 1 back out of GSI 0x21.
      expect(asl, contains('Return (0x20)'));
      expect(asl, contains('0x21'));
    });

    test('a device that is not an interrupt controller gets no _GSB', () {
      final uart = _MockAcpiDevice(
        const HarborAcpiDevice(
          hid: 'RSCV0003',
          memory: [BusAddressRange(0x10000000, 0x1000)],
          interrupts: [1],
        ),
      );

      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        peripherals: [uart],
      ).generate();

      expect(asl, isNot(contains('_GSB')));
    });

    test('the real PLIC peripheral emits a _GSB', () {
      final plic = HarborPlic(baseAddress: 0xC000000, sources: 32, contexts: 2);
      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        peripherals: [plic],
      ).generate();

      expect(asl, contains('Name (_HID, "RSCV0001")'));
      expect(asl, contains('Method (_GSB, 0, NotSerialized)'));
      expect(asl, contains('Return (0x0)'));
    });

    test('the real APLIC peripheral emits a _GSB', () {
      final aplic = HarborAplic(baseAddress: 0xC000000, sources: 32, harts: 1);
      final asl = HarborAcpiGenerator(
        oemId: 'MDSTLL',
        oemTableId: 'CREEKV1',
        peripherals: [aplic],
      ).generate();

      expect(asl, contains('Name (_HID, "RSCV0002")'));
      expect(asl, contains('Method (_GSB, 0, NotSerialized)'));
      expect(asl, contains('Return (0x0)'));
    });
  });
}

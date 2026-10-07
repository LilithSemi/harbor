import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborDeviceField', () {
    test('basic properties', () {
      const field = HarborDeviceField(name: 'data', width: 4, offset: 0x100);
      expect(field.widthBits, equals(32));
      expect(field.end, equals(0x104));
      expect(field.contains(0x100), isTrue);
      expect(field.contains(0x103), isTrue);
      expect(field.contains(0x104), isFalse);
    });
  });

  group('HarborDeviceRegisterMap', () {
    test('field lookup', () {
      const map = HarborDeviceRegisterMap(
        name: 'test',
        fields: [
          HarborDeviceField(name: 'a', width: 4, offset: 0x00),
          HarborDeviceField(name: 'b', width: 4, offset: 0x04),
          HarborDeviceField(name: 'c', width: 4, offset: 0x08),
        ],
      );

      expect(map['a']?.offset, equals(0x00));
      expect(map['b']?.offset, equals(0x04));
      expect(map['nonexistent'], isNull);
      expect(map.fieldAt(0x04)?.name, equals('b'));
      expect(map.size, equals(0x0C));
    });

    test('validates overlaps', () {
      const map = HarborDeviceRegisterMap(
        name: 'bad',
        fields: [
          HarborDeviceField(name: 'a', width: 4, offset: 0x00),
          HarborDeviceField(name: 'b', width: 4, offset: 0x02),
        ],
      );
      expect(map.validate(), isNotEmpty);
    });

    test('standard UART register map', () {
      expect(StandardRegisters.uart16550.fields, hasLength(8));
      expect(StandardRegisters.uart16550['lcr']?.resetValue, equals(0x03));
      expect(StandardRegisters.uart16550['lsr']?.readOnly, isTrue);
    });

    test('standard CLINT register map', () {
      expect(StandardRegisters.clint['msip']?.offset, equals(0x0000));
      expect(StandardRegisters.clint['mtimecmp']?.offset, equals(0x4000));
      expect(StandardRegisters.clint['mtime']?.offset, equals(0xBFF8));
    });

    test('toPrettyString', () {
      final pretty = StandardRegisters.uart16550.toPrettyString();
      expect(pretty, contains('uart16550'));
      expect(pretty, contains('rbr_thr_dll'));
      expect(pretty, contains('RO')); // LSR
    });
  });

  group('HarborSram', () {
    test('creates with correct config', () {
      // Bigger than the generic register-per-word model holds, so it takes
      // a target: this checks the metadata, not the storage.
      final sram = HarborSram(
        baseAddress: 0x80000000,
        size: 64 * 1024,
        target: const HarborSimTarget(),
      );
      expect(sram.bus, isNotNull);
      final dt = sram.dtNode;
      expect(dt.compatible.first, equals('harbor,sram'));
      expect(dt.reg.start, equals(0x80000000));
      expect(dt.reg.size, equals(64 * 1024));
    });
  });

  group('HarborFlash', () {
    test('creates with correct config', () {
      final flash = HarborFlash(baseAddress: 0x00000000, size: 256 * 1024);
      expect(flash.bus, isNotNull);
      final dt = flash.dtNode;
      expect(dt.compatible.first, equals('harbor,flash'));
      expect(dt.reg.size, equals(256 * 1024));
    });
  });

  group('HarborMaskRom', () {
    test('creates with initial data', () {
      final rom = HarborMaskRom(
        baseAddress: 0x00000000,
        initialData: [0x00000297, 0x02028593, 0x0005a583, 0x00058067],
      );
      expect(rom.bus, isNotNull);
      expect(rom.size, equals(16)); // 4 words * 4 bytes
      final dt = rom.dtNode;
      expect(dt.compatible.first, equals('harbor,maskrom'));
      expect(dt.reg.size, equals(16));
      expect(dt.properties['depth'], equals(4));
    });

    test('single word rom', () {
      final rom = HarborMaskRom(
        baseAddress: 0x10000,
        initialData: [0xDEADBEEF],
      );
      expect(rom.size, equals(4));
    });
  });

  group('HarborDdrConfig', () {
    test('OrangeCrab preset', () {
      const config = HarborDdrConfig.orangeCrab();
      expect(config.type, equals(HarborDdrType.ddr3));
      expect(config.size, equals(128 * 1024 * 1024));
      expect(config.dataWidth, equals(16));
      expect(config.frequencyMhz, closeTo(400, 1));
    });

    test('Arty S7 preset', () {
      const config = HarborDdrConfig.artyS7();
      expect(config.type, equals(HarborDdrType.ddr3l));
      expect(config.size, equals(256 * 1024 * 1024));
      expect(config.dataRate, equals(666666666));
    });

    test('bandwidth calculation', () {
      const config = HarborDdrConfig(
        type: HarborDdrType.ddr3,
        size: 128 * 1024 * 1024,
        dataWidth: 16,
        frequency: 400000000,
      );
      // 800 MT/s * 2 bytes = 1600 MB/s
      expect(config.bandwidthMBs, closeTo(1600, 1));
    });

    test('toPrettyString', () {
      const config = HarborDdrConfig.orangeCrab();
      final pretty = config.toPrettyString();
      expect(pretty, contains('ddr3'));
      expect(pretty, contains('128 MB'));
      expect(pretty, contains('400 MHz'));
    });
  });

  group('HarborDdr3', () {
    test('creates with correct config', () {
      final ddr = HarborDdr3(
        config: const HarborDdrConfig.orangeCrab(),
        baseAddress: 0x40000000,
        clockHz: 48000000,
      );
      expect(ddr.bus, isNotNull);
      final dt = ddr.dtNode;
      expect(dt.compatible.first, equals('harbor,sdram-controller'));
      expect(dt.compatible, contains('harbor,ddr3-sdram'));
      expect(dt.reg.size, equals(128 * 1024 * 1024));
      expect(dt.properties['sdram-type'], equals('ddr3'));
    });
  });
}

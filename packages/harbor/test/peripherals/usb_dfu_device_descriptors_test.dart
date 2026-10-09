import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

// HarborUsbDfu.dfuDescriptors() derives wTotalLength from the actual
// CONFIGURATION bytes it builds. These tests check that field against the
// real byte count for both includeFlashAlt values, and that every other
// byte stays the same as before the fix.

List<int> _configBytes(List<UsbDescriptorEntry> descs) =>
    descs.firstWhere((d) => d.type == 0x02).bytes;

void main() {
  group('HarborUsbDfu.dfuDescriptors', () {
    test('wTotalLength matches the byte count, flash alt included', () {
      final config = _configBytes(HarborUsbDfu.dfuDescriptors());
      final wTotalLength = config[2] | (config[3] << 8);
      expect(wTotalLength, equals(config.length));
      expect(wTotalLength, equals(36));
    });

    test('wTotalLength matches the byte count, flash alt dropped', () {
      final config = _configBytes(
        HarborUsbDfu.dfuDescriptors(includeFlashAlt: false),
      );
      final wTotalLength = config[2] | (config[3] << 8);
      expect(wTotalLength, equals(config.length));
      expect(wTotalLength, equals(27));
    });

    test('descriptor bytes are unchanged, flash alt included', () {
      final config = _configBytes(HarborUsbDfu.dfuDescriptors());
      expect(
        config,
        equals(<int>[
          // Configuration header.
          9, 0x02, 0x24, 0x00, 1, 1, 0, 0x80, 50,
          // Interface, alt setting 0 (RAM).
          9, 0x04, 0, 0, 0, 0xFE, 0x01, 0x02, 4,
          // Interface, alt setting 1 (SPI flash).
          9, 0x04, 0, 1, 0, 0xFE, 0x01, 0x02, 5,
          // DFU functional descriptor.
          9,
          0x21,
          0x05,
          0xFF,
          0x00,
          HarborUsbDfu.transferSize,
          0x00,
          0x10,
          0x01,
        ]),
      );
    });

    test('descriptor bytes are unchanged, flash alt dropped', () {
      final config = _configBytes(
        HarborUsbDfu.dfuDescriptors(includeFlashAlt: false),
      );
      expect(
        config,
        equals(<int>[
          // Configuration header.
          9, 0x02, 0x1B, 0x00, 1, 1, 0, 0x80, 50,
          // Interface, alt setting 0 (RAM).
          9, 0x04, 0, 0, 0, 0xFE, 0x01, 0x02, 4,
          // DFU functional descriptor.
          9,
          0x21,
          0x05,
          0xFF,
          0x00,
          HarborUsbDfu.transferSize,
          0x00,
          0x10,
          0x01,
        ]),
      );
    });
  });
}

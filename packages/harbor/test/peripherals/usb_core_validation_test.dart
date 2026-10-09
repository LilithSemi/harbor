import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

import 'usb_core_harness.dart';

void main() {
  const device = UsbDescriptorEntry(0x01, 0, devDesc);
  const config = UsbDescriptorEntry(0x02, 0, cfgDesc);

  group('HarborUsbCore construction checks', () {
    test('maxPacketSize must be 8, 16, 32 or 64', () {
      expect(
        () => HarborUsbCore(descriptors: [device, config], maxPacketSize: 48),
        throwsArgumentError,
      );
    });

    test('bMaxPacketSize0 must equal maxPacketSize', () {
      expect(
        () => HarborUsbCore(descriptors: [device, config], maxPacketSize: 32),
        throwsArgumentError,
      );
    });

    test('a DEVICE descriptor is needed', () {
      expect(() => HarborUsbCore(descriptors: [config]), throwsArgumentError);
    });

    test('endpoint counts must fit a 4-bit endpoint number', () {
      expect(
        () => HarborUsbCore(descriptors: [device, config], numOutEps: 16),
        throwsArgumentError,
      );
      expect(
        () => HarborUsbCore(descriptors: [device, config], numInEps: -1),
        throwsArgumentError,
      );
    });

    test('a descriptor above 255 bytes is an ArgumentError', () {
      final big = [9, 0x02, 300 & 0xFF, 300 >> 8, ...List.filled(296, 0)];
      expect(
        () => HarborUsbCore(
          descriptors: [device, UsbDescriptorEntry(0x02, 0, big)],
        ),
        throwsArgumentError,
      );
    });
  });
}

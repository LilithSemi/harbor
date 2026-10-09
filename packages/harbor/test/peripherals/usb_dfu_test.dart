import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Independent re-derivation of the descriptor byte tables FROM the field
// tables (USB 2.0 ch9 + DFU 1.1). These are built by hand here rather than
// imported from the module, so a transcription error in the module is caught.

// Little-endian 16-bit helper.
List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

// UTF-16LE encode an ASCII string (each char + 0x00).
List<int> _utf16le(String s) {
  final out = <int>[];
  for (final u in s.codeUnits) {
    out.add(u & 0xFF);
    out.add((u >> 8) & 0xFF);
  }
  return out;
}

// DEVICE descriptor, 18 bytes.
final List<int> expectedDevice = [
  18, // bLength
  0x01, // bDescriptorType
  ..._le16(0x0200), // bcdUSB
  0, // bDeviceClass
  0, // bDeviceSubClass
  0, // bDeviceProtocol
  64, // bMaxPacketSize0
  ..._le16(0x1209), // idVendor
  ..._le16(0x5BF1), // idProduct
  ..._le16(0x0100), // bcdDevice
  1, // iManufacturer
  2, // iProduct
  0, // iSerialNumber
  1, // bNumConfigurations
];

// CONFIGURATION tree, 36 bytes.
final List<int> expectedConfigHeader = [
  9,
  0x02,
  ..._le16(36),
  1,
  1,
  0,
  0x80,
  50,
];
final List<int> expectedIfaceAlt0 = [9, 0x04, 0, 0, 0, 0xFE, 0x01, 0x02, 4];
final List<int> expectedIfaceAlt1 = [9, 0x04, 0, 1, 0, 0xFE, 0x01, 0x02, 5];
final List<int> expectedDfuFunctional = [
  9,
  0x21,
  0x05,
  ..._le16(0x00FF),
  ..._le16(64),
  ..._le16(0x0110),
];
final List<int> expectedConfig = [
  ...expectedConfigHeader,
  ...expectedIfaceAlt0,
  ...expectedIfaceAlt1,
  ...expectedDfuFunctional,
];

// STRING descriptors.
final List<int> expectedStr0 = [4, 0x03, ..._le16(0x0409)];
List<int> _expectedString(String s) => [2 + 2 * s.length, 0x03, ..._utf16le(s)];

// A 31-character string gives a 64-byte STRING descriptor, an exact
// multiple of the EP0 max packet size, so a GET_DESCRIPTOR for it needs a
// terminating ZLP.
const String _zlpTestString = 'River DFU 64-byte ZLP test desc';

// The DFU set plus that 64-byte descriptor at STRING index 6.
List<UsbDescriptorEntry> _dfuWithZlpString() => [
  ...HarborUsbDfu.dfuDescriptors(),
  UsbDescriptorEntry(0x03, 6, usbStringDescriptor(_zlpTestString)),
];

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // Reads the full descriptor from the ROM for a given (type, index): walks
  // offset 0..length-1 and returns the assembled bytes plus present/length.
  Future<Map<String, dynamic>> readDescriptor(
    int type,
    int index, {
    List<UsbDescriptorEntry>? descriptors,
  }) async {
    final dut = UsbDescriptorRom(
      descriptors: descriptors ?? HarborUsbDfu.dfuDescriptors(),
      name:
          'rom_${type}_${index}_'
          '${DateTime.now().microsecondsSinceEpoch & 0xFFFFFF}',
    );
    final descType = Logic(name: 'desc_type', width: 8);
    final descIndex = Logic(name: 'desc_index', width: 8);
    final offset = Logic(name: 'offset', width: 8);

    dut.input('desc_type').srcConnection! <= descType;
    dut.input('desc_index').srcConnection! <= descIndex;
    dut.input('offset').srcConnection! <= offset;

    await dut.build();

    final clk = SimpleClockGenerator(10).clk;
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());

    descType.inject(type);
    descIndex.inject(index);
    offset.inject(0);
    await clk.nextPosedge;

    final present = dut.output('present').value.toInt();
    final length = dut.output('length').value.toInt();

    final bytes = <int>[];
    for (var o = 0; o < length; o++) {
      offset.inject(o);
      await clk.nextPosedge;
      bytes.add(dut.output('data').value.toInt());
    }
    // Also read one byte past the end to confirm out-of-range reads as 0.
    offset.inject(length);
    await clk.nextPosedge;
    final pastEnd = dut.output('data').value.toInt();

    await Simulator.endSimulation();

    return {
      'present': present,
      'length': length,
      'bytes': bytes,
      'pastEnd': pastEnd,
    };
  }

  group('UsbDescriptorRom', () {
    test('module is purely combinational (no clk/reset port)', () async {
      final dut = UsbDescriptorRom(
        descriptors: HarborUsbDfu.dfuDescriptors(),
        name: 'rom_comb',
      );
      // A pure-combinational ROM exposes only the data ports.
      expect(dut.tryInput('clk'), isNull, reason: 'no clk port');
      expect(dut.tryInput('reset'), isNull, reason: 'no reset port');
      expect(dut.tryInput('desc_type'), isNotNull);
      expect(dut.tryInput('desc_index'), isNotNull);
      expect(dut.tryInput('offset'), isNotNull);
    });

    test('DEVICE descriptor: present, length 18, byte-for-byte', () async {
      final r = await readDescriptor(0x01, 0);
      expect(r['present'], equals(1), reason: 'device descriptor present');
      expect(r['length'], equals(18), reason: 'device length 18');
      expect(
        expectedDevice.length,
        equals(18),
        reason: 'sanity: re-derived device is 18 bytes',
      );
      final bytes = r['bytes'] as List<int>;
      for (var i = 0; i < 18; i++) {
        expect(bytes[i], equals(expectedDevice[i]), reason: 'device byte[$i]');
      }
      expect(r['pastEnd'], equals(0), reason: 'out-of-range data is 0');

      // Explicit VID/PID LE field checks at their device-descriptor offsets.
      expect(bytes[7], equals(64), reason: 'bMaxPacketSize0 at offset 7');
      // idVendor at offsets 8..9 = 0x1209 LE => 0x09, 0x12.
      expect(bytes[8], equals(0x09), reason: 'idVendor LE low');
      expect(bytes[9], equals(0x12), reason: 'idVendor LE high');
      expect(
        bytes[8] | (bytes[9] << 8),
        equals(0x1209),
        reason: 'VID 0x1209 LE',
      );
      // idProduct at offsets 10..11 = 0x5BF1 LE => 0xF1, 0x5B.
      expect(bytes[10], equals(0xF1), reason: 'idProduct LE low');
      expect(bytes[11], equals(0x5B), reason: 'idProduct LE high');
      expect(
        bytes[10] | (bytes[11] << 8),
        equals(0x5BF1),
        reason: 'PID 0x5BF1 LE',
      );
    });

    test(
      'CONFIGURATION descriptor: length 36, key offsets, sub-lengths sum',
      () async {
        final r = await readDescriptor(0x02, 0);
        expect(r['present'], equals(1), reason: 'config present');
        expect(r['length'], equals(36), reason: 'config length 36');
        final bytes = r['bytes'] as List<int>;
        expect(bytes.length, equals(36));

        // Full byte-for-byte against the independent re-derivation.
        for (var i = 0; i < 36; i++) {
          expect(
            bytes[i],
            equals(expectedConfig[i]),
            reason: 'config byte[$i]',
          );
        }

        // Config header.
        expect(bytes[0], equals(9), reason: 'config header bLength 9');
        expect(bytes[1], equals(0x02), reason: 'config descriptor type');
        expect(
          bytes[2] | (bytes[3] << 8),
          equals(36),
          reason: 'wTotalLength 36 (LE)',
        );

        // Interface alt0 begins at offset 9.
        expect(bytes[9 + 1], equals(0x04), reason: 'alt0 INTERFACE type');
        expect(bytes[9 + 3], equals(0), reason: 'alt0 bAlternateSetting 0');
        expect(bytes[9 + 5], equals(0xFE), reason: 'alt0 bInterfaceClass 0xFE');
        expect(
          bytes[9 + 6],
          equals(0x01),
          reason: 'alt0 bInterfaceSubClass 0x01',
        );
        expect(
          bytes[9 + 7],
          equals(0x02),
          reason: 'alt0 bInterfaceProtocol 0x02',
        );

        // Interface alt1 begins at offset 18.
        expect(bytes[18 + 1], equals(0x04), reason: 'alt1 INTERFACE type');
        expect(bytes[18 + 3], equals(1), reason: 'alt1 bAlternateSetting 1');

        // DFU functional descriptor begins at offset 27.
        expect(bytes[27 + 0], equals(9), reason: 'DFU func bLength 9');
        expect(
          bytes[27 + 1],
          equals(0x21),
          reason: 'DFU functional descriptor type 0x21',
        );
        expect(bytes[27 + 2], equals(0x05), reason: 'DFU bmAttributes 0x05');
        // wTransferSize at DFU offset 5..6 = 64 (LE).
        expect(
          bytes[27 + 5] | (bytes[27 + 6] << 8),
          equals(64),
          reason: 'DFU wTransferSize 64 (LE)',
        );

        // The three sub-descriptors (after the 9-byte header) plus header sum.
        expect(
          expectedConfigHeader.length +
              expectedIfaceAlt0.length +
              expectedIfaceAlt1.length +
              expectedDfuFunctional.length,
          equals(36),
          reason: 'header(9)+alt0(9)+alt1(9)+dfu(9) = 36',
        );
      },
    );

    test('STRING 0 (LANGID): length 4, bytes [4,3,0x09,0x04]', () async {
      final r = await readDescriptor(0x03, 0);
      expect(r['present'], equals(1));
      expect(r['length'], equals(4));
      expect(
        r['bytes'],
        equals([4, 0x03, 0x09, 0x04]),
        reason: 'LANGID descriptor bytes',
      );
      expect(r['bytes'], equals(expectedStr0));
    });

    test('STRING 1 (Manufacturer "River"): length 12, UTF-16LE', () async {
      final r = await readDescriptor(0x03, 1);
      expect(r['present'], equals(1));
      expect(r['length'], equals(12), reason: '2 + 2*5 = 12');
      final bytes = r['bytes'] as List<int>;
      expect(bytes, equals(_expectedString('River')));
      expect(bytes[0], equals(12), reason: 'bLength');
      expect(bytes[1], equals(0x03), reason: 'STRING type');
      // "River" UTF-16LE: R(0x52),0, i(0x69),0, v(0x76),0, ...
      expect(bytes[2], equals(0x52), reason: "'R' low byte");
      expect(bytes[3], equals(0x00), reason: "'R' high byte");
      expect(bytes[4], equals(0x69), reason: "'i' low byte");
      expect(bytes[5], equals(0x00), reason: "'i' high byte");
    });

    test('STRING 2 (Product "River DFU"): length 20', () async {
      final r = await readDescriptor(0x03, 2);
      expect(r['present'], equals(1));
      expect(r['length'], equals(20), reason: '2 + 2*9 = 20');
      expect(r['bytes'], equals(_expectedString('River DFU')));
    });

    test('STRING 4 (Interface alt0 "RAM"): length 8', () async {
      final r = await readDescriptor(0x03, 4);
      expect(r['present'], equals(1));
      expect(r['length'], equals(8), reason: '2 + 2*3 = 8');
      expect(r['bytes'], equals(_expectedString('RAM')));
    });

    test('STRING 5 (Interface alt1 "SPI flash"): length 20', () async {
      final r = await readDescriptor(0x03, 5);
      expect(r['present'], equals(1));
      expect(r['length'], equals(20), reason: '2 + 2*9 = 20');
      expect(r['bytes'], equals(_expectedString('SPI flash')));
    });

    test('STRING 6 (64-byte ZLP test string): length 64', () async {
      final r = await readDescriptor(0x03, 6, descriptors: _dfuWithZlpString());
      expect(r['present'], equals(1));
      expect(r['length'], equals(64));
      expect(r['bytes'], equals(_expectedString(_zlpTestString)));
    });

    test('a descriptor above 255 bytes is an ArgumentError', () {
      // A CONFIGURATION descriptor whose wTotalLength is right, so only the
      // size limit can reject it.
      final big = [9, 0x02, 300 & 0xFF, 300 >> 8, ...List.filled(296, 0)];
      expect(
        () => UsbDescriptorRom(
          descriptors: [UsbDescriptorEntry(0x02, 0, big)],
          name: 'rom_big',
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('limit is 255'),
          ),
        ),
      );
    });

    test('STRING 3 not present', () async {
      final r = await readDescriptor(0x03, 3);
      expect(r['present'], equals(0), reason: 'string index 3 absent');
      expect(r['length'], equals(0), reason: 'absent length 0');
    });

    test('unknown descriptor type (0x05): not present', () async {
      final r = await readDescriptor(0x05, 0);
      expect(r['present'], equals(0));
      expect(r['length'], equals(0));
      expect(r['pastEnd'], equals(0), reason: 'data 0 for unknown');
    });

    test('out-of-range offset reads 0 for a known descriptor', () async {
      final dut = UsbDescriptorRom(
        descriptors: HarborUsbDfu.dfuDescriptors(),
        name: 'rom_oob',
      );
      final descType = Logic(name: 'desc_type', width: 8);
      final descIndex = Logic(name: 'desc_index', width: 8);
      final offset = Logic(name: 'offset', width: 8);
      dut.input('desc_type').srcConnection! <= descType;
      dut.input('desc_index').srcConnection! <= descIndex;
      dut.input('offset').srcConnection! <= offset;
      await dut.build();

      final clk = SimpleClockGenerator(10).clk;
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());

      descType.inject(0x01); // DEVICE
      descIndex.inject(0);
      offset.inject(18); // exactly one past the last valid byte
      await clk.nextPosedge;
      expect(
        dut.output('data').value.toInt(),
        equals(0),
        reason: 'offset == length reads 0',
      );
      offset.inject(200);
      await clk.nextPosedge;
      expect(
        dut.output('data').value.toInt(),
        equals(0),
        reason: 'far out-of-range reads 0',
      );

      await Simulator.endSimulation();
    });
  });
}

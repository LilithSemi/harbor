/// Ethernet frame helpers and vectors for tests.
library;

/// Reference CRC32 of [bytes]: init 0xFFFFFFFF, reflected, final inversion.
int ethCrc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b & 0xFF;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return ~crc & 0xFFFFFFFF;
}

/// The FCS of [frame] as it goes on the wire, low byte first.
List<int> ethFcsBytes(List<int> frame) {
  final fcs = ethCrc32(frame);
  return [for (var i = 0; i < 4; i++) (fcs >> (8 * i)) & 0xFF];
}

/// A 60-byte broadcast ARP request without FCS.
final List<int> ethArpRequest = [
  ...List.filled(6, 0xFF),
  0x02,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x01,
  0x08,
  0x00,
  0x06,
  0x04,
  0x00,
  0x01,
  0x02,
  0x00,
  0x00,
  0x00,
  0x00,
  0x01,
  192,
  168,
  0,
  1,
  ...List.filled(6, 0),
  192,
  168,
  0,
  2,
  ...List.filled(18, 0),
];

/// FCS of [ethArpRequest] from Python `zlib.crc32`.
const int ethArpRequestFcs = 0x40888DAD;

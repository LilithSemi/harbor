import 'package:rohd/rohd.dart';

/// One byte step of the Ethernet CRC32, polynomial 0xEDB88320 reflected.
///
/// Returns the next 32-bit CRC state with no inversion. The caller loads
/// 0xFFFFFFFF before the first byte and inverts the state after the last
/// byte to get the FCS. The FCS goes on the wire low byte first.
Logic harborEthCrcByte(Logic crc32, Logic byte) {
  assert(crc32.width == 32, 'crc32 must be 32 bits');
  assert(byte.width == 8, 'byte must be 8 bits');
  var c = crc32 ^ byte.zeroExtend(32);
  for (var i = 0; i < 8; i++) {
    final shifted = [Const(0), c.slice(31, 1)].swizzle();
    c = mux(c[0], shifted ^ Const(0xEDB88320, width: 32), shifted);
  }
  return c;
}

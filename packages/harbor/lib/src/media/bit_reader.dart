import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 `f(n)` bitstream reader, the descriptor that header parsing rides
/// on.
///
/// AV1 uncompressed headers (sequence/frame headers, tile info) are read with
/// `f(n)`: take the next `n` bits MSB-first from the byte stream, not
/// byte-aligned. This module reads `f(n)` at an arbitrary bit offset into a
/// fixed byte window and reports the advanced offset, so a header parser chains
/// reads by feeding `next_offset` back in.
///
/// `bytes` packs the window LSB-first (byte 0 at bit 0), but the stream is
/// big-endian within and across bytes (byte 0 bit 7 is stream bit 0), so the
/// module assembles a big-endian vector internally. `n` is 0..32. `value` holds
/// the `n`-bit field right-aligned (top bits zero). Combinational.
class HarborBitReader extends BridgeModule {
  HarborBitReader({int maxBytes = 16, String? name})
    : super('HarborBitReader_B$maxBytes', name: name ?? 'bit_reader') {
    final totalBits = maxBytes * 8;
    final offW = (totalBits).bitLength; // enough to index every bit + end

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('bit_offset', PortDirection.input, width: offW);
    createPort('n', PortDirection.input, width: 6); // 0..32
    addOutput('value', width: 32);
    addOutput('next_offset', width: offW);

    final bytes = input('bytes');
    Logic byte(int i) => bytes.getRange(i * 8, i * 8 + 8);

    // Big-endian stream vector: byte 0 is the most-significant byte, so stream
    // bit (totalBits-1) is byte0 bit7 = AV1 stream bit 0.
    final stream = [for (var i = 0; i < maxBytes; i++) byte(i)].swizzle();

    final off = input('bit_offset');
    final n = input('n');

    // Shift the desired field up to the top, then take the high 32 bits as the
    // peek window (MSB-first), zero-filled past the end.
    final window = (stream << off.zeroExtend(totalBits)).getRange(
      totalBits - 32,
      totalBits,
    );
    // Right-align the top n bits: value = window >> (32 - n).
    final shift = (Const(32, width: 7) - n.zeroExtend(7)).getRange(0, 7);
    output('value') <= (window.zeroExtend(64) >>> shift).getRange(0, 32);
    output('next_offset') <= (off + n.zeroExtend(offW)).getRange(0, offW);
  }
}

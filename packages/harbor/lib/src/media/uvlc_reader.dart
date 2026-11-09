import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 `uvlc()` reader (unsigned variable-length / Exp-Golomb).
///
/// Many AV1 header fields use `uvlc()`: count the leading zero bits, read a 1,
/// then read that many value bits. `value = (1 << leadingZeros) - 1 + f(lz)`,
/// consuming `2*leadingZeros + 1` bits. A run of >= 32 leading zeros saturates
/// to `2^32 - 1`. This module decodes one `uvlc()` at an arbitrary bit offset
/// and reports `next_offset`, matching [HarborBitReader]'s stream conventions
/// (bytes packed LSB-first, big-endian within/across bytes).
class HarborUvlcReader extends BridgeModule {
  HarborUvlcReader({int maxBytes = 16, String? name})
    : super('HarborUvlcReader', name: name ?? 'uvlc_reader') {
    final totalBits = maxBytes * 8;
    final offW = totalBits.bitLength;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('bit_offset', PortDirection.input, width: offW);
    addOutput('value', width: 32);
    addOutput('next_offset', width: offW);

    final bytes = input('bytes');
    Logic byte(int i) => bytes.getRange(i * 8, i * 8 + 8);
    final stream = [for (var i = 0; i < maxBytes; i++) byte(i)].concat();

    final off = input('bit_offset');
    final shifted = (stream << off.zeroExtend(totalBits)).getRange(
      0,
      totalBits,
    );

    // Count leading zeros over the top 32 bits (cap at 32).
    Logic lz = Const(32, width: 6);
    Logic found = Const(0, width: 1);
    for (var k = 0; k < 32; k++) {
      final bit = shifted[totalBits - 1 - k];
      final hit = (~found & bit).getRange(0, 1);
      lz = mux(hit, Const(k, width: 6), lz);
      found = (found | bit).getRange(0, 1);
    }

    // Suffix = f(lz) starting just past the terminating 1 (offset + lz + 1).
    final sufOff =
        ((off + lz.zeroExtend(offW)).getRange(0, offW) + Const(1, width: offW))
            .getRange(0, offW);
    final sufWindow = (stream << sufOff.zeroExtend(totalBits)).getRange(
      totalBits - 32,
      totalBits,
    );
    final rsh = (Const(32, width: 7) - lz.zeroExtend(7)).getRange(0, 7);
    final suffix = (sufWindow.zeroExtend(64) >>> rsh).getRange(0, 32);

    // value = (1 << lz) - 1 + suffix, saturating when lz >= 32.
    final base =
        ((Const(1, width: 40) << lz.zeroExtend(40)).getRange(0, 40) -
                Const(1, width: 40))
            .getRange(0, 40);
    final valNorm = (base + suffix.zeroExtend(40)).getRange(0, 32);
    final capped = lz.gte(Const(32, width: 6));
    output('value') <= mux(capped, Const(0xFFFFFFFF, width: 32), valNorm);

    // Consumed = 2*lz + 1.
    final consumed =
        ((lz.zeroExtend(offW) << 1).getRange(0, offW) + Const(1, width: offW))
            .getRange(0, offW);
    output('next_offset') <= (off + consumed).getRange(0, offW);
  }
}

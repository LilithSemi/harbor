import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'cdef_direction.dart';
import 'cdef_filter.dart';
import 'cdef_filter_sentinel.dart';

/// Harbor CDEF block filter: the full Constrained Directional Enhancement Filter
/// over an 8x8 block.
///
/// Combines the two CDEF halves: [HarborCdefDirection] finds the block's edge
/// direction from its central 8x8, and [HarborCdefFilter] then filters each of
/// the 64 pixels along that direction. The input is a 12x12 padded region (the
/// 8x8 block plus a 2-pixel border, so every pixel's 5x5 neighbourhood is in
/// range). The output is the filtered 8x8. Combinational (one direction unit and
/// 64 filter units with fixed wiring).
///
/// `padded` packs the 12x12 LSB-first (pixel (r,c) at bit (r*12+c)*W, W bits
/// per sample). The block occupies rows/cols 2..9. `out` packs the 8x8 (pixel
/// (r,c) at bit (r*8+c)*8). For luma the primary strength is scaled by the
/// block's directional variance (libaom `adjust_strength`) and the direction is
/// gated on the original strength. The per-pixel filter applies the [min, max]
/// clip. The block's raw direction is exposed on `dir` so a caller can reuse it
/// for a co-located chroma block (libaom shares the luma direction).
///
/// When [sentinel] is false (the default) samples are 8 bits and the border is
/// assumed to be real pixels (interior-block case). When [sentinel] is true the
/// samples widen to 15 bits so a caller can mark out-of-frame border pixels with
/// CDEF_VERY_LARGE (0x4000): the direction search still reads the always-in-frame
/// central 8x8 (low 8 bits) and the per-pixel core switches to
/// [HarborCdefFilterSentinel], giving the exact frame-edge behaviour.
class HarborCdefBlock extends BridgeModule {
  /// When [luma] (the default), the primary strength is scaled by the block's
  /// directional variance via libaom `adjust_strength`. Chroma planes pass the
  /// strength through unchanged ([luma] = false). When [sentinel] is set the
  /// padded input carries 15-bit samples with CDEF_VERY_LARGE frame-edge
  /// markers and the sentinel-aware per-pixel core is used.
  HarborCdefBlock({
    bool luma = true,
    bool sentinel = false,
    int bd = 8,
    String? name,
  }) : super(
         'HarborCdefBlock_B${bd}_L${luma ? 1 : 0}_S${sentinel ? 1 : 0}',
         name: name ?? 'cdef_block',
       ) {
    // Non-sentinel (interior) samples widen to [bd] bits. Sentinel samples stay
    // 15 bits (they must also hold CDEF_VERY_LARGE = 0x4000).
    final int sampleW = sentinel ? 15 : bd;
    createPort('padded', PortDirection.input, width: 12 * 12 * sampleW);
    createPort('pri', PortDirection.input, width: 8);
    createPort('sec', PortDirection.input, width: 8);
    createPort('pri_damp', PortDirection.input, width: 8);
    createPort('sec_damp', PortDirection.input, width: 8);
    addOutput('out', width: 8 * 8 * bd);
    addOutput('dir', width: 3);

    Logic pad(int r, int c) => input(
      'padded',
    ).getRange((r * 12 + c) * sampleW, (r * 12 + c) * sampleW + sampleW);

    // Direction search on the central 8x8 (padded rows/cols 2..9). The central
    // block is always in-frame (samples 0..255), so the low 8 bits carry the
    // pixel value even in sentinel mode.
    final dirUnit = HarborCdefDirection(name: 'dir', bd: bd);
    addSubModule(dirUnit);
    dirUnit.input('block').srcConnection! <=
        [
          for (var r = 7; r >= 0; r--)
            for (var c = 7; c >= 0; c--) pad(r + 2, c + 2).getRange(0, bd),
        ].swizzle();
    final rawDir = dirUnit.output('dir');
    final variance = dirUnit.output('variance');

    final priIn = input('pri');
    final sec = input('sec');
    final priDamp = input('pri_damp');
    final secDamp = input('sec_damp');

    // adjust_strength(strength, var) for luma:
    //   i = (var>>6) ? min(getMsb(var>>6), 12) : 0
    //   t = var ? (strength*(4+i)+8) >> 4 : 0
    Logic adjusted() {
      final v6 = variance.getRange(6, 24); // var >> 6 (18 bits)
      // getMsb: index of the highest set bit (0 when v6 == 0).
      Logic msb = Const(0, width: 4);
      for (var b = 1; b < 18; b++) {
        msb = mux(v6[b], Const(b < 12 ? b : 12, width: 4), msb);
      }
      final i = mux(v6.or(), msb, Const(0, width: 4)); // (var>>6)!=0 ? msb : 0
      final factor = (i.zeroExtend(8) + Const(4, width: 8)).getRange(0, 8);
      final prod = (priIn.zeroExtend(20) * factor.zeroExtend(20)).getRange(
        0,
        20,
      );
      final t = (prod + Const(8, width: 20)).getRange(4, 20); // >> 4
      return mux(variance.or(), t.getRange(0, 8), Const(0, width: 8));
    }

    // Effective primary strength fed to the filters. dir is gated on the
    // ORIGINAL strength (libaom: dir = priStrength != 0 ? dr.dir : 0).
    final pri = luma ? adjusted() : priIn;
    final dir = mux(priIn.or(), rawDir, Const(0, width: 3));
    output('dir') <= rawDir;

    // One filter per output pixel. Each sees a fixed 5x5 from the padded region.
    final outPx = <Logic>[];
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        final nb = [
          for (var dr = 4; dr >= 0; dr--)
            for (var dc = 4; dc >= 0; dc--) pad(r + dr, c + dc),
        ].swizzle();
        final Logic fout;
        if (sentinel) {
          final f = HarborCdefFilterSentinel(name: 'flt_${r}_$c', bd: bd);
          addSubModule(f);
          f.input('nb').srcConnection! <= nb;
          f.input('dir').srcConnection! <= dir;
          f.input('pri').srcConnection! <= pri;
          f.input('sec').srcConnection! <= sec;
          f.input('pri_damp').srcConnection! <= priDamp;
          f.input('sec_damp').srcConnection! <= secDamp;
          fout = f.output('out');
        } else {
          final f = HarborCdefFilter(name: 'flt_${r}_$c', bd: bd);
          addSubModule(f);
          f.input('nb').srcConnection! <= nb;
          f.input('dir').srcConnection! <= dir;
          f.input('pri').srcConnection! <= pri;
          f.input('sec').srcConnection! <= sec;
          f.input('pri_damp').srcConnection! <= priDamp;
          f.input('sec_damp').srcConnection! <= secDamp;
          fout = f.output('out');
        }
        outPx.add(fout);
      }
    }
    // outPx is row-major (r*8+c). Pack LSB-first.
    output('out') <= outPx.reversed.toList().swizzle();
  }
}

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 `FILTER_INTRA` recursive intra predictor (libaom
/// `av1_filter_intra_predictor`), bd8. Combinational.
///
/// A buffer `buf[bh+1][bw+1]` is seeded with the left column (`buf[r+1][0]`) and the
/// above row plus the above-left corner (`buf[0][c]`). The predictor then scans
/// `4x2` patches left-to-right, top-to-bottom: for each patch it reads seven
/// taps `p0..p6` from already-filled buffer cells and writes eight new cells
/// `buf[r..r+1][c..c+3]`. Because later patches read cells written by earlier
/// patches, the recursion is a strict scan-order dependency that is unrolled
/// combinationally here: every `buf` cell is a [Logic] computed from cells
/// produced earlier in the same scan order.
///
/// Each output cell is `clipPixel(roundPow2(sum_j taps[mode][k][j]*p_j, 4))`
/// where taps are signed (`_filterIntraScaleBits = 4`).
///
/// Ports:
///   `above` (`(bw+1)*8`): the above-left corner followed by `bw` above samples,
///     LSB-first. Index 0 is the corner (`buf[0][0]`), index `c+1` is `buf[0][c+1]`.
///   `left`  (`bh*8`): the `bh` left samples, LSB-first. Index `r` is `buf[r+1][0]`.
///   `mode`  (3b): filter-intra mode `0..4`, taps are muxed by this value.
///   `pred`  (`bw*bh*8`): output, `dst[r*bw+c]` packed at index `r*bw+c`, LSB-first.
///
/// `bw` must be a multiple of 4 and `bh` a multiple of 2 (the patch step is
/// `4x2`), both positive. Filter-intra is defined for blocks up to `32x32`.
class HarborFilterIntra extends BridgeModule {
  /// av1_filter_intra_taps[5][8][7] from libaom.
  static const List<List<List<int>>> _taps = [
    [
      [-6, 10, 0, 0, 0, 12, 0],
      [-5, 2, 10, 0, 0, 9, 0],
      [-3, 1, 1, 10, 0, 7, 0],
      [-3, 1, 1, 2, 10, 5, 0],
      [-4, 6, 0, 0, 0, 2, 12],
      [-3, 2, 6, 0, 0, 2, 9],
      [-3, 2, 2, 6, 0, 2, 7],
      [-3, 1, 2, 2, 6, 3, 5],
    ],
    [
      [-10, 16, 0, 0, 0, 10, 0],
      [-6, 0, 16, 0, 0, 6, 0],
      [-4, 0, 0, 16, 0, 4, 0],
      [-2, 0, 0, 0, 16, 2, 0],
      [-10, 16, 0, 0, 0, 0, 10],
      [-6, 0, 16, 0, 0, 0, 6],
      [-4, 0, 0, 16, 0, 0, 4],
      [-2, 0, 0, 0, 16, 0, 2],
    ],
    [
      [-8, 8, 0, 0, 0, 16, 0],
      [-8, 0, 8, 0, 0, 16, 0],
      [-8, 0, 0, 8, 0, 16, 0],
      [-8, 0, 0, 0, 8, 16, 0],
      [-4, 4, 0, 0, 0, 0, 16],
      [-4, 0, 4, 0, 0, 0, 16],
      [-4, 0, 0, 4, 0, 0, 16],
      [-4, 0, 0, 0, 4, 0, 16],
    ],
    [
      [-2, 8, 0, 0, 0, 10, 0],
      [-1, 3, 8, 0, 0, 6, 0],
      [-1, 2, 3, 8, 0, 4, 0],
      [0, 1, 2, 3, 8, 2, 0],
      [-1, 4, 0, 0, 0, 3, 10],
      [-1, 3, 4, 0, 0, 4, 6],
      [-1, 2, 3, 4, 0, 4, 4],
      [-1, 2, 2, 3, 4, 3, 3],
    ],
    [
      [-12, 14, 0, 0, 0, 14, 0],
      [-10, 0, 14, 0, 0, 12, 0],
      [-9, 0, 0, 14, 0, 11, 0],
      [-8, 0, 0, 0, 14, 10, 0],
      [-10, 12, 0, 0, 0, 0, 14],
      [-9, 1, 12, 0, 0, 0, 12],
      [-8, 0, 0, 12, 0, 1, 11],
      [-7, 0, 0, 1, 12, 1, 9],
    ],
  ];

  static const int _scaleBits = 4;

  /// Working width for the signed accumulator/products. Max |tap|=16, max
  /// sample=255, seven products: |sum| <= 16*255*7 = 28560 (< 2^15), so 24-bit
  /// signed leaves generous headroom for the round add and sign handling.
  static const int _w = 24;

  HarborFilterIntra({int bw = 8, int bh = 8, String? name})
    : super('HarborFilterIntra_${bw}x$bh', name: name ?? 'filter_intra') {
    if (bw <= 0 || bw % 4 != 0) {
      throw ArgumentError(
        'HarborFilterIntra.bw must be a positive multiple of '
        '4, got $bw',
      );
    }
    if (bh <= 0 || bh % 2 != 0) {
      throw ArgumentError(
        'HarborFilterIntra.bh must be a positive multiple of '
        '2, got $bh',
      );
    }

    createPort('above', PortDirection.input, width: (bw + 1) * 8);
    createPort('left', PortDirection.input, width: bh * 8);
    createPort('mode', PortDirection.input, width: 3);
    addOutput('pred', width: bw * bh * 8);

    final above = input('above');
    final left = input('left');
    final mode = input('mode');

    Logic aboveAt(int i) => above.getRange(i * 8, i * 8 + 8);
    Logic leftAt(int i) => left.getRange(i * 8, i * 8 + 8);

    // Signed two's-complement tap constant at the working width, muxed by mode.
    Logic tapConst(int k, int j) {
      Logic asConst(int m) {
        final v = _taps[m][k][j];
        final tc = v < 0 ? (BigInt.one << _w) + BigInt.from(v) : BigInt.from(v);
        return Const(tc, width: _w);
      }

      Logic t = asConst(0);
      for (var m = 1; m < 5; m++) {
        t = mux(mode.eq(m), asConst(m), t);
      }
      return t;
    }

    // buf grid: bh+1 rows by bw+1 cols. Seed col 0 with left, row 0 with above
    // (above index 0 is the corner buf[0][0]).
    final buf = [
      for (var r = 0; r < bh + 1; r++)
        List<Logic?>.filled(bw + 1, null, growable: false),
    ];
    for (var c = 0; c < bw + 1; c++) {
      buf[0][c] = aboveAt(c);
    }
    for (var r = 0; r < bh; r++) {
      buf[r + 1][0] = leftAt(r);
    }

    // roundPow2(pr, 4) then clipPixel, returning an 8-bit unsigned cell. pr is
    // a signed value at width _w.
    Logic roundClip(Logic pr) {
      // roundPow2: (pr + 8) arithmetic-shift-right by 4 (signed).
      final added = (pr + Const(8, width: _w)).getRange(0, _w);
      final shifted = [
        added[_w - 1].replicate(_scaleBits),
        added.getRange(_scaleBits, _w),
      ].swizzle();
      // clipPixel: negative -> 0, >255 -> 255, else low 8 bits.
      final neg = shifted[_w - 1];
      final gt255 = shifted.gt(Const(255, width: _w));
      final low8 = shifted.getRange(0, 8);
      return mux(
        neg,
        Const(0, width: 8),
        mux(gt255, Const(255, width: 8), low8),
      );
    }

    // Scan 4x2 patches in source order so later patches read earlier writes.
    for (var r = 1; r < bh + 1; r += 2) {
      for (var c = 1; c < bw + 1; c += 4) {
        final p = <Logic>[
          buf[r - 1][c - 1]!,
          buf[r - 1][c]!,
          buf[r - 1][c + 1]!,
          buf[r - 1][c + 2]!,
          buf[r - 1][c + 3]!,
          buf[r][c - 1]!,
          buf[r + 1][c - 1]!,
        ];
        for (var k = 0; k < 8; k++) {
          final rOff = k >> 2;
          final cOff = k & 3;
          // pr = sum_j taps[mode][k][j] * p_j, signed at width _w.
          Logic pr = Const(0, width: _w);
          for (var j = 0; j < 7; j++) {
            final prod = (tapConst(k, j) * p[j].zeroExtend(_w)).getRange(0, _w);
            pr = (pr + prod).getRange(0, _w);
          }
          buf[r + rOff][c + cOff] = roundClip(pr);
        }
      }
    }

    // dst[r*bw+c] = buf[r+1][c+1], packed LSB-first.
    final parts = <Logic>[];
    for (var r = 0; r < bh; r++) {
      for (var c = 0; c < bw; c++) {
        parts.add(buf[r + 1][c + 1]!);
      }
    }
    output('pred') <= parts.reversed.toList().swizzle();
  }
}

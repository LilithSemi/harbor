import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor CDEF (Constrained Directional Enhancement Filter) per-pixel core.
///
/// CDEF is AV1's second in-loop filter (after deblocking): along a detected edge
/// direction it nudges each pixel toward its neighbours, but only by a
/// *constrained* amount so true edges are preserved. This module filters one
/// pixel given its 5x5 neighbourhood (centre = the pixel), the direction
/// `dir` (0..7), the primary/secondary strengths and dampings. It implements
/// libaom's `constrain` and the primary (2 taps along `dir`) + secondary (2 taps
/// along `dir`+/-2) accumulation exactly:
///   sum += tap * (constrain(p - x, str, damp) + constrain(q - x, str, damp))
///   y    = x + ((8 + sum - (sum<0)) >> 4)
/// where constrain(d, t, damp) = sign(d) * min(|d|, max(0, t - (|d| >> shift))),
/// shift = max(0, damp - floor(log2 t)), and 0 when t == 0. When both primary
/// and secondary are enabled (pri != 0 and sec != 0) the output is clamped to
/// the [min, max] of the centre and tap pixels (libaom `clipping_required`).
/// Otherwise it is the low 8 bits of `y` (lowbd store).
///
/// `nb` packs the 5x5 LSB-first (row-major, pixel (r,c) at bit (r*5+c)*8). The
/// 8-bit interface carries no CDEF_VERY_LARGE border sentinels, so this is the
/// interior-pixel filter. Frame-edge sentinel padding is handled by the caller.
class HarborCdefFilter extends BridgeModule {
  /// [bd] is the sample bit-depth (8/10/12), `coeffShift = bd - 8`. Pixels are
  /// [bd] bits wide and the primary tap set is selected by bit `coeffShift` of
  /// `pri` (libaom `cdef_pri_taps[(pri_strength >> coeff_shift) & 1]`).
  HarborCdefFilter({int bd = 8, String? name})
    : super('HarborCdefFilter_B$bd', name: name ?? 'cdef') {
    final int coeffShift = bd - 8;
    const w = 24; // signed working width

    createPort('nb', PortDirection.input, width: 5 * 5 * bd); // 5x5 pixels
    createPort('dir', PortDirection.input, width: 3);
    createPort('pri', PortDirection.input, width: 8);
    createPort('sec', PortDirection.input, width: 8);
    createPort('pri_damp', PortDirection.input, width: 8);
    createPort('sec_damp', PortDirection.input, width: 8);
    addOutput('out', width: bd);

    // Cdef_Directions[8][2] = (dy, dx) for the two taps of each direction.
    const dirs = [
      [
        [-1, 1],
        [-2, 2],
      ],
      [
        [0, 1],
        [-1, 2],
      ],
      [
        [0, 1],
        [0, 2],
      ],
      [
        [0, 1],
        [1, 2],
      ],
      [
        [1, 1],
        [2, 2],
      ],
      [
        [1, 0],
        [2, 1],
      ],
      [
        [1, 0],
        [2, 0],
      ],
      [
        [1, 0],
        [2, -1],
      ],
    ];
    const priTaps = [
      [4, 2],
      [3, 3],
    ]; // by (pri & 1), [near, far]
    const secTaps = [2, 1];

    Logic nbAt(int r, int c) =>
        input('nb').getRange((r * 5 + c) * bd, (r * 5 + c) * bd + bd);
    final cur = nbAt(2, 2);
    final dir = input('dir');

    Logic selByDir(List<Logic> perDir, Logic d) {
      Logic v = perDir.last;
      for (var i = 6; i >= 0; i--) {
        v = mux(d.eq(Const(i, width: 3)), perDir[i], v);
      }
      return v;
    }

    // The pixel at the tap offset for tap `k`, sign `s` (+1 forward, -1 back),
    // selected by direction `d`.
    Logic tapPixel(Logic d, int k, int s) => selByDir([
      for (var dd = 0; dd < 8; dd++)
        nbAt(2 + s * dirs[dd][k][0], 2 + s * dirs[dd][k][1]),
    ], d);

    // floor(log2(t)) for an 8-bit t (>= 1), 0 for t == 0.
    Logic msb8(Logic t) {
      Logic m = Const(0, width: 4);
      for (var i = 1; i < 8; i++) {
        m = mux(t[i], Const(i, width: 4), m);
      }
      return m;
    }

    // constrain(diff, thr, damp), diff is a w-bit signed value.
    Logic constrain(Logic diff, Logic thr, Logic damp) {
      final isZero = thr.eq(Const(0, width: 8));
      // shift = max(0, damp - floor(log2 thr)), capped at 31.
      final shiftRaw = (damp - msb8(thr).zeroExtend(8)).getRange(0, 8);
      final shiftPos = mux(shiftRaw[7], Const(0, width: 8), shiftRaw);
      final shift = mux(
        shiftPos.gt(Const(31, width: 8)),
        Const(31, width: 5),
        shiftPos.getRange(0, 5),
      );
      final neg = diff[w - 1];
      final ad = mux(
        neg,
        (Const(0, width: w) - diff).getRange(0, w),
        diff,
      ).getRange(0, w); // |diff|
      final adShift = (ad >>> shift).getRange(0, w);
      final innerRaw = (thr.zeroExtend(w) - adShift).getRange(0, w);
      final inner = mux(
        innerRaw[w - 1],
        Const(0, width: w),
        innerRaw,
      ); // max(0)
      final mag = mux(ad.lt(inner), ad, inner); // min(|diff|, inner)
      final signed = mux(neg, (Const(0, width: w) - mag).getRange(0, w), mag);
      return mux(isZero, Const(0, width: w), signed);
    }

    Logic diffOf(Logic p) =>
        (p.zeroExtend(w) - cur.zeroExtend(w)).getRange(0, w);

    final pri = input('pri');
    final sec = input('sec');
    final priDamp = input('pri_damp');
    final secDamp = input('sec_damp');
    final secDir1 = (dir + Const(2, width: 3)).getRange(0, 3);
    final secDir2 = (dir + Const(6, width: 3)).getRange(0, 3);

    // clippingRequired = enablePrimary && enableSecondary, where the caller
    // passes the already-adjusted strengths, so enable == (strength != 0).
    final clip = pri.or() & sec.or();

    Logic acc = Const(0, width: w);
    // The tap pixels feed both the sum and the (min, max) clamp window.
    final taps = <Logic>[];
    // Primary taps.
    for (var k = 0; k < 2; k++) {
      final tap = mux(
        pri[coeffShift],
        Const(priTaps[1][k], width: w),
        Const(priTaps[0][k], width: w),
      );
      final p = tapPixel(dir, k, 1), q = tapPixel(dir, k, -1);
      taps
        ..add(p)
        ..add(q);
      final c =
          (constrain(diffOf(p), pri, priDamp) +
                  constrain(diffOf(q), pri, priDamp))
              .getRange(0, w);
      acc = (acc + (tap * c).getRange(0, w)).getRange(0, w);
    }
    // Secondary taps (two directions at +/- 2).
    for (var k = 0; k < 2; k++) {
      final tap = Const(secTaps[k], width: w);
      for (final sd in [secDir1, secDir2]) {
        final p = tapPixel(sd, k, 1), q = tapPixel(sd, k, -1);
        taps
          ..add(p)
          ..add(q);
        final c =
            (constrain(diffOf(p), sec, secDamp) +
                    constrain(diffOf(q), sec, secDamp))
                .getRange(0, w);
        acc = (acc + (tap * c).getRange(0, w)).getRange(0, w);
      }
    }

    // minV / maxV over the centre pixel and every tap (no VERY_LARGE sentinels
    // in this 8-bit interior interface, so plain unsigned min/max).
    var minV = cur, maxV = cur;
    for (final tp in taps) {
      minV = mux(tp.lt(minV), tp, minV);
      maxV = mux(tp.gt(maxV), tp, maxV);
    }

    // out = cur + ((8 + sum - (sum < 0)) >> 4).
    final sneg = acc[w - 1];
    final rounded = (acc + Const(8, width: w) - sneg.zeroExtend(w)).getRange(
      0,
      w,
    );
    final shifted = [
      rounded[w - 1].replicate(4),
      rounded.getRange(4, w),
    ].swizzle();
    final outVal = (cur.zeroExtend(w) + shifted).getRange(0, w);

    // clippingRequired -> clamp(out, minV, maxV), else lowbd store = out & 0xff.
    final ltMin = (outVal - minV.zeroExtend(w)).getRange(0, w)[w - 1];
    final gtMax = (maxV.zeroExtend(w) - outVal).getRange(0, w)[w - 1];
    final clamped = mux(ltMin, minV, mux(gtMax, maxV, outVal.getRange(0, bd)));
    output('out') <= mux(clip, clamped, outVal.getRange(0, bd));
  }
}

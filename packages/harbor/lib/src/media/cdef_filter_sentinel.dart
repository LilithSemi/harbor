import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor CDEF per-pixel core with CDEF_VERY_LARGE frame-edge sentinel handling.
///
/// Sentinel-aware sibling of `HarborCdefFilter`. CDEF reads each pixel's 5x5
/// neighbourhood, but at the frame border some tap neighbours lie outside the
/// frame. libaom marks those samples with CDEF_VERY_LARGE (0x4000) so their
/// constrain contribution is zero and they are excluded from the [min, max]
/// clip window. The 8-bit interior core cannot represent 0x4000, so this module
/// widens every sample to 15 bits and carries a per-tap valid mask.
///
/// Datapath is identical to `HarborCdefFilter` (constrain + primary/secondary
/// tap accumulation + rounding + clip), plus two additions:
///   - per tap valid = (sample != CDEF_VERY_LARGE). The constrain term is
///     mux(valid, constrain(..), 0). Gating to 0 is bit-identical to libaom,
///     whose constrain arithmetic already returns 0 for a huge diff.
///   - min/max seed from the always-valid centre and fold a tap only when
///     valid. 0x4000 can never lower the min (centre and in-frame taps are
///     <= 255), so gating both folds is bit-identical.
///
/// `nb` packs the 5x5 LSB-first, 15 bits per sample (pixel (r,c) at bit
/// (r*5+c)*15). In-frame samples are 0..255, out-of-frame samples are 0x4000.
/// The centre (2,2) is always in-frame. `out` is the filtered pixel.
class HarborCdefFilterSentinel extends BridgeModule {
  /// [bd] is the sample bit-depth (8/10/12). `coeffShift = bd - 8`. The sample
  /// width stays 15 bits (holds both `CDEF_VERY_LARGE = 0x4000` and any bd<=12
  /// pixel, since 4095 < 16384). Only the primary-tap selector bit
  /// (`pri[coeffShift]`) and the stored-pixel width (`out` = [bd] bits) depend
  /// on the bit-depth.
  HarborCdefFilterSentinel({int bd = 8, String? name})
    : super('HarborCdefFilterSentinel_B$bd', name: name ?? 'cdef_sentinel') {
    final int coeffShift = bd - 8;
    const sw = 15; // sample width (so 0x4000 is representable)
    const w = 24; // signed working width

    createPort('nb', PortDirection.input, width: 5 * 5 * sw); // 5x5 pixels
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

    final veryLarge = Const(0x4000, width: sw);

    Logic nbAt(int r, int c) =>
        input('nb').getRange((r * 5 + c) * sw, (r * 5 + c) * sw + sw);
    // The centre is always in-frame (0..255) and never equals the sentinel.
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

    // constrain(diff, thr, damp). diff is a w-bit signed value.
    Logic constrain(Logic diff, Logic thr, Logic damp) {
      final isZero = thr.eq(Const(0, width: 8));
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
    Logic validOf(Logic p) => p.neq(veryLarge);

    final pri = input('pri');
    final sec = input('sec');
    final priDamp = input('pri_damp');
    final secDamp = input('sec_damp');
    final secDir1 = (dir + Const(2, width: 3)).getRange(0, 3);
    final secDir2 = (dir + Const(6, width: 3)).getRange(0, 3);

    final clip = pri.or() & sec.or();

    Logic acc = Const(0, width: w);
    // Each tap carries its sample and a valid flag for the min/max fold.
    final taps = <(Logic, Logic)>[];

    // Primary taps.
    for (var k = 0; k < 2; k++) {
      final tap = mux(
        pri[coeffShift],
        Const(priTaps[1][k], width: w),
        Const(priTaps[0][k], width: w),
      );
      final p = tapPixel(dir, k, 1), q = tapPixel(dir, k, -1);
      final pv = validOf(p), qv = validOf(q);
      taps
        ..add((p, pv))
        ..add((q, qv));
      // Gate each constrain term to 0 when its tap is out-of-frame.
      final cp = mux(
        pv,
        constrain(diffOf(p), pri, priDamp),
        Const(0, width: w),
      );
      final cq = mux(
        qv,
        constrain(diffOf(q), pri, priDamp),
        Const(0, width: w),
      );
      final c = (cp + cq).getRange(0, w);
      acc = (acc + (tap * c).getRange(0, w)).getRange(0, w);
    }
    // Secondary taps (two directions at +/- 2).
    for (var k = 0; k < 2; k++) {
      final tap = Const(secTaps[k], width: w);
      for (final sd in [secDir1, secDir2]) {
        final p = tapPixel(sd, k, 1), q = tapPixel(sd, k, -1);
        final pv = validOf(p), qv = validOf(q);
        taps
          ..add((p, pv))
          ..add((q, qv));
        final cp = mux(
          pv,
          constrain(diffOf(p), sec, secDamp),
          Const(0, width: w),
        );
        final cq = mux(
          qv,
          constrain(diffOf(q), sec, secDamp),
          Const(0, width: w),
        );
        final c = (cp + cq).getRange(0, w);
        acc = (acc + (tap * c).getRange(0, w)).getRange(0, w);
      }
    }

    // minV / maxV seed from the (always-valid) centre and fold each tap only
    // when valid. 15-bit unsigned compares (sentinel taps are excluded).
    var minV = cur, maxV = cur;
    for (final (tp, tv) in taps) {
      minV = mux(tv & tp.lt(minV), tp, minV);
      maxV = mux(tv & tp.gt(maxV), tp, maxV);
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
    final clamped = mux(
      ltMin,
      minV.getRange(0, bd),
      mux(gtMax, maxV.getRange(0, bd), outVal.getRange(0, bd)),
    );
    output('out') <= mux(clip, clamped, outVal.getRange(0, bd));
  }
}

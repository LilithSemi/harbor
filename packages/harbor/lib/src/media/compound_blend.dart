import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 inter compound prediction blend, bd8. The pixel-level
/// combine that merges two inter predictions into the final 8-bit block,
/// matching libaom's distance-weighted average and masked blend.
///
/// Inputs `src0`/`src1` are the two predictions as 16-bit CONV_BUF d16 values:
/// each is `roundOffset(6144) + (signed prediction in the DIST domain)`, the
/// pre-combine intermediate produced by `_compoundConvolve` (libaom
/// av1_dist_wtd_convolve, round_0=3, round_1=7). For bd8 these stay within a
/// ~16-bit unsigned band centred on 6144, and the realistic sweep is `[0, 16383]`.
///
/// The combine is selected by `mode`:
///   mode==0: COMPOUND_AVERAGE / COMPOUND_DISTWTD.
///            `use_dist_wtd==0` -> `tmp = (src0 + src1) >> 1`
///            `use_dist_wtd==1` -> `tmp = (src0*fwd + src1*bck) >> 4`
///   mode==1: masked blend (av1_lowbd_blend_a64_d16_mask), per-pixel mask
///            `m` (0..64): `tmp = (m*src0 + (64-m)*src1) >> 6`.
/// Then for every mode: `tmp -= 6144`, then `out = clip255((tmp + 8) >> 4)`.
///
/// `fwd`/`bck` are the 5-bit dist-weight offsets (av1 LUT entries, each <= 13,
/// average uses {8,8}). The per-pixel mask `m` is 7-bit because its alpha range
/// is 0..64 (64 does not fit in 6 bits), supplied at luma resolution (sx=sy=0,
/// chroma subsampling of the mask is done upstream). All array ports pack pixel
/// `(i,j)` row-major LSB-first at index `i*width + j`. Combinational.
class HarborCompoundBlend extends BridgeModule {
  HarborCompoundBlend({int width = 8, int height = 8, String? name})
    : super('HarborCompoundBlend', name: name ?? 'compound_blend') {
    final n = width * height;

    createPort('src0', PortDirection.input, width: n * 16);
    createPort('src1', PortDirection.input, width: n * 16);
    createPort('mask', PortDirection.input, width: n * 7);
    createPort('fwd', PortDirection.input, width: 5);
    createPort('bck', PortDirection.input, width: 5);
    createPort('use_dist_wtd', PortDirection.input, width: 1);
    createPort('mode', PortDirection.input, width: 2);
    addOutput('out', width: n * 8);

    // Working width: m*src0 + (64-m)*src1 <= 64*16383 < 2^20. With sign and the
    // roundOffset subtraction (signed) w=28 leaves ample headroom.
    const w = 28;
    const roundOffset = 6144;

    final src0In = input('src0');
    final src1In = input('src1');
    final maskIn = input('mask');
    final fwd = input('fwd').zeroExtend(w);
    final bck = input('bck').zeroExtend(w);
    final useDistWtd = input('use_dist_wtd');
    final mode = input('mode');

    Logic s0(int k) => src0In.getRange(k * 16, k * 16 + 16).zeroExtend(w);
    Logic s1(int k) => src1In.getRange(k * 16, k * 16 + 16).zeroExtend(w);
    Logic mk(int k) => maskIn.getRange(k * 7, k * 7 + 7).zeroExtend(w);

    // Logical right shift by [s] bits of a non-negative value at width w.
    Logic lshr(Logic x, int s) =>
        [Const(0, width: s), x.getRange(s, w)].concat();
    // Arithmetic right shift by [s] bits at width w (sign-extends MSB).
    Logic ashr(Logic x, int s) =>
        [x[w - 1].replicate(s), x.getRange(s, w)].concat();

    final parts = <Logic>[];
    for (var k = 0; k < n; k++) {
      final a = s0(k), b = s1(k), m = mk(k);

      // mode 0, average: (src0 + src1) >> 1.
      final avg = lshr((a + b).getRange(0, w), 1);
      // mode 0, dist-wtd: (src0*fwd + src1*bck) >> 4.
      final distWtd = lshr(
        ((a * fwd).getRange(0, w) + (b * bck).getRange(0, w)).getRange(0, w),
        4,
      );
      final mode0 = mux(useDistWtd, distWtd, avg);

      // mode 1, masked: (m*src0 + (64-m)*src1) >> 6.
      final inv = (Const(64, width: w) - m).getRange(0, w);
      final masked = lshr(
        ((m * a).getRange(0, w) + (inv * b).getRange(0, w)).getRange(0, w),
        6,
      );

      final tmp = mux(mode[0], masked, mode0);

      // Common tail: tmp -= 6144, then out = clip255((tmp + 8) >> 4).
      final off = (tmp - Const(roundOffset, width: w)).getRange(0, w);
      final rounded = (off + Const(1 << (4 - 1), width: w)).getRange(0, w);
      final shifted = ashr(rounded, 4);
      // clip to [0,255]: negative (MSB set) -> 0, > 255 -> 255.
      final neg = shifted[w - 1];
      final gt255 = shifted.gt(Const(255, width: w));
      final clipped = mux(
        neg,
        Const(0, width: 8),
        mux(gt255, Const(255, width: 8), shifted.getRange(0, 8)),
      );
      parts.add(clipped);
    }

    output('out') <= parts.reversed.toList().concat();
  }
}

/// Harbor bit-exact AV1 compound DIFFWTD mask generator, bd8. Matches libaom
/// av1_build_compound_diffwtd_mask_d16 (DIFFWTD_38 / _38_INV).
///
/// From two 16-bit CONV_BUF d16 predictions it derives the per-pixel mask:
///   `diff = |src0 - src1|`
///   `diff = (diff + 8) >> 4`               (round = 2*7-3-7 = 4)
///   `m = clamp(38 + (diff >> 4), 0, 64)`   (mask_base 38, DIFF_FACTOR 16)
///   `mask = type ? 64 - m : m`
/// `src0`/`src1` pack pixel `(i,j)` row-major LSB-first (16b each). `mask`
/// packs the result the same way (7b each, alpha 0..64). The 7-bit output
/// feeds directly into [HarborCompoundBlend]'s `mask` port. Combinational.
class HarborDiffwtdMask extends BridgeModule {
  HarborDiffwtdMask({int width = 8, int height = 8, String? name})
    : super('HarborDiffwtdMask', name: name ?? 'diffwtd_mask') {
    final n = width * height;

    createPort('src0', PortDirection.input, width: n * 16);
    createPort('src1', PortDirection.input, width: n * 16);
    createPort('inv_type', PortDirection.input, width: 1);
    addOutput('mask', width: n * 7);

    // |src0 - src1| <= 16383 fits in 15b. Keep a safe signed working width.
    const w = 20;

    final src0In = input('src0');
    final src1In = input('src1');
    final type = input('inv_type');

    Logic s0(int k) => src0In.getRange(k * 16, k * 16 + 16).zeroExtend(w);
    Logic s1(int k) => src1In.getRange(k * 16, k * 16 + 16).zeroExtend(w);

    // Logical right shift by [s] of a non-negative value at width w.
    Logic lshr(Logic x, int s) =>
        [Const(0, width: s), x.getRange(s, w)].concat();

    final parts = <Logic>[];
    for (var k = 0; k < n; k++) {
      final a = s0(k), b = s1(k);
      // Signed difference, then absolute value via two's-complement negate.
      final diffSigned = (a - b).getRange(0, w);
      final neg = diffSigned[w - 1];
      final absDiff = mux(
        neg,
        (Const(0, width: w) - diffSigned).getRange(0, w),
        diffSigned,
      );
      // (diff + 8) >> 4, non-negative.
      final rd = lshr(
        (absDiff + Const(1 << (4 - 1), width: w)).getRange(0, w),
        4,
      );
      // 38 + (diff >> 4).
      final dd = lshr(rd, 4);
      final mRaw = (dd + Const(38, width: w)).getRange(0, w);
      // clamp to [0,64]. mRaw >= 38 so only the upper clamp can fire.
      final gt64 = mRaw.gt(Const(64, width: w));
      final m = mux(gt64, Const(64, width: 7), mRaw.getRange(0, 7));
      // mask = type ? 64 - m : m.
      final inv = (Const(64, width: 7) - m).getRange(0, 7);
      final out = mux(type, inv, m);
      parts.add(out);
    }

    output('mask') <= parts.reversed.toList().concat();
  }
}

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 normative superres HORIZONTAL upscaler for one plane.
///
/// Superres is a normative horizontal upscale applied after CDEF and before
/// loop restoration (deblock -> CDEF -> superres upscale -> LR). A plane coded
/// at the downscaled width [downW] is upscaled to [upW] using an 8-tap,
/// 64-phase polyphase filter with SUPERRES_SCALE_BITS(14) subpel precision.
///
/// This implements the AV1 superres upscaling spec
/// (av1_upscale_normative_rows / av1_convolve_horiz_rs) exactly:
///   * step = ((downW << 14) + upW/2) / upW, x0 = the subpel start phase
///     (both derived at elaboration from [downW]/[upW]),
///   * per output pixel x, xqn = x0 + x*step, base = (xqn>>14) - 1 - (TAPS/2-1),
///     phase index = (xqn & mask) >> 8 (a 6-bit index into the filter bank),
///   * an 8-tap dot product of the filter against source samples base..base+7
///     with source indices clamped to [0, downW-1] (left/right edge
///     replication),
///   * rounding ROUND_POWER_OF_TWO(sum, FILTER_BITS=7) then clip to [0, 2^bd-1].
///
/// Because [downW]/[upW] are fixed at build time, every output pixel's `base`,
/// phase index and filter coefficients are compile-time constants. Only the
/// pixel data is runtime. The module is therefore purely combinational: each
/// output pixel is a fixed set of 8 constant-coefficient multiplies of known
/// source lanes, split into positive/negative accumulators to keep the
/// datapath unsigned (same idiom as HarborCflPredict), then rounded and
/// clipped.
///
/// Ports. Input `plane` packs source pixel (y,x) LSB-first row-major at
/// `[(y*downW + x)*bd +: bd]`. Output `out` packs upscaled pixel (y,x) at
/// `[(y*upW + x)*bd +: bd]`. Both use `bd` bits per pixel ([bd] default 8,
/// matching the 8-bit pixel-bus convention of the other frame-pass filters).
class HarborSuperresUpscale extends BridgeModule {
  /// SUPERRES_SCALE_BITS: subpel fractional precision of the scale accumulator.
  static const int _rsScaleSubpelBits = 14;

  /// Mask for the subpel fraction ((1 << 14) - 1).
  static const int _rsScaleSubpelMask = (1 << _rsScaleSubpelBits) - 1;

  /// RS_SCALE_SUBPEL_BITS - RS_SUBPEL_BITS (14 - 6): right-shift to turn the
  /// 14-bit subpel fraction into the 6-bit phase (filter-bank) index.
  static const int _rsScaleExtraBits = 8;

  /// RS_SCALE_EXTRA_OFF (1 << 7): rounding offset baked into x0.
  static const int _rsScaleExtraOff = 1 << 7;

  /// Number of filter taps.
  static const int _taps = 8;

  /// FILTER_BITS: the filter is normalized to 1<<7, so the dot product is
  /// rounded down by 7 bits.
  static const int _filterBits = 7;

  /// av1_resize_filter_normative[64][8]: the superres upscale polyphase filter
  /// bank, indexed by the 6-bit phase.
  static const List<List<int>> kResizeFilterNormative = <List<int>>[
    [0, 0, 0, 128, 0, 0, 0, 0],
    [0, 0, -1, 128, 2, -1, 0, 0],
    [0, 1, -3, 127, 4, -2, 1, 0],
    [0, 1, -4, 127, 6, -3, 1, 0],
    [0, 2, -6, 126, 8, -3, 1, 0],
    [0, 2, -7, 125, 11, -4, 1, 0],
    [-1, 2, -8, 125, 13, -5, 2, 0],
    [-1, 3, -9, 124, 15, -6, 2, 0],
    [-1, 3, -10, 123, 18, -6, 2, -1],
    [-1, 3, -11, 122, 20, -7, 3, -1],
    [-1, 4, -12, 121, 22, -8, 3, -1],
    [-1, 4, -13, 120, 25, -9, 3, -1],
    [-1, 4, -14, 118, 28, -9, 3, -1],
    [-1, 4, -15, 117, 30, -10, 4, -1],
    [-1, 5, -16, 116, 32, -11, 4, -1],
    [-1, 5, -16, 114, 35, -12, 4, -1],
    [-1, 5, -17, 112, 38, -12, 4, -1],
    [-1, 5, -18, 111, 40, -13, 5, -1],
    [-1, 5, -18, 109, 43, -14, 5, -1],
    [-1, 6, -19, 107, 45, -14, 5, -1],
    [-1, 6, -19, 105, 48, -15, 5, -1],
    [-1, 6, -19, 103, 51, -16, 5, -1],
    [-1, 6, -20, 101, 53, -16, 6, -1],
    [-1, 6, -20, 99, 56, -17, 6, -1],
    [-1, 6, -20, 97, 58, -17, 6, -1],
    [-1, 6, -20, 95, 61, -18, 6, -1],
    [-2, 7, -20, 93, 64, -18, 6, -2],
    [-2, 7, -20, 91, 66, -19, 6, -1],
    [-2, 7, -20, 88, 69, -19, 6, -1],
    [-2, 7, -20, 86, 71, -19, 6, -1],
    [-2, 7, -20, 84, 74, -20, 7, -2],
    [-2, 7, -20, 81, 76, -20, 7, -1],
    [-2, 7, -20, 79, 79, -20, 7, -2],
    [-1, 7, -20, 76, 81, -20, 7, -2],
    [-2, 7, -20, 74, 84, -20, 7, -2],
    [-1, 6, -19, 71, 86, -20, 7, -2],
    [-1, 6, -19, 69, 88, -20, 7, -2],
    [-1, 6, -19, 66, 91, -20, 7, -2],
    [-2, 6, -18, 64, 93, -20, 7, -2],
    [-1, 6, -18, 61, 95, -20, 6, -1],
    [-1, 6, -17, 58, 97, -20, 6, -1],
    [-1, 6, -17, 56, 99, -20, 6, -1],
    [-1, 6, -16, 53, 101, -20, 6, -1],
    [-1, 5, -16, 51, 103, -19, 6, -1],
    [-1, 5, -15, 48, 105, -19, 6, -1],
    [-1, 5, -14, 45, 107, -19, 6, -1],
    [-1, 5, -14, 43, 109, -18, 5, -1],
    [-1, 5, -13, 40, 111, -18, 5, -1],
    [-1, 4, -12, 38, 112, -17, 5, -1],
    [-1, 4, -12, 35, 114, -16, 5, -1],
    [-1, 4, -11, 32, 116, -16, 5, -1],
    [-1, 4, -10, 30, 117, -15, 4, -1],
    [-1, 3, -9, 28, 118, -14, 4, -1],
    [-1, 3, -9, 25, 120, -13, 4, -1],
    [-1, 3, -8, 22, 121, -12, 4, -1],
    [-1, 3, -7, 20, 122, -11, 3, -1],
    [-1, 2, -6, 18, 123, -10, 3, -1],
    [0, 2, -6, 15, 124, -9, 3, -1],
    [0, 2, -5, 13, 125, -8, 2, -1],
    [0, 1, -4, 11, 125, -7, 2, 0],
    [0, 1, -3, 8, 126, -6, 2, 0],
    [0, 1, -3, 6, 127, -4, 1, 0],
    [0, 1, -2, 4, 127, -3, 1, 0],
    [0, 0, -1, 2, 128, -1, 0, 0],
  ];

  /// Scale step: ((inLen << 14) + outLen/2) / outLen (get_upscale_convolve_step).
  static int getStep(int inLen, int outLen) =>
      ((inLen << _rsScaleSubpelBits) + outLen ~/ 2) ~/ outLen;

  /// Initial subpel position x0, wrapped to the 14-bit subpel range.
  static int getX0(int inLen, int outLen, int step) {
    final err = outLen * step - (inLen << _rsScaleSubpelBits);
    final x0 =
        (-((outLen - inLen) << (_rsScaleSubpelBits - 1)) + outLen ~/ 2) ~/
            outLen +
        _rsScaleExtraOff -
        (err ~/ 2);
    return x0 & _rsScaleSubpelMask;
  }

  /// [downW] downscaled (coded) plane width. [upW] upscaled width. [height]
  /// number of rows. [bd] bit depth (default 8, verified path).
  HarborSuperresUpscale({
    int downW = 48,
    int upW = 64,
    int height = 1,
    int bd = 8,
    String? name,
  }) : super(
         'HarborSuperresUpscale_D${downW}_U${upW}_H${height}_B$bd',
         name: name ?? 'superres_upscale',
       ) {
    if (downW <= 0) {
      throw ArgumentError('downW must be positive, got $downW');
    }
    if (upW <= 0) {
      throw ArgumentError('upW must be positive, got $upW');
    }
    if (height <= 0) {
      throw ArgumentError('height must be positive, got $height');
    }
    if (bd < 8 || bd > 12) {
      throw ArgumentError('bd must be in 8..12, got $bd');
    }

    createPort('plane', PortDirection.input, width: downW * height * bd);
    addOutput('out', width: upW * height * bd);

    final pixMax = (1 << bd) - 1;
    // Working width: a pixel (<= bd bits) times a coefficient (|c| <= 128, 8
    // bits) is <= bd+8 bits. Summing 8 taps adds <= 3 bits, plus the +64
    // rounding. bd+16 is comfortably wide and leaves headroom for the >>7 slice.
    final w = bd + 16;

    final step = getStep(downW, upW);
    final x0 = getX0(downW, upW, step);

    Logic px(int y, int x) => input(
      'plane',
    ).getRange((y * downW + x) * bd, (y * downW + x) * bd + bd);
    // Left/right border replication: clamp source column to [0, downW-1].
    int clampIdx(int idx) => idx < 0 ? 0 : (idx >= downW ? downW - 1 : idx);

    final pixMaxShift = Const(pixMax, width: w - _filterBits);
    final outSlices = List<Logic>.filled(upW * height, Const(0, width: bd));

    for (var y = 0; y < height; y++) {
      var xqn = x0;
      for (var x = 0; x < upW; x++) {
        final base = (xqn >> _rsScaleSubpelBits) - 1 - (_taps ~/ 2 - 1);
        final fidx = (xqn & _rsScaleSubpelMask) >> _rsScaleExtraBits;
        final f = kResizeFilterNormative[fidx];

        // Split the signed dot product into unsigned positive/negative sums so
        // the datapath stays unsigned. sum = pos - neg.
        Logic pos = Const(0, width: w);
        Logic neg = Const(0, width: w);
        for (var k = 0; k < _taps; k++) {
          final c = f[k];
          if (c == 0) continue;
          final sample = px(y, clampIdx(base + k)).zeroExtend(w);
          final term = sample * Const(c.abs(), width: w); // w-wide, fits
          if (c > 0) {
            pos = pos + term;
          } else {
            neg = neg + term;
          }
        }

        // ROUND_POWER_OF_TWO(sum, 7) = (pos - neg + 64) >> 7, then clip [0,max].
        // If (pos+64) < neg the rounded value is negative -> clips to 0.
        final posPlus = pos + Const(1 << (_filterBits - 1), width: w);
        final nonNeg = posPlus.gte(neg);
        final diff = posPlus - neg; // valid only when nonNeg
        final shifted = diff.getRange(_filterBits, w); // logical >> 7
        final clipped = mux(
          shifted.gt(pixMaxShift),
          pixMaxShift,
          shifted,
        ).getRange(0, bd);
        outSlices[y * upW + x] = mux(nonNeg, clipped, Const(0, width: bd));

        xqn += step;
      }
    }

    output('out') <=
        [for (var i = upW * height - 1; i >= 0; i--) outSlices[i]].swizzle();
  }
}

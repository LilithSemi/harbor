import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Bit-exact AV1 masked-pixel blend (libaom blend core), bd8. Combinational.
///
/// The central runtime engine shared by AV1 OBMC (overlapped block motion
/// compensation, where a block prediction is blended with above/left neighbour-MV
/// strip predictions) and inter-intra prediction (blend of the inter prediction
/// with an intra prediction). Both reduce to the same per-pixel expression:
///
///   out(i,j) = (m(i,j) * a(i,j) + (64 - m(i,j)) * b(i,j) + 32) >> 6
///
/// where `a` and `b` are 8-bit predictions and `m` is a 6-bit mask in `0..64`.
/// For OBMC `a` is the current plane pixel and `b` the neighbour strip, for
/// inter-intra `a` is the intra prediction and `b` the inter prediction.
///
/// Ports operate on a `width x height` block (default 8x8), all bytes packed
/// LSB-first row-major (pixel `(i,j)` at index `i*width + j`):
///   `a`    : input,  `width*height*8` bits (8-bit predictions)
///   `b`    : input,  `width*height*8` bits (8-bit predictions)
///   `mask` : input,  `width*height*7` bits (7-bit per-pixel mask, value 0..64)
///   `out`  : output, `width*height*8` bits (8-bit blended pixels)
///
/// Arithmetic is exact: `m*a + (64-m)*b + 32` peaks at `64*255 + 32 = 16352`
/// (15 bits). A 20-bit working width carries it with margin. The `>>6` is a
/// logical shift (all operands non-negative) and the result is always `<256`.
class HarborMaskBlend extends BridgeModule {
  /// Block width in pixels.
  final int width;

  /// Block height in pixels.
  final int height;

  HarborMaskBlend({this.width = 8, this.height = 8, String? name})
    : super('HarborMaskBlend', name: name ?? 'mask_blend') {
    if (width <= 0) {
      throw ArgumentError('HarborMaskBlend.width must be positive, got $width');
    }
    if (height <= 0) {
      throw ArgumentError(
        'HarborMaskBlend.height must be positive, got $height',
      );
    }

    final n = width * height;
    createPort('a', PortDirection.input, width: n * 8);
    createPort('b', PortDirection.input, width: n * 8);
    createPort('mask', PortDirection.input, width: n * 7);
    addOutput('out', width: n * 8);

    final a = input('a');
    final b = input('b');
    final mask = input('mask');

    const w = 20; // working width: holds 64*255 + 32 = 16352 with margin.
    final c64 = Const(64, width: w);
    final c32 = Const(32, width: w);

    final pixels = <Logic>[];
    for (var idx = 0; idx < n; idx++) {
      final av = a.getRange(idx * 8, idx * 8 + 8).zeroExtend(w);
      final bv = b.getRange(idx * 8, idx * 8 + 8).zeroExtend(w);
      final mv = mask.getRange(idx * 7, idx * 7 + 7).zeroExtend(w);

      final ma = (mv * av).getRange(0, w);
      final inv = (c64 - mv).getRange(0, w);
      final mb = (inv * bv).getRange(0, w);
      final sum = (ma + mb).getRange(0, w);
      final biased = (sum + c32).getRange(0, w);
      final shifted = (biased >>> 6).getRange(0, w);
      pixels.add(shifted.getRange(0, 8));
    }

    // Pack pixel (i,j) at index i*width + j, LSB-first row-major.
    output('out') <= pixels.reversed.toList().concat();
  }

  // Build-time constant mask producers. These generate the per-pixel mask grids
  // the blend consumes. They are pure compile-time constants (the masks are fixed
  // tables, not data-dependent), so a caller drives `mask` from `obmcMask(...)` /
  // `interIntraMask(...)` packed LSB-first to match the `mask` port layout.

  /// AV1 OBMC 1D blend masks, indexed by overlap dimension. Legal lengths are
  /// 1, 2, 4, 8, 16, 32.
  static const _obmcMask1 = [64];
  static const _obmcMask2 = [45, 64];
  static const _obmcMask4 = [39, 50, 59, 64];
  static const _obmcMask8 = [36, 42, 48, 53, 57, 61, 64, 64];
  static const _obmcMask16 = [
    34,
    37,
    40,
    43,
    46,
    49,
    52,
    54,
    56,
    58,
    60,
    61,
    64,
    64,
    64,
    64,
  ];
  static const _obmcMask32 = [
    33, 35, 36, 38, 40, 41, 43, 44, 45, 47, 48, 50, 51, 52, 53, 55, //
    56, 57, 58, 59, 60, 60, 61, 62, 64, 64, 64, 64, 64, 64, 64, 64,
  ];

  /// The raw 1D OBMC mask for an overlap [len] (one of 1, 2, 4, 8, 16, 32).
  static List<int> obmcMask1d(int len) {
    switch (len) {
      case 1:
        return _obmcMask1;
      case 2:
        return _obmcMask2;
      case 4:
        return _obmcMask4;
      case 8:
        return _obmcMask8;
      case 16:
        return _obmcMask16;
      case 32:
        return _obmcMask32;
      default:
        throw ArgumentError('OBMC overlap must be 1,2,4,8,16,32, got $len');
    }
  }

  /// The 2D OBMC per-pixel mask for a `pbw x pbh` overlap block, packed
  /// row-major (`m(i,j)` at index `i*pbw + j`).
  ///
  /// For the above-neighbour blend the mask varies along rows: `m = mask1d[i]`
  /// where the 1D mask length is the overlap height ([above] true). For the
  /// left-neighbour blend it varies along columns: `m = mask1d[j]` with the 1D
  /// mask length the overlap width ([above] false).
  static List<int> obmcMask(int pbw, int pbh, {required bool above}) {
    final mask1d = obmcMask1d(above ? pbh : pbw);
    final out = List<int>.filled(pbw * pbh, 0);
    for (var i = 0; i < pbh; i++) {
      for (var j = 0; j < pbw; j++) {
        out[i * pbw + j] = above ? mask1d[i] : mask1d[j];
      }
    }
    return out;
  }

  /// AV1 smooth inter-intra 1D weight ramp, 132 entries, consumed by the
  /// V/H/SMOOTH inter-intra modes.
  static const interIntraWeights1d = [
    60,
    58,
    56,
    54,
    52,
    50,
    48,
    47,
    45,
    44,
    42,
    41,
    39,
    38,
    37,
    35,
    34,
    33,
    32,
    31,
    30,
    29,
    28,
    27,
    26,
    25,
    24,
    23,
    22,
    22,
    21,
    20,
    19,
    19,
    18,
    18,
    17,
    16,
    16,
    15,
    15,
    14,
    14,
    13,
    13,
    12,
    12,
    12,
    11,
    11,
    10,
    10,
    10,
    9,
    9,
    9,
    8,
    8,
    8,
    8,
    7,
    7,
    7,
    7,
    6,
    6,
    6,
    6,
    6,
    5,
    5,
    5,
    5,
    5,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
  ];

  /// The 2D inter-intra per-pixel mask for a `pbw x pbh` block in [mode],
  /// packed row-major (`m(i,j)` at index `i*pbw + j`). The mask is built from a
  /// 1D ramp sampled at a block-size-dependent scale `128 / max(pbw,pbh)`.
  static List<int> interIntraMask(InterIntraMode mode, int pbw, int pbh) {
    final scale = 128 ~/ (pbw > pbh ? pbw : pbh);
    final out = List<int>.filled(pbw * pbh, 0);
    for (var y = 0; y < pbh; y++) {
      for (var x = 0; x < pbw; x++) {
        int m;
        switch (mode) {
          case InterIntraMode.v:
            m = interIntraWeights1d[y * scale];
            break;
          case InterIntraMode.h:
            m = interIntraWeights1d[x * scale];
            break;
          case InterIntraMode.smooth:
            m = interIntraWeights1d[(y < x ? y : x) * scale];
            break;
          case InterIntraMode.dc:
            m = 32;
            break;
        }
        out[y * pbw + x] = m;
      }
    }
    return out;
  }
}

/// AV1 inter-intra prediction modes (0=DC, 1=V, 2=H, 3=SMOOTH).
enum InterIntraMode { dc, v, h, smooth }

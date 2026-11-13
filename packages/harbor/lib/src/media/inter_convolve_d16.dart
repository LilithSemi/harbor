import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// AV1 sub-pel interpolation filter family (8-tap), for the compound-prediction
/// 16-bit CONV_BUF convolution. Same tables as
/// `InterConvolveFilter` in inter_convolve.dart.
enum InterConvolveD16Filter { regular, smooth, sharp }

// EIGHTTAP (regular). libaom `av1_sub_pel_filters_8`.
const List<List<int>> _filterRegular = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [0, 2, -6, 126, 8, -2, 0, 0],
  [0, 2, -10, 122, 18, -4, 0, 0],
  [0, 2, -12, 116, 28, -8, 2, 0],
  [0, 2, -14, 110, 38, -10, 2, 0],
  [0, 2, -14, 102, 48, -12, 2, 0],
  [0, 2, -16, 94, 58, -12, 2, 0],
  [0, 2, -14, 84, 66, -12, 2, 0],
  [0, 2, -14, 76, 76, -14, 2, 0],
  [0, 2, -12, 66, 84, -14, 2, 0],
  [0, 2, -12, 58, 94, -16, 2, 0],
  [0, 2, -12, 48, 102, -14, 2, 0],
  [0, 2, -10, 38, 110, -14, 2, 0],
  [0, 2, -8, 28, 116, -12, 2, 0],
  [0, 0, -4, 18, 122, -10, 2, 0],
  [0, 0, -2, 8, 126, -6, 2, 0],
];

// EIGHTTAP_SMOOTH. libaom `av1_sub_pel_filters_8smooth`.
const List<List<int>> _filterSmooth = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [0, 2, 28, 62, 34, 2, 0, 0],
  [0, 0, 26, 62, 36, 4, 0, 0],
  [0, 0, 22, 62, 40, 4, 0, 0],
  [0, 0, 20, 60, 42, 6, 0, 0],
  [0, 0, 18, 58, 44, 8, 0, 0],
  [0, 0, 16, 56, 46, 10, 0, 0],
  [0, -2, 16, 54, 48, 12, 0, 0],
  [0, -2, 14, 52, 52, 14, -2, 0],
  [0, 0, 12, 48, 54, 16, -2, 0],
  [0, 0, 10, 46, 56, 16, 0, 0],
  [0, 0, 8, 44, 58, 18, 0, 0],
  [0, 0, 6, 42, 60, 20, 0, 0],
  [0, 0, 4, 40, 62, 22, 0, 0],
  [0, 0, 4, 36, 62, 26, 0, 0],
  [0, 0, 2, 34, 62, 28, 2, 0],
];

// MULTITAP_SHARP. libaom `av1_sub_pel_filters_8sharp`.
const List<List<int>> _filterSharp = [
  [0, 0, 0, 128, 0, 0, 0, 0],
  [-2, 2, -6, 126, 8, -2, 2, 0],
  [-2, 6, -12, 124, 16, -6, 4, -2],
  [-2, 8, -18, 120, 26, -10, 6, -2],
  [-4, 10, -22, 116, 38, -14, 6, -2],
  [-4, 10, -22, 108, 48, -18, 8, -2],
  [-4, 10, -24, 100, 60, -20, 8, -2],
  [-4, 10, -24, 90, 70, -22, 10, -2],
  [-4, 12, -24, 80, 80, -24, 12, -4],
  [-2, 10, -22, 70, 90, -24, 10, -4],
  [-2, 8, -20, 60, 100, -24, 10, -4],
  [-2, 8, -18, 48, 108, -22, 10, -4],
  [-2, 6, -14, 38, 116, -22, 10, -4],
  [-2, 6, -10, 26, 120, -18, 8, -2],
  [-2, 4, -6, 16, 124, -12, 6, -2],
  [0, 2, -2, 8, 126, -6, 2, -2],
];

List<List<int>> _tableFor(InterConvolveD16Filter f) {
  switch (f) {
    case InterConvolveD16Filter.regular:
      return _filterRegular;
    case InterConvolveD16Filter.smooth:
      return _filterSmooth;
    case InterConvolveD16Filter.sharp:
      return _filterSharp;
  }
}

/// Harbor bit-exact AV1 compound inter-prediction 16-bit CONV_BUF convolution
/// core (libaom `av1_dist_wtd_convolve_{2d,x,y,2d_copy}`, tile_decode
/// `_compoundConvolve`), bit depth 8, the `!doAverage` producer path.
///
/// Produces the 16-bit CONV_BUF `res` value per output pixel: exactly the
/// src0/src1 inputs that `HarborCompoundBlend` consumes (the doAverage blend
/// itself lives in compound_blend.dart, this module only PRODUCES the values).
///
/// Four fractional-phase cases keyed by `(fracX, fracY)` (each 0..15):
///   * `(0,0)`         : copy, `res = (ref << 4) + roundOffset`.
///   * `(fracX,0)`     : horizontal-only separable 8-tap.
///   * `(0,fracY)`     : vertical-only separable 8-tap.
///   * `(fracX,fracY)` : 2D separable, horizontal first into an intermediate of
///                       height `height+7`, then vertical.
///
/// PATCH GEOMETRY (caller contract, identical to `HarborInterConvolve`): the
/// 8-tap support reaches 3 samples left/up and 4 right/down of each output
/// position, so an output block of `width x height` consumes
/// `(width+7) x (height+7)` reference samples. The caller must pass that patch
/// ALREADY edge-replicated (the module performs no clamping). Output position
/// `(0,0)` at fractional phase 0 reads patch sample `(row=3, col=3)`. In general
/// output `(x,y)` taps patch rows `y .. y+7` and cols `x .. x+7`, with the
/// integer (phase-0) sample at patch `(y+3, x+3)`.
///
/// `patch` packs sample `(row, col)` (row 0..height+6, col 0..width+6) row-major
/// LSB-first at bit `(row*(width+7) + col)*8`, 8 bits each. `conv` packs output
/// `(x,y)` at index `y*width + x` (16 bits each), LSB-first. Combinational.
///
/// Rounding constants (from `_compoundConvolve`, bd8): filterBits=7, round0=3,
/// round1=7, offsetBits = 8 + 2*filterBits - round0 = 19,
/// roundOffset = (1<<(offsetBits-round1)) + (1<<(offsetBits-round1-1)) = 6144.
/// The `res` value is centred on 6144 and verified to stay within the unsigned
/// 16-bit range [0, 65535] across all families and phases (measured worst-case
/// [1012, 15356] on the sharp family). No clip is applied.
class HarborInterConvolveD16 extends BridgeModule {
  /// Output block width (pixels).
  final int width;

  /// Output block height (pixels).
  final int height;

  /// Sub-pel filter family.
  final InterConvolveD16Filter filter;

  HarborInterConvolveD16({
    this.width = 8,
    this.height = 8,
    this.filter = InterConvolveD16Filter.regular,
    String? name,
  }) : super('HarborInterConvolveD16', name: name ?? 'inter_convolve_d16') {
    if (width <= 0) {
      throw ArgumentError(
        'HarborInterConvolveD16.width must be > 0, got $width',
      );
    }
    if (height <= 0) {
      throw ArgumentError(
        'HarborInterConvolveD16.height must be > 0, got $height',
      );
    }

    const filterBits = 7, round0 = 3, round1 = 7, bd = 8;
    const offsetBits = bd + 2 * filterBits - round0; // 19
    const roundOffset =
        (1 << (offsetBits - round1)) + (1 << (offsetBits - round1 - 1)); // 6144
    const w = 32; // working width, signed, covers all stages with headroom.

    final pw = width + 7; // patch columns
    final imH = height + 7; // 2D intermediate rows

    createPort('patch', PortDirection.input, width: pw * (height + 7) * 8);
    createPort('frac_x', PortDirection.input, width: 4);
    createPort('frac_y', PortDirection.input, width: 4);
    addOutput('conv', width: width * height * 16);

    final patch = input('patch');
    final fracX = input('frac_x');
    final fracY = input('frac_y');

    final table = _tableFor(filter);

    // Patch sample (row, col) as an unsigned 8b Logic.
    Logic sample(int row, int col) {
      final base = (row * pw + col) * 8;
      return patch.getRange(base, base + 8);
    }

    // Zero-extend an unsigned pixel to width w.
    Logic px(int row, int col) => sample(row, col).zeroExtend(w);

    // Constant signed tap, two's complement over width w.
    Logic tap(int value) => Const(BigInt.from(value).toUnsigned(w), width: w);

    // tap * pixel, low w bits (signed product mod 2^w, fits in w).
    Logic mul(Logic t, Logic p) => (t * p).getRange(0, w);

    // Signed arithmetic right shift by n of a width-w value.
    Logic asr(Logic x, int n) {
      if (n == 0) {
        return x;
      }
      return [x[w - 1].replicate(n), x.getRange(n, w)].concat();
    }

    // Add a constant (possibly negative) bias, low w bits.
    Logic addC(Logic x, int c) =>
        (x + Const(BigInt.from(c).toUnsigned(w), width: w)).getRange(0, w);

    // Select one tap-row from a constant table by 4b phase. Returns 8 taps.
    List<Logic> taps(Logic phase, List<List<int>> tbl) {
      final result = <Logic>[];
      for (var k = 0; k < 8; k++) {
        Logic acc = tap(tbl[15][k]);
        for (var p = 14; p >= 0; p--) {
          acc = mux(phase.eq(Const(p, width: 4)), tap(tbl[p][k]), acc);
        }
        result.add(acc);
      }
      return result;
    }

    final xf = taps(fracX, table);
    final yf = taps(fracY, table);

    // The res value is non-negative and < 2^16. Take the low 16 bits.
    Logic out16(Logic v) => v.getRange(0, 16);

    // case 1: copy (fracX==0 && fracY==0).
    // res = (ref[y+3][x+3] << 4) + roundOffset. bits = 2*7-7-3 = 4.
    Logic copyOut(int x, int y) {
      const bits = 2 * filterBits - round1 - round0; // 4
      final ref = px(y + 3, x + 3); // zero-extended, non-negative
      final shifted = (ref * Const(1 << bits, width: w)).getRange(0, w);
      return out16(addC(shifted, roundOffset));
    }

    // case 2: horizontal only.
    // raw = sum_k xf[k]*ref[y+3][x + k]  (x0=3, col = x0 + x - 3 + k = x + k)
    // bits = filterBits - round1 = 0.
    // res = ((1<<bits) * ((raw + 4) >> round0)) + roundOffset.
    Logic horizOut(int x, int y) {
      const bits = filterBits - round1; // 0
      Logic acc = Const(0, width: w);
      for (var k = 0; k < 8; k++) {
        acc = (acc + mul(xf[k], px(y + 3, x + k))).getRange(0, w);
      }
      var res = asr(addC(acc, 1 << (round0 - 1)), round0);
      // bits == 0: (1<<bits) == 1, multiply is a no-op. Kept general:
      if (bits != 0) {
        res = (res * Const(1 << bits, width: w)).getRange(0, w);
      }
      return out16(addC(res, roundOffset));
    }

    // case 3: vertical only.
    // raw = sum_k yf[k]*ref[y + k][x+3]. bits = filterBits - round0 = 4.
    // raw *= (1<<bits). res = ((raw + 64) >> round1) + roundOffset.
    Logic vertOut(int x, int y) {
      const bits = filterBits - round0; // 4
      Logic acc = Const(0, width: w);
      for (var k = 0; k < 8; k++) {
        acc = (acc + mul(yf[k], px(y + k, x + 3))).getRange(0, w);
      }
      final scaled = (acc * Const(1 << bits, width: w)).getRange(0, w);
      final res = asr(addC(scaled, 1 << (round1 - 1)), round1);
      return out16(addC(res, roundOffset));
    }

    // case 4: 2D separable.
    // Horizontal pass into intermediate im[imy][x], imy = 0..imH-1:
    //   sum = (1<<14) + sum_k xf[k]*ref[imy][x + k]   (ref row y0+imy-3 = imy)
    //   im = (sum + 4) >> round0
    final im = <List<Logic>>[];
    for (var imy = 0; imy < imH; imy++) {
      final row = <Logic>[];
      for (var x = 0; x < width; x++) {
        Logic acc = Const(1 << (bd + filterBits - 1), width: w); // 1<<14
        for (var k = 0; k < 8; k++) {
          acc = (acc + mul(xf[k], px(imy, x + k))).getRange(0, w);
        }
        row.add(asr(addC(acc, 1 << (round0 - 1)), round0));
      }
      im.add(row);
    }
    // Vertical pass:
    //   sum = (1<<offsetBits) + sum_k yf[k]*im[y+k][x]
    //   res = (sum + 64) >> round1     (NO subtract: compound keeps the offset)
    Logic twodOut(int x, int y) {
      Logic acc = Const(1 << offsetBits, width: w);
      for (var k = 0; k < 8; k++) {
        acc = (acc + mul(yf[k], im[y + k][x])).getRange(0, w);
      }
      final res = asr(addC(acc, 1 << (round1 - 1)), round1);
      return out16(res);
    }

    // Case selectors.
    final xZero = fracX.eq(Const(0, width: 4));
    final yZero = fracY.eq(Const(0, width: 4));

    final outParts = <Logic>[];
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final c1 = copyOut(x, y); // 00
        final c2 = horizOut(x, y); // x0
        final c3 = vertOut(x, y); // 0y
        final c4 = twodOut(x, y); // xy
        final out = mux(xZero, mux(yZero, c1, c3), mux(yZero, c2, c4));
        outParts.add(out);
      }
    }
    // Pack index y*width + x LSB-first, 16 bits each.
    output('conv') <= outParts.reversed.toList().concat();
  }
}

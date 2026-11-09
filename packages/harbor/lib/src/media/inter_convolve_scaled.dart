import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// AV1 sub-pel interpolation filter family (8-tap), for the SCALED (superres /
/// resolution-change) motion-compensation convolution. Same tables as
/// `InterConvolveFilter` in inter_convolve.dart.
enum InterConvolveScaledFilter { regular, smooth, sharp }

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

List<List<int>> _tableFor(InterConvolveScaledFilter f) {
  switch (f) {
    case InterConvolveScaledFilter.regular:
      return _filterRegular;
    case InterConvolveScaledFilter.smooth:
      return _filterSmooth;
    case InterConvolveScaledFilter.sharp:
      return _filterSharp;
  }
}

/// Harbor bit-exact AV1 SCALED motion-compensation convolution core
/// (libaom `av1_convolve_2d_scale_c`).
///
/// Used when a reference frame's stored (upscaled) size differs from the CURRENT
/// coded frame size (superres inter frames, or a spatial resolution change). The
/// reference is resampled with a fractional PER-SAMPLE step in q10
/// (SCALE_SUBPEL_BITS = 10) fixed point, instead of the fixed 1/16-pel phase of
/// the unscaled `HarborInterConvolve`.
///
/// This is a 2-pass separable 8-tap convolve with a running q10 phase
/// accumulator:
///   * Horizontal pass, for each intermediate row `iy` and output column `x`,
///     starts `xqn = subX` and steps `+= xStep`. The integer reference column is
///     `xqn >> 10`, the 8-tap phase is `fx[(xqn & 1023) >> 6]`.
///   * Vertical pass, for each output column `x` and row `y`, starts `yqn = subY`
///     and steps `+= yStep`. The intermediate row base is `yqn >> 10`, phase is
///     `fy[(yqn & 1023) >> 6]`.
///
/// PATCH GEOMETRY (caller contract): the caller supplies the reference already
/// windowed and edge-replicated so that `patch[pr][pc]` holds reference sample
/// `(row = by0 - fo + pr, col = bx0 - fo + pc)`, with `fo = 3`, `bx0 = posX>>10`,
/// `by0 = posY>>10`. The horizontal pass at output column `x`, tap `k`, reads
/// `patch[iy][(xqn>>10) + k]`. The vertical pass reads intermediate row
/// `(yqn>>10) + k`. The module performs NO clamping. The caller bakes the wide
/// UMV border replication into the patch. Patch dimensions are sized for the
/// worst-case step [maxStepQ10] (default 2048 == a 2x downscale of the coded
/// frame, the largest superres ratio):
///   * `pw` (patch columns) = `((1023 + (width-1)*maxStepQ10) >> 10) + 8`.
///   * `ph` (patch rows)    = `((1023 + (height-1)*maxStepQ10) >> 10) + 8`
///                          == the maximum intermediate height `imH`.
///
/// `patch` packs sample `(pr, pc)` row-major LSB-first at bit
/// `(pr*pw + pc)*bitDepth`. Combinational.
///
/// MODES (build time):
///   * `!isCompound`                    : single-ref. Output `pred`
///     (`width*height` pixels, `bitDepth` each) = `clip(res - roundOffset)`.
///   * `isCompound && !doAverage`       : first compound reference. Output `conv`
///     (`width*height` signed [accWidth]-bit values) = `res` (the CONV_BUF).
///   * `isCompound && doAverage`        : second compound reference. Input
///     `dst16` (the other reference's `conv`) is blended with this `res`
///     (distance-weighted when [useDistWtd], else straight average), then
///     rounded to `pred`. Distance weights come from `fwd_off` / `bck_off`.
///
/// Rounding constants (from `_scaledConvolve`): filterBits = 7, fo = 3.
/// `round0` starts at 3 and is bumped when `bd + filterBits - round0 + 2 > 16`
/// (fires for 12-bit). `round1 = isCompound ? 7 : 2*filterBits - round0`.
/// `offsetBits = bd + 2*filterBits - round0`.
/// `roundOffset = (1<<(offsetBits-round1)) + (1<<(offsetBits-round1-1))`.
/// `roundBits = 2*filterBits - round0 - round1`.
class HarborInterConvolveScaled extends BridgeModule {
  /// Output block width (pixels).
  final int width;

  /// Output block height (pixels).
  final int height;

  /// Sub-pel filter family.
  final InterConvolveScaledFilter filter;

  /// Pixel bit depth (8/10/12).
  final int bitDepth;

  /// Worst-case q10 step the patch is sized for (2048 == 2x, largest superres).
  final int maxStepQ10;

  /// Compound (two-reference) prediction path.
  final bool isCompound;

  /// Compound blend of this reference with a previously stored `dst16`.
  final bool doAverage;

  /// Distance-weighted compound average (uses `fwd_off` / `bck_off`).
  final bool useDistWtd;

  /// Signed working width for the convolution accumulators and the CONV_BUF.
  static const int accWidth = 32;

  /// Patch columns.
  late final int pw;

  /// Patch rows (== maximum intermediate height).
  late final int ph;

  HarborInterConvolveScaled({
    this.width = 8,
    this.height = 8,
    this.filter = InterConvolveScaledFilter.regular,
    this.bitDepth = 8,
    this.maxStepQ10 = 2048,
    this.isCompound = false,
    this.doAverage = false,
    this.useDistWtd = false,
    String? name,
  }) : super(
         'HarborInterConvolveScaled',
         name: name ?? 'inter_convolve_scaled',
       ) {
    if (width <= 0) {
      throw ArgumentError(
        'HarborInterConvolveScaled.width must be > 0, got $width',
      );
    }
    if (height <= 0) {
      throw ArgumentError(
        'HarborInterConvolveScaled.height must be > 0, got $height',
      );
    }
    if (bitDepth != 8 && bitDepth != 10 && bitDepth != 12) {
      throw ArgumentError(
        'HarborInterConvolveScaled.bitDepth must be 8/10/12, got $bitDepth',
      );
    }
    if (maxStepQ10 < 1024) {
      throw ArgumentError(
        'HarborInterConvolveScaled.maxStepQ10 must be >= 1024,'
        ' got $maxStepQ10',
      );
    }
    if (doAverage && !isCompound) {
      throw ArgumentError('doAverage requires isCompound');
    }
    if (useDistWtd && !doAverage) {
      throw ArgumentError('useDistWtd requires doAverage');
    }

    const filterBits = 7;
    final bd = bitDepth;
    var round0 = 3;
    final intbufrange = bd + filterBits - round0 + 2;
    if (intbufrange > 16) {
      round0 += intbufrange - 16;
    }
    final round1 = isCompound ? 7 : 2 * filterBits - round0;
    final offsetBits = bd + 2 * filterBits - round0;
    final roundOffset =
        (1 << (offsetBits - round1)) + (1 << (offsetBits - round1 - 1));
    final roundBits = 2 * filterBits - round0 - round1;
    final maxVal = (1 << bd) - 1;

    // Worst-case patch geometry for the largest permitted step.
    pw = ((1023 + (width - 1) * maxStepQ10) >> 10) + 8;
    ph = ((1023 + (height - 1) * maxStepQ10) >> 10) + 8;

    const w = accWidth;
    // q10 phase accumulator width: subX up to 1023 (< 2^11) plus
    // (dim-1)*maxStep. 32 bits is ample.
    const qW = 32;
    final subXW = 11; // subX/subY are posX & 1023, at most 10 bits used.
    // xStep/yStep up to maxStepQ10 (2048 -> 12 bits). Sized generously.
    final stepW = (maxStepQ10.bitLength) + 1;

    createPort('patch', PortDirection.input, width: pw * ph * bd);
    createPort('sub_x', PortDirection.input, width: subXW);
    createPort('sub_y', PortDirection.input, width: subXW);
    createPort('x_step', PortDirection.input, width: stepW);
    createPort('y_step', PortDirection.input, width: stepW);
    if (doAverage) {
      createPort('dst16', PortDirection.input, width: width * height * w);
      if (useDistWtd) {
        createPort('fwd_off', PortDirection.input, width: 8);
        createPort('bck_off', PortDirection.input, width: 8);
      }
    }
    if (isCompound && !doAverage) {
      addOutput('conv', width: width * height * w);
    } else {
      addOutput('pred', width: width * height * bd);
    }

    final patch = input('patch');
    final table = _tableFor(filter);

    // small helpers over the signed working width w
    Logic constW(int c) => Const(BigInt.from(c).toUnsigned(w), width: w);
    Logic asr(Logic x, int n) {
      if (n <= 0) return x;
      return [x[w - 1].replicate(n), x.getRange(n, w)].concat();
    }

    Logic addC(Logic x, int c) => (x + constW(c)).getRange(0, w);
    Logic mul(Logic a, Logic b) => (a * b).getRange(0, w);

    // Select one 8-tap filter row from [tbl] by a 4-bit phase.
    List<Logic> taps(Logic phase, List<List<int>> tbl) {
      final result = <Logic>[];
      for (var k = 0; k < 8; k++) {
        Logic acc = constW(tbl[15][k]);
        for (var p = 14; p >= 0; p--) {
          acc = mux(phase.eq(Const(p, width: 4)), constW(tbl[p][k]), acc);
        }
        result.add(acc);
      }
      return result;
    }

    // Clip a signed working-width value to [0, maxVal] -> bd-bit unsigned.
    Logic clip(Logic v) {
      final neg = v[w - 1];
      final overMax = v.gt(Const(maxVal, width: w));
      final clamped = mux(
        neg,
        Const(0, width: w),
        mux(overMax, Const(maxVal, width: w), v),
      );
      return clamped.getRange(0, bd);
    }

    final subX = input('sub_x').zeroExtend(qW);
    final subY = input('sub_y').zeroExtend(qW);
    final xStep = input('x_step').zeroExtend(qW);
    final yStep = input('y_step').zeroExtend(qW);

    // Per-output-column horizontal phase accumulator: xqn = subX + x*xStep.
    final xqn = <Logic>[
      for (var x = 0; x < width; x++)
        (subX + (xStep * Const(x, width: qW)).getRange(0, qW)).getRange(0, qW),
    ];
    // Per-output-row vertical phase accumulator: yqn = subY + y*yStep.
    final yqn = <Logic>[
      for (var y = 0; y < height; y++)
        (subY + (yStep * Const(y, width: qW)).getRange(0, qW)).getRange(0, qW),
    ];

    // baseCol[x] = xqn>>10 (integer ref column, non-negative), phaseX[x] taps.
    final baseCol = [for (var x = 0; x < width; x++) xqn[x].getRange(10, qW)];
    final phaseX = [for (var x = 0; x < width; x++) xqn[x].getRange(6, 10)];
    final fx = [for (var x = 0; x < width; x++) taps(phaseX[x], table)];

    final base = [for (var y = 0; y < height; y++) yqn[y].getRange(10, qW)];
    final phaseY = [for (var y = 0; y < height; y++) yqn[y].getRange(6, 10)];
    final fy = [for (var y = 0; y < height; y++) taps(phaseY[y], table)];

    // horizontal pass into im[ph][width] (full working precision)
    // A patch row is a pw*bd-bit slice. Barrel-shift it right by baseCol*bd to
    // bring the 8-tap window to bit 0, then split into pixels.
    final rowShW = (pw * bd).bitLength;
    final bcW = pw.bitLength; // holds baseCol in 0..pw-8
    final im = <List<Logic>>[];
    final hStart = 1 << (bd + filterBits - 1);
    // baseCol[x] * bd shift amount, computed once per column.
    final xShamt = <Logic>[
      for (var x = 0; x < width; x++)
        (baseCol[x].getRange(0, bcW).zeroExtend(rowShW) *
                Const(bd, width: rowShW))
            .getRange(0, rowShW),
    ];
    for (var iy = 0; iy < ph; iy++) {
      final patchRow = patch.getRange(iy * pw * bd, (iy + 1) * pw * bd);
      final row = <Logic>[];
      for (var x = 0; x < width; x++) {
        // shamt = baseCol[x] * bd, logical right shift (zero fill).
        final shamt = xShamt[x];
        final windowed = (patchRow >>> shamt).getRange(0, 8 * bd);
        Logic acc = constW(hStart);
        for (var k = 0; k < 8; k++) {
          final pix = windowed.getRange(k * bd, (k + 1) * bd).zeroExtend(w);
          acc = (acc + mul(fx[x][k], pix)).getRange(0, w);
        }
        row.add(asr(addC(acc, 1 << (round0 - 1)), round0));
      }
      im.add(row);
    }

    // Pack each intermediate column (im[0..ph-1][x]) LSB-first (row 0 low) for
    // the vertical barrel shift.
    final imCol = <Logic>[
      for (var x = 0; x < width; x++)
        [for (var iy = ph - 1; iy >= 0; iy--) im[iy][x]].concat(),
    ];
    final colShW = (ph * w).bitLength;
    final brW = ph.bitLength; // holds base row in 0..ph-8

    // vertical pass
    final vStart = 1 << offsetBits;
    // dst16 input samples (compound doAverage).
    Logic dst16At(int x, int y) {
      final idx = y * width + x;
      return input('dst16').getRange(idx * w, (idx + 1) * w);
    }

    final fwdOff = useDistWtd ? input('fwd_off').zeroExtend(w) : constW(0);
    final bckOff = useDistWtd ? input('bck_off').zeroExtend(w) : constW(0);

    final outParts = List<Logic>.filled(
      width * height,
      Const(0, width: 1),
      growable: false,
    );
    for (var x = 0; x < width; x++) {
      for (var y = 0; y < height; y++) {
        final shamt =
            (base[y].getRange(0, brW).zeroExtend(colShW) *
                    Const(w, width: colShW))
                .getRange(0, colShW);
        final windowed = (imCol[x] >>> shamt).getRange(0, 8 * w);
        Logic acc = constW(vStart);
        for (var k = 0; k < 8; k++) {
          final imk = windowed.getRange(k * w, (k + 1) * w);
          acc = (acc + mul(fy[y][k], imk)).getRange(0, w);
        }
        final res = asr(addC(acc, 1 << (round1 - 1)), round1);

        Logic outv;
        if (!isCompound) {
          outv = clip(addC(res, -roundOffset));
        } else if (!doAverage) {
          outv = res; // CONV_BUF value, width w.
        } else {
          final d = dst16At(x, y);
          Logic tmp;
          if (useDistWtd) {
            tmp = asr((mul(d, fwdOff) + mul(res, bckOff)).getRange(0, w), 4);
          } else {
            tmp = asr((d + res).getRange(0, w), 1);
          }
          tmp = addC(tmp, -roundOffset);
          outv = clip(asr(addC(tmp, 1 << (roundBits - 1)), roundBits));
        }
        outParts[y * width + x] = outv;
      }
    }

    final packed = [
      for (var i = width * height - 1; i >= 0; i--) outParts[i],
    ].concat();
    if (isCompound && !doAverage) {
      output('conv') <= packed;
    } else {
      output('pred') <= packed;
    }
  }
}

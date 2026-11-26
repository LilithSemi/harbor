import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 inter-prediction sub-pixel position setup, UNSCALED
/// (1:1) reference path. Combinational.
///
/// Turns a motion vector plus the block origin within a plane into the integer
/// source pixel coordinate and the 4-bit (1/16-pel) sub-pixel phase that the
/// convolution consumes, following the AV1 spec motion-compensation setup:
///
/// ```dart
///   final mvq = mv << (1 - subsampling)    // 1/8-pel -> 1/16-pel (luma: <<1)
///   final base = (pos * 16 + mvq) >> 4     // arithmetic shift -> integer px
///   final frac = mvq & 15                  // 1/16-pel phase 0..15
/// ```
///
/// MV is signed in 1/8-pel (3 fractional bits). SUBPEL_BITS = 4 selects 1/16-pel
/// (SUBPEL_MASK = 15), so a `<< (1 - subsampling)` converts 1/8 -> 1/16
/// (luma `subsampling = 0` gives the `<< 1`). `pos * 16` is `pos << SUBPEL_BITS`,
/// which contributes nothing to the low 4 bits, hence the phase is exactly
/// `mvq & 15`. The `>> 4` is an arithmetic (sign-propagating) shift so negative
/// motion vectors produce the correct negative integer source coordinate, just
/// as Dart `>>` on a signed `int` does in the SW.
///
/// Scope: the unscaled 1:1 case only, the bit-exact target. This is the only
/// case used for same-size references (`x_scale_fp == y_scale_fp ==
/// REF_NO_SCALE`), which is what the software decoder implements. The general
/// scaled path (`av1_scaled_x/y` with `SCALE_SUBPEL_BITS = 10` and a per-step
/// `x_step`/`y_step`) is a documented follow-up and is intentionally not wired
/// here. No `x_scale_fp`/`y_scale_fp` inputs are exposed yet.
///
/// Ports (all values two's complement where signed):
///   inputs : `mv_row`, `mv_col` (signed, [mvWidth], 1/8-pel)
///            `pos_x`, `pos_y`   (unsigned, [posWidth], plane pixel origin)
///   outputs: `x0`, `y0`         (signed, [coordWidth], integer source pixel)
///            `frac_x`, `frac_y` (unsigned 4b, 1/16-pel phase 0..15)
class HarborInterScaleSetup extends BridgeModule {
  /// Chroma subsampling for this plane (0 = luma / full res, 1 = half res).
  /// Selects the 1/8 -> 1/16-pel up-shift `1 - subsampling`.
  final int subsampling;

  /// Width of the signed motion-vector inputs, in bits.
  final int mvWidth;

  /// Width of the unsigned plane-origin position inputs, in bits.
  final int posWidth;

  /// Width of the signed integer source-coordinate outputs (`x0`/`y0`), in bits.
  late final int coordWidth;

  HarborInterScaleSetup({
    this.subsampling = 0,
    this.mvWidth = 16,
    this.posWidth = 16,
    String? name,
  }) : super('HarborInterScaleSetup', name: name ?? 'inter_scale_setup') {
    if (subsampling != 0 && subsampling != 1) {
      throw ArgumentError(
        'HarborInterScaleSetup.subsampling must be 0 or 1, got $subsampling',
      );
    }
    if (mvWidth < 4) {
      throw ArgumentError(
        'HarborInterScaleSetup.mvWidth must be >= 4, got $mvWidth',
      );
    }
    if (posWidth < 1) {
      throw ArgumentError(
        'HarborInterScaleSetup.posWidth must be >= 1, got $posWidth',
      );
    }

    // Working width: hold pos*16 (posWidth+4) and mvq = mv << 1 (mvWidth+1)
    // signed, with sign headroom so the add never wraps. The result of the
    // arithmetic >> 4 is the integer coordinate, same signed width.
    final w = (posWidth + 4 > mvWidth + 1 ? posWidth + 4 : mvWidth + 1) + 2;
    coordWidth = w;

    createPort('mv_row', PortDirection.input, width: mvWidth);
    createPort('mv_col', PortDirection.input, width: mvWidth);
    createPort('pos_x', PortDirection.input, width: posWidth);
    createPort('pos_y', PortDirection.input, width: posWidth);
    addOutput('x0', width: coordWidth);
    addOutput('y0', width: coordWidth);
    addOutput('frac_x', width: 4);
    addOutput('frac_y', width: 4);

    // Sign-extend a Logic to the working width (two's complement).
    Logic sext(Logic x) {
      final n = x.width;
      if (n >= w) return x.getRange(0, w);
      return [x[n - 1].replicate(w - n), x].concat();
    }

    // Zero-extend an (unsigned) position to the working width.
    Logic zext(Logic x) => x.width >= w ? x.getRange(0, w) : x.zeroExtend(w);

    // Arithmetic (sign-propagating) right shift by [n] on a signed width-w
    // value, keeping the result width w.
    Logic asr(Logic x, int n) =>
        [x[w - 1].replicate(n), x.getRange(n, w)].concat();

    final shift = 1 - subsampling; // luma: 1, half-res: 0

    void axis(Logic mv, Logic pos, String coordOut, String fracOut) {
      // mvq = mv << shift, in the working width (truncating add semantics are
      // avoided by extending first).
      final mvq = (sext(mv) * Const(1 << shift, width: w)).getRange(0, w);
      // pos * 16 == pos << SUBPEL_BITS (SUBPEL_BITS = 4).
      final posShifted = (zext(pos) * Const(16, width: w)).getRange(0, w);
      // p = pos*16 + mvq (signed, two's complement).
      final p = (posShifted + mvq).getRange(0, w);
      // x0 = p >> 4 (arithmetic).
      output(coordOut) <= asr(p, 4);
      // frac = mvq & 15 (== p & 15, since pos*16 has zero low 4 bits).
      output(fracOut) <= mvq.getRange(0, 4);
    }

    axis(input('mv_col'), input('pos_x'), 'x0', 'frac_x');
    axis(input('mv_row'), input('pos_y'), 'y0', 'frac_y');
  }
}

/// Harbor bit-exact AV1 inter-prediction sub-pixel position setup, SCALED
/// (superres / resolution-change) reference path. Combinational.
///
/// Implements the AV1 spec reference-scale + scaled-position setup. Given the
/// reference's
/// stored (upscaled) LUMA size, the current coded LUMA size, a motion vector and
/// the block's plane origin, it produces the q10 (SCALE_SUBPEL_BITS = 10) scale
/// factors and per-axis phase/step that `HarborInterConvolveScaled` consumes:
///
/// ```dart
///   xfp   = ((refW << 14) + thisW ~/ 2) ~/ thisW    // REF_SCALE_SHIFT = 14
///   xStep = (xfp + 8) >> 4                          // q10 per-sample step
///   isScaled = xfp != (1<<14) || yfp != (1<<14)
///   origX = (posX << 4) + mvCol * (1 << (1 - sx))
///   posX  = _scaledPos(origX, xfp) + 32              // SCALE_EXTRA_OFF
///   // clamp posX to the wide UMV border, then:
///   subX = posX & 1023, bx0 = posX >> 10
/// ```
/// with `_scaledPos(v, fp) = t<0 ? -((-t+128)>>8) : ((t+128)>>8)` and
/// `t = v*fp + (fp - (1<<14))*8`.
///
/// `is_scaled` is the detection signal: when set, the block's warp / OBMC motion
/// modes are disabled and the scaled convolve replaces the unscaled one (the
/// gate is a single AND in the MC control path, `warp_enable & ~is_scaled`).
///
/// Ports (two's complement where signed):
///   inputs : `ref_w`,`ref_h`,`this_w`,`this_h` (unsigned, [dimWidth])
///            `mv_row`,`mv_col` (signed, [mvWidth], 1/8-pel)
///            `pos_x`,`pos_y`   (unsigned, [posWidth], plane pixel origin)
///   outputs: `x_scale_fp`,`y_scale_fp` (unsigned 16b, q14)
///            `x_step`,`y_step`          (unsigned 12b, q10)
///            `is_scaled`                (1b)
///            `sub_x`,`sub_y`            (unsigned 11b, q10 phase 0..1023)
///            `bx0`,`by0`                (signed [coordWidth], integer ref pos)
class HarborInterScaleSetupScaled extends BridgeModule {
  /// Horizontal chroma subsampling for this plane (0 luma / 1 half-res).
  final int sx;

  /// Vertical chroma subsampling for this plane (0 luma / 1 half-res).
  final int sy;

  /// Width of the unsigned frame-dimension inputs, in bits.
  final int dimWidth;

  /// Width of the signed motion-vector inputs, in bits.
  final int mvWidth;

  /// Width of the unsigned plane-origin position inputs, in bits.
  final int posWidth;

  /// Width of the signed integer source-coordinate outputs (`bx0`/`by0`).
  late final int coordWidth;

  HarborInterScaleSetupScaled({
    this.sx = 0,
    this.sy = 0,
    this.dimWidth = 16,
    this.mvWidth = 16,
    this.posWidth = 16,
    String? name,
  }) : super(
         'HarborInterScaleSetupScaled',
         name: name ?? 'inter_scale_setup_scaled',
       ) {
    if (sx != 0 && sx != 1) {
      throw ArgumentError('HarborInterScaleSetupScaled.sx must be 0 or 1');
    }
    if (sy != 0 && sy != 1) {
      throw ArgumentError('HarborInterScaleSetupScaled.sy must be 0 or 1');
    }

    const fpW = 32; // fixed-point scale datapath (holds refW<<14)
    const tW = 48; // wide signed for _scaledPos t = origX*fp and the clamp
    coordWidth = tW;

    createPort('ref_w', PortDirection.input, width: dimWidth);
    createPort('ref_h', PortDirection.input, width: dimWidth);
    createPort('this_w', PortDirection.input, width: dimWidth);
    createPort('this_h', PortDirection.input, width: dimWidth);
    createPort('mv_row', PortDirection.input, width: mvWidth);
    createPort('mv_col', PortDirection.input, width: mvWidth);
    createPort('pos_x', PortDirection.input, width: posWidth);
    createPort('pos_y', PortDirection.input, width: posWidth);
    addOutput('x_scale_fp', width: 16);
    addOutput('y_scale_fp', width: 16);
    addOutput('x_step', width: 12);
    addOutput('y_step', width: 12);
    addOutput('is_scaled', width: 1);
    addOutput('sub_x', width: 11);
    addOutput('sub_y', width: 11);
    addOutput('bx0', width: coordWidth);
    addOutput('by0', width: coordWidth);

    Logic zext(Logic x, int width) =>
        x.width >= width ? x.getRange(0, width) : x.zeroExtend(width);
    Logic sext(Logic x, int width) {
      final n = x.width;
      if (n >= width) return x.getRange(0, width);
      return [x[n - 1].replicate(width - n), x].concat();
    }

    // Signed less-than over width [tW].
    Logic slt(Logic a, Logic b) {
      final sa = a[tW - 1], sb = b[tW - 1];
      final diff = (a - b).getRange(0, tW);
      return (sa & ~sb) | (sa.eq(sb) & diff[tW - 1]);
    }

    // fp = ((dim << 14) + this/2) / this, unsigned q14.
    (Logic, Logic) scaleFactor(Logic refDim, Logic thisDim) {
      final r = zext(refDim, fpW);
      final t = zext(thisDim, fpW);
      final num = ((r << 14) + (t >>> 1)).getRange(0, fpW);
      final fp = (num / t).getRange(0, fpW);
      final step = ((fp + Const(8, width: fpW)) >>> 4).getRange(0, fpW);
      return (fp, step);
    }

    final (xfp, xStep) = scaleFactor(input('ref_w'), input('this_w'));
    final (yfp, yStep) = scaleFactor(input('ref_h'), input('this_h'));
    const noScale = 1 << 14;
    final notX = xfp.neq(Const(noScale, width: fpW));
    final notY = yfp.neq(Const(noScale, width: fpW));

    output('x_scale_fp') <= xfp.getRange(0, 16);
    output('y_scale_fp') <= yfp.getRange(0, 16);
    output('x_step') <= xStep.getRange(0, 12);
    output('y_step') <= yStep.getRange(0, 12);
    output('is_scaled') <= (notX | notY);

    // _scaledPos + SCALE_EXTRA_OFF + UMV clamp for one axis.
    void axis(
      Logic pos,
      Logic mv,
      Logic fp,
      Logic refDim,
      int ss,
      String subOut,
      String bOut,
    ) {
      final shiftMv = 1 - ss; // luma: *2, chroma: *1
      final origin = ((zext(pos, tW) << 4) + (sext(mv, tW) << shiftMv))
          .getRange(0, tW);
      final fpS = zext(fp, tW);
      // t = origin*fp + (fp - (1<<14))*8
      final t =
          ((origin * fpS).getRange(0, tW) +
                  ((fpS - Const(noScale, width: tW)) << 3).getRange(0, tW))
              .getRange(0, tW);
      final tNeg = t[tW - 1];
      final negT = (~t + Const(1, width: tW)).getRange(0, tW);
      final posBranch = ((t + Const(128, width: tW)).getRange(0, tW) >> 8);
      final negInner = ((negT + Const(128, width: tW)).getRange(0, tW) >> 8);
      final negBranch = (~negInner + Const(1, width: tW)).getRange(0, tW);
      final scaled = mux(tNeg, negBranch, posBranch);
      var p = (scaled + Const(32, width: tW)).getRange(0, tW);
      // Clamp to the wide UMV border.
      final leftConst = -(((288 >> ss) - 4) << 10);
      final left = Const(BigInt.from(leftConst).toUnsigned(tW), width: tW);
      final right =
          ((((zext(refDim, tW) + Const(ss, width: tW)) >>> ss) +
                      Const(4, width: tW)) <<
                  10)
              .getRange(0, tW);
      p = mux(slt(p, left), left, mux(slt(right, p), right, p));
      output(subOut) <= p.getRange(0, 10).zeroExtend(11); // posX & 1023
      output(bOut) <= [p[tW - 1].replicate(10), p.getRange(10, tW)].concat();
    }

    axis(
      input('pos_x'),
      input('mv_col'),
      xfp,
      input('ref_w'),
      sx,
      'sub_x',
      'bx0',
    );
    axis(
      input('pos_y'),
      input('mv_row'),
      yfp,
      input('ref_h'),
      sy,
      'sub_y',
      'by0',
    );
  }
}

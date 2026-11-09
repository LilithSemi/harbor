import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Builds the 256-entry film-grain scaling LUT by piecewise-linear interpolation
/// across `numPoints` control points `points[i] = [value, scaling]` (both 0..255,
/// with `value` strictly increasing). Flat below the first point and above the
/// last, per the AV1 film-grain spec.
///
/// Returns a `List<int>` of length 256 where the index is the pixel value and the
/// entry is the scaling factor. For bd8 the runtime
/// lookup is `lut[pixel]` directly (the `_scaleLut` interpolation branch is for
/// high bit depth only).
List<int> filmGrainScalingLut(List<List<int>> points, int numPoints) {
  final lut = List<int>.filled(256, 0);
  if (numPoints == 0) return lut;
  for (var i = 0; i < points[0][0]; i++) {
    lut[i] = points[0][1];
  }
  for (var point = 0; point < numPoints - 1; point++) {
    final dy = points[point + 1][1] - points[point][1];
    final dx = points[point + 1][0] - points[point][0];
    final delta = dy * ((65536 + (dx >> 1)) ~/ dx);
    for (var x = 0; x < dx; x++) {
      lut[points[point][0] + x] =
          points[point][1] + ((x * delta + 32768) >> 16);
    }
  }
  for (var i = points[numPoints - 1][0]; i < 256; i++) {
    lut[i] = points[numPoints - 1][1];
  }
  return lut;
}

/// Harbor bit-exact AV1 film-grain per-pixel noise-application kernel, bd8 - the
/// runtime datapath inside libaom's `add_noise` ([_addNoise] in the SW model).
///
/// For every pixel in a `width x height` block it computes, combinationally and
/// in parallel per lane:
///   `noise = (scaling * grain + (1 << (scalingShift-1))) >> scalingShift`
///   `out   = clamp(pixel + noise, lo, hi)`
/// where `>>` is an arithmetic (sign-preserving) right shift and the clamp bounds
/// are selected at runtime: `clip_legal=1` gives legal-range [16,235] luma or
/// [16,240] chroma (per `is_chroma`). `clip_legal=0` gives the full [0,255].
///
/// `scaling` is the per-pixel scaling factor `_scaleLut(lut, pixel, 8) = lut[pixel]`
/// (build the LUT with [filmGrainScalingLut] and index it by pixel upstream), it
/// is supplied directly here so the LUT memory stays out of the per-pixel core.
///
/// Packing (all LSB-first, lane `k` at bit `k*width-of-field`):
///   `pixel`    : `width*height*8`  unsigned 0..255
///   `grain`    : `width*height*8`  SIGNED two's-complement, range [-128,127]
///                (bd8 grain clamp `[grainMin,grainMax] = [-128,127]`)
///   `scaling`  : `width*height*8`  unsigned 0..255
///   `out`      : `width*height*8`  unsigned 0..255
/// Scalar controls:
///   `scaling_shift` : 4b, runtime shift (AV1 scaling_shift range 8..11)
///   `clip_legal`    : 1b, 1 => restricted/legal clamp range
///   `is_chroma`     : 1b, selects 240 vs 235 legal max (and 16 legal min)
class HarborFilmGrainScale extends BridgeModule {
  /// Block dimensions. Each lane is an independent per-pixel kernel.
  final int width;
  final int height;

  HarborFilmGrainScale({this.width = 8, this.height = 8, String? name})
    : super('HarborFilmGrainScale', name: name ?? 'film_grain_scale') {
    if (width <= 0 || height <= 0) {
      throw ArgumentError(
        'HarborFilmGrainScale dims must be positive, '
        'got ${width}x$height',
      );
    }
    final n = width * height;

    // Working width for the signed scaling*grain product + bias. scaling 0..255
    // (8b) x grain [-128,127] gives [-32640, 32385], plus the rounding bias
    // (<= 1<<14) and pixel (0..255) all sit well inside signed 24b.
    const wWork = 24;

    createPort('pixel', PortDirection.input, width: n * 8);
    createPort('grain', PortDirection.input, width: n * 8);
    createPort('scaling', PortDirection.input, width: n * 8);
    createPort('scaling_shift', PortDirection.input, width: 4);
    createPort('clip_legal', PortDirection.input, width: 1);
    createPort('is_chroma', PortDirection.input, width: 1);
    addOutput('out', width: n * 8);

    final pixel = input('pixel');
    final grain = input('grain');
    final scaling = input('scaling');
    final scalingShift = input('scaling_shift');
    final clipLegal = input('clip_legal');
    final isChroma = input('is_chroma');

    // Supported runtime shift values (AV1 scaling_shift is 8..11, cover 1..15 so
    // every legal field value has a defined mux arm).
    const minShift = 1, maxShift = 15;

    // Arithmetic right shift of signed `x` (width wWork) by a compile-time `k`.
    Logic asr(Logic x, int k) {
      if (k == 0) return x;
      if (k >= wWork) return x[wWork - 1].replicate(wWork);
      return [x[wWork - 1].replicate(k), x.getRange(k, wWork)].concat();
    }

    // Clamp bounds selected by clip_legal / is_chroma (bd8).
    final lo = mux(
      clipLegal,
      Const(16, width: wWork), // legal min: 16 for both luma and chroma.
      Const(0, width: wWork),
    );
    final hiLegal = mux<Logic>(
      isChroma,
      Const(240, width: wWork),
      Const(235, width: wWork),
    );
    final hi = mux(clipLegal, hiLegal, Const(255, width: wWork));

    final lanes = <Logic>[];
    for (var k = 0; k < n; k++) {
      final px = pixel.getRange(k * 8, k * 8 + 8); // unsigned 8b
      final gr = grain.getRange(k * 8, k * 8 + 8); // signed 8b
      final sc = scaling.getRange(k * 8, k * 8 + 8); // unsigned 8b

      // Signed product scaling*grain in wWork bits. Sign-extend grain, zero-
      // extend scaling, multiply at full width then truncate to wWork.
      final scW = sc.zeroExtend(wWork);
      final grW = gr.signExtend(wWork);
      final prod = (scW * grW).getRange(0, wWork);

      // noise = (prod + (1<<(shift-1))) >> shift, arithmetic, runtime shift.
      // Mux over the supported shift values.
      Logic? noise;
      for (var s = minShift; s <= maxShift; s++) {
        final bias = Const(1 << (s - 1), width: wWork);
        final biased = (prod + bias).getRange(0, wWork);
        final shifted = asr(biased, s);
        final isThis = scalingShift.eq(Const(s, width: 4));
        noise = (noise == null) ? shifted : mux(isThis, shifted, noise);
        // Note: the final mux below makes `noise` default to the s==1 arm for
        // out-of-range shift values. AV1 never emits those.
      }

      // out = clamp(pixel + noise, lo, hi), all signed in wWork bits.
      final sum = (px.zeroExtend(wWork) + noise!).getRange(0, wWork);
      // sum < lo ?  (signed compare: sum negative, or sum < lo)
      final ltLo = sum.lt(lo) | sum[wWork - 1];
      final clampedLo = mux(ltLo, lo, sum);
      final gtHi = clampedLo.gt(hi);
      final clamped = mux(gtHi, hi, clampedLo);

      lanes.add(clamped.getRange(0, 8));
    }

    output('out') <= lanes.reversed.toList().concat();
  }
}

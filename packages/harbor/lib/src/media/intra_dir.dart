import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 directional intra predictor (libaom `dr_predictor`
/// z1/z2/z3) for the six directional modes at angle_delta = 0, no edge filter,
/// no upsampling. Square block, bit depth 8.
///
/// Modes (AV1 PREDICTION_MODE): 3 D45 (45deg), 4 D135, 5 D113, 6 D157,
/// 7 D203, 8 D67. The prediction angle is fixed per mode, so every reference
/// index and interpolation shift is a build-time constant. Each output pixel
/// is a 2-tap blend `round((32-shift)*ref[base] + shift*ref[base+1], 5)`. The
/// six mode blocks are computed and muxed by the runtime `mode`.
///
/// References are extended by repetition (matching `n_top_right_px = 0` /
/// `n_bottom_left_px = 0`): `above` is the `bs` samples above, `left` the `bs`
/// to the left, `above_left` the corner. `pred` packs pixel (r, c) at
/// `[(r*bs + c)*8 +: 8]`. Combinational (bs in {4, 8, 16}).
class HarborIntraDir extends BridgeModule {
  /// Square block size (4, 8 or 16).
  final int bs;

  // dr_intra_derivative[90] (reconintra.h).
  static const _drv = [
    0, 0, 0, 1023, 0, 0, 547, 0, 0, 372, 0, 0, 0, 0, 273, 0, 0, 215, 0, 0, //
    178, 0, 0, 151, 0, 0, 132, 0, 0, 116, 0, 0, 102, 0, 0, 0, 90, 0, 0, 80, //
    0, 0, 71, 0, 0, 64, 0, 0, 57, 0, 0, 51, 0, 0, 45, 0, 0, 0, 40, 0, 0, 35, //
    0, 0, 31, 0, 0, 27, 0, 0, 23, 0, 0, 19, 0, 0, 15, 0, 0, 0, 0, 11, 0, 0, //
    7, 0, 0, 3, 0, 0,
  ];
  static const _modeAngle = {3: 45, 4: 135, 5: 113, 6: 157, 7: 203, 8: 67};

  static int _getDx(int a) =>
      (a > 0 && a < 90) ? _drv[a] : (a > 90 && a < 180 ? _drv[180 - a] : 1);
  static int _getDy(int a) => (a > 90 && a < 180)
      ? _drv[a - 90]
      : (a > 180 && a < 270 ? _drv[270 - a] : 1);

  /// Sample bit depth (8/10/12). bd 8 is byte-identical to the original.
  final int bitDepth;

  HarborIntraDir({required this.bs, this.bitDepth = 8, String? name})
    : assert(bs == 4 || bs == 8 || bs == 16 || bs == 32, 'bs in {4,8,16,32}'),
      assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
      super(
        'HarborIntraDir_S${bs}_B$bitDepth',
        name: name ?? 'intra_dir_${bs}_$bitDepth',
      ) {
    final pw = bitDepth;
    createPort('mode', PortDirection.input, width: 4);
    createPort('above', PortDirection.input, width: bs * pw);
    createPort('left', PortDirection.input, width: bs * pw);
    createPort('above_left', PortDirection.input, width: pw);
    addOutput('pred', width: bs * bs * pw);

    Logic above(int c) => input('above').getRange(c * pw, c * pw + pw);
    Logic left(int r) => input('left').getRange(r * pw, r * pw + pw);
    final corner = input('above_left');

    // Extended reference access (repeat past the block edge, corner at -1).
    Logic aboveRef(int i) =>
        i < 0 ? corner : (i < bs ? above(i) : above(bs - 1));
    Logic leftRef(int i) => i < 0 ? corner : (i < bs ? left(i) : left(bs - 1));

    // 2-tap blend with build-time taps, `shift` 0..31.
    final bw = bitDepth + 8; // holds 32*maxV (16 at bd8)
    Logic blend(Logic a, Logic b, int shift) {
      if (shift == 0) return a;
      final v =
          (a.zeroExtend(bw) * Const(32 - shift, width: bw) +
                  b.zeroExtend(bw) * Const(shift, width: bw))
              .getRange(0, bw);
      return ((v + Const(16, width: bw)).getRange(0, bw) >>> 5).getRange(0, pw);
    }

    // Build the prediction block for one directional mode (all build-time).
    List<Logic> predFor(int mode) {
      final angle = _modeAngle[mode]!;
      final dst = List<Logic>.filled(bs * bs, Const(0, width: pw));
      if (angle < 90) {
        // z1: from `above`.
        final dx = _getDx(angle);
        final maxBaseX = bs + bs - 1;
        var x = dx;
        for (var r = 0; r < bs; r++, x += dx) {
          var base = x >> 6;
          final shift = (x & 0x3F) >> 1;
          if (base >= maxBaseX) {
            for (var i = r; i < bs; i++) {
              for (var c = 0; c < bs; c++) {
                dst[i * bs + c] = aboveRef(maxBaseX);
              }
            }
            break;
          }
          for (var c = 0; c < bs; c++, base++) {
            dst[r * bs + c] = base < maxBaseX
                ? blend(aboveRef(base), aboveRef(base + 1), shift)
                : aboveRef(maxBaseX);
          }
        }
      } else if (angle > 180) {
        // z3: from `left`.
        final dy = _getDy(angle);
        final maxBaseY = bs + bs - 1;
        var y = dy;
        for (var c = 0; c < bs; c++, y += dy) {
          var base = y >> 6;
          final shift = (y & 0x3F) >> 1;
          var r = 0;
          for (; r < bs; r++, base++) {
            if (base < maxBaseY) {
              dst[r * bs + c] = blend(leftRef(base), leftRef(base + 1), shift);
            } else {
              for (; r < bs; r++) {
                dst[r * bs + c] = leftRef(maxBaseY);
              }
              break;
            }
          }
        }
      } else {
        // z2: from `above` (baseX >= -1) else `left`.
        final dx = _getDx(angle), dy = _getDy(angle);
        for (var r = 0; r < bs; r++) {
          for (var c = 0; c < bs; c++) {
            final yv = r + 1;
            final xv = (c << 6) - yv * dx;
            final baseX = xv >> 6;
            if (baseX >= -1) {
              final shift = (xv & 0x3F) >> 1;
              dst[r * bs + c] = blend(
                aboveRef(baseX),
                aboveRef(baseX + 1),
                shift,
              );
            } else {
              final xv2 = c + 1;
              final yv2 = (r << 6) - xv2 * dy;
              final baseY = yv2 >> 6;
              final shift = (yv2 & 0x3F) >> 1;
              dst[r * bs + c] = blend(
                leftRef(baseY),
                leftRef(baseY + 1),
                shift,
              );
            }
          }
        }
      }
      return dst;
    }

    final mode = input('mode');
    final blocks = {for (final m in _modeAngle.keys) m: predFor(m)};
    final outs = <Logic>[];
    for (var i = 0; i < bs * bs; i++) {
      Logic px = blocks[8]![i]; // default D67
      for (final m in [3, 4, 5, 6, 7]) {
        px = mux(mode.eq(Const(m, width: 4)), blocks[m]![i], px);
      }
      outs.add(px);
    }
    output('pred') <= outs.reversed.toList().swizzle();
  }
}

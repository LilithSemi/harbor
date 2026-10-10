import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 intra predictor for the non-directional modes (libaom
/// `build_intra_predictors`, the DC / V / H / PAETH / SMOOTH family).
///
/// Square block, bit depth 8. Modes (AV1 PREDICTION_MODE enum):
/// 0 DC, 1 V, 2 H, 9 SMOOTH, 10 SMOOTH_V, 11 SMOOTH_H, 12 PAETH. (The
/// directional modes 3..8, filter-intra and CfL are follow-ups.) Reference
/// samples are assumed available (the DC128 / DC_left / DC_top availability
/// variants are a follow-up). The caller supplies the prepared edges.
///
/// `above` packs the `bs` samples above the block (sample c at `[c*8 +: 8]`),
/// `left` the `bs` samples to its left (sample r at `[r*8 +: 8]`), `above_left`
/// the corner sample. `pred` is the `bs*bs` predicted block, pixel (r, c) at
/// `[(r*bs + c)*8 +: 8]`. Combinational (build it for bs in {4, 8, 16}, larger
/// sizes want a sequential, row-serial core like the transform).
class HarborIntraPred extends BridgeModule {
  /// Square block size (4, 8 or 16).
  final int bs;

  /// Sample bit depth (8/10/12). Sets the pixel width (`pw = bitDepth`) and the
  /// working accumulator widths. bd 8 is byte-identical to the original.
  final int bitDepth;

  static const _smoothWeights = {
    4: [255, 149, 85, 64],
    8: [255, 197, 146, 105, 73, 50, 37, 32],
    16: [255, 225, 196, 170, 145, 123, 102, 84, 68, 54, 43, 33, 26, 20, 17, 16],
    32: [
      255,
      240,
      225,
      210,
      196,
      182,
      169,
      157,
      145,
      133,
      122,
      111,
      101,
      92,
      83, //
      74, 66, 59, 52, 45, 39, 34, 29, 25, 21, 17, 14, 12, 10, 9, 8, 8,
    ],
  };

  // AV1 PREDICTION_MODE values for the supported modes.
  static const _dc = 0, _v = 1, _h = 2, _smooth = 9, _smoothV = 10;
  static const _smoothH = 11, _paeth = 12;

  HarborIntraPred({required this.bs, this.bitDepth = 8, String? name})
    : assert(bs == 4 || bs == 8 || bs == 16 || bs == 32, 'bs in {4,8,16,32}'),
      assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
      super(
        'HarborIntraPred_S${bs}_B$bitDepth',
        name: name ?? 'intra_pred_${bs}_$bitDepth',
      ) {
    final pw = bitDepth; // pixel width
    createPort('mode', PortDirection.input, width: 4);
    createPort('above', PortDirection.input, width: bs * pw);
    createPort('left', PortDirection.input, width: bs * pw);
    createPort('above_left', PortDirection.input, width: pw);
    addOutput('pred', width: bs * bs * pw);

    final mode = input('mode');
    Logic above(int c) => input('above').getRange(c * pw, c * pw + pw);
    Logic left(int r) => input('left').getRange(r * pw, r * pw + pw);
    final aboveLeft = input('above_left');
    final smW = _smoothWeights[bs]!;
    const scale = 256; // 1 << 8 (8-bit smooth weight scale, bd-independent)
    final maxV = (1 << bitDepth) - 1;

    // divide_round(value, bits) = (value + (1<<(bits-1))) >> bits.
    Logic divRound(Logic value, int bits, int w) =>
        ((value + Const(1 << (bits - 1), width: w)).getRange(0, w) >>> bits)
            .getRange(0, pw);

    // DC: (sum(above) + sum(left) + count/2) / count, count = 2*bs.
    final dcW = (2 * bs * maxV).bitLength + 2;
    Logic sum = Const(0, width: dcW);
    for (var i = 0; i < bs; i++) {
      sum = (sum + above(i).zeroExtend(dcW)).getRange(0, dcW);
    }
    for (var i = 0; i < bs; i++) {
      sum = (sum + left(i).zeroExtend(dcW)).getRange(0, dcW);
    }
    // count = 2*bs is a power of two -> (sum + bs) >> (log2(bs) + 1).
    final dcShift = bs.bitLength; // log2(bs) + 1 (bs power of two)
    final dcVal = ((sum + Const(bs, width: dcW)).getRange(0, dcW) >>> dcShift)
        .getRange(0, pw);

    // PAETH single (signed base + abs-diff)
    Logic paeth(Logic l, Logic t, Logic tl) {
      final w = bitDepth + 4; // 12 at bd8, holds t+l-tl and the abs diffs
      Logic sx(Logic v) => v.zeroExtend(w); // pixels are non-negative
      final base = (sx(t) + sx(l) - sx(tl)).getRange(
        0,
        w,
      ); // signed (two's comp)
      Logic absd(Logic x) {
        final d = (base - sx(x)).getRange(0, w);
        return mux(d[w - 1], (Const(0, width: w) - d).getRange(0, w), d);
      }

      final pL = absd(l), pT = absd(t), pTL = absd(tl);
      return mux(pL.lte(pT) & pL.lte(pTL), l, mux(pT.lte(pTL), t, tl));
    }

    final belowLeft = left(bs - 1);
    final rightPred = above(bs - 1);
    // Accumulator widths: 4-term smooth <= 512*maxV -> bd+12 (20 at bd8).
    // 2-term smooth <= 256*maxV -> bd+10 (18 at bd8).
    final smW4 = bitDepth + 12;
    final smW2 = bitDepth + 10;

    final outs = <Logic>[];
    for (var r = 0; r < bs; r++) {
      for (var c = 0; c < bs; c++) {
        final vP = above(c);
        final hP = left(r);
        final pP = paeth(left(r), above(c), aboveLeft);
        // SMOOTH: 4-term weighted blend >> 9.
        final wv = smW[r], wh = smW[c];
        final sm = divRound(
          (Const(wv, width: smW4) * above(c).zeroExtend(smW4) +
                  Const(scale - wv, width: smW4) * belowLeft.zeroExtend(smW4) +
                  Const(wh, width: smW4) * left(r).zeroExtend(smW4) +
                  Const(scale - wh, width: smW4) * rightPred.zeroExtend(smW4))
              .getRange(0, smW4),
          9,
          smW4,
        );
        // SMOOTH_V / SMOOTH_H: 2-term >> 8.
        final smv = divRound(
          (Const(wv, width: smW2) * above(c).zeroExtend(smW2) +
                  Const(scale - wv, width: smW2) * belowLeft.zeroExtend(smW2))
              .getRange(0, smW2),
          8,
          smW2,
        );
        final smh = divRound(
          (Const(wh, width: smW2) * left(r).zeroExtend(smW2) +
                  Const(scale - wh, width: smW2) * rightPred.zeroExtend(smW2))
              .getRange(0, smW2),
          8,
          smW2,
        );

        final px = mux(
          mode.eq(Const(_v, width: 4)),
          vP,
          mux(
            mode.eq(Const(_h, width: 4)),
            hP,
            mux(
              mode.eq(Const(_paeth, width: 4)),
              pP,
              mux(
                mode.eq(Const(_smooth, width: 4)),
                sm,
                mux(
                  mode.eq(Const(_smoothV, width: 4)),
                  smv,
                  mux(mode.eq(Const(_smoothH, width: 4)), smh, dcVal),
                ),
              ),
            ),
          ),
        ); // default: DC
        outs.add(px);
      }
    }
    // Mode constant _dc is the default branch above.
    assert(_dc == 0);

    output('pred') <= outs.reversed.toList().swizzle();
  }
}

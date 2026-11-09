import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// AV1 SMOOTH-mode weight tables (Sm_Weights), one entry per position. The
/// weights blend the near edge toward the far edge across the block.
const List<int> _smWeights4 = [255, 149, 85, 64];
const List<int> _smWeights8 = [255, 197, 146, 105, 73, 50, 37, 32];

/// Harbor intra-prediction + reconstruction unit.
///
/// Predicts a block from already-reconstructed neighbours (the row above, the
/// column to the left, and the above-left corner) and adds the inverse-
/// transform residual to produce reconstructed pixels: `recon = clamp(pred +
/// residual)`. This is purely combinational.
///
/// Modes (3-bit `mode`): 0 = DC (average of the neighbours), 1 = Vertical (copy
/// the row above), 2 = Horizontal (copy the left column), 3 = Paeth (per pixel,
/// the neighbour closest to above+left-aboveLeft), 4 = SMOOTH (2D weighted
/// blend), 5 = SMOOTH_V (vertical blend), 6 = SMOOTH_H (horizontal blend),
/// 7 = D45 (pure 45-degree diagonal copy from the above row). The full
/// angle-table directional modes with intra-edge filtering are follow-up work.
///
/// Blocks live in a fixed stride-8 grid (residual/recon indexed `r*8 + c`). The
/// `size` input selects a 4x4 or 8x8 block.
class HarborIntraPredictor extends BridgeModule {
  /// Pixel bit depth.
  final int bitDepth;

  int get pixWidth => bitDepth;

  HarborIntraPredictor({this.bitDepth = 8, String? name})
    : super('HarborIntraPredictor', name: name ?? 'intra_pred') {
    final pw = pixWidth;
    final maxVal = (1 << bitDepth) - 1;
    createPort('mode', PortDirection.input, width: 3);
    createPort('size', PortDirection.input); // 0 = 4x4, 1 = 8x8
    createPort('above', PortDirection.input, width: 8 * pw);
    createPort('left', PortDirection.input, width: 8 * pw);
    createPort('above_left', PortDirection.input, width: pw);
    createPort('residual', PortDirection.input, width: 64 * 16);
    addOutput('recon', width: 64 * pw);

    final size8 = input('size');
    final aboveP = [
      for (var i = 0; i < 8; i++) input('above').getRange(i * pw, i * pw + pw),
    ];
    final leftP = [
      for (var i = 0; i < 8; i++) input('left').getRange(i * pw, i * pw + pw),
    ];
    final al = input('above_left');
    final res = [
      for (var i = 0; i < 64; i++)
        input('residual').getRange(i * 16, i * 16 + 16),
    ];

    // DC: average of the available above/left neighbours.
    Logic sumN(List<Logic> arr) {
      Logic s8 = Const(0, width: 16);
      Logic s4 = Const(0, width: 16);
      for (var i = 0; i < 8; i++) {
        s8 = (s8 + arr[i].zeroExtend(16)).getRange(0, 16);
        if (i < 4) s4 = (s4 + arr[i].zeroExtend(16)).getRange(0, 16);
      }
      return mux(size8, s8, s4);
    }

    final dcSum = (sumN(aboveP) + sumN(leftP)).getRange(0, 16);
    final dc = mux(
      size8,
      ((dcSum + Const(8, width: 16)) >>> 4),
      ((dcSum + Const(4, width: 16)) >>> 3),
    ).getRange(0, pw);

    // Paeth: pick the neighbour closest to (above + left - aboveLeft).
    Logic absDiff(Logic a, Logic b) => mux(a.gte(b), a - b, b - a);
    Logic paeth(Logic a, Logic l, Logic c) {
      const w = 12;
      final aw = a.zeroExtend(w);
      final lw = l.zeroExtend(w);
      final cw = c.zeroExtend(w);
      final pa = absDiff(lw, cw); // |left - aboveLeft|
      final pl = absDiff(aw, cw); // |above - aboveLeft|
      final pal = absDiff((aw + lw).getRange(0, w), (cw << 1).getRange(0, w));
      return mux(pa.lte(pl) & pa.lte(pal), a, mux(pl.lte(pal), l, c));
    }

    // SMOOTH weights, selected by block size, as 16-bit values.
    Logic smWeight(int i) => mux<Logic>(
      size8,
      Const(_smWeights8[i], width: 16),
      Const(i < 4 ? _smWeights4[i] : 0, width: 16),
    );
    // The far edges the SMOOTH modes blend toward: bottom-left and top-right.
    final belowLeft = mux(size8, leftP[7], leftP[3]);
    final aboveRight = mux(size8, aboveP[7], aboveP[3]);
    Logic smMul(Logic a, Logic b) =>
        (a.zeroExtend(20) * b.zeroExtend(20)).getRange(0, 20);

    // reconstruct = clamp(pred + residual, 0, maxVal).
    Logic recon(Logic pred, Logic resi) {
      final sum = (pred.zeroExtend(18) + [resi[15].replicate(2), resi].concat())
          .getRange(0, 18);
      final neg = sum[17];
      final tooBig = ~neg & sum.gt(Const(maxVal, width: 18));
      return mux(
        neg,
        Const(0, width: pw),
        mux(tooBig, Const(maxVal, width: pw), sum.getRange(0, pw)),
      );
    }

    final mode = input('mode');
    final outs = List<Logic>.generate(64, (_) => Const(0, width: pw));
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        final predP = paeth(aboveP[c], leftP[r], al);

        // SMOOTH family: per-axis weighted blend of the near edge toward the
        // opposite edge. vsum/hsum hold the *256 weighted sums.
        final wv = smWeight(r);
        final wh = smWeight(c);
        final invV = (Const(256, width: 16) - wv).getRange(0, 16);
        final invH = (Const(256, width: 16) - wh).getRange(0, 16);
        final vsum = (smMul(wv, aboveP[c]) + smMul(invV, belowLeft)).getRange(
          0,
          20,
        );
        final hsum = (smMul(wh, leftP[r]) + smMul(invH, aboveRight)).getRange(
          0,
          20,
        );
        final smooth =
            (((vsum + hsum).getRange(0, 20) + Const(256, width: 20)).getRange(
                      0,
                      20,
                    ) >>>
                    9)
                .getRange(0, pw);
        final smoothV = ((vsum + Const(128, width: 20)).getRange(0, 20) >>> 8)
            .getRange(0, pw);
        final smoothH = ((hsum + Const(128, width: 20)).getRange(0, 20) >>> 8)
            .getRange(0, pw);

        // D45: pure 45-degree diagonal, copying from the above row (the edge
        // sample is held at the right end of the available neighbours).
        final d45 = aboveP[(r + c + 1) > 7 ? 7 : (r + c + 1)];

        final pred = mux(
          mode.eq(Const(0, width: 3)),
          dc,
          mux(
            mode.eq(Const(1, width: 3)),
            aboveP[c],
            mux(
              mode.eq(Const(2, width: 3)),
              leftP[r],
              mux(
                mode.eq(Const(3, width: 3)),
                predP,
                mux(
                  mode.eq(Const(4, width: 3)),
                  smooth,
                  mux(
                    mode.eq(Const(5, width: 3)),
                    smoothV,
                    mux(mode.eq(Const(6, width: 3)), smoothH, d45),
                  ),
                ),
              ),
            ),
          ),
        );
        outs[r * 8 + c] = recon(pred, res[r * 8 + c]);
      }
    }
    output('recon') <= [for (var i = 63; i >= 0; i--) outs[i]].concat();
  }
}

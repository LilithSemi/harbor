import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// AV1 sub-pixel interpolation filter family.
enum HarborInterpFilter {
  /// 2-tap bilinear. Cheapest, used here as the default small-FPGA config.
  bilinear,

  /// 8-tap EIGHTTAP_REGULAR.
  regular,

  /// 8-tap EIGHTTAP_SMOOTH.
  smooth,

  /// 8-tap EIGHTTAP_SHARP.
  sharp,
}

/// AV1 8-tap luma sub-pel filter kernels, one 8-tap row per 1/16-pel phase
/// (SUBPEL_SHIFTS = 16). Coefficients sum to 128 (FILTER_BITS = 7). These are
/// libaom's `av1_sub_pel_filters_8`, `_8smooth`, and `_8sharp` tables.
const List<List<int>> _av1Filter8Regular = [
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

const List<List<int>> _av1Filter8Smooth = [
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

const List<List<int>> _av1Filter8Sharp = [
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

/// Harbor inter-prediction (motion compensation) + reconstruction unit.
///
/// Predicts a block from a reference frame: a motion vector's integer part
/// selects the reference region (supplied here as a pixel patch wide enough for
/// the 8x8 block plus the filter's border), and its fractional part (1/16-pel
/// `frac_x` / `frac_y`) drives a separable sub-pixel interpolation. The
/// inverse-transform residual is then added: `recon = clamp(interp + residual)`.
/// Combinational.
///
/// The filter is selectable at build time via [taps]: a 2-tap bilinear (the
/// cheap small-FPGA default, patch is 9x9) or the 8-tap AV1 kernels (patch is
/// 15x15). With 8 taps a `filter_type` input picks REGULAR / SMOOTH / SHARP at
/// run time. The residual/recon use the stride-8 block layout, and `size`
/// selects 4x4 or 8x8 (the predictor always computes 8x8, the engine reads back
/// only the active corner).
class HarborInterPredictor extends BridgeModule {
  /// Pixel bit depth.
  final int bitDepth;

  /// Interpolation tap count: 2 (bilinear) or 8 (AV1 sub-pel).
  final int taps;

  int get pixWidth => bitDepth;

  /// Reference patch side length: 8 output samples plus the filter border.
  int get patchDim => 8 + taps - 1;

  /// Whether the run-time filter-type selector is present (8-tap only).
  bool get hasFilterType => taps > 2;

  HarborInterPredictor({this.bitDepth = 8, this.taps = 2, String? name})
    : assert(taps == 2 || taps == 8, 'only 2-tap or 8-tap supported'),
      super('HarborInterPredictor', name: name ?? 'inter_pred') {
    final pw = pixWidth;
    final maxVal = (1 << bitDepth) - 1;
    final dim = patchDim;
    const wdt = 24; // signed working width for the convolution accumulators
    final shift = taps == 2 ? 4 : 7; // bilinear sums to 16, 8-tap to 128

    createPort('ref_patch', PortDirection.input, width: dim * dim * pw);
    createPort('frac_x', PortDirection.input, width: 4);
    createPort('frac_y', PortDirection.input, width: 4);
    createPort('residual', PortDirection.input, width: 64 * 16);
    if (hasFilterType) {
      createPort('filter_type', PortDirection.input, width: 2);
    }
    addOutput('recon', width: 64 * pw);

    final filterType = hasFilterType
        ? input('filter_type')
        : Const(0, width: 2);

    Logic constW(int c) => Const(c & ((1 << wdt) - 1), width: wdt);
    Logic asr(Logic v, int s) =>
        [v[wdt - 1].replicate(s), v.getRange(s, wdt)].concat();
    Logic roundShift(Logic v) =>
        asr((v + Const(1 << (shift - 1), width: wdt)).getRange(0, wdt), shift);

    // Reference pixel (r,c) as a non-negative working-width value.
    Logic refPx(int r, int c) => input(
      'ref_patch',
    ).getRange((r * dim + c) * pw, (r * dim + c) * pw + pw).zeroExtend(wdt);

    // The `taps` filter coefficients for a given 1/16-pel phase. Bilinear is
    // derived directly from the phase, the 8-tap rows come from the AV1 tables,
    // selected by phase and filter type.
    List<Logic> coefRow(Logic frac) {
      if (taps == 2) {
        final fe = frac.zeroExtend(wdt);
        return [(Const(16, width: wdt) - fe).getRange(0, wdt), fe];
      }
      Logic phaseSel(List<List<int>> tbl, int k) {
        Logic v = constW(tbl[15][k]);
        for (var p = 14; p >= 0; p--) {
          v = mux(frac.eq(Const(p, width: 4)), constW(tbl[p][k]), v);
        }
        return v;
      }

      return [
        for (var k = 0; k < 8; k++)
          mux(
            filterType.eq(Const(0, width: 2)),
            phaseSel(_av1Filter8Regular, k),
            mux(
              filterType.eq(Const(1, width: 2)),
              phaseSel(_av1Filter8Smooth, k),
              phaseSel(_av1Filter8Sharp, k),
            ),
          ),
      ];
    }

    // One separable convolution tap-sum, rounded back to the working width.
    Logic conv(List<Logic> samples, List<Logic> coefs) {
      Logic acc = Const(0, width: wdt);
      for (var k = 0; k < taps; k++) {
        acc = (acc + (samples[k] * coefs[k]).getRange(0, wdt)).getRange(0, wdt);
      }
      return roundShift(acc);
    }

    final coefX = coefRow(input('frac_x'));
    final coefY = coefRow(input('frac_y'));

    // Horizontal pass over every patch row, vertical pass over the 8 output
    // rows. The intermediate keeps full working-width precision between passes.
    final hpass = [
      for (var r = 0; r < dim; r++)
        [
          for (var c = 0; c < 8; c++)
            conv([for (var k = 0; k < taps; k++) refPx(r, c + k)], coefX),
        ],
    ];
    final interp = [
      for (var r = 0; r < 8; r++)
        [
          for (var c = 0; c < 8; c++)
            conv([for (var k = 0; k < taps; k++) hpass[r + k][c]], coefY),
        ],
    ];

    // reconstruct = clamp(prediction + residual, 0, maxVal).
    final res = [
      for (var i = 0; i < 64; i++)
        input('residual').getRange(i * 16, i * 16 + 16),
    ];
    Logic recon(Logic pred, Logic resi) {
      final sum = (pred + [resi[15].replicate(wdt - 16), resi].concat())
          .getRange(0, wdt);
      final neg = sum[wdt - 1];
      final tooBig = ~neg & sum.gt(Const(maxVal, width: wdt));
      return mux(
        neg,
        Const(0, width: pw),
        mux(tooBig, Const(maxVal, width: pw), sum.getRange(0, pw)),
      );
    }

    final outs = List<Logic>.generate(64, (_) => Const(0, width: pw));
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        outs[r * 8 + c] = recon(interp[r][c], res[r * 8 + c]);
      }
    }
    output('recon') <= [for (var i = 63; i >= 0; i--) outs[i]].concat();
  }
}

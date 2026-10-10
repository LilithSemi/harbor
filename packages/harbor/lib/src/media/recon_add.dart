import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor reconstruction add: `recon = clip(pred + residual, 0, (1<<bd)-1)`.
///
/// The final per-pixel step of block reconstruction: the intra (or inter)
/// prediction plus the inverse-transform residual, clamped to the pixel range.
/// `pred` packs `n` unsigned `bd`-bit samples (pixel i at `[i*bd +: bd]`),
/// `residual` `n` signed 16-bit samples, `recon` the clamped sum. Combinational.
class HarborReconAdd extends BridgeModule {
  /// Number of pixels (e.g. bs*bs).
  final int n;

  /// Bit depth.
  final int bitDepth;

  HarborReconAdd({required this.n, this.bitDepth = 8, String? name})
    : assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
      super('HarborReconAdd_N${n}_B$bitDepth', name: name ?? 'recon_add') {
    final bd = bitDepth;
    final rw = bd + 8; // signed residual element width (16 at bd8)
    final sumW = rw + 2; // 18 at bd8; holds pred + sign-extended residual
    createPort('pred', PortDirection.input, width: n * bd);
    createPort('residual', PortDirection.input, width: n * rw);
    addOutput('recon', width: n * bd);

    final maxV = (1 << bd) - 1;
    final outs = <Logic>[];
    for (var i = 0; i < n; i++) {
      final p = input('pred').getRange(i * bd, i * bd + bd);
      final r = input('residual').getRange(i * rw, i * rw + rw);
      // sum = pred + sign-extended residual, in a sumW-bit signed field.
      final sum =
          (p.zeroExtend(sumW) + [r[rw - 1].replicate(sumW - rw), r].swizzle())
              .getRange(0, sumW);
      final neg = sum[sumW - 1];
      final tooBig = ~neg & sum.gt(Const(maxV, width: sumW));
      outs.add(
        mux(
          neg,
          Const(0, width: bd),
          mux(tooBig, Const(maxV, width: bd), sum.getRange(0, bd)),
        ),
      );
    }
    output('recon') <= outs.reversed.toList().swizzle();
  }
}

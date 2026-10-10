import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sgr_cross_sum.dart';

/// Harbor bit-exact AV1 SGR projection (libaom `_sgrProcUnit` final combine),
/// bit-depth aware.
///
/// AV1's self-guided restoration runs up to two box filters producing the
/// higher-precision estimates `flt0`/`flt1` (in the SGRPROJ_RST_BITS domain),
/// then projects the source pixel toward them with signed per-unit weights
/// `xq0`/`xq1`:
///   u   = pre << 4                       (SGRPROJ_RST_BITS)
///   v   = (pre << 11) + xq0*(flt0 - u) + xq1*(flt1 - u)
///   out = clip_pixel_highbd(
///           ((v + (1<<10)) >> 11).toSigned(16), bd)   (PRJ_BITS + RST_BITS = 11)
/// libaom stores the projected value in an int16_t before clip_pixel_highbd, so
/// the rounded result is truncated to 16 bits (signed) regardless of bit depth.
/// At 8-bit that truncation never triggers, at 12-bit it can wrap. A disabled
/// radius is signalled by its weight being 0 (libaom `decode_xq`), so its term
/// vanishes and `flt` is don't-care. Combinational.
///
/// Ports: `pre` ([bd]-bit pixel), `flt0`/`flt1` (`sgrFltWidth(bd)`, RST-domain
/// estimates), `xq0`/`xq1` (8b signed) -> `out` ([bd]-bit).
class HarborSgrProject extends BridgeModule {
  HarborSgrProject({int bd = 8, String? name})
    : super('HarborSgrProject_B$bd', name: name ?? 'sgr_project') {
    final w = bd + 20 < 28 ? 28 : bd + 20; // signed working width (bd8 -> 28)
    const rstBits = 4;
    const prjBits = 7;
    const shift = prjBits + rstBits; // 11
    final fltW = sgrFltWidth(bd);
    final hi = (1 << bd) - 1;

    createPort('pre', PortDirection.input, width: bd);
    createPort('flt0', PortDirection.input, width: fltW);
    createPort('flt1', PortDirection.input, width: fltW);
    createPort('xq0', PortDirection.input, width: 8); // signed
    createPort('xq1', PortDirection.input, width: 8); // signed
    addOutput('out', width: bd);

    final pre = input('pre').zeroExtend(w);
    final flt0 = input('flt0').zeroExtend(w);
    final flt1 = input('flt1').zeroExtend(w);
    final xq0 = input('xq0').signExtend(w);
    final xq1 = input('xq1').signExtend(w);

    Logic mul(Logic a, Logic b) => (a * b).getRange(0, w);
    final u = (pre * Const(1 << rstBits, width: w)).getRange(0, w);
    final base = (pre * Const(1 << shift, width: w)).getRange(
      0,
      w,
    ); // pre << 11

    final term0 = mul(xq0, (flt0 - u).getRange(0, w));
    final term1 = mul(xq1, (flt1 - u).getRange(0, w));
    final v = ((base + term0).getRange(0, w) + term1).getRange(0, w);
    final pre2 = (v + Const(1 << (shift - 1), width: w)).getRange(0, w);
    final shifted = [
      pre2[w - 1].replicate(shift),
      pre2.getRange(shift, w),
    ].swizzle();

    // int16_t truncation of the rounded projection, then clip_pixel_highbd(bd).
    final outw = shifted.getRange(0, 16);
    final neg = outw[15];
    final tooBig = ~neg & outw.gt(Const(hi, width: 16));
    output('out') <=
        mux(
          neg,
          Const(0, width: bd),
          mux(tooBig, Const(hi, width: bd), outw.getRange(0, bd)),
        );
  }
}

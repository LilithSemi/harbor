import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sgr_calc_ab.dart';

/// SGR restoration-estimate (`flt`) output width for a bit depth [bd].
/// bd8 -> 18 (legacy). The estimate scales with the source pixel (`~pre<<4`):
/// bd12 needs ~18, formula gives 22 for headroom.
int sgrFltWidth(int bd) => bd + 10;

/// Harbor bit-exact AV1 SGR 3x3 A/B cross-sum (libaom `_sgrFast`/`_sgrFull`
/// inner loop), bit-depth aware, the step that turns per-pixel A/B into the
/// restoration estimate `flt`.
///
/// Over the 3x3 A/B neighbourhood (row-major, centre at index 4) it forms the
/// libaom weighted sums and produces `flt = round2(av*center + bv, nb + 4)`:
///   mode 0 (sgr_full,  nb 5): av = (a4+a3+a5+a1+a7)*4 + (a0+a2+a6+a8)*3
///   mode 1 (sgr_fast even row, nb 5): av = (a1+a7)*6 + (a0+a2+a6+a8)*5
///   mode 2 (sgr_fast odd  row, nb 4): av = a4*6 + (a3+a5)*5
/// (same weights for `bv` over the B window). Combinational.
///
/// Ports: `aw` (9*9b, nine A values 0..256), `bw` (9*`sgrBWidth(bd)`, nine B
/// values), `center` ([bd]-bit pixel), `mode` (2b) -> `flt` (`sgrFltWidth(bd)`).
class HarborSgrCrossSum extends BridgeModule {
  HarborSgrCrossSum({int bd = 8, String? name})
    : super('HarborSgrCrossSum_B$bd', name: name ?? 'sgr_cross') {
    const w = 32;
    final bW = sgrBWidth(bd);
    final fltW = sgrFltWidth(bd);

    createPort('aw', PortDirection.input, width: 9 * 9); // a0..a8 (9b each)
    createPort('bw', PortDirection.input, width: 9 * bW); // b0..b8 (bW each)
    createPort('center', PortDirection.input, width: bd);
    createPort('mode', PortDirection.input, width: 2);
    addOutput('flt', width: fltW);

    Logic a(int i) => input('aw').getRange(i * 9, i * 9 + 9).zeroExtend(w);
    Logic b(int i) => input('bw').getRange(i * bW, i * bW + bW).zeroExtend(w);
    final center = input('center').zeroExtend(w);
    final mode = input('mode');
    Logic kc(int v) => Const(v, width: w);
    Logic add(List<Logic> xs) => xs.reduce((x, y) => (x + y).getRange(0, w));
    Logic mul(Logic x, Logic y) => (x * y).getRange(0, w);

    // Weighted sum for a given window accessor (A or B), per mode.
    Logic weighted(Logic Function(int) g) {
      // mode 0: (g4+g3+g5+g1+g7)*4 + (g0+g2+g6+g8)*3
      final full =
          (mul(add([g(4), g(3), g(5), g(1), g(7)]), kc(4)) +
                  mul(add([g(0), g(2), g(6), g(8)]), kc(3)))
              .getRange(0, w);
      // mode 1: (g1+g7)*6 + (g0+g2+g6+g8)*5
      final fastE =
          (mul(add([g(1), g(7)]), kc(6)) +
                  mul(add([g(0), g(2), g(6), g(8)]), kc(5)))
              .getRange(0, w);
      // mode 2: g4*6 + (g3+g5)*5
      final fastO = (mul(g(4), kc(6)) + mul(add([g(3), g(5)]), kc(5))).getRange(
        0,
        w,
      );
      return mux(mode.eq(0), full, mux(mode.eq(1), fastE, fastO));
    }

    final av = weighted(a);
    final bv = weighted(b);
    final v = (mul(av, center) + bv).getRange(0, w);

    // shift = nb + 4: 9 for modes 0/1 (nb 5), 8 for mode 2 (nb 4).
    final shift9 = (v + kc(1 << 8)).getRange(9, 9 + fltW);
    final shift8 = (v + kc(1 << 7)).getRange(8, 8 + fltW);
    output('flt') <= mux(mode.eq(2), shift8, shift9);
  }
}

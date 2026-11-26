import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor deblocking loop filter (the AV1 / VP9 4-tap narrow filter, `filter4`).
///
/// Operates on one 8-pixel line straddling a block edge (p3 p2 p1 p0 | q0 q1 q2
/// q3, packed LSB-first in `line`). A filter mask gates filtering on the local
/// gradients against `limit` / `blimit`. A high-edge-variance (hev) mask decides
/// whether the outer taps and the p1/q1 adjustment apply. The 4-tap filter then
/// nudges p1,p0,q0,q1 toward each other to soften the edge, exactly as libaom's
/// `aom_dsp/loopfilter.c filter4`/`filter_mask`/`hev_mask`. Combinational.
/// Outputs the four filtered pixels op1,op0,oq0,oq1 (p3,p2,q2,q3 are unchanged).
///
/// This is the narrow filter only. The wider 6/8/13/14-tap flat filters, the
/// per-edge filter-level derivation, and CDEF / loop restoration are follow-ups.
class HarborDeblockFilter extends BridgeModule {
  /// When [narrowOnly], the wide flat filter (filter8) is disabled and only the
  /// 4-tap filter4 is applied: the correct behaviour for 4x4 transform blocks.
  HarborDeblockFilter({bool narrowOnly = false, String? name})
    : super('HarborDeblockFilter', name: name ?? 'deblock') {
    const w = 12; // signed working width

    createPort('line', PortDirection.input, width: 64); // 8 pixels, LSB first
    createPort('blimit', PortDirection.input, width: 8);
    createPort('limit', PortDirection.input, width: 8);
    createPort('thresh', PortDirection.input, width: 8);
    createPort(
      'flat_thresh',
      PortDirection.input,
      width: 8,
    ); // flat-region thresh
    // op2, op1, op0, oq0, oq1, oq2 (LSB first). The narrow filter leaves op2/oq2
    // = p2/q2. The wide flat filter (filter8) updates all six.
    addOutput('filtered', width: 48);

    Logic px(int i) => input('line').getRange(i * 8, i * 8 + 8);
    final p3 = px(0), p2 = px(1), p1 = px(2), p0 = px(3);
    final q0 = px(4), q1 = px(5), q2 = px(6), q3 = px(7);
    final blimit = input('blimit');
    final limit = input('limit');
    final thresh = input('thresh');

    // |a - b| for unsigned 8-bit values (9-bit result).
    Logic absDiff(Logic a, Logic b) {
      final ae = a.zeroExtend(9), be = b.zeroExtend(9);
      return mux(
        ae.gte(be),
        (ae - be).getRange(0, 9),
        (be - ae).getRange(0, 9),
      );
    }

    // filter_mask: 1 when the edge should be filtered (all gradients in range).
    final lim9 = limit.zeroExtend(9);
    Logic le(Logic d) => d.lte(lim9);
    final flatOk =
        le(absDiff(p3, p2)) &
        le(absDiff(p2, p1)) &
        le(absDiff(p1, p0)) &
        le(absDiff(q1, q0)) &
        le(absDiff(q2, q1)) &
        le(absDiff(q3, q2));
    final edge =
        ((absDiff(p0, q0).zeroExtend(11) << 1).getRange(0, 11) +
                (absDiff(p1, q1) >>> 1).zeroExtend(11))
            .getRange(0, 11);
    final maskBit = flatOk & edge.lte(blimit.zeroExtend(11));

    // hev_mask: high edge variance.
    final hev =
        absDiff(p1, p0).gt(thresh.zeroExtend(9)) |
        absDiff(q1, q0).gt(thresh.zeroExtend(9));

    // Signed working values: x ^ 0x80 is x - 128 in two's complement.
    Logic sgn(Logic u8) => (u8 ^ Const(0x80, width: 8)).signExtend(w);
    final ps1 = sgn(p1), ps0 = sgn(p0), qs0 = sgn(q0), qs1 = sgn(q1);

    // Clamp a w-bit signed value to the signed 8-bit range [-128, 127].
    Logic clampS(Logic x) {
      final sign = x[w - 1];
      final hi = x.getRange(7, w); // bits 7..w-1
      final inRange = hi.eq(sign.replicate(w - 7));
      final sat = mux<Logic>(
        sign,
        Const(0x80, width: 8),
        Const(0x7F, width: 8),
      );
      return mux(inRange, x.getRange(0, 8), sat).signExtend(w);
    }

    Logic asr(Logic x, int n) =>
        [x[w - 1].replicate(n), x.getRange(n, w)].concat();

    // filter = (hev ? clamp(ps1 - qs1) : 0), then += 3*(qs0 - ps0), clamped.
    final outer = mux(
      hev,
      clampS((ps1 - qs1).getRange(0, w)),
      Const(0, width: w),
    );
    final qmp = (qs0 - ps0).getRange(0, w);
    final inner = clampS(
      (outer + ((qmp << 1).getRange(0, w) + qmp).getRange(0, w)).getRange(0, w),
    );
    final filter = mux(maskBit, inner, Const(0, width: w));

    final filter1 = asr(
      clampS((filter + Const(4, width: w)).getRange(0, w)),
      3,
    );
    final filter2 = asr(
      clampS((filter + Const(3, width: w)).getRange(0, w)),
      3,
    );

    final oq0 = clampS((qs0 - filter1).getRange(0, w));
    final op0 = clampS((ps0 + filter2).getRange(0, w));

    // Outer-tap adjustment: (filter1 + 1) >> 1, applied only when not hev.
    final fAdj = mux(
      hev,
      Const(0, width: w),
      asr((filter1 + Const(1, width: w)).getRange(0, w), 1),
    );
    final oq1 = clampS((qs1 - fAdj).getRange(0, w));
    final op1 = clampS((ps1 + fAdj).getRange(0, w));

    // Back to unsigned 8-bit (x ^ 0x80) and the narrow-filter pixels.
    Logic uns(Logic s) => s.getRange(0, 8) ^ Const(0x80, width: 8);
    final f4p1 = uns(op1), f4p0 = uns(op0), f4q0 = uns(oq0), f4q1 = uns(oq1);

    // flat_mask4: the six pixels are all within flat_thresh of p0 / q0.
    final ft9 = input('flat_thresh').zeroExtend(9);
    Logic flatLe(Logic d) => d.lte(ft9);
    final flat =
        flatLe(absDiff(p1, p0)) &
        flatLe(absDiff(q1, q0)) &
        flatLe(absDiff(p2, p0)) &
        flatLe(absDiff(q2, q0)) &
        flatLe(absDiff(p3, p0)) &
        flatLe(absDiff(q3, q0));
    final useWide = narrowOnly ? Const(0) : (flat & maskBit);

    // filter8: the wide 7-tap flat average, ROUND_POWER_OF_TWO(sum, 3).
    Logic avg(List<Logic> terms) {
      Logic acc = Const(4, width: 12); // rounding bias
      for (final t in terms) {
        acc = (acc + t.zeroExtend(12)).getRange(0, 12);
      }
      return (acc >>> 3).getRange(0, 8);
    }

    final w2 = [p3, p3, p3, p2, p2, p1, p0, q0]; // 3p3 + 2p2 + p1 + p0 + q0
    final w1 = [p3, p3, p2, p1, p1, p0, q0, q1];
    final w0 = [p3, p2, p1, p0, p0, q0, q1, q2];
    final wq0 = [p2, p1, p0, q0, q0, q1, q2, q3];
    final wq1 = [p1, p0, q0, q1, q1, q2, q3, q3];
    final wq2 = [p0, q0, q1, q2, q2, q3, q3, q3];

    output('filtered') <=
        [
          mux(useWide, avg(wq2), q2), // oq2
          mux(useWide, avg(wq1), f4q1),
          mux(useWide, avg(wq0), f4q0),
          mux(useWide, avg(w0), f4p0),
          mux(useWide, avg(w1), f4p1),
          mux(useWide, avg(w2), p2), // op2
        ].concat();
  }
}

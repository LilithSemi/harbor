import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 deblocking WIDE (filter8) luma edge filter (libaom
/// `filter8`). Bit-depth aware (`bd` 8/10/12). The 8-tap-decision filter: when
/// the region is flat the 7-tap [1,1,1,2,1,1,1] kernel modifies p2..q2,
/// otherwise it falls back to the 4-tap `filter4` (p1..q1). p3/q3 always pass
/// through.
///
/// Ports: pixel inputs `p3`..`q3` and outputs `op3`..`oq3` are `bd` bits.
/// `limit`,`blimit`,`thresh` stay 8 bits. Combinational.
class HarborDeblock8 extends BridgeModule {
  HarborDeblock8({String? name, int bd = 8})
    : super('HarborDeblock8_B$bd', name: name ?? 'deblock8') {
    for (final p in ['p3', 'p2', 'p1', 'p0', 'q0', 'q1', 'q2', 'q3']) {
      createPort(p, PortDirection.input, width: bd);
    }
    for (final p in ['limit', 'blimit', 'thresh']) {
      createPort(p, PortDirection.input, width: 8);
    }
    for (final o in ['op3', 'op2', 'op1', 'op0', 'oq0', 'oq1', 'oq2', 'oq3']) {
      addOutput(o, width: bd);
    }

    final s = bd - 8;
    final w = bd + 4;
    final off = 0x80 << s;
    final maxv = (128 << s) - 1;
    final minv = -(128 << s);
    Logic se(Logic v) => v.zeroExtend(w);
    Logic kc(int v) => Const(BigInt.from(v).toUnsigned(w), width: w);
    Logic thr(Logic v) => s == 0 ? se(v) : se(v) << s;
    Logic absDiff(Logic a, Logic b) => mux(
      a.gte(b),
      (a - b).getRange(0, bd),
      (b - a).getRange(0, bd),
    ).zeroExtend(w);
    Logic clampSC(Logic x) {
      final gtMax = (kc(maxv) - x).getRange(0, w)[w - 1];
      final ltMin = (x - kc(minv)).getRange(0, w)[w - 1];
      return mux(ltMin, kc(minv), mux(gtMax, kc(maxv), x));
    }

    Logic ashr(Logic x, int sh) =>
        [x[w - 1].replicate(sh), x.getRange(sh, w)].swizzle();
    // round_pow2(sum, 3) over an unsigned sum (= (sum + 4) >> 3), bd-bit result.
    Logic rp3(Logic sum) => (sum + kc(4)).getRange(3, 3 + bd);

    final p3 = input('p3'),
        p2 = input('p2'),
        p1 = input('p1'),
        p0 = input('p0');
    final q0 = input('q0'),
        q1 = input('q1'),
        q2 = input('q2'),
        q3 = input('q3');
    final limit = input('limit'),
        blimit = input('blimit'),
        thresh = input('thresh');
    Logic mul(Logic a, int k) => (a.zeroExtend(w) * kc(k)).getRange(0, w);

    // filter_mask (8-tap): OFF when any |diff| > limit or the blimit term.
    final cond8 =
        absDiff(p3, p2).gt(thr(limit)) |
        absDiff(p2, p1).gt(thr(limit)) |
        absDiff(p1, p0).gt(thr(limit)) |
        absDiff(q1, q0).gt(thr(limit)) |
        absDiff(q2, q1).gt(thr(limit)) |
        absDiff(q3, q2).gt(thr(limit)) |
        ((absDiff(p0, q0) * kc(2)).getRange(0, w) + ashr(absDiff(p1, q1), 1))
            .getRange(0, w)
            .gt(thr(blimit));
    final mask8 = ~cond8;
    // flat_mask4 (thresh = 1, bd-scaled).
    final flatThr = kc(1 << s);
    final condFlat =
        absDiff(p1, p0).gt(flatThr) |
        absDiff(q1, q0).gt(flatThr) |
        absDiff(p2, p0).gt(flatThr) |
        absDiff(q2, q0).gt(flatThr) |
        absDiff(p3, p0).gt(flatThr) |
        absDiff(q3, q0).gt(flatThr);
    final flat4 = ~condFlat;
    final useWide = mask8 & flat4;

    // 7-tap wide kernel (set p2..q2)
    final w2 =
        mul(p3, 3).getRange(0, w) +
        mul(p2, 2).getRange(0, w) +
        se(p1) +
        se(p0) +
        se(q0);
    final w1 =
        mul(p3, 2).getRange(0, w) +
        se(p2) +
        mul(p1, 2).getRange(0, w) +
        se(p0) +
        se(q0) +
        se(q1);
    final w0p =
        se(p3) +
        se(p2) +
        se(p1) +
        mul(p0, 2).getRange(0, w) +
        se(q0) +
        se(q1) +
        se(q2);
    final w0q =
        se(p2) +
        se(p1) +
        se(p0) +
        mul(q0, 2).getRange(0, w) +
        se(q1) +
        se(q2) +
        se(q3);
    final w1q =
        se(p1) +
        se(p0) +
        se(q0) +
        mul(q1, 2).getRange(0, w) +
        se(q2) +
        mul(q3, 2).getRange(0, w);
    final w2q =
        se(p0) +
        se(q0) +
        se(q1) +
        mul(q2, 2).getRange(0, w) +
        mul(q3, 3).getRange(0, w);
    final wideOp2 = rp3(w2.getRange(0, w));
    final wideOp1 = rp3(w1.getRange(0, w));
    final wideOp0 = rp3(w0p.getRange(0, w));
    final wideOq0 = rp3(w0q.getRange(0, w));
    final wideOq1 = rp3(w1q.getRange(0, w));
    final wideOq2 = rp3(w2q.getRange(0, w));

    // 4-tap fallback (filter4 with mask8)
    final ps1 = (se(p1) - kc(off)).getRange(0, w);
    final ps0 = (se(p0) - kc(off)).getRange(0, w);
    final qs0 = (se(q0) - kc(off)).getRange(0, w);
    final qs1 = (se(q1) - kc(off)).getRange(0, w);
    final hev =
        absDiff(p1, p0).gt(thr(thresh)) | absDiff(q1, q0).gt(thr(thresh));
    var filter = mux(hev, clampSC((ps1 - qs1).getRange(0, w)), kc(0));
    filter = mux(
      mask8,
      clampSC(
        (filter + (kc(3) * (qs0 - ps0).getRange(0, w)).getRange(0, w)).getRange(
          0,
          w,
        ),
      ),
      kc(0),
    );
    final filter1 = ashr(clampSC((filter + kc(4)).getRange(0, w)), 3);
    final filter2 = ashr(clampSC((filter + kc(3)).getRange(0, w)), 3);
    final f4Oq0 = (clampSC((qs0 - filter1).getRange(0, w)) + kc(off)).getRange(
      0,
      bd,
    );
    final f4Op0 = (clampSC((ps0 + filter2).getRange(0, w)) + kc(off)).getRange(
      0,
      bd,
    );
    final fAdj = mux(hev, kc(0), ashr((filter1 + kc(1)).getRange(0, w), 1));
    final f4Oq1 = (clampSC((qs1 - fAdj).getRange(0, w)) + kc(off)).getRange(
      0,
      bd,
    );
    final f4Op1 = (clampSC((ps1 + fAdj).getRange(0, w)) + kc(off)).getRange(
      0,
      bd,
    );

    output('op3') <= p3;
    output('oq3') <= q3;
    output('op2') <= mux(useWide, wideOp2, p2);
    output('oq2') <= mux(useWide, wideOq2, q2);
    output('op1') <= mux(useWide, wideOp1, f4Op1);
    output('op0') <= mux(useWide, wideOp0, f4Op0);
    output('oq0') <= mux(useWide, wideOq0, f4Oq0);
    output('oq1') <= mux(useWide, wideOq1, f4Oq1);
  }
}

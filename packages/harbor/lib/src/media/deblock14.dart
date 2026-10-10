import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 deblocking WIDEST (filter14) luma edge filter (libaom
/// `filter14`). Bit-depth aware (`bd` 8/10/12). The 13-tap decision filter
/// operating on 14 samples straddling the edge. When the region is flat across
/// the whole 14-tap span (flat2 and flat and mask) the 13-tap kernel rewrites
/// p5..q5. Otherwise it falls back to `filter8` (7-tap wide p2..q2 or `filter4`
/// p1..q1). p6/q6 always pass through.
///
/// Ports: pixel inputs `p6`..`q6` and outputs `op6`..`oq6` are `bd` bits.
/// `limit`,`blimit`,`thresh` stay 8 bits. Combinational.
class HarborDeblock14 extends BridgeModule {
  HarborDeblock14({String? name, int bd = 8})
    : super('HarborDeblock14_B$bd', name: name ?? 'deblock14') {
    for (final p in [
      'p6', 'p5', 'p4', 'p3', 'p2', 'p1', 'p0', //
      'q0', 'q1', 'q2', 'q3', 'q4', 'q5', 'q6', //
    ]) {
      createPort(p, PortDirection.input, width: bd);
    }
    for (final p in ['limit', 'blimit', 'thresh']) {
      createPort(p, PortDirection.input, width: 8);
    }
    for (final o in [
      'op6', 'op5', 'op4', 'op3', 'op2', 'op1', 'op0', //
      'oq0', 'oq1', 'oq2', 'oq3', 'oq4', 'oq5', 'oq6',
    ]) {
      addOutput(o, width: bd);
    }

    final s = bd - 8;
    final w = bd + 8; // working width (13-tap sum up to 16*4095 for bd=12)
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
    Logic mul(Logic a, int k) => (a.zeroExtend(w) * kc(k)).getRange(0, w);
    // round_pow2(sum, n) = (sum + (1<<(n-1))) >> n, unsigned sum -> bd-bit.
    Logic rp(Logic sum, int n) => (sum + kc(1 << (n - 1))).getRange(n, n + bd);
    // weighted sum of [logic, coeff] terms at width w.
    Logic wsum(List<List<Object>> terms) {
      var acc = kc(0);
      for (final t in terms) {
        final v = t[0] as Logic;
        final k = t[1] as int;
        final term = k == 1 ? se(v) : mul(v, k);
        acc = (acc + term).getRange(0, w);
      }
      return acc;
    }

    final p6 = input('p6'),
        p5 = input('p5'),
        p4 = input('p4'),
        p3 = input('p3');
    final p2 = input('p2'), p1 = input('p1'), p0 = input('p0');
    final q0 = input('q0'),
        q1 = input('q1'),
        q2 = input('q2'),
        q3 = input('q3');
    final q4 = input('q4'), q5 = input('q5'), q6 = input('q6');
    final limit = input('limit'),
        blimit = input('blimit'),
        thresh = input('thresh');

    // filter_mask (8-tap) on p3..q3.
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
    final flatThr = kc(1 << s);
    // flat_mask4 (thresh 1) on p3..q3.
    final condFlat =
        absDiff(p1, p0).gt(flatThr) |
        absDiff(q1, q0).gt(flatThr) |
        absDiff(p2, p0).gt(flatThr) |
        absDiff(q2, q0).gt(flatThr) |
        absDiff(p3, p0).gt(flatThr) |
        absDiff(q3, q0).gt(flatThr);
    final flat4 = ~condFlat;
    // flat_mask4 (thresh 1) on outer span: p6/p5/p4 and q4/q5/q6 vs p0/q0.
    final condFlat2 =
        absDiff(p4, p0).gt(flatThr) |
        absDiff(q4, q0).gt(flatThr) |
        absDiff(p5, p0).gt(flatThr) |
        absDiff(q5, q0).gt(flatThr) |
        absDiff(p6, p0).gt(flatThr) |
        absDiff(q6, q0).gt(flatThr);
    final flat2 = ~condFlat2;

    final useWide14 = mask8 & flat4 & flat2;
    final useWide8 = mask8 & flat4;

    // 13-tap kernel (rewrites p5..q5), round_pow2 by 4
    final k14 = {
      'op5': wsum([
        [p6, 7],
        [p5, 2],
        [p4, 2],
        [p3, 1],
        [p2, 1],
        [p1, 1],
        [p0, 1],
        [q0, 1],
      ]),
      'op4': wsum([
        [p6, 5],
        [p5, 2],
        [p4, 2],
        [p3, 2],
        [p2, 1],
        [p1, 1],
        [p0, 1],
        [q0, 1],
        [q1, 1],
      ]),
      'op3': wsum([
        [p6, 4],
        [p5, 1],
        [p4, 2],
        [p3, 2],
        [p2, 2],
        [p1, 1],
        [p0, 1],
        [q0, 1],
        [q1, 1],
        [q2, 1],
      ]),
      'op2': wsum([
        [p6, 3],
        [p5, 1],
        [p4, 1],
        [p3, 2],
        [p2, 2],
        [p1, 2],
        [p0, 1],
        [q0, 1],
        [q1, 1],
        [q2, 1],
        [q3, 1],
      ]),
      'op1': wsum([
        [p6, 2],
        [p5, 1],
        [p4, 1],
        [p3, 1],
        [p2, 2],
        [p1, 2],
        [p0, 2],
        [q0, 1],
        [q1, 1],
        [q2, 1],
        [q3, 1],
        [q4, 1],
      ]),
      'op0': wsum([
        [p6, 1],
        [p5, 1],
        [p4, 1],
        [p3, 1],
        [p2, 1],
        [p1, 2],
        [p0, 2],
        [q0, 2],
        [q1, 1],
        [q2, 1],
        [q3, 1],
        [q4, 1],
        [q5, 1],
      ]),
      'oq0': wsum([
        [p5, 1],
        [p4, 1],
        [p3, 1],
        [p2, 1],
        [p1, 1],
        [p0, 2],
        [q0, 2],
        [q1, 2],
        [q2, 1],
        [q3, 1],
        [q4, 1],
        [q5, 1],
        [q6, 1],
      ]),
      'oq1': wsum([
        [p4, 1],
        [p3, 1],
        [p2, 1],
        [p1, 1],
        [p0, 1],
        [q0, 2],
        [q1, 2],
        [q2, 2],
        [q3, 1],
        [q4, 1],
        [q5, 1],
        [q6, 2],
      ]),
      'oq2': wsum([
        [p3, 1],
        [p2, 1],
        [p1, 1],
        [p0, 1],
        [q0, 1],
        [q1, 2],
        [q2, 2],
        [q3, 2],
        [q4, 1],
        [q5, 1],
        [q6, 3],
      ]),
      'oq3': wsum([
        [p2, 1],
        [p1, 1],
        [p0, 1],
        [q0, 1],
        [q1, 1],
        [q2, 2],
        [q3, 2],
        [q4, 2],
        [q5, 1],
        [q6, 4],
      ]),
      'oq4': wsum([
        [p1, 1],
        [p0, 1],
        [q0, 1],
        [q1, 1],
        [q2, 1],
        [q3, 2],
        [q4, 2],
        [q5, 2],
        [q6, 5],
      ]),
      'oq5': wsum([
        [p0, 1],
        [q0, 1],
        [q1, 1],
        [q2, 1],
        [q3, 1],
        [q4, 2],
        [q5, 2],
        [q6, 7],
      ]),
    }.map((k, v) => MapEntry(k, rp(v, 4)));

    // 7-tap wide kernel (filter8 path, rewrites p2..q2), round_pow2 by 3
    Logic rp3(Logic v) => rp(v, 3);
    final wOp2 = rp3(
      wsum([
        [p3, 3],
        [p2, 2],
        [p1, 1],
        [p0, 1],
        [q0, 1],
      ]),
    );
    final wOp1 = rp3(
      wsum([
        [p3, 2],
        [p2, 1],
        [p1, 2],
        [p0, 1],
        [q0, 1],
        [q1, 1],
      ]),
    );
    final wOp0 = rp3(
      wsum([
        [p3, 1],
        [p2, 1],
        [p1, 1],
        [p0, 2],
        [q0, 1],
        [q1, 1],
        [q2, 1],
      ]),
    );
    final wOq0 = rp3(
      wsum([
        [p2, 1],
        [p1, 1],
        [p0, 1],
        [q0, 2],
        [q1, 1],
        [q2, 1],
        [q3, 1],
      ]),
    );
    final wOq1 = rp3(
      wsum([
        [p1, 1],
        [p0, 1],
        [q0, 1],
        [q1, 2],
        [q2, 1],
        [q3, 2],
      ]),
    );
    final wOq2 = rp3(
      wsum([
        [p0, 1],
        [q0, 1],
        [q1, 1],
        [q2, 2],
        [q3, 3],
      ]),
    );

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

    // p2..q2 from filter8 path (wide8 or filter4).
    final f8Op2 = mux(useWide8, wOp2, p2);
    final f8Oq2 = mux(useWide8, wOq2, q2);
    final f8Op1 = mux(useWide8, wOp1, f4Op1);
    final f8Op0 = mux(useWide8, wOp0, f4Op0);
    final f8Oq0 = mux(useWide8, wOq0, f4Oq0);
    final f8Oq1 = mux(useWide8, wOq1, f4Oq1);

    output('op6') <= p6;
    output('oq6') <= q6;
    output('op5') <= mux(useWide14, k14['op5']!, p5);
    output('oq5') <= mux(useWide14, k14['oq5']!, q5);
    output('op4') <= mux(useWide14, k14['op4']!, p4);
    output('oq4') <= mux(useWide14, k14['oq4']!, q4);
    output('op3') <= mux(useWide14, k14['op3']!, p3);
    output('oq3') <= mux(useWide14, k14['oq3']!, q3);
    output('op2') <= mux(useWide14, k14['op2']!, f8Op2);
    output('oq2') <= mux(useWide14, k14['oq2']!, f8Oq2);
    output('op1') <= mux(useWide14, k14['op1']!, f8Op1);
    output('op0') <= mux(useWide14, k14['op0']!, f8Op0);
    output('oq0') <= mux(useWide14, k14['oq0']!, f8Oq0);
    output('oq1') <= mux(useWide14, k14['oq1']!, f8Oq1);
  }
}

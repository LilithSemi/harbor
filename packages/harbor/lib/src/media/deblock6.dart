import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 deblocking chroma WIDE (filter6) edge filter (libaom
/// `filter6`). Bit-depth aware (`bd` 8/10/12). The 5-tap [1,2,2,2,1] kernel used
/// on chroma 8-wide edges: when the region is flat (flat_mask3_chroma and
/// filter_mask3_chroma) the kernel rewrites p1..q1. Otherwise it falls back to
/// `filter4`. p2/q2 always pass through.
///
/// Ports: pixel inputs `p2`,`p1`,`p0`,`q0`,`q1`,`q2` and outputs
/// `op2`..`oq2` are `bd` bits. `limit`,`blimit`,`thresh` stay 8 bits.
/// Combinational.
class HarborDeblock6 extends BridgeModule {
  HarborDeblock6({String? name, int bd = 8})
    : super('HarborDeblock6_B$bd', name: name ?? 'deblock6') {
    for (final p in ['p2', 'p1', 'p0', 'q0', 'q1', 'q2']) {
      createPort(p, PortDirection.input, width: bd);
    }
    for (final p in ['limit', 'blimit', 'thresh']) {
      createPort(p, PortDirection.input, width: 8);
    }
    for (final o in ['op2', 'op1', 'op0', 'oq0', 'oq1', 'oq2']) {
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
    Logic mul(Logic a, int k) => (a.zeroExtend(w) * kc(k)).getRange(0, w);
    Logic rp3(Logic sum) => (sum + kc(4)).getRange(3, 3 + bd);
    Logic wsum(List<List<Object>> terms) {
      var acc = kc(0);
      for (final t in terms) {
        final v = t[0] as Logic;
        final k = t[1] as int;
        acc = (acc + (k == 1 ? se(v) : mul(v, k))).getRange(0, w);
      }
      return acc;
    }

    final p2 = input('p2'), p1 = input('p1'), p0 = input('p0');
    final q0 = input('q0'), q1 = input('q1'), q2 = input('q2');
    final limit = input('limit'),
        blimit = input('blimit'),
        thresh = input('thresh');

    // filter_mask3_chroma (6-tap decision).
    final cond =
        absDiff(p2, p1).gt(thr(limit)) |
        absDiff(p1, p0).gt(thr(limit)) |
        absDiff(q1, q0).gt(thr(limit)) |
        absDiff(q2, q1).gt(thr(limit)) |
        ((absDiff(p0, q0) * kc(2)).getRange(0, w) + ashr(absDiff(p1, q1), 1))
            .getRange(0, w)
            .gt(thr(blimit));
    final maskOn = ~cond;
    // flat_mask3_chroma (thresh 1, bd-scaled).
    final flatThr = kc(1 << s);
    final condFlat =
        absDiff(p1, p0).gt(flatThr) |
        absDiff(q1, q0).gt(flatThr) |
        absDiff(p2, p0).gt(flatThr) |
        absDiff(q2, q0).gt(flatThr);
    final flat = ~condFlat;
    final useWide = maskOn & flat;

    // 5-tap [1,2,2,2,1] wide kernel (rewrites p1..q1)
    final wOp1 = rp3(
      wsum([
        [p2, 3],
        [p1, 2],
        [p0, 2],
        [q0, 1],
      ]),
    );
    final wOp0 = rp3(
      wsum([
        [p2, 1],
        [p1, 2],
        [p0, 2],
        [q0, 2],
        [q1, 1],
      ]),
    );
    final wOq0 = rp3(
      wsum([
        [p1, 1],
        [p0, 2],
        [q0, 2],
        [q1, 2],
        [q2, 1],
      ]),
    );
    final wOq1 = rp3(
      wsum([
        [p0, 1],
        [q0, 2],
        [q1, 2],
        [q2, 3],
      ]),
    );

    // 4-tap fallback (filter4 with maskOn)
    final ps1 = (se(p1) - kc(off)).getRange(0, w);
    final ps0 = (se(p0) - kc(off)).getRange(0, w);
    final qs0 = (se(q0) - kc(off)).getRange(0, w);
    final qs1 = (se(q1) - kc(off)).getRange(0, w);
    final hev =
        absDiff(p1, p0).gt(thr(thresh)) | absDiff(q1, q0).gt(thr(thresh));
    var filter = mux(hev, clampSC((ps1 - qs1).getRange(0, w)), kc(0));
    filter = mux(
      maskOn,
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

    output('op2') <= p2;
    output('oq2') <= q2;
    output('op1') <= mux(useWide, wOp1, f4Op1);
    output('op0') <= mux(useWide, wOp0, f4Op0);
    output('oq0') <= mux(useWide, wOq0, f4Oq0);
    output('oq1') <= mux(useWide, wOq1, f4Oq1);
  }
}

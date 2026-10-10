import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 deblocking NARROW (filter4) edge filter (libaom
/// `aom_lpf_*_4` / `filter4`), the 4-tap loop filter and the fallback for the
/// wider filters. Bit-depth aware (`bd` 8/10/12).
///
/// Operates on the four samples straddling a block edge (p1, p0 | q0, q1),
/// computing the filter_mask2 (4-tap) and hev_mask internally from the loop
/// params (`limit`, `blimit`, `thresh`, all derived from the filter level), then
/// applying the 4-tap kernel. When the mask is off the output equals the input.
///
/// Ports: pixel inputs `p1`,`p0`,`q0`,`q1` and outputs `op1`,`op0`,`oq0`,`oq1`
/// are `bd` bits, the level-derived `limit`,`blimit`,`thresh` stay 8 bits (the
/// bd scaling `<< (bd-8)` happens inside the masks). Combinational.
class HarborDeblock4 extends BridgeModule {
  HarborDeblock4({String? name, int bd = 8})
    : super('HarborDeblock4_B$bd', name: name ?? 'deblock4') {
    for (final p in ['p1', 'p0', 'q0', 'q1']) {
      createPort(p, PortDirection.input, width: bd);
    }
    for (final p in ['limit', 'blimit', 'thresh']) {
      createPort(p, PortDirection.input, width: 8);
    }
    for (final o in ['op1', 'op0', 'oq0', 'oq1']) {
      addOutput(o, width: bd);
    }

    final s = bd - 8; // bd scaling shift
    final w = bd + 4; // signed working width (bd=8 -> 12)
    final off = 0x80 << s; // signed<->unsigned offset (128<<s)
    final maxv = (128 << s) - 1; // signed_char_clamp_high max
    final minv = -(128 << s); // signed_char_clamp_high min
    Logic se(Logic v) => v.zeroExtend(w); // -> w-bit
    Logic kc(int v) => Const(BigInt.from(v).toUnsigned(w), width: w);
    // Threshold scaled by bd: limit/blimit/thresh << (bd-8).
    Logic thr(Logic v) => s == 0 ? se(v) : se(v) << s;
    // |a - b| for bd-bit unsigned a,b -> w-bit.
    Logic absDiff(Logic a, Logic b) => mux(
      a.gte(b),
      (a - b).getRange(0, bd),
      (b - a).getRange(0, bd),
    ).zeroExtend(w);
    // signed_char_clamp to [minv, maxv] (house idiom via subtraction sign bits).
    Logic clampSC(Logic x) {
      final gtMax = (kc(maxv) - x).getRange(0, w)[w - 1]; // maxv - x < 0
      final ltMin = (x - kc(minv)).getRange(0, w)[w - 1];
      return mux(ltMin, kc(minv), mux(gtMax, kc(maxv), x));
    }

    // arithmetic shift right.
    Logic ashr(Logic x, int sh) =>
        [x[w - 1].replicate(sh), x.getRange(sh, w)].swizzle();

    final p1 = input('p1'),
        p0 = input('p0'),
        q0 = input('q0'),
        q1 = input('q1');
    final limit = input('limit'),
        blimit = input('blimit'),
        thresh = input('thresh');

    final ps1 = (se(p1) - kc(off)).getRange(0, w);
    final ps0 = (se(p0) - kc(off)).getRange(0, w);
    final qs0 = (se(q0) - kc(off)).getRange(0, w);
    final qs1 = (se(q1) - kc(off)).getRange(0, w);

    final hev =
        absDiff(p1, p0).gt(thr(thresh)) | absDiff(q1, q0).gt(thr(thresh));
    // filter_mask2 condition (mask OFF when any holds).
    final cond =
        absDiff(p1, p0).gt(thr(limit)) |
        absDiff(q1, q0).gt(thr(limit)) |
        ((absDiff(p0, q0) * kc(2)).getRange(0, w) + ashr(absDiff(p1, q1), 1))
            .getRange(0, w)
            .gt(thr(blimit));
    final maskOn = ~cond;

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

    final oq0v = clampSC((qs0 - filter1).getRange(0, w));
    final op0v = clampSC((ps0 + filter2).getRange(0, w));
    // f = hev ? 0 : round_pow2(filter1, 1) = (filter1 + 1) >> 1.
    final f = mux(hev, kc(0), ashr((filter1 + kc(1)).getRange(0, w), 1));
    final oq1v = clampSC((qs1 - f).getRange(0, w));
    final op1v = clampSC((ps1 + f).getRange(0, w));

    // + off back to unsigned bd-bit.
    output('oq0') <= (oq0v + kc(off)).getRange(0, bd);
    output('op0') <= (op0v + kc(off)).getRange(0, bd);
    output('oq1') <= (oq1v + kc(off)).getRange(0, bd);
    output('op1') <= (op1v + kc(off)).getRange(0, bd);
  }
}

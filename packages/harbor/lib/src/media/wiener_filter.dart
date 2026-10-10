import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

const _filterBits = 7;

/// libaom `get_conv_params_wiener` round_0/round_1 for a bit depth [bd].
///
/// Defaults are round_0=3, round_1=11. When the horizontal intermediate buffer
/// would overflow 16 bits (`intbufrange = bd + FILTER_BITS - round0 + 2 > 16`)
/// libaom shifts precision from round_1 into round_0. This only fires at 12-bit
/// (8/10-bit keep 3/11, 12-bit -> 5/9).
({int round0, int round1}) wienerRounds(int bd) {
  var round0 = 3;
  var round1 = 2 * _filterBits - round0; // 11
  final intbufrange = bd + _filterBits - round0 + 2;
  if (intbufrange > 16) {
    round0 += intbufrange - 16;
    round1 -= intbufrange - 16;
  }
  return (round0: round0, round1: round1);
}

/// Width of the round_0 horizontal intermediate (`mid`) for a bit depth [bd].
/// The clamped value range is `[0, (1<<(bd+1+FILTER_BITS-round0)) - 1]`. The
/// port carries one extra bit of headroom (bd8 -> 14, matching the legacy port).
int wienerMidWidth(int bd) =>
    bd + 1 + _filterBits - wienerRounds(bd).round0 + 1;

/// Harbor bit-exact AV1 Wiener restoration horizontal core (libaom
/// `wiener_convolve` round_0 pass), bit-depth aware.
///
/// Wiener restoration is AV1's third in-loop filter (after deblocking and CDEF):
/// a separable symmetric 7-tap FIR. This is the horizontal pass over one 7-pixel
/// line `p0..p6` (centre `p3`, each [bd]-bit). Only the three half-taps
/// `t0,t1,t2` (signed) are signalled. The centre tap is `tc = -2*(t0+t1+t2)`,
/// and the centre pixel is re-added through the rounding offset exactly as
/// libaom:
///   sum = t0*(p0+p6) + t1*(p1+p5) + t2*(p2+p4) + tc*p3
///   val = clamp((sum + (p3<<7) + (1<<(bd+6)) + (1<<(round0-1))) >> round0,
///               0, clampLimit-1)
/// with `clampLimit = 1 << (bd + 1 + FILTER_BITS - round0)`. The intermediate
/// feeds [HarborWienerVert]. Combinational.
class HarborWienerHorz extends BridgeModule {
  HarborWienerHorz({int bd = 8, String? name})
    : super('HarborWienerHorz_B$bd', name: name ?? 'wiener_h') {
    final w = bd + 16; // signed working width (bd8 -> 24)
    final rounds = wienerRounds(bd);
    final round0 = rounds.round0;
    final midW = wienerMidWidth(bd);
    final clampLimit = 1 << (bd + 1 + _filterBits - round0);

    createPort('line', PortDirection.input, width: 7 * bd); // p0..p6
    createPort('t0', PortDirection.input, width: 8); // signed half-taps
    createPort('t1', PortDirection.input, width: 8);
    createPort('t2', PortDirection.input, width: 8);
    addOutput('mid', width: midW); // round_0 intermediate, 0..clampLimit-1

    Logic p(int i) => input('line').getRange(i * bd, i * bd + bd).zeroExtend(w);
    final t0 = input('t0').signExtend(w);
    final t1 = input('t1').signExtend(w);
    final t2 = input('t2').signExtend(w);
    final tc =
        (Const(0, width: w) -
                ((t0 + t1).getRange(0, w) + t2).getRange(0, w) *
                    Const(2, width: w))
            .getRange(0, w);

    Logic mul(Logic a, Logic b) => (a * b).getRange(0, w);
    Logic pair(int a, int b) => (p(a) + p(b)).getRange(0, w);

    final sum =
        ((mul(t0, pair(0, 6)) + mul(t1, pair(1, 5))).getRange(0, w) +
                (mul(t2, pair(2, 4)) + mul(tc, p(3))).getRange(0, w))
            .getRange(0, w);
    // sum + (p3 << FILTER_BITS) + (1 << (bd+6)), then round_2 by round0.
    final off =
        ((p(3) * Const(1 << _filterBits, width: w)).getRange(0, w) +
                Const(1 << (bd + _filterBits - 1), width: w))
            .getRange(0, w);
    final pre =
        ((sum + off).getRange(0, w) + Const(1 << (round0 - 1), width: w))
            .getRange(0, w);
    final shifted = [
      pre[w - 1].replicate(round0),
      pre.getRange(round0, w),
    ].swizzle();
    final neg = shifted[w - 1];
    final tooBig = ~neg & shifted.gt(Const(clampLimit - 1, width: w));
    output('mid') <=
        mux(
          neg,
          Const(0, width: midW),
          mux(
            tooBig,
            Const(clampLimit - 1, width: midW),
            shifted.getRange(0, midW),
          ),
        );
  }
}

/// Harbor bit-exact AV1 Wiener restoration vertical core (libaom
/// `wiener_convolve` round_1 pass), bit-depth aware.
///
/// The vertical pass over seven round_0 intermediates `m0..m6` (centre `m3`,
/// each `wienerMidWidth(bd)` bits) with half-taps `v0,v1,v2` (centre
/// `vc = -2*(v0+v1+v2)`):
///   sum = v0*(m0+m6) + v1*(m1+m5) + v2*(m2+m4) + vc*m3
///   out = clip_pixel_highbd(
///           (sum + (m3<<7) - (1<<(bd+round1-1)) + (1<<(round1-1))) >> round1,
///           bd)
/// Combinational.
class HarborWienerVert extends BridgeModule {
  HarborWienerVert({int bd = 8, String? name})
    : super('HarborWienerVert_B$bd', name: name ?? 'wiener_v') {
    final w = bd + 20; // signed working width (bd8 -> 28)
    final rounds = wienerRounds(bd);
    final round1 = rounds.round1;
    final midW = wienerMidWidth(bd);
    final hi = (1 << bd) - 1;

    createPort('col', PortDirection.input, width: 7 * midW); // m0..m6
    createPort('t0', PortDirection.input, width: 8);
    createPort('t1', PortDirection.input, width: 8);
    createPort('t2', PortDirection.input, width: 8);
    addOutput('out', width: bd);

    Logic m(int i) =>
        input('col').getRange(i * midW, i * midW + midW).zeroExtend(w);
    final t0 = input('t0').signExtend(w);
    final t1 = input('t1').signExtend(w);
    final t2 = input('t2').signExtend(w);
    final tc =
        (Const(0, width: w) -
                ((t0 + t1).getRange(0, w) + t2).getRange(0, w) *
                    Const(2, width: w))
            .getRange(0, w);

    Logic mul(Logic a, Logic b) => (a * b).getRange(0, w);
    Logic pair(int a, int b) => (m(a) + m(b)).getRange(0, w);

    final sum =
        ((mul(t0, pair(0, 6)) + mul(t1, pair(1, 5))).getRange(0, w) +
                (mul(t2, pair(2, 4)) + mul(tc, m(3))).getRange(0, w))
            .getRange(0, w);
    // sum + (m3 << FILTER_BITS) - (1 << (bd+round1-1)), then round_2 by round1.
    final off =
        ((m(3) * Const(1 << _filterBits, width: w)).getRange(0, w) -
                Const(1 << (bd + round1 - 1), width: w))
            .getRange(0, w);
    final pre =
        ((sum + off).getRange(0, w) + Const(1 << (round1 - 1), width: w))
            .getRange(0, w);
    final shifted = [
      pre[w - 1].replicate(round1),
      pre.getRange(round1, w),
    ].swizzle();
    final neg = shifted[w - 1];
    final tooBig = ~neg & shifted.gt(Const(hi, width: w));
    output('out') <=
        mux(
          neg,
          Const(0, width: bd),
          mux(tooBig, Const(hi, width: bd), shifted.getRange(0, bd)),
        );
  }
}

/// Harbor bit-exact AV1 2D separable Wiener restoration over a 7x7 region,
/// bit-depth aware.
///
/// Composes the round_0 horizontal core ([HarborWienerHorz], one per row of the
/// 7x7) and the round_1 vertical core ([HarborWienerVert]) over the seven
/// intermediates, reproducing libaom `_wienerConvolve` for a single output
/// pixel (the centre of the window). Horizontal half-taps `h0,h1,h2`, vertical
/// `v0,v1,v2` (all 8-bit signed).
///
/// `region` packs pixel (r,c) of the 7x7 at bits `[(r*7 + c)*bd +: bd]`,
/// LSB-first. `out` is the restored centre pixel ([bd]-bit). Combinational.
class HarborWienerFilter2D extends BridgeModule {
  HarborWienerFilter2D({int bd = 8, String? name})
    : super('HarborWienerFilter2D_B$bd', name: name ?? 'wiener2d') {
    createPort('region', PortDirection.input, width: 7 * 7 * bd);
    for (final t in ['h0', 'h1', 'h2', 'v0', 'v1', 'v2']) {
      createPort(t, PortDirection.input, width: 8);
    }
    addOutput('out', width: bd);

    final region = input('region');
    Logic px(int r, int c) =>
        region.getRange((r * 7 + c) * bd, (r * 7 + c) * bd + bd);

    // Horizontal pass: round_0 intermediate for the centre of each of 7 rows.
    final mid = <Logic>[];
    for (var r = 0; r < 7; r++) {
      final h = HarborWienerHorz(bd: bd, name: 'wh_$r');
      addSubModule(h);
      h.input('line').srcConnection! <=
          [for (var c = 6; c >= 0; c--) px(r, c)].swizzle();
      h.input('t0').srcConnection! <= input('h0');
      h.input('t1').srcConnection! <= input('h1');
      h.input('t2').srcConnection! <= input('h2');
      mid.add(h.output('mid'));
    }

    // Vertical pass over the 7 intermediates.
    final v = HarborWienerVert(bd: bd, name: 'wv');
    addSubModule(v);
    v.input('col').srcConnection! <= mid.reversed.toList().swizzle();
    v.input('t0').srcConnection! <= input('v0');
    v.input('t1').srcConnection! <= input('v1');
    v.input('t2').srcConnection! <= input('v2');
    output('out') <= v.output('out');
  }
}

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Bit-exact AV1 directional-intra edge filter (`av1_filter_intra_edge_c`), bd8.
///
/// The 5-tap edge filter smooths a reference edge before directional intra
/// prediction. For active strength `1..3` it selects one of three kernels
///   `[[0,4,8,4,0],[0,5,6,5,0],[2,4,4,4,2]]` by `filt = strength-1`,
/// then for every sample `i` in `1..sz-1` forms
///   `s = sum_j kernel[filt][j] * edge[clamp(i-2+j, 0, sz-1)]`
/// and writes `out[i] = (s + 8) >> 4` (the kernels sum to 16, so this is a
/// rounding divide by 16, no pixel clip in the SW reference). Sample `0` is
/// copied unchanged. `strength == 0` is a pure passthrough of the whole edge.
///
/// Combinational. `sz` (the active edge length) is fixed at build time, so the
/// `clamp(i-2+j, 0, sz-1)` indices are build-time constants and select the edge
/// sample directly (no runtime mux). `strength` is a runtime 2-bit input
/// (`0..3`) fed by [intraEdgeFilterStrength].
///
/// Ports: `edge_in` (`sz*8`), `strength` (2b), `out` (`sz*8`). Both `edge_in` and
/// `out` pack sample `i` LSB-first at bit `i*8`. The accumulator never exceeds
/// `255*16 = 4080`, so a 16-bit unsigned working width is exact.
class HarborIntraEdgeFilter extends BridgeModule {
  HarborIntraEdgeFilter({this.sz = 33, String? name})
    : super('HarborIntraEdgeFilter', name: name ?? 'intra_edge_filter') {
    if (sz < 2) {
      throw ArgumentError('HarborIntraEdgeFilter.sz must be >= 2, got $sz');
    }

    createPort('edge_in', PortDirection.input, width: sz * 8);
    createPort('strength', PortDirection.input, width: 2);
    addOutput('out', width: sz * 8);

    final edge = input('edge_in');
    final strength = input('strength');

    // The three kernels, indexed by filt = strength-1.
    const kernels = [
      [0, 4, 8, 4, 0],
      [0, 5, 6, 5, 0],
      [2, 4, 4, 4, 2],
    ];
    const taps = 5;
    const w = 16;

    Logic sample(int i) => edge.getRange(i * 8, i * 8 + 8); // unsigned 8b

    final out = <Logic>[];
    // Sample 0 is copied unchanged for every strength.
    out.add(sample(0));

    for (var i = 1; i < sz; i++) {
      // For each of the three kernels, build the filtered byte, passthrough is
      // the original sample.
      final filtered = <Logic>[];
      for (final kernel in kernels) {
        Logic acc = Const(0, width: w);
        for (var j = 0; j < taps; j++) {
          final coeff = kernel[j];
          if (coeff == 0) {
            continue;
          }
          var k = i - 2 + j;
          if (k < 0) k = 0;
          if (k > sz - 1) k = sz - 1;
          final term = (sample(k).zeroExtend(w) * Const(coeff, width: w))
              .getRange(0, w);
          acc = (acc + term).getRange(0, w);
        }
        // (s + 8) >> 4, unsigned (acc is nonnegative).
        final rounded = (acc + Const(8, width: w)).getRange(0, w);
        final shifted = (rounded >>> 4).getRange(0, w);
        filtered.add(shifted.getRange(0, 8));
      }

      // strength: 0 -> passthrough, 1 -> filtered[0], 2 -> filtered[1],
      // 3 -> filtered[2].
      final passthrough = sample(i);
      final byte = mux(
        strength.eq(Const(0, width: 2)),
        passthrough,
        mux(
          strength.eq(Const(1, width: 2)),
          filtered[0],
          mux(strength.eq(Const(2, width: 2)), filtered[1], filtered[2]),
        ),
      );
      out.add(byte);
    }

    output('out') <= out.reversed.toList().concat();
  }

  /// Active edge length, fixed at build time.
  final int sz;
}

/// Bit-exact AV1 directional-intra edge upsample (`av1_upsample_intra_edge_c`),
/// bd8.
///
/// Doubles the edge resolution with a 4-tap `[-1, 9, 9, -1] / 16` interpolator.
/// The SW reference reads `p[off-1 .. off+sz-1]` (the corner sample plus the
/// `sz`-sample edge) and writes `p[off-2 .. off+2*sz-2]` (`2*sz+1` samples):
///   `in[0] = in[1] = p[off-1]`, `in[i+2] = p[off+i]`, `in[sz+2] = p[off+sz-1]`
///   `p[off-2] = in[0]`
///   for i in 0..sz-1:
///     `s = -in[i] + 9*in[i+1] + 9*in[i+2] - in[i+3]`
///     `p[off+2i-1] = clip255((s + 8) >> 4)`   (interpolated sample)
///     `p[off+2i]   = in[i+2]`                  (original sample, copied)
///
/// Combinational. `sz` is fixed at build time. The `edge_in` input carries the
/// `sz+1` samples `p[off-1 .. off+sz-1]` (sample 0 is the corner `p[off-1]`).
/// `out` carries the `2*sz+1` samples `p[off-2 .. off+2*sz-2]`. Both pack
/// sample `i` LSB-first at bit `i*8`.
///
/// The `-1` taps make the accumulator signed, range is `[-510, 4590]`, so a
/// 16-bit signed working width is exact. `(s + 8) >> 4` is an arithmetic
/// (sign-preserving) shift, then `clip255` clamps to `[0, 255]`.
class HarborIntraEdgeUpsample extends BridgeModule {
  HarborIntraEdgeUpsample({this.sz = 16, String? name})
    : super('HarborIntraEdgeUpsample', name: name ?? 'intra_edge_upsample') {
    if (sz < 1) {
      throw ArgumentError('HarborIntraEdgeUpsample.sz must be >= 1, got $sz');
    }

    // edge: p[off-1 .. off+sz-1] = sz+1 samples.
    createPort('edge_in', PortDirection.input, width: (sz + 1) * 8);
    // out: p[off-2 .. off+2*sz-2] = 2*sz+1 samples.
    addOutput('out', width: (2 * sz + 1) * 8);

    final edge = input('edge_in');
    const w = 16;

    // edge sample e: e=0 -> p[off-1], e>=1 -> p[off+(e-1)].
    Logic edgeByte(int e) => edge.getRange(e * 8, e * 8 + 8);

    // inp[m] per the SW reference, m in 0..sz+2:
    //   inp[0] = inp[1] = p[off-1] = edgeByte(0)
    //   inp[i+2] = p[off+i]        = edgeByte(i+1), i in 0..sz-1
    //   inp[sz+2] = p[off+sz-1]    = edgeByte(sz)
    Logic inp(int m) {
      if (m <= 1) return edgeByte(0);
      if (m <= sz + 1) return edgeByte(m - 1);
      return edgeByte(sz); // m == sz+2
    }

    // Output buffer indexed by q = (off+2i-1) - (off-2) etc. Output sample k
    // maps to p[off-2+k], k in 0..2*sz.
    final out = List<Logic?>.filled(2 * sz + 1, null);

    // p[off-2] = inp[0], output index 0.
    out[0] = inp(0);

    for (var i = 0; i < sz; i++) {
      // s = -inp[i] + 9*inp[i+1] + 9*inp[i+2] - inp[i+3], signed w-bit.
      final a = inp(i).zeroExtend(w); // bytes are nonnegative
      final b = inp(i + 1).zeroExtend(w);
      final c = inp(i + 2).zeroExtend(w);
      final d = inp(i + 3).zeroExtend(w);
      final nine = Const(9, width: w);
      final s = (b * nine).getRange(0, w) + (c * nine).getRange(0, w) - a - d;
      final sw = s.getRange(0, w);
      // (s + 8) >> 4, arithmetic shift.
      final biased = (sw + Const(8, width: w)).getRange(0, w);
      // Arithmetic (sign-preserving) shift right by 4.
      final shifted = [
        biased[w - 1].replicate(4),
        biased.getRange(4, w),
      ].concat();
      // clip to [0, 255].
      final neg = shifted[w - 1];
      final gt255 = shifted.gt(Const(255, width: w));
      final clipped = mux(
        neg,
        Const(0, width: w),
        mux(gt255, Const(255, width: w), shifted),
      ).getRange(0, 8);

      // p[off+2i-1] -> output index (off+2i-1)-(off-2) = 2i+1.
      out[2 * i + 1] = clipped;
      // p[off+2i] -> output index 2i+2, value inp[i+2] = original sample.
      out[2 * i + 2] = inp(i + 2);
    }

    output('out') <= out.map((e) => e!).toList().reversed.toList().concat();
  }

  /// Edge length being upsampled, fixed at build time.
  final int sz;
}

/// `av1_intra_edge_filter_strength` (reconintra.c): build-time decision that
/// returns the edge-filter strength `0..3` from the two block dimensions, the
/// directional `delta`, and the plane `type` (0 = luma, 1 = chroma). A pure
/// Dart helper that feeds the `strength` input of [HarborIntraEdgeFilter].
int intraEdgeFilterStrength(int bs0, int bs1, int delta, int type) {
  final d = delta.abs();
  var strength = 0;
  final blkWh = bs0 + bs1;
  if (type == 0) {
    if (blkWh <= 8) {
      if (d >= 56) strength = 1;
    } else if (blkWh <= 12) {
      if (d >= 40) strength = 1;
    } else if (blkWh <= 16) {
      if (d >= 40) strength = 1;
    } else if (blkWh <= 24) {
      if (d >= 8) strength = 1;
      if (d >= 16) strength = 2;
      if (d >= 32) strength = 3;
    } else if (blkWh <= 32) {
      if (d >= 1) strength = 1;
      if (d >= 4) strength = 2;
      if (d >= 32) strength = 3;
    } else {
      if (d >= 1) strength = 3;
    }
  } else {
    if (blkWh <= 8) {
      if (d >= 40) strength = 1;
      if (d >= 64) strength = 2;
    } else if (blkWh <= 16) {
      if (d >= 20) strength = 1;
      if (d >= 48) strength = 2;
    } else if (blkWh <= 24) {
      if (d >= 4) strength = 3;
    } else {
      if (d >= 1) strength = 3;
    }
  }
  return strength;
}

/// `av1_use_intra_edge_upsample` (reconintra.c): build-time decision for whether
/// to upsample the reference edge. Pure Dart helper.
bool useIntraEdgeUpsample(int bs0, int bs1, int delta, int type) {
  final d = delta.abs();
  final blkWh = bs0 + bs1;
  if (d == 0 || d >= 40) return false;
  return type != 0 ? (blkWh <= 8) : (blkWh <= 16);
}

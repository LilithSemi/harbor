import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor CDEF direction search (libaom `cdef_find_dir`).
///
/// Picks the dominant edge direction (0..7) of an 8x8 block, which drives the
/// [HarborCdefFilter]. Each candidate direction projects the block's pixels
/// (minus 128) onto a set of partial sums. The cost of a direction is the
/// weighted sum of the squares of its partial sums, and the chosen direction is
/// the one whose cost is largest (the edge is "sharpest" along it). Weights come
/// from the libaom `div_table`. Combinational.
///
/// `block` packs the 8x8 pixels LSB-first (pixel (r,c) at bit (r*8+c)*8). The
/// returned `dir` feeds the CDEF filter and `variance` = `(bestCost -
/// oppositeCost) >> 10` drives the luma `adjust_strength` scaling.
class HarborCdefDirection extends BridgeModule {
  /// [bd] is the sample bit-depth (8/10/12). Each `block` sample is [bd] bits.
  /// libaom's `cdef_find_dir` computes `x = (img >> coeff_shift) - 128` with
  /// `coeff_shift = bd - 8`, so we shift each sample right by `bd - 8` (back to
  /// an 8-bit range) before the `^0x80` centring. Everything downstream
  /// (partial-sum width, costs, variance) is therefore unchanged from 8-bit.
  HarborCdefDirection({int bd = 8, String? name})
    : super('HarborCdefDirection_B$bd', name: name ?? 'cdef_dir') {
    final int coeffShift = bd - 8;
    const pw = 13; // partial-sum signed width
    const cw = 40; // cost width (all non-negative)
    const divTable = [0, 840, 420, 280, 210, 168, 140, 120, 105];
    const sizes = [15, 11, 8, 11, 15, 11, 8, 11];

    createPort('block', PortDirection.input, width: 8 * 8 * bd);
    addOutput('dir', width: 3);
    addOutput('variance', width: 24);

    // x[i][j] = (pixel >> coeffShift) - 128 (signed). `getRange(coeffShift, bd)`
    // is exactly the low 8 bits after the arithmetic right shift (bd samples are
    // non-negative), matching `(img >> coeff_shift)` in the reference.
    Logic x(int i, int j) =>
        (input('block').getRange(
                  (i * 8 + j) * bd + coeffShift,
                  (i * 8 + j) * bd + bd,
                ) ^
                Const(0x80, width: 8))
            .signExtend(pw);

    int idxFor(int d, int i, int j) {
      switch (d) {
        case 0:
          return i + j;
        case 1:
          return i + (j >> 1);
        case 2:
          return i;
        case 3:
          return 3 + i - (j >> 1);
        case 4:
          return 7 + i - j;
        case 5:
          return 3 - (i >> 1) + j;
        case 6:
          return j;
        default:
          return (i >> 1) + j;
      }
    }

    // partial[d][idx] = sum of x[i][j] mapping to idx for direction d.
    List<Logic> partial(int d) {
      final terms = [for (var e = 0; e < sizes[d]; e++) <Logic>[]];
      for (var i = 0; i < 8; i++) {
        for (var j = 0; j < 8; j++) {
          terms[idxFor(d, i, j)].add(x(i, j));
        }
      }
      return [
        for (final t in terms)
          t.isEmpty
              ? Const(0, width: pw)
              : t.reduce((a, b) => (a + b).getRange(0, pw)),
      ];
    }

    // |p|^2 (p signed), zero-extended to the cost width.
    Logic sq(Logic p) {
      final a = mux(
        p[pw - 1],
        (Const(0, width: pw) - p).getRange(0, pw),
        p,
      ).getRange(0, pw);
      return (a.zeroExtend(cw) * a.zeroExtend(cw)).getRange(0, cw);
    }

    Logic add(Logic a, Logic b) => (a + b).getRange(0, cw);
    Logic wmul(Logic a, int v) => (a * Const(v, width: cw)).getRange(0, cw);

    Logic costFor(int d, List<Logic> par) {
      Logic acc = Const(0, width: cw);
      if (d == 2 || d == 6) {
        for (var i = 0; i < 8; i++) {
          acc = add(acc, sq(par[i]));
        }
        return wmul(acc, 105);
      } else if (d == 0 || d == 4) {
        for (var i = 0; i < 7; i++) {
          acc = add(
            acc,
            wmul(add(sq(par[i]), sq(par[14 - i])), divTable[i + 1]),
          );
        }
        return add(acc, wmul(sq(par[7]), divTable[8]));
      } else {
        Logic s = Const(0, width: cw);
        for (var j = 0; j < 5; j++) {
          s = add(s, sq(par[3 + j]));
        }
        acc = wmul(s, 105);
        for (var j = 0; j < 3; j++) {
          acc = add(
            acc,
            wmul(add(sq(par[j]), sq(par[10 - j])), divTable[2 * j + 2]),
          );
        }
        return acc;
      }
    }

    final cost = [for (var d = 0; d < 8; d++) costFor(d, partial(d))];

    // Argmax with first (lowest) index winning ties (libaom uses strict >).
    Logic bestDir = Const(0, width: 3);
    Logic bestCost = cost[0];
    for (var i = 1; i < 8; i++) {
      final gt = cost[i].gt(bestCost);
      bestDir = mux(gt, Const(i, width: 3), bestDir);
      bestCost = mux(gt, cost[i], bestCost);
    }
    output('dir') <= bestDir;

    // variance = (bestCost - cost[(bestDir + 4) & 7]) >> 10. bestCost is the
    // max so the difference is non-negative and a plain logical shift suffices.
    Logic oppCost = cost[4];
    for (var k = 0; k < 8; k++) {
      oppCost = mux(bestDir.eq(k), cost[(k + 4) & 7], oppCost);
    }
    output('variance') <= (bestCost - oppCost).getRange(0, cw).getRange(10, 34);
  }
}

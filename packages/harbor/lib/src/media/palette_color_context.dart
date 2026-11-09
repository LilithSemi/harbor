import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 palette color-index context: the per-pixel neighbour context and
/// color-ordering used by the palette color-index-map wavefront decode
/// (`av1_get_palette_color_index_context`, SW `_paletteColorCtx`).
///
/// At each wavefront position the three already-decoded neighbours, LEFT
/// (weight 2), ABOVE-LEFT (weight 1) and ABOVE (weight 2), vote for their
/// palette color index. A score array (one bucket per palette color) is built,
/// the top three buckets are stable-selection-sorted to the front (producing the
/// score-ordered `color_order`), and a hash of the top-three scores selects the
/// entropy context via `av1_palette_color_index_context_lookup`.
///
/// The subsequent `palette_color_idx` symbol (decoded elsewhere with this `ctx`)
/// is an index INTO `color_order`, so recovering the true palette color index
/// requires `color_order[symbol]`.
///
/// Inputs: `n` (palette size 2..8). `left`/`above_left`/`above` each a 4-bit
/// neighbour color index, value >= 8 meaning "unavailable" (SW's -1). Outputs:
/// `ctx` (0..4) and `color_order` (eight 3-bit entries, entry i at `[i*3 +: 3]`).
/// Combinational.
class HarborPaletteColorContext extends BridgeModule {
  static const _weights = [2, 1, 2]; // left, above-left, above
  // av1_palette_color_index_context_lookup[MAX_COLOR_CONTEXT_HASH+1 = 9].
  static const _lookup = [-1, -1, 0, -1, -1, 4, 3, 2, 1];

  HarborPaletteColorContext({String? name})
    : super('HarborPaletteColorContext', name: name ?? 'palette_color_ctx') {
    createPort('n', PortDirection.input, width: 4);
    createPort('left', PortDirection.input, width: 4);
    createPort('above_left', PortDirection.input, width: 4);
    createPort('above', PortDirection.input, width: 4);
    addOutput('ctx', width: 3);
    addOutput('color_order', width: 8 * 3);

    final n = input('n');
    final neigh = [input('left'), input('above_left'), input('above')];

    // scores[k] = sum of weights of neighbours whose index == k (valid only).
    // Max score is 2+1+2 = 5 -> 3 bits.
    var scores = <Logic>[for (var k = 0; k < 8; k++) Const(0, width: 3)];
    for (var ni = 0; ni < 3; ni++) {
      final valid = neigh[ni].lt(Const(8, width: 4));
      final idx = neigh[ni].getRange(0, 3);
      scores = [
        for (var k = 0; k < 8; k++)
          mux(
            valid & idx.eq(Const(k, width: 3)),
            (scores[k] + Const(_weights[ni], width: 3)).getRange(0, 3),
            scores[k],
          ),
      ];
    }

    var order = <Logic>[for (var k = 0; k < 8; k++) Const(k, width: 3)];

    // Stable partial selection sort of the top three positions, considering
    // only palette indices j < n (SW iterates j from i+1 while j < n), moving
    // the strictly-greater score to the front and rotating the rest down by
    // one.
    for (var i = 0; i < 3; i++) {
      Logic bestScore = scores[i];
      Logic bestIdx = Const(i, width: 4);
      Logic bestOrder = order[i];
      for (var j = i + 1; j < 8; j++) {
        final inRange = Const(j, width: 4).lt(n);
        final better = inRange & scores[j].gt(bestScore);
        bestScore = mux(better, scores[j], bestScore);
        bestIdx = mux(better, Const(j, width: 4), bestIdx);
        bestOrder = mux(better, order[j], bestOrder);
      }
      // Rotate [i..bestIdx] down by one, placing best at position i.
      final newScores = <Logic>[];
      final newOrder = <Logic>[];
      for (var k = 0; k < 8; k++) {
        if (k < i) {
          newScores.add(scores[k]);
          newOrder.add(order[k]);
        } else if (k == i) {
          newScores.add(bestScore);
          newOrder.add(bestOrder);
        } else {
          // k > i: shifted copy of k-1 when k <= bestIdx, else unchanged.
          final shifted = Const(k, width: 4).lte(bestIdx);
          newScores.add(mux(shifted, scores[k - 1], scores[k]));
          newOrder.add(mux(shifted, order[k - 1], order[k]));
        }
      }
      scores = newScores;
      order = newOrder;
    }

    // hash = scores[0]*1 + scores[1]*2 + scores[2]*2 (top-three, post-sort).
    // _hashMul = [1, 2, 2]. The *2 terms are left shifts by one.
    final s0 = scores[0].zeroExtend(6);
    final s1 = (scores[1].zeroExtend(6) << 1).getRange(0, 6);
    final s2 = (scores[2].zeroExtend(6) << 1).getRange(0, 6);
    final hash = (s0 + s1 + s2).getRange(0, 6);

    // ctx = lookup[hash] (entries that never occur are don't-care / 0).
    Logic ctx = Const(0, width: 3);
    for (var h = 8; h >= 0; h--) {
      final v = _lookup[h] < 0 ? 0 : _lookup[h];
      ctx = mux(hash.eq(Const(h, width: 6)), Const(v, width: 3), ctx);
    }
    output('ctx') <= ctx;
    output('color_order') <= [for (var k = 7; k >= 0; k--) order[k]].concat();
  }
}

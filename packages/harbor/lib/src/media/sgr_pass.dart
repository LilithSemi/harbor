import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sgr_boxsum.dart';
import 'sgr_calc_ab.dart';
import 'sgr_cross_sum.dart';

/// Harbor bit-exact AV1 SGR self-guided pass (libaom `_sgrFull` / `_sgrFast`),
/// bd8 - the end-to-end box -> A/B -> cross-sum chain that turns a padded recon
/// block into an `flt` restoration estimate.
///
/// It wires the three SGR primitives over a `width` x `height` body block:
///   1. [HarborSgrBoxsum] over the `(width+2) x (height+2)` A/B grid (the body
///      plus the one-pixel ring `_calcAb` evaluates, indices `-1..width`).
///   2. [HarborSgrCalcAb] per grid position -> per-pixel `a`/`b`.
///   3. [HarborSgrCrossSum] per output pixel -> `flt = round2(av*center + bv,
///      nb+4)` over the 3x3 A/B neighbourhood, with `center` the body pixel.
///
/// [fast] selects the libaom pass: the `_sgrFull` pass (`radiusIdx 0`) uses
/// cross-sum mode 0 (3x3 weights `4`/`3`, nb 5) everywhere, the `_sgrFast` pass
/// (`radiusIdx 1`) uses mode 1 on even output rows (vertical neighbours, weights
/// `6`/`5`, nb 5) and mode 2 on odd output rows (horizontal only, nb 4). The fast
/// pass only ever reads odd-row A/B values, so computing the full grid and
/// selecting the mode per row is bit-identical. The two-pass xqd projection
/// (combining the full and fast `flt`s with the source) is [HarborSgrProject].
/// Combinational.
///
/// `padded` packs the `(width+2r+2) x (height+2r+2)` source region row-major
/// LSB-first (8b pixels), body pixel `(0,0)` sits at padded `(r+1, r+1)` so the
/// A/B grid ring and every box window are in range. `s` (12b) is the SGR noise
/// parameter. `flt` packs output `(i,j)` at index `i*width + j` (18b each).
class HarborSgrPass extends BridgeModule {
  HarborSgrPass({
    int radius = 1,
    int width = 8,
    int height = 8,
    bool fast = false,
    int bd = 8,
    String? name,
  }) : super(
         'HarborSgrPass_R${radius}_W${width}_H${height}_B${bd}_'
         'F${fast ? 1 : 0}',
         name: name ?? 'sgr_pass',
       ) {
    final r = radius;
    // A/B grid is the body plus a one-pixel ring: positions (-1..width).
    final gw = width + 2;
    final gh = height + 2;
    // Padded region: each grid position needs an r-wide box, and the grid itself
    // extends one past the body, so the source ring is (r+1) wide.
    final pw = width + 2 * (r + 1);
    final ph = height + 2 * (r + 1);
    final bsumW = sgrBsumWidth(bd);
    final asumW = sgrAsumWidth(bd);
    final fltW = sgrFltWidth(bd);

    createPort('padded', PortDirection.input, width: pw * ph * bd);
    createPort('s', PortDirection.input, width: 12);
    addOutput('flt', width: width * height * fltW);

    final padded = input('padded');
    final s = input('s');

    // Box sums over the A/B grid. The grid's top-left position (-1,-1) in body
    // coords is padded (r,r), so its box window starts at padded (0,0): the
    // boxsum body of gw x gh sits directly on `padded` with a 2r border.
    final box = HarborSgrBoxsum(
      radius: r,
      width: gw,
      height: gh,
      bd: bd,
      name: 'box',
    );
    addSubModule(box);
    box.input('padded').srcConnection! <= padded;
    final bsum = box.output('bsum'); // gw*gh * bsumW, index ci*gw + cj
    final asum = box.output('asum'); // gw*gh * asumW

    Logic bAt(int ci, int cj) {
      final k = ci * gw + cj;
      return bsum.getRange(k * bsumW, k * bsumW + bsumW);
    }

    Logic aAt(int ci, int cj) {
      final k = ci * gw + cj;
      return asum.getRange(k * asumW, k * asumW + asumW);
    }

    // Per-position A/B. Grid index (ci,cj): ci/cj 0 == body coord -1.
    final aGrid = <List<Logic>>[for (var ci = 0; ci < gh; ci++) <Logic>[]];
    final bGrid = <List<Logic>>[for (var ci = 0; ci < gh; ci++) <Logic>[]];
    var inst = 0;
    for (var ci = 0; ci < gh; ci++) {
      for (var cj = 0; cj < gw; cj++) {
        final ab = HarborSgrCalcAb(radius: r, bd: bd, name: 'ab_${inst++}');
        addSubModule(ab);
        ab.input('av').srcConnection! <= aAt(ci, cj);
        ab.input('bv').srcConnection! <= bAt(ci, cj);
        ab.input('s').srcConnection! <= s;
        aGrid[ci].add(ab.output('a')); // 9b
        bGrid[ci].add(ab.output('b')); // bW
      }
    }

    // Body pixel (i,j) is padded (i + r + 1, j + r + 1).
    Logic bodyPx(int i, int j) {
      final row = i + r + 1, col = j + r + 1;
      final k = row * pw + col;
      return padded.getRange(k * bd, k * bd + bd);
    }

    // Cross-sum (mode 0) per output pixel. The 3x3 A/B neighbourhood of body
    // (i,j) is grid positions (i..i+2, j..j+2) (since grid (0,0) == body (-1,-1)).
    final fltParts = <Logic>[];
    inst = 0;
    for (var i = 0; i < height; i++) {
      for (var j = 0; j < width; j++) {
        final cs = HarborSgrCrossSum(bd: bd, name: 'cs_${inst++}');
        addSubModule(cs);
        final aw = <Logic>[];
        final bw = <Logic>[];
        for (var dr = 0; dr < 3; dr++) {
          for (var dc = 0; dc < 3; dc++) {
            aw.add(aGrid[i + dr][j + dc]);
            bw.add(bGrid[i + dr][j + dc]);
          }
        }
        // full pass: mode 0. fast pass: mode 1 on even rows, mode 2 on odd.
        final mode = !fast ? 0 : (i.isEven ? 1 : 2);
        cs.input('aw').srcConnection! <= aw.reversed.toList().swizzle();
        cs.input('bw').srcConnection! <= bw.reversed.toList().swizzle();
        cs.input('center').srcConnection! <= bodyPx(i, j);
        cs.input('mode').srcConnection! <= Const(mode, width: 2);
        fltParts.add(cs.output('flt'));
      }
    }

    output('flt') <= fltParts.reversed.toList().swizzle();
  }
}

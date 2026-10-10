import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Sum-of-pixels box-sum output width for a bit depth [bd] (n<=25 taps).
/// bd8 -> 16 (legacy). Holds `n*(2^bd-1)`: bd12 needs 17, formula gives 20.
int sgrBsumWidth(int bd) => bd + 8;

/// Sum-of-squares box-sum output width for a bit depth [bd] (n<=25 taps).
/// bd8 -> 24 (legacy). Holds `n*(2^bd-1)^2`: bd12 needs 29, formula gives 32.
int sgrAsumWidth(int bd) => 2 * bd + 8;

/// Harbor bit-exact AV1 SGR box-sum area engine (libaom `_boxsum1`/`_boxsum2`),
/// bit-depth aware, the front end that feeds [HarborSgrCalcAb].
///
/// Over a padded pixel region it produces, for every output position, the two
/// box sums the self-guided filter needs across its `(2r+1)x(2r+1)` window:
///   `bsum` = sum of pixels        (libaom B buffer, sqr 0)
///   `asum` = sum of squared pixels (libaom A buffer, sqr 1)
/// libaom computes these with a separable sliding sum (rows then columns) but
/// over an interior position that is exactly the full window sum, so this engine
/// forms each window sum directly, bit-identical for every position `_calcAb`
/// actually consumes. Combinational.
///
/// The padded region is `(height + 2r) x (width + 2r)` pixels: output position
/// `(i,j)` (`0..height-1`, `0..width-1`) owns the window at padded rows `i..i+2r`,
/// cols `j..j+2r`, so its window centre is padded `(i+r, j+r)`. `padded` packs
/// pixel `(r,c)` row-major LSB-first at bit `(r*side + c)*bd` (`side = width+2r`).
/// `bsum`/`asum` pack position `(i,j)` at index `i*width + j`
/// (`sgrBsumWidth(bd)` / `sgrAsumWidth(bd)` bits each), matching the `bv`/`av`
/// widths of [HarborSgrCalcAb].
class HarborSgrBoxsum extends BridgeModule {
  HarborSgrBoxsum({
    int radius = 1,
    int width = 8,
    int height = 8,
    int bd = 8,
    String? name,
  }) : super(
         'HarborSgrBoxsum_R${radius}_W${width}_H${height}_B$bd',
         name: name ?? 'sgr_boxsum',
       ) {
    final r = radius;
    final win = 2 * r + 1;
    final side = width + 2 * r;
    final sideV = height + 2 * r;
    final bsumW = sgrBsumWidth(bd);
    final asumW = sgrAsumWidth(bd);
    final sqW = 2 * bd; // pixel^2 width

    createPort('padded', PortDirection.input, width: side * sideV * bd);
    addOutput('bsum', width: width * height * bsumW);
    addOutput('asum', width: width * height * asumW);

    final padded = input('padded');
    Logic pad(int row, int col) =>
        padded.getRange((row * side + col) * bd, (row * side + col) * bd + bd);

    Logic addB(List<Logic> xs) => xs
        .map((x) => x.zeroExtend(bsumW))
        .reduce((a, b) => (a + b).getRange(0, bsumW));
    Logic addA(List<Logic> xs) => xs
        .map((x) => x.zeroExtend(asumW))
        .reduce((a, b) => (a + b).getRange(0, asumW));

    final bParts = <Logic>[];
    final aParts = <Logic>[];
    for (var i = 0; i < height; i++) {
      for (var j = 0; j < width; j++) {
        final pix = <Logic>[];
        final sqs = <Logic>[];
        for (var dr = 0; dr < win; dr++) {
          for (var dc = 0; dc < win; dc++) {
            final p = pad(i + dr, j + dc);
            pix.add(p);
            sqs.add((p.zeroExtend(sqW) * p.zeroExtend(sqW)).getRange(0, sqW));
          }
        }
        bParts.add(addB(pix));
        aParts.add(addA(sqs));
      }
    }

    // Pack position (i,j) at index i*width + j, LSB-first.
    output('bsum') <= bParts.reversed.toList().swizzle();
    output('asum') <= aParts.reversed.toList().swizzle();
  }
}

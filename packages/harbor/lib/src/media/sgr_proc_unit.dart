import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sgr_cross_sum.dart';
import 'sgr_pass.dart';
import 'sgr_project.dart';

/// Harbor bit-exact AV1 SGR restoration unit (libaom `_sgrProcUnit`), bd8 - the
/// complete self-guided restoration for one processing unit.
///
/// It runs both self-guided box filters and projects the source toward them:
///   flt0 = [HarborSgrPass] radius 2, fast cross-sum  (libaom `_sgrFast`, idx 0)
///   flt1 = [HarborSgrPass] radius 1, full cross-sum  (libaom `_sgrFull`, idx 1)
///   out  = [HarborSgrProject](pre, flt0, flt1, xq0, xq1)
/// matching the standard `av1_sgr_params` entries (both radii active). A disabled
/// radius is handled by its decoded weight being 0 (so its `flt` term vanishes),
/// the caller passes the `decode_xq` weights `xq0`/`xq1` and the per-pass noise
/// `s0`/`s1` directly. Combinational.
///
/// `padded` packs the `(width+6) x (height+6)` source region row-major LSB-first
/// (8b pixels), the radius-2 pass's box reach. Body pixel `(0,0)` sits at padded
/// `(3,3)`. The radius-1 pass reads the inner `(width+4) x (height+4)` sub-region
/// at padded `(1,1)`. `s0`/`s1` are 12b, `xq0`/`xq1` are 8b signed. `out` packs
/// output `(i,j)` at index `i*width + j` (8b each).
class HarborSgrProcUnit extends BridgeModule {
  HarborSgrProcUnit({int width = 8, int height = 8, int bd = 8, String? name})
    : super(
        'HarborSgrProcUnit_W${width}_H${height}_B$bd',
        name: name ?? 'sgr_proc',
      ) {
    final pw = width + 6; // radius-2 reach: body at (3,3), ring (r+1)=3 wide
    final ph = height + 6;
    final fltW = sgrFltWidth(bd);

    createPort('padded', PortDirection.input, width: pw * ph * bd);
    createPort('s0', PortDirection.input, width: 12); // fast pass (radius 2)
    createPort('s1', PortDirection.input, width: 12); // full pass (radius 1)
    createPort('xq0', PortDirection.input, width: 8); // signed
    createPort('xq1', PortDirection.input, width: 8); // signed
    addOutput('out', width: width * height * bd);

    final padded = input('padded');
    Logic padAt(int row, int col) {
      final k = row * pw + col;
      return padded.getRange(k * bd, k * bd + bd);
    }

    // flt0: fast cross-sum, radius 2. Its padded region is the whole input.
    final pass0 = HarborSgrPass(
      radius: 2,
      width: width,
      height: height,
      fast: true,
      bd: bd,
      name: 'p0',
    );
    addSubModule(pass0);
    pass0.input('padded').srcConnection! <= padded;
    pass0.input('s').srcConnection! <= input('s0');
    final flt0 = pass0.output('flt');

    // flt1: full cross-sum, radius 1. Its padded region is (width+4)x(height+4)
    // with its body (0,0) at its-padded (2,2), that lands at proc padded (1,1).
    final sw = width + 4, sh = height + 4;
    final sub = <Logic>[
      for (var r = 1; r < 1 + sh; r++)
        for (var c = 1; c < 1 + sw; c++) padAt(r, c),
    ];
    final pass1 = HarborSgrPass(
      radius: 1,
      width: width,
      height: height,
      fast: false,
      bd: bd,
      name: 'p1',
    );
    addSubModule(pass1);
    pass1.input('padded').srcConnection! <= sub.reversed.toList().swizzle();
    pass1.input('s').srcConnection! <= input('s1');
    final flt1 = pass1.output('flt');

    // Projection per output pixel. pre = body pixel (i,j) = proc padded (i+3,j+3).
    final outParts = <Logic>[];
    var inst = 0;
    for (var i = 0; i < height; i++) {
      for (var j = 0; j < width; j++) {
        final k = i * width + j;
        final pr = HarborSgrProject(bd: bd, name: 'prj_${inst++}');
        addSubModule(pr);
        pr.input('pre').srcConnection! <= padAt(i + 3, j + 3);
        pr.input('flt0').srcConnection! <=
            flt0.getRange(k * fltW, k * fltW + fltW);
        pr.input('flt1').srcConnection! <=
            flt1.getRange(k * fltW, k * fltW + fltW);
        pr.input('xq0').srcConnection! <= input('xq0');
        pr.input('xq1').srcConnection! <= input('xq1');
        outParts.add(pr.output('out'));
      }
    }

    output('out') <= outParts.reversed.toList().swizzle();
  }
}

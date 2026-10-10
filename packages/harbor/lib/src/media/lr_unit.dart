import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sgr_proc_unit.dart';
import 'wiener_filter.dart';

/// Harbor bit-exact AV1 loop-restoration unit dispatcher (libaom
/// `restoration.c` per-unit apply), bd8 - selects and applies the correct
/// in-loop restoration filter for one block by its restoration type.
///
/// AV1's loop restoration runs after CDEF and applies, per restoration unit,
/// one of three operations selected by a 2-bit `rtype`:
///   0 RESTORE_NONE    -> copy the post-CDEF body pixels through unchanged.
///   1 RESTORE_WIENER  -> the separable 7-tap Wiener filter
///                        ([HarborWienerFilter2D], round_0 then round_1).
///   2 RESTORE_SGRPROJ -> the self-guided projection ([HarborSgrProcUnit],
///                        fast+full box passes then projection).
///
/// This module COMPOSES the two already-bit-exact filter cores under the type
/// selector. It instantiates one [HarborSgrProcUnit] over the whole padded
/// region, one [HarborWienerFilter2D] per output pixel over that pixel's 7x7
/// window, and a copy-through path, then muxes the per-pixel output by `rtype`.
///
/// `padded` packs the `(width+6) x (height+6)` post-CDEF source region
/// row-major LSB-first (8b pixels) - the radius-2 SGR reach, which also covers
/// the Wiener `+/-3` reach. Body pixel `(0,0)` sits at padded `(3,3)`. Wiener
/// output `(i,j)` is the centre of the 7x7 window whose pixel `(r,c)` is padded
/// `(i+r, j+c)`. `out` packs output `(i,j)` at index `i*width + j` (8b each),
/// matching [HarborSgrProcUnit]. Wiener half-taps `h0..h2`/`v0..v2` are 8b
/// signed, `s0`/`s1` are 12b, `xq0`/`xq1` are 8b signed. Combinational.
class HarborLrUnit extends BridgeModule {
  HarborLrUnit({int width = 8, int height = 8, int bd = 8, String? name})
    : super('HarborLrUnit_W${width}_H${height}_B$bd', name: name ?? 'lr_unit') {
    final pw = width + 6;
    final ph = height + 6;

    createPort('padded', PortDirection.input, width: pw * ph * bd);
    for (final t in ['h0', 'h1', 'h2', 'v0', 'v1', 'v2']) {
      createPort(t, PortDirection.input, width: 8); // Wiener half-taps (signed)
    }
    createPort('s0', PortDirection.input, width: 12); // SGR fast pass noise
    createPort('s1', PortDirection.input, width: 12); // SGR full pass noise
    createPort('xq0', PortDirection.input, width: 8); // SGR weight (signed)
    createPort('xq1', PortDirection.input, width: 8); // SGR weight (signed)
    createPort('rtype', PortDirection.input, width: 2); // 0 none/1 wiener/2 sgr
    addOutput('out', width: width * height * bd);

    final padded = input('padded');
    Logic padAt(int row, int col) {
      final k = row * pw + col;
      return padded.getRange(k * bd, k * bd + bd);
    }

    // SGRPROJ path: one proc unit over the full padded region.
    final sgr = HarborSgrProcUnit(
      width: width,
      height: height,
      bd: bd,
      name: 'sgr',
    );
    addSubModule(sgr);
    sgr.input('padded').srcConnection! <= padded;
    sgr.input('s0').srcConnection! <= input('s0');
    sgr.input('s1').srcConnection! <= input('s1');
    sgr.input('xq0').srcConnection! <= input('xq0');
    sgr.input('xq1').srcConnection! <= input('xq1');
    final sgrOut = sgr.output('out');

    final outParts = <Logic>[];
    var winst = 0;
    for (var i = 0; i < height; i++) {
      for (var j = 0; j < width; j++) {
        final k = i * width + j;

        // NONE: copy-through of the body pixel (i,j) = padded (i+3, j+3).
        final noneOut = padAt(i + 3, j + 3);

        // WIENER: 7x7 window pixel (r,c) = padded (i+r, j+c), packed the same
        // way HarborWienerFilter2D expects ((r*7 + c)*bd, LSB-first).
        final wf = HarborWienerFilter2D(bd: bd, name: 'wf_${winst++}');
        addSubModule(wf);
        final win = <Logic>[
          for (var r = 0; r < 7; r++)
            for (var c = 0; c < 7; c++) padAt(i + r, j + c),
        ];
        wf.input('region').srcConnection! <= win.reversed.toList().swizzle();
        wf.input('h0').srcConnection! <= input('h0');
        wf.input('h1').srcConnection! <= input('h1');
        wf.input('h2').srcConnection! <= input('h2');
        wf.input('v0').srcConnection! <= input('v0');
        wf.input('v1').srcConnection! <= input('v1');
        wf.input('v2').srcConnection! <= input('v2');
        final wienerOut = wf.output('out');

        // SGRPROJ: pixel k of the proc unit output.
        final sgrPx = sgrOut.getRange(k * bd, k * bd + bd);

        // 3-way select on rtype via nested 2-way muxes.
        final rtype = input('rtype');
        final sel = mux(
          rtype.eq(2),
          sgrPx,
          mux(rtype.eq(1), wienerOut, noneOut),
        );
        outParts.add(sel);
      }
    }

    output('out') <= outParts.reversed.toList().swizzle();
  }
}

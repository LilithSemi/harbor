import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'deblock_filter.dart';

/// Harbor frame-level deblocking pass for an 8x8 reconstructed block grid of
/// 4x4 sub-blocks.
///
/// Applies the [HarborDeblockFilter] across the internal block edges in AV1
/// order: first the vertical edge (between columns 3 and 4) on every row, then
/// the horizontal edge (between rows 3 and 4) on every column of the
/// vertically-filtered result. Each 8-pixel line straddling an edge is filtered
/// and its inner six pixels written back, the outermost pixels (cols/rows 0 and
/// 7) are untouched. Combinational, one filter instance per edge line.
///
/// `frame` / `out` pack pixel (r,c) at bits [(r*8 + c)*8 +: 8]. This is a fixed
/// 8x8 demonstration of the loop-filter stage. A DMA pass over an arbitrary
/// frame (and the deblock-level derivation) are follow-ups.
class HarborFrameDeblock extends BridgeModule {
  HarborFrameDeblock({String? name})
    : super('HarborFrameDeblock', name: name ?? 'frame_deblock') {
    createPort('frame', PortDirection.input, width: 512); // 8x8 pixels
    createPort('blimit', PortDirection.input, width: 8);
    createPort('limit', PortDirection.input, width: 8);
    createPort('thresh', PortDirection.input, width: 8);
    createPort('flat_thresh', PortDirection.input, width: 8);
    addOutput('out', width: 512);

    Logic fpx(Logic frame, int r, int c) =>
        frame.getRange((r * 8 + c) * 8, (r * 8 + c) * 8 + 8);

    final blimit = input('blimit');
    final limit = input('limit');
    final thresh = input('thresh');
    final flatThresh = input('flat_thresh');

    // One filter pass over an 8-pixel line, returns the 6 filtered inner pixels.
    var inst = 0;
    Logic filterLine(List<Logic> line8) {
      final f = HarborDeblockFilter(name: 'flt_${inst++}');
      addSubModule(f);
      f.input('line').srcConnection! <= line8.reversed.toList().concat();
      f.input('blimit').srcConnection! <= blimit;
      f.input('limit').srcConnection! <= limit;
      f.input('thresh').srcConnection! <= thresh;
      f.input('flat_thresh').srcConnection! <= flatThresh;
      return f.output('filtered'); // op2,op1,op0,oq0,oq1,oq2 (LSB first)
    }

    Logic outByte(Logic filtered, int i) => filtered.getRange(i * 8, i * 8 + 8);

    final frame = input('frame');
    // Vertical edge (cols 3|4): filter each row, inner cols 1..6 update.
    final inter = <Logic>[for (var i = 0; i < 64; i++) Const(0, width: 8)];
    for (var r = 0; r < 8; r++) {
      final filt = filterLine([for (var c = 0; c < 8; c++) fpx(frame, r, c)]);
      inter[r * 8 + 0] = fpx(frame, r, 0);
      inter[r * 8 + 7] = fpx(frame, r, 7);
      for (var k = 0; k < 6; k++) {
        inter[r * 8 + 1 + k] = outByte(filt, k);
      }
    }

    // Horizontal edge (rows 3|4): filter each column of `inter`, inner
    // rows 1..6 update.
    final outPx = <Logic>[for (var i = 0; i < 64; i++) inter[i]];
    for (var c = 0; c < 8; c++) {
      final filt = filterLine([for (var r = 0; r < 8; r++) inter[r * 8 + c]]);
      for (var k = 0; k < 6; k++) {
        outPx[(1 + k) * 8 + c] = outByte(filt, k);
      }
    }

    output('out') <= outPx.reversed.toList().concat();
  }
}

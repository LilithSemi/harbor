import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'deblock_filter.dart';

/// Harbor AV1 deblocking frame pass over a reconstructed picture.
///
/// Applies the narrow loop filter (`filter4`) to every internal 4-pixel block
/// edge of a `width` x `height` frame, in AV1 order: all vertical edges first
/// (columns 4, 8, ... on every row), then all horizontal edges (rows 4, 8, ...
/// on every column) of the vertically-filtered result. Each edge's 8-pixel line
/// is filtered and the four inner pixels (op1, op0, oq0, oq1) written back, with
/// edges 4 apart the narrow filter's 4-pixel footprint never overlaps. This is
/// the post-reconstruction deblock stage that runs after the decode/reconstruct
/// pipeline.
///
/// `frame`/`out` pack pixel (y,x) at `[(y*width + x)*8 +: 8]`. `blimit`/`limit`/
/// `thresh` are the edge thresholds (from HarborDeblockLimits). `flat_thresh` is
/// kept low so the wide filter does not engage (4x4-block granularity).
/// Combinational.
class HarborDeblockFramePass extends BridgeModule {
  HarborDeblockFramePass({int width = 16, int height = 16, String? name})
    : super('HarborDeblockFramePass', name: name ?? 'deblock_pass') {
    createPort('frame', PortDirection.input, width: width * height * 8);
    createPort('blimit', PortDirection.input, width: 8);
    createPort('limit', PortDirection.input, width: 8);
    createPort('thresh', PortDirection.input, width: 8);
    createPort('flat_thresh', PortDirection.input, width: 8);
    addOutput('out', width: width * height * 8);

    final blimit = input('blimit');
    final limit = input('limit');
    final thresh = input('thresh');
    final flatThresh = input('flat_thresh');

    var inst = 0;
    // Filter one 8-pixel line, returns [op1, op0, oq0, oq1] (the narrow result).
    List<Logic> filt(List<Logic> line8) {
      final f = HarborDeblockFilter(narrowOnly: true, name: 'flt_${inst++}');
      addSubModule(f);
      f.input('line').srcConnection! <= line8.reversed.toList().concat();
      f.input('blimit').srcConnection! <= blimit;
      f.input('limit').srcConnection! <= limit;
      f.input('thresh').srcConnection! <= thresh;
      f.input('flat_thresh').srcConnection! <= flatThresh;
      final out = f.output('filtered'); // op2,op1,op0,oq0,oq1,oq2 (LSB-first)
      return [
        out.getRange(1 * 8, 2 * 8), // op1
        out.getRange(2 * 8, 3 * 8), // op0
        out.getRange(3 * 8, 4 * 8), // oq0
        out.getRange(4 * 8, 5 * 8), // oq1
      ];
    }

    Logic fpx(List<Logic> f, int y, int x) => f[y * width + x];

    // Mutable working grid, initialised from the input.
    final src = input('frame');
    final grid = <Logic>[
      for (var i = 0; i < width * height; i++) src.getRange(i * 8, i * 8 + 8),
    ];

    // Vertical edges (x = 4, 8, ...): filter each row's line straddling them.
    for (var x = 4; x < width; x += 4) {
      for (var y = 0; y < height; y++) {
        final line = [for (var k = -4; k < 4; k++) fpx(grid, y, x + k)];
        final r = filt(line);
        grid[y * width + (x - 2)] = r[0]; // op1
        grid[y * width + (x - 1)] = r[1]; // op0
        grid[y * width + x] = r[2]; // oq0
        grid[y * width + (x + 1)] = r[3]; // oq1
      }
    }

    // Horizontal edges (y = 4, 8, ...): filter each column's line.
    final grid2 = <Logic>[for (var i = 0; i < width * height; i++) grid[i]];
    for (var y = 4; y < height; y += 4) {
      for (var x = 0; x < width; x++) {
        final line = [for (var k = -4; k < 4; k++) grid[(y + k) * width + x]];
        final r = filt(line);
        grid2[(y - 2) * width + x] = r[0];
        grid2[(y - 1) * width + x] = r[1];
        grid2[y * width + x] = r[2];
        grid2[(y + 1) * width + x] = r[3];
      }
    }

    output('out') <=
        [for (var i = width * height - 1; i >= 0; i--) grid2[i]].concat();
  }
}

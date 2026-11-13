import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'sgr_filter.dart';

/// Harbor SGR self-guided restoration over a full 8x8 block.
///
/// Ties [HarborSgrFilter] across an 8x8 block, mirroring [HarborCdefBlock] and
/// [HarborFrameDeblock]: it takes a padded region (the 8x8 block plus a
/// `radius`-wide border so every output pixel's box window is in range) and runs
/// one per-pixel SGR core per output sample. The same noise parameter `s` drives
/// every pixel. Combinational, 64 core instances.
///
/// `padded` packs pixel (r,c) of the `(8+2r)x(8+2r)` region row-major, LSB-first
/// (the block sits at rows/cols `radius..radius+7`). `out` is the filtered 8x8
/// (pixel (r,c) at bit `(r*8+c)*8`). For `radius` 1 the region is 10x10.
class HarborSgrBlock extends BridgeModule {
  HarborSgrBlock({int radius = 1, String? name})
    : super('HarborSgrBlock', name: name ?? 'sgr_block') {
    final side = 8 + 2 * radius;
    final winSide = 2 * radius + 1;

    createPort('padded', PortDirection.input, width: side * side * 8);
    createPort('s', PortDirection.input, width: 8);
    addOutput('out', width: 512);

    final padded = input('padded');
    final s = input('s');
    Logic pad(int r, int c) =>
        padded.getRange((r * side + c) * 8, (r * side + c) * 8 + 8);

    final outPx = <Logic>[];
    var inst = 0;
    for (var r = 0; r < 8; r++) {
      for (var c = 0; c < 8; c++) {
        final core = HarborSgrFilter(radius: radius, name: 'sgr_${inst++}');
        addSubModule(core);
        // Box window for output pixel (r,c): padded rows r..r+2radius.
        final win = <Logic>[
          for (var dr = 0; dr < winSide; dr++)
            for (var dc = 0; dc < winSide; dc++) pad(r + dr, c + dc),
        ];
        core.input('window').srcConnection! <= win.reversed.toList().concat();
        core.input('s').srcConnection! <= s;
        outPx.add(core.output('out'));
      }
    }

    output('out') <= outPx.reversed.toList().concat();
  }
}

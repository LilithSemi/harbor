import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 palette reconstruction: map a per-pixel color-index map to base
/// colors.
///
/// A palette block carries a small set (2..8) of base colors and a per-pixel
/// color-INDEX map (decoded by [HarborKeyframeModeWalk] / the SW
/// `_readPaletteTokens`). Reconstruction is a pure table lookup with NO intra
/// prediction and NO transform residual: `pixel[i] = colors[idx[i]]`
/// (libaom `av1_reconstruct_palette` / SW `_reconBlock` palette branch).
///
/// `colors` packs eight `bitDepth`-bit palette entries (entry k at
/// `[k*bitDepth +: bitDepth]`, entries >= palette size are unused). `indices`
/// packs `n` 3-bit color indices (pixel i at `[i*3 +: 3]`). `pixels` packs the
/// `n` looked-up `bitDepth`-bit samples (pixel i at `[i*bitDepth +: bitDepth]`).
/// Combinational. One plane's worth of pixels.
class HarborPaletteRecon extends BridgeModule {
  /// Number of pixels to reconstruct (e.g. a tx block's tw*th, or a whole
  /// palette block's width*height).
  final int n;

  /// Sample bit depth (8/10/12).
  final int bitDepth;

  /// PALETTE_COLORS = 8 (max palette size).
  static const _maxColors = 8;

  HarborPaletteRecon({required this.n, this.bitDepth = 8, String? name})
    : super(
        'HarborPaletteRecon_N${n}_B$bitDepth',
        name: name ?? 'palette_recon',
      ) {
    final bd = bitDepth;
    createPort('colors', PortDirection.input, width: _maxColors * bd);
    createPort('indices', PortDirection.input, width: n * 3);
    addOutput('pixels', width: n * bd);

    final cols = [
      for (var k = 0; k < _maxColors; k++)
        input('colors').getRange(k * bd, k * bd + bd),
    ];
    Logic selColor(Logic idx) {
      Logic v = cols.last;
      for (var k = _maxColors - 2; k >= 0; k--) {
        v = mux(idx.eq(Const(k, width: 3)), cols[k], v);
      }
      return v;
    }

    final outs = <Logic>[];
    for (var i = 0; i < n; i++) {
      final idx = input('indices').getRange(i * 3, i * 3 + 3);
      outs.add(selColor(idx));
    }
    output('pixels') <= outs.reversed.toList().swizzle();
  }
}

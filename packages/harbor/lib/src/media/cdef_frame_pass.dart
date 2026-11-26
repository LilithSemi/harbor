import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'cdef_block.dart';

/// Harbor AV1 CDEF (Constrained Directional Enhancement Filter) frame pass over
/// one region of a deblocked plane.
///
/// Walks a `region` x `region` area (a multiple of 8, e.g. a 64x64 superblock
/// unit) in 8x8 blocks. Each non-skipped 8x8 block is filtered with
/// [HarborCdefBlock] using the unit-level primary/secondary strengths and
/// damping. Skipped blocks pass through unchanged. This composes the per-8x8
/// core (which it does NOT reimplement) into the superblock application loop of
/// libaom `av1_cdef_frame` / the software reference `cdefFrame`.
///
/// Geometry. [HarborCdefBlock] needs a 12x12 window per 8x8 block (the block
/// plus a 2-pixel border so every output pixel's 5x5 neighbourhood is in
/// range). The `padded` input is therefore a (`region`+4) x (`region`+4) grid:
/// the region plus a 2-pixel border ring of real neighbour pixels. Padded pixel
/// (r,c) maps to region pixel (r-2, c-2). Region pixel (y,x) is padded
/// (y+2, x+2). The block at grid position (by,bx) reads padded rows/cols
/// by*8 .. by*8+11.
///
/// Sentinel scope. libaom fills out-of-frame neighbour pixels with
/// CDEF_VERY_LARGE (0x4000) so `constrain` clamps their contribution to zero.
/// [HarborCdefBlock]/[HarborCdefFilter] are an 8-bit interior interface with no
/// VERY_LARGE sentinel (0x4000 does not fit in 8 bits), so this pass models the
/// interior-superblock case: the border ring carries the real deblocked
/// neighbour pixels, which is exactly libaom's behaviour for any block whose
/// 2px border lies inside the frame. True frame-edge sentinel padding is out of
/// scope for this 8-bit composition.
///
/// `padded` packs pixel (r,c) at bit `(r*(region+4)+c)*8` (LSB-first, 8 bits
/// each). `out` packs region pixel (y,x) at bit `(y*region+x)*8`. `skip` carries
/// one bit per 8x8 block, block (by,bx) at bit `by*(region/8)+bx`, set when the
/// block is skipped (passed through). `pri`/`sec`/`pri_damp`/`sec_damp` are the
/// unit-level strengths and dampings. Combinational.
class HarborCdefFramePass extends BridgeModule {
  /// [region] is the side length in pixels (multiple of 8). [luma] selects the
  /// luma path (primary strength scaled by directional variance) versus chroma
  /// (strength passed through), forwarded to each [HarborCdefBlock].
  HarborCdefFramePass({int region = 16, bool luma = true, String? name})
    : super('HarborCdefFramePass', name: name ?? 'cdef_pass') {
    if (region <= 0 || region % 8 != 0) {
      throw ArgumentError(
        'HarborCdefFramePass.region must be a positive multiple of 8, '
        'got $region',
      );
    }
    final int padded = region + 4;
    final int nb = region ~/ 8;

    createPort('padded', PortDirection.input, width: padded * padded * 8);
    createPort('skip', PortDirection.input, width: nb * nb);
    createPort('pri', PortDirection.input, width: 8);
    createPort('sec', PortDirection.input, width: 8);
    createPort('pri_damp', PortDirection.input, width: 8);
    createPort('sec_damp', PortDirection.input, width: 8);
    addOutput('out', width: region * region * 8);

    final pri = input('pri');
    final sec = input('sec');
    final priDamp = input('pri_damp');
    final secDamp = input('sec_damp');
    final skip = input('skip');

    // Padded pixel (r,c), 0 <= r,c < padded.
    Logic pad(int r, int c) => input(
      'padded',
    ).getRange((r * padded + c) * 8, (r * padded + c) * 8 + 8);

    // Working grid of region pixels, initialised as pass-through (region pixel
    // (y,x) is padded (y+2, x+2)). Skipped blocks keep these values.
    final grid = <Logic>[
      for (var y = 0; y < region; y++)
        for (var x = 0; x < region; x++) pad(y + 2, x + 2),
    ];

    for (var by = 0; by < nb; by++) {
      for (var bx = 0; bx < nb; bx++) {
        final blk = HarborCdefBlock(luma: luma, name: 'blk_${by}_$bx');
        addSubModule(blk);

        // 12x12 window for this block: padded rows/cols by*8 .. by*8+11,
        // packed LSB-first as HarborCdefBlock expects (pixel (r,c) at bit
        // (r*12+c)*8).
        blk.input('padded').srcConnection! <=
            [
              for (var r = 11; r >= 0; r--)
                for (var c = 11; c >= 0; c--) pad(by * 8 + r, bx * 8 + c),
            ].concat();
        blk.input('pri').srcConnection! <= pri;
        blk.input('sec').srcConnection! <= sec;
        blk.input('pri_damp').srcConnection! <= priDamp;
        blk.input('sec_damp').srcConnection! <= secDamp;

        final filtered = blk.output('out'); // 8x8, (r,c) at bit (r*8+c)*8.
        final blkSkip = skip[by * nb + bx];
        for (var r = 0; r < 8; r++) {
          for (var c = 0; c < 8; c++) {
            final y = by * 8 + r;
            final x = bx * 8 + c;
            final fpx = filtered.getRange((r * 8 + c) * 8, (r * 8 + c) * 8 + 8);
            // Skip => keep the original (pass-through) region pixel.
            grid[y * region + x] = mux(blkSkip, grid[y * region + x], fpx);
          }
        }
      }
    }

    output('out') <=
        [for (var i = region * region - 1; i >= 0; i--) grid[i]].concat();
  }
}

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'cdef_block.dart';
import 'cdef_filter_sentinel.dart';

/// Harbor full-frame AV1 CDEF (Constrained Directional Enhancement Filter) pass.
///
/// Frame-level driver around the CDEF kernels ([HarborCdefBlock] =
/// direction search + [HarborCdefFilter]/[HarborCdefFilterSentinel]). Mirrors
/// libaom `av1_cdef_frame` for the single-tile, 8-bit (lowbd) case:
///
///  * **Full-frame walk.** The frame is covered by 64x64 CDEF units (16x16 mi).
///    Each unit is walked in 8x8 luma blocks. Only non-skipped blocks are
///    filtered, skipped blocks pass through unchanged.
///  * **Per-64x64 strength selection.** Each unit carries a `cdef_idx` that
///    picks the primary/secondary strengths for that unit from the frame's Y and
///    UV strength tables (`y_pri`/`y_sec`/`uv_pri`/`uv_sec`, `1 << cdefBits`
///    entries each) plus the frame damping. Luma damping is `cdef_damping`,
///    chroma damping is `cdef_damping - 1` (pli != Y).
///  * **Frame-edge sentinel.** The padded neighbourhood of each block is built
///    from the reconstructed plane. Taps that fall outside the true frame
///    boundary are filled with `CDEF_VERY_LARGE` (0x4000) so the sentinel-aware
///    core drops their contribution and excludes them from the [min, max] clip.
///    Interior taps carry the real (deblocked) pixels. Single-tile => tile
///    boundaries are frame boundaries.
///  * **Skip.** An 8x8 luma block is skipped when all of its in-frame 4x4 mi are
///    skip (`is_8x8_block_skip`). Out-of-frame mi are treated as skip.
///  * **Chroma.** For `numPlanes > 1` each luma block has a co-located chroma
///    block of size `(8 >> subX) x (8 >> subY)`. Chroma reuses the luma block's
///    direction (remapped only for 4:2:2 / 4:4:0 where `subX != subY`), applies
///    no `adjust_strength`, and uses the UV strengths + chroma damping.
///
/// Purely combinational. Geometry ([lumaW]/[lumaH]/[subX]/[subY]/[numPlanes]/
/// [cdefBits]) is fixed at build time. Pixel data, `cdef_idx`, the strength
/// tables, damping and the skip mask are runtime inputs. [lumaW]/[lumaH] must be
/// multiples of 8 (the direction search reads an always-in-frame central 8x8).
///
/// Port packing (all LSB-first, `bd` bits per pixel, where `bd` is 8/10/12):
///  * `plane_y` / `out_y`: luma pixel (y,x) at bit `(y*lumaW + x)*bd`.
///  * `plane_u`/`plane_v` / `out_u`/`out_v`: chroma pixel at `(y*chW + x)*bd`.
///  * `skip`: 4x4 mi (r,c) at bit `r*miCols + c`, set when that mi is skip.
///  * `cdef_idx`: unit `(fbr*nhfb + fbc)` at bit `unit*idxW` (`idxW = cdefBits`,
///    or 1 and ignored when `cdefBits == 0`).
///  * `y_pri`/`y_sec`/`uv_pri`/`uv_sec`: entry `e` (0..`(1<<cdefBits)-1`) at bit
///    `e*8`.
///  * `cdef_damping`: 8-bit frame damping (`cdef_damping_minus_3 + 3`).
class HarborCdefFrame extends BridgeModule {
  /// [lumaW]/[lumaH] are the luma plane pixel dimensions (multiples of 8).
  /// [subX]/[subY] are the chroma subsampling shifts (0 or 1). [numPlanes] is 1
  /// (monochrome) or 3. [cdefBits] selects `1 << cdefBits` strength sets.
  HarborCdefFrame({
    required int lumaW,
    required int lumaH,
    int subX = 1,
    int subY = 1,
    int numPlanes = 3,
    int cdefBits = 0,
    int bd = 8,
    String? name,
  }) : super(
         'HarborCdefFrame_W${lumaW}_H${lumaH}_SX${subX}_SY${subY}_'
         'P${numPlanes}_C${cdefBits}_B$bd',
         name: name ?? 'cdef_frame',
       ) {
    if (lumaW <= 0 || lumaW % 8 != 0 || lumaH <= 0 || lumaH % 8 != 0) {
      throw ArgumentError(
        'HarborCdefFrame.lumaW/lumaH must be positive '
        'multiples of 8, got ${lumaW}x$lumaH',
      );
    }
    if (subX < 0 || subX > 1 || subY < 0 || subY > 1) {
      throw ArgumentError('HarborCdefFrame.subX/subY must be 0 or 1');
    }
    if (numPlanes != 1 && numPlanes != 3) {
      throw ArgumentError('HarborCdefFrame.numPlanes must be 1 or 3');
    }
    if (cdefBits < 0 || cdefBits > 3) {
      throw ArgumentError('HarborCdefFrame.cdefBits must be 0..3');
    }
    if (bd != 8 && bd != 10 && bd != 12) {
      throw ArgumentError('HarborCdefFrame.bd must be 8, 10 or 12');
    }

    // coeff_shift = bit_depth - 8: shifts strengths/damping and selects the
    // primary tap set, and the pixel bus widens from 8 to `bd` bits.
    final int coeffShift = bd - 8;
    const cdefVeryLarge = 0x4000;
    final bool haveChroma = numPlanes > 1;
    final int chW = haveChroma ? (lumaW + subX) >> subX : 0;
    final int chH = haveChroma ? (lumaH + subY) >> subY : 0;

    // 4x4 mi grid and 64x64 (16 mi) unit grid.
    final int miRows = lumaH ~/ 4;
    final int miCols = lumaW ~/ 4;
    const int miSize64 = 16;
    final int nvfb = (miRows + miSize64 - 1) ~/ miSize64;
    final int nhfb = (miCols + miSize64 - 1) ~/ miSize64;
    final int numUnits = nvfb * nhfb;

    final int numEntries = 1 << cdefBits;
    final int idxW = cdefBits == 0 ? 1 : cdefBits;

    // ports
    createPort('plane_y', PortDirection.input, width: lumaW * lumaH * bd);
    addOutput('out_y', width: lumaW * lumaH * bd);
    if (haveChroma) {
      createPort('plane_u', PortDirection.input, width: chW * chH * bd);
      createPort('plane_v', PortDirection.input, width: chW * chH * bd);
      addOutput('out_u', width: chW * chH * bd);
      addOutput('out_v', width: chW * chH * bd);
      createPort('uv_pri', PortDirection.input, width: numEntries * 8);
      createPort('uv_sec', PortDirection.input, width: numEntries * 8);
    }
    createPort('skip', PortDirection.input, width: miRows * miCols);
    createPort('cdef_idx', PortDirection.input, width: numUnits * idxW);
    createPort('y_pri', PortDirection.input, width: numEntries * 8);
    createPort('y_sec', PortDirection.input, width: numEntries * 8);
    createPort('cdef_damping', PortDirection.input, width: 8);

    final skip = input('skip');
    final cdefIdx = input('cdef_idx');
    final yPriTab = input('y_pri');
    final ySecTab = input('y_sec');
    final cdefDamping = input('cdef_damping');
    final uvPriTab = haveChroma ? input('uv_pri') : null;
    final uvSecTab = haveChroma ? input('uv_sec') : null;

    // Damping (libaom): Y damping = cdef_damping + coeff_shift, chroma damping =
    // cdef_damping - 1 + coeff_shift (pli != Y). The port stays 8-bit.
    final yDamp = coeffShift == 0
        ? cdefDamping
        : (cdefDamping + Const(coeffShift, width: 8)).getRange(0, 8);
    final uvDamp = haveChroma
        ? (cdefDamping + Const(coeffShift, width: 8) - Const(1, width: 8))
              .getRange(0, 8)
        : null;

    // Strength `<< coeff_shift` (libaom pri/sec strength = level << coeff_shift).
    // Real strengths are <= 15 so the shifted value still fits 8 bits.
    Logic shl(Logic v) =>
        coeffShift == 0 ? v : (v.zeroExtend(16) << coeffShift).getRange(0, 8);

    // Per-plane [bd]-bit pixel accessors (in-frame only).
    Logic pxY(int r, int c) => input(
      'plane_y',
    ).getRange((r * lumaW + c) * bd, (r * lumaW + c) * bd + bd);
    Logic pxU(int r, int c) =>
        input('plane_u').getRange((r * chW + c) * bd, (r * chW + c) * bd + bd);
    Logic pxV(int r, int c) =>
        input('plane_v').getRange((r * chW + c) * bd, (r * chW + c) * bd + bd);

    // 15-bit sentinel sample: real pixel in-frame, CDEF_VERY_LARGE outside.
    Logic srcY(int r, int c) => (r >= 0 && r < lumaH && c >= 0 && c < lumaW)
        ? pxY(r, c).zeroExtend(15)
        : Const(cdefVeryLarge, width: 15);
    Logic srcU(int r, int c) => (r >= 0 && r < chH && c >= 0 && c < chW)
        ? pxU(r, c).zeroExtend(15)
        : Const(cdefVeryLarge, width: 15);
    Logic srcV(int r, int c) => (r >= 0 && r < chH && c >= 0 && c < chW)
        ? pxV(r, c).zeroExtend(15)
        : Const(cdefVeryLarge, width: 15);

    // Working grids, initialised to the (pass-through) reconstructed pixels.
    final gridY = <Logic>[
      for (var y = 0; y < lumaH; y++)
        for (var x = 0; x < lumaW; x++) pxY(y, x),
    ];
    final gridU = <Logic>[
      if (haveChroma)
        for (var y = 0; y < chH; y++)
          for (var x = 0; x < chW; x++) pxU(y, x),
    ];
    final gridV = <Logic>[
      if (haveChroma)
        for (var y = 0; y < chH; y++)
          for (var x = 0; x < chW; x++) pxV(y, x),
    ];

    // Strength table select: entry `idx` (runtime) of an 8-bit table.
    Logic tableSel(Logic table, Logic idx) {
      Logic v = table.getRange(0, 8);
      for (var e = 1; e < numEntries; e++) {
        v = mux(
          idx.eq(Const(e, width: idxW)),
          table.getRange(e * 8, e * 8 + 8),
          v,
        );
      }
      return v;
    }

    // Per-4x4-mi skip bit.
    Logic miSkip(int r, int c) => skip[r * miCols + c];

    // is_8x8_block_skip: block (mi top-left miR,miC) skipped iff every in-range
    // 4x4 mi is skip, and out-of-range mi treated as skip.
    Logic blockSkip(int miR, int miC) {
      Logic acc = Const(1, width: 1);
      for (var dr = 0; dr < 2; dr++) {
        for (var dc = 0; dc < 2; dc++) {
          final rr = miR + dr;
          final cc = miC + dc;
          if (rr >= miRows || cc >= miCols) continue; // outside frame => skip
          acc = acc & miSkip(rr, cc);
        }
      }
      return acc;
    }

    // Chroma direction remap for 4:2:2 (conv422) / 4:4:0 (conv440). Identity for
    // 4:2:0 / 4:4:4 (subX == subY).
    const conv422 = [7, 0, 2, 4, 5, 6, 6, 6];
    const conv440 = [1, 2, 2, 2, 3, 4, 6, 0];
    Logic remapDir(Logic dir) {
      if (subX == subY) return dir;
      final lut = subX != 0 ? conv422 : conv440;
      Logic v = Const(lut[7], width: 3);
      for (var d = 6; d >= 0; d--) {
        v = mux(dir.eq(Const(d, width: 3)), Const(lut[d], width: 3), v);
      }
      return v;
    }

    // frame walk
    for (var fbr = 0; fbr < nvfb; fbr++) {
      for (var fbc = 0; fbc < nhfb; fbc++) {
        final int miR0 = fbr * miSize64;
        final int miC0 = fbc * miSize64;
        final int unit = fbr * nhfb + fbc;

        final Logic idx = cdefBits == 0
            ? Const(0, width: 1)
            : cdefIdx.getRange(unit * idxW, unit * idxW + idxW);
        final yPri = shl(tableSel(yPriTab, idx));
        final ySec = shl(tableSel(ySecTab, idx));
        final uvPri = haveChroma ? shl(tableSel(uvPriTab!, idx)) : null;
        final uvSec = haveChroma ? shl(tableSel(uvSecTab!, idx)) : null;

        final int maxR = (miSize64 < miRows - miR0) ? miSize64 : miRows - miR0;
        final int maxC = (miSize64 < miCols - miC0) ? miSize64 : miCols - miC0;

        for (var r = 0; r < maxR; r += 2) {
          for (var c = 0; c < maxC; c += 2) {
            final int gby = (miR0 + r) >> 1; // global 8x8 block indices
            final int gbx = (miC0 + c) >> 1;
            final int blkRow = gby * 8;
            final int blkCol = gbx * 8;
            final Logic sk = blockSkip(miR0 + r, miC0 + c);

            // luma 8x8 block
            final blk = HarborCdefBlock(
              luma: true,
              sentinel: true,
              bd: bd,
              name: 'ly_${gby}_$gbx',
            );
            addSubModule(blk);
            blk.input('padded').srcConnection! <=
                [
                  for (var wr = 11; wr >= 0; wr--)
                    for (var wc = 11; wc >= 0; wc--)
                      srcY(blkRow + wr - 2, blkCol + wc - 2),
                ].swizzle();
            blk.input('pri').srcConnection! <= yPri;
            blk.input('sec').srcConnection! <= ySec;
            blk.input('pri_damp').srcConnection! <= yDamp;
            blk.input('sec_damp').srcConnection! <= yDamp;
            final filtered = blk.output('out');
            final rawDir = blk.output('dir');
            for (var r8 = 0; r8 < 8; r8++) {
              for (var c8 = 0; c8 < 8; c8++) {
                final y = blkRow + r8;
                final x = blkCol + c8;
                final fpx = filtered.getRange(
                  (r8 * 8 + c8) * bd,
                  (r8 * 8 + c8) * bd + bd,
                );
                final gi = y * lumaW + x;
                gridY[gi] = mux(sk, gridY[gi], fpx);
              }
            }

            // chroma blocks
            if (haveChroma) {
              final int chBlkRow = blkRow >> subY;
              final int chBlkCol = blkCol >> subX;
              final int bw = 8 >> subX;
              final int bh = 8 >> subY;
              final Logic chDir = mux(
                uvPri!.or(),
                remapDir(rawDir),
                Const(0, width: 3),
              );
              for (var pl = 1; pl < numPlanes; pl++) {
                Logic src(int rr, int cc) =>
                    pl == 1 ? srcU(rr, cc) : srcV(rr, cc);
                final grid = pl == 1 ? gridU : gridV;
                for (var i = 0; i < bh; i++) {
                  for (var j = 0; j < bw; j++) {
                    final f = HarborCdefFilterSentinel(
                      bd: bd,
                      name: 'c${pl}_${chBlkRow + i}_${chBlkCol + j}',
                    );
                    addSubModule(f);
                    f.input('nb').srcConnection! <=
                        [
                          for (var dr = 4; dr >= 0; dr--)
                            for (var dc = 4; dc >= 0; dc--)
                              src(chBlkRow + i + dr - 2, chBlkCol + j + dc - 2),
                        ].swizzle();
                    f.input('dir').srcConnection! <= chDir;
                    f.input('pri').srcConnection! <= uvPri;
                    f.input('sec').srcConnection! <= uvSec!;
                    f.input('pri_damp').srcConnection! <= uvDamp!;
                    f.input('sec_damp').srcConnection! <= uvDamp;
                    final gi = (chBlkRow + i) * chW + (chBlkCol + j);
                    grid[gi] = mux(sk, grid[gi], f.output('out'));
                  }
                }
              }
            }
          }
        }
      }
    }

    output('out_y') <=
        [for (var i = lumaW * lumaH - 1; i >= 0; i--) gridY[i]].swizzle();
    if (haveChroma) {
      output('out_u') <=
          [for (var i = chW * chH - 1; i >= 0; i--) gridU[i]].swizzle();
      output('out_v') <=
          [for (var i = chW * chH - 1; i >= 0; i--) gridV[i]].swizzle();
    }
  }
}

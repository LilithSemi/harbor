import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'filter_intra.dart';
import 'intra_dir_edge.dart';
import 'intra_pred_rect.dart';
import 'intra_pred_row.dart';
import 'inv_txfm.dart';
import 'palette_recon.dart';

/// Harbor SEQUENTIAL variable-square intra RECON walk: the build-scalable
/// counterpart of [HarborIntraReconWalk]. It reconstructs a square superblock
/// luma plane (`sbSize` x `sbSize`) from variable square leaves (4/8/16/32) in
/// decode order, but predicts + writes back ONE ROW PER CYCLE via
/// [HarborIntraPredRow], so the O(side^2)-multiplier predictor and the
/// O(nPix*side^2) full-block writeback of the flat walk (which make bs >= 32
/// unbuildable) collapse to O(side) predictor work and O(nPix*side) writeback.
///
/// Per leaf: pulse the size-selected [HarborInvTxfm], when it finishes, sweep
/// `row` 0..side-1, each cycle predicting one row, adding the size-selected
/// residual row (clip [0,255]), and writing it into the frame RAM at the leaf's
/// row. Origin-pinned single-SB availability (above iff not on the plane top
/// edge, left iff not on the left edge), no tiling / external neighbours yet.
///
/// Leaf-array packing matches [HarborIntraReconWalk]: `positions`
/// (`maxLeaves*2*miBits`, miRow low / miCol high), `log2sizes` (`maxLeaves*2`,
/// recon log2 0/1/2/3), `y_modes` / `tx_types` (`maxLeaves*4`), `coeffs`
/// (`maxLeaves*coeffN*16`, coeffN=(4<<maxLog2)^2, row-major signed 16b),
/// `leaf_count`. `frame` output is the plane (pixel (r,c) at `[(r*F+c)*8 +: 8]`).
class HarborIntraReconWalkSeq extends BridgeModule {
  /// Plane side in pixels (square superblock), multiple of 4, >= largest leaf.
  final int sbSize;

  /// Max leaves the walk holds.
  final int maxLeaves;

  /// Largest leaf log2(side/4): 2 = up to 16x16, 3 = up to 32x32.
  final int maxLog2;

  /// Sample bit depth (8/10/12). Sets the frame/predictor pixel width
  /// (`pw = bitDepth`), the dequantized-coeff / residual element width
  /// (`cw = bitDepth + 8`) and the final recon clip range `[0, (1<<bd)-1]`.
  /// Defaults to 8 (byte-identical). High bit depth is currently supported only
  /// for the plain square DC/directional path (the optional edgeFilter / rect /
  /// filterIntra / palette / tiled lanes are 8-bit only).
  final int bitDepth;

  /// When true, expose the tile/SB placement + external-neighbour ports and use
  /// tile-relative availability (a leaf on the SB top/left edge whose
  /// tile-relative neighbour IS available draws from the external inputs = the
  /// adjacent SB's reconstructed edge). When false (default) the module is
  /// origin-pinned single-SB, byte-identical to before. Mirrors
  /// [HarborIntraReconWalk]'s tiled path.
  final bool tiled;

  /// When true, route directional leaves (y_mode V..D67) through
  /// [HarborIntraDirEdge]: the full AV1 directional predictor WITH runtime
  /// angle_delta, the corner/edge filter and edge upsample, instead of the
  /// angle_delta-0 [HarborIntraPredRow] directional branch. Adds a `y_angles`
  /// input (per-leaf raw angle_delta, SW delta = raw-3) and an
  /// `enable_edge_filter` input (the seq-header `enable_intra_edge_filter`
  /// flag). Availability of the z1 top-right / z3 bottom-left extension follows
  /// AV1's has_top_right / has_bottom_left within the (single) 64x64 superblock.
  /// The reference-pixel construction (incl. the unavailable-side constant fill)
  /// mirrors the SW `predictIntraRaw` exactly, so [HarborIntraDirEdge]'s
  /// filter/upsample is bit-exact even at partial-availability edges (those
  /// collapse to a constant reference where filtering is a no-op). When false
  /// (default) NONE of this is built and the module is byte-identical to before.
  /// Only supported for the origin-pinned (non-tiled) single-SB path and only
  /// for leaf sizes <= 16 (angle_delta / edge filter for 32x32 is out of scope).
  final bool edgeFilter;

  /// When true, the walk also reconstructs RECTANGULAR leaves (the six shapes
  /// whose largest rect tx has both dims <= 16: 8x4/4x8/16x8/8x16/16x4/4x16).
  /// A new `rect_kinds` input (per-leaf, 3 bits: 0 = square, else 1 + rect kind
  /// where 1=TX_8X4 2=TX_4X8 3=TX_16X8 4=TX_8X16 5=TX_16X4 6=TX_4X16) selects the
  /// geometry. A rect leaf routes through [HarborIntraPredRect] (angle_delta 0)
  /// + [HarborInvTxfm] (runtime tx_type) and a bh-rows x bw-cols writeback (the
  /// leaf coeff slot is row-major r*bw+c, matching the mode-walk raster). When
  /// false (default) NONE of this is built and the module is byte-identical to
  /// before. Requires maxLog2 >= 2 (the largest rect dim is 16) and the origin-
  /// pinned single-SB path (no tiling), angle_delta / edge-filter for rect
  /// directional leaves is out of scope (encode with --enable-angle-delta=0).
  final bool rect;

  /// When true, the walk reconstructs FILTER_INTRA leaves. A new
  /// `leaf_use_filter_intra` input (1 bit/leaf) selects, per leaf, the
  /// [HarborFilterIntra] recursive full-block predictor (fed the leaf's
  /// neighbour border with the SW `predictIntraRaw` constant-fill on the
  /// unavailable side) instead of the DC/directional predictor. The 0..4
  /// filter_intra mode comes from `leaf_filter_intra_modes` (3 bits/leaf).
  /// Filter_intra leaves KEEP the inverse-transform residual (added + clipped
  /// exactly like every other predictor lane). Only the predictor is replaced.
  /// Non-tiled single-SB only, leaf sizes <= 32. Byte-identical when false.
  final bool filterIntra;

  /// When true, the walk reconstructs PALETTE leaves. A new `leaf_has_pal_y`
  /// input (1 bit/leaf) selects, per leaf, a pure color-index lookup
  /// ([HarborPaletteRecon]) instead of intra prediction: `leaf_pal_y_colors`
  /// (8 base colours, 8b each, colour k at [k*8 +: 8]) indexed by
  /// `leaf_pal_y_map` (per-leaf, leaf-local raster with stride = the leaf's
  /// side, 3 bits/index). The looked-up colour REPLACES the predictor. The
  /// (usually zero for palette) inverse-transform residual is still added +
  /// clipped, matching the SW `_reconBlock` palette branch. Non-tiled
  /// single-SB, square leaves only. Byte-identical when false.
  final bool palette;

  // recon rect kinds (1-based, matching the mode-walk leaf_rect_kinds output):
  // (bw, bh, libaom TX_SIZE).
  static const _rectDims = <int, List<int>>{
    1: [8, 4, 6], // TX_8X4
    2: [4, 8, 5], // TX_4X8
    3: [16, 8, 8], // TX_16X8
    4: [8, 16, 7], // TX_8X16
    5: [16, 4, 14], // TX_16X4
    6: [4, 16, 13], // TX_4X16
  };

  // SW has_top_right / has_bottom_left lookup tables (av1/common/reconintra.c),
  // only the square 4x4 / 8x8 / 16x16 entries this within-64x64-SB path needs.
  static const _hasTr4x4 = [
    255, 255, 255, 255, 85, 85, 85, 85, 119, 119, 119, 119, 85, 85, 85, 85, //
    127, 127, 127, 127, 85, 85, 85, 85, 119, 119, 119, 119, 85, 85, 85, 85, //
    255, 127, 255, 127, 85, 85, 85, 85, 119, 119, 119, 119, 85, 85, 85, 85, //
    127, 127, 127, 127, 85, 85, 85, 85, 119, 119, 119, 119, 85, 85, 85, 85, //
  ];
  static const _hasTr8x8 = [
    255, 255, 85, 85, 119, 119, 85, 85, 127, 127, 85, 85, 119, 119, 85, 85, //
    255, 127, 85, 85, 119, 119, 85, 85, 127, 127, 85, 85, 119, 119, 85, 85, //
  ];
  static const _hasTr16x16 = [255, 85, 119, 85, 127, 85, 119, 85];
  static const _hasBl4x4 = [
    84, 85, 85, 85, 16, 17, 17, 17, 84, 85, 85, 85, 0, 1, 1, 1, 84, 85, 85, //
    85, 16, 17, 17, 17, 84, 85, 85, 85, 0, 0, 1, 0, 84, 85, 85, 85, 16, 17, //
    17, 17, 84, 85, 85, 85, 0, 1, 1, 1, 84, 85, 85, 85, 16, 17, 17, 17, 84, //
    85, 85, 85, 0, 0, 0, 0, 84, 85, 85, 85, 16, 17, 17, 17, 84, 85, 85, 85, //
    0, 1, 1, 1, 84, 85, 85, 85, 16, 17, 17, 17, 84, 85, 85, 85, 0, 0, 1, //
    0, 84, 85, 85, 85, 16, 17, 17, 17, 84, 85, 85, 85, 0, 1, 1, 1, 84, 85, //
    85, 85, 16, 17, 17, 17, 84, 85, 85, 85, 0, 0, 0, 0, //
  ];
  static const _hasBl8x8 = [
    84, 85, 16, 17, 84, 85, 0, 1, 84, 85, 16, 17, 84, 85, 0, 0, //
    84, 85, 16, 17, 84, 85, 0, 1, 84, 85, 16, 17, 84, 85, 0, 0, //
  ];
  static const _hasBl16x16 = [84, 16, 84, 0, 84, 16, 84, 0];

  // Build-time has_top_right bit for a square leaf (log2 size `s`: 0=4x4,
  // 1=8x8, 2=16x16) at superblock block-grid (blkRow, blkCol), within a 64x64
  // SB (sbMiSize=16). Mirrors has_top_right's rowOff==0, ssX=ssY=0 branch.
  static int _trBit(int s, int br, int bc) {
    if (br == 0) return 1; // top row of SB
    if (((bc + 1) << s) >= 16) return 0; // rightmost column of SB
    final idx = (br << (5 - s)) + bc;
    final tbl = s == 0 ? _hasTr4x4 : (s == 1 ? _hasTr8x8 : _hasTr16x16);
    return (tbl[idx >> 3] >> (idx & 7)) & 1;
  }

  // Build-time has_bottom_left bit (has_bottom_left colOff==0, ssX=ssY=0).
  static int _blBit(int s, int br, int bc) {
    if (bc == 0) return ((br << s) + (1 << s)) < 16 ? 1 : 0; // leftmost column
    if (((br + 1) << s) >= 16) return 0; // bottom row of SB
    final idx = (br << (5 - s)) + bc;
    final tbl = s == 0 ? _hasBl4x4 : (s == 1 ? _hasBl8x8 : _hasBl16x16);
    return (tbl[idx >> 3] >> (idx & 7)) & 1;
  }

  HarborIntraReconWalkSeq({
    required this.sbSize,
    this.maxLeaves = 16,
    this.maxLog2 = 3,
    this.tiled = false,
    this.edgeFilter = false,
    this.rect = false,
    this.filterIntra = false,
    this.palette = false,
    this.bitDepth = 8,
    String? name,
  }) : assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
       assert(
         bitDepth == 8 ||
             (!tiled && !edgeFilter && !rect && !filterIntra && !palette),
         'high bit depth: plain square path only (no tiled/edgeFilter/'
         'rect/filterIntra/palette)',
       ),
       assert(sbSize >= 8 && sbSize % 4 == 0, 'sbSize multiple of 4, >= 8'),
       assert(maxLeaves >= 1 && maxLeaves <= 64, 'maxLeaves 1..64'),
       assert(maxLog2 >= 1 && maxLog2 <= 4, 'maxLog2 1..4'),
       assert(sbSize >= (4 << maxLog2), 'plane must hold the largest leaf'),
       assert(
         !rect || (!tiled && maxLog2 >= 2),
         'rect: non-tiled single-SB with maxLog2 >= 2 (rect dim up to 16)',
       ),
       assert(!edgeFilter || !tiled, 'edgeFilter only for non-tiled single-SB'),
       assert(
         !filterIntra || !tiled,
         'filterIntra only for non-tiled single-SB',
       ),
       assert(!palette || !tiled, 'palette only for non-tiled single-SB'),
       // has_top_right / has_bottom_left assume a 64x64 SB (sbMiSize=16).
       assert(!edgeFilter || sbSize == 64, 'edgeFilter requires a 64x64 SB'),
       super(
         'HarborIntraReconWalkSeq_S${sbSize}_L${maxLeaves}_G${maxLog2}_'
         'T${tiled ? 1 : 0}_E${edgeFilter ? 1 : 0}_R${rect ? 1 : 0}_'
         'F${filterIntra ? 1 : 0}_P${palette ? 1 : 0}_B$bitDepth',
         name: name ?? 'intra_recon_walk_seq_${sbSize}_$maxLeaves',
       ) {
    final f = sbSize;
    final pw = bitDepth; // pixel width
    final cw = bitDepth + 8; // dequant-coeff / residual element width
    final nPix = f * f;
    final mw = sbSize ~/ 4;
    final miBits = mw.bitLength;
    final maxSide = 4 << maxLog2;
    final coeffN = maxSide * maxSide;
    final cntW = (maxLeaves + 1).bitLength;
    final leafW = maxLeaves.bitLength;
    final iw = (nPix + f).bitLength;
    final rowMax = maxSide; // row counter range
    final rowBits = (rowMax - 1).bitLength;
    final sizes = [for (var i = 0; i <= maxLog2; i++) 4 << i];
    // Per-leaf log2size field width. The recon log2 index runs 0..maxLog2, so
    // maxLog2 4 (64x64) needs 3 bits. Smaller keep the historic 2-bit field
    // (byte-identical). A 2-bit field silently truncates index 4 to 0 (=> a
    // 64x64 leaf misroutes to the 4x4 lane), which is the tx64 recon bug.
    final log2W = maxLog2 >= 4 ? 3 : 2;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('leaf_count', PortDirection.input, width: cntW);
    createPort('positions', PortDirection.input, width: maxLeaves * 2 * miBits);
    createPort('log2sizes', PortDirection.input, width: maxLeaves * log2W);
    createPort('y_modes', PortDirection.input, width: maxLeaves * 4);
    createPort('tx_types', PortDirection.input, width: maxLeaves * 4);
    createPort('coeffs', PortDirection.input, width: maxLeaves * coeffN * cw);
    if (rect) {
      // per-leaf rect kind (0 = square, 1..6 = rect geometry). See [rect].
      createPort('rect_kinds', PortDirection.input, width: maxLeaves * 3);
    }
    if (edgeFilter) {
      // Per-leaf RAW angle_delta_y (0..6, SW delta = raw-3). 0 (=> delta 0) for
      // non-directional / sub-8x8 leaves. Consumed by [HarborIntraDirEdge].
      createPort('y_angles', PortDirection.input, width: maxLeaves * 3);
      // The seq-header enable_intra_edge_filter flag (0 => pure dr_predictor).
      createPort('enable_edge_filter', PortDirection.input);
    }
    if (filterIntra) {
      // Per-leaf FILTER_INTRA select (1 = use the recursive predictor) + the
      // 0..4 filter_intra_mode (3 bits/leaf). Mirror the mode-walk's
      // leaf_use_filter_intra / leaf_filter_intra_modes packing.
      createPort(
        'leaf_use_filter_intra',
        PortDirection.input,
        width: maxLeaves,
      );
      createPort(
        'leaf_filter_intra_modes',
        PortDirection.input,
        width: maxLeaves * 3,
      );
    }
    if (palette) {
      // Per-leaf PALETTE select + the 8 base colours (8b each) + the color-
      // index map (leaf-local raster, stride = the leaf's side, 3 bits/index).
      createPort('leaf_has_pal_y', PortDirection.input, width: maxLeaves);
      createPort(
        'leaf_pal_y_colors',
        PortDirection.input,
        width: maxLeaves * 64,
      );
      createPort(
        'leaf_pal_y_map',
        PortDirection.input,
        width: maxLeaves * maxSide * maxSide * 3,
      );
    }
    // Tile/SB placement (MI units) + external neighbours, only when `tiled`.
    const miAbsW = 16;
    if (tiled) {
      createPort('sb_r', PortDirection.input, width: miAbsW);
      createPort('sb_c', PortDirection.input, width: miAbsW);
      createPort('tile_top_mi', PortDirection.input, width: miAbsW);
      createPort('tile_left_mi', PortDirection.input, width: miAbsW);
      createPort('ext_above', PortDirection.input, width: f * 8);
      createPort('ext_left', PortDirection.input, width: f * 8);
      createPort('ext_corner', PortDirection.input, width: 8);
    }
    addOutput('done');
    addOutput('frame', width: nPix * pw);

    final clk = input('clk');
    final reset = input('reset');

    final frame = [
      for (var i = 0; i < nPix; i++) Logic(name: 'f_$i', width: pw),
    ];
    final leaf = Logic(name: 'leaf', width: leafW);
    final rowc = Logic(name: 'rowc', width: rowBits);

    Logic selSlice(String port, int w) {
      Logic v = input(port).getRange((maxLeaves - 1) * w, maxLeaves * w);
      for (var l = maxLeaves - 2; l >= 0; l--) {
        v = mux(
          leaf.eq(Const(l, width: leafW)),
          input(port).getRange(l * w, l * w + w),
          v,
        );
      }
      return v;
    }

    final posCur = selSlice('positions', 2 * miBits);
    final miR = posCur.getRange(0, miBits).zeroExtend(iw);
    final miC = posCur.getRange(miBits, 2 * miBits).zeroExtend(iw);
    final log2Cur = selSlice('log2sizes', log2W);
    final yMode = selSlice('y_modes', 4);
    final txType = selSlice('tx_types', 4);
    final coeffsCur = selSlice('coeffs', coeffN * cw);
    // rect kind of the current leaf (0 = square).
    final rectKindCur = rect ? selSlice('rect_kinds', 3) : Const(0, width: 3);
    final isRect = rect ? rectKindCur.neq(Const(0, width: 3)) : Const(0);

    final py = (miR * Const(4, width: iw)).getRange(0, iw);
    final px = (miC * Const(4, width: iw)).getRange(0, iw);
    final aboveRow = (py - Const(1, width: iw)).getRange(0, iw);
    final leftCol = (px - Const(1, width: iw)).getRange(0, iw);

    // 2D frame access (frame stays flops, values identical). A read of a whole
    // row (row-major select, O(f)) or column (col-major select, O(f)) is done
    // ONCE, then individual pixels are extracted (O(f) each). This makes the
    // above-row read O(f^2 + side*f) and the left-column read O(f^2 + side*f)
    // instead of O(nPix) per pixel: the key to building at sbSize >= 64.
    Logic frameRowSel(Logic r) {
      Logic v = [
        for (var c = f - 1; c >= 0; c--) frame[(f - 1) * f + c],
      ].swizzle();
      for (var rr = f - 2; rr >= 0; rr--) {
        v = mux(
          r.eq(Const(rr, width: iw)),
          [for (var c = f - 1; c >= 0; c--) frame[rr * f + c]].swizzle(),
          v,
        );
      }
      return v; // f pixels (row r), pixel c at [c*pw +: pw]
    }

    Logic frameColSel(Logic c) {
      Logic v = [
        for (var rr = f - 1; rr >= 0; rr--) frame[rr * f + (f - 1)],
      ].swizzle();
      for (var cc = f - 2; cc >= 0; cc--) {
        v = mux(
          c.eq(Const(cc, width: iw)),
          [for (var rr = f - 1; rr >= 0; rr--) frame[rr * f + cc]].swizzle(),
          v,
        );
      }
      return v; // f pixels (col c), pixel r at [r*pw +: pw]
    }

    Logic pixAt(Logic lineData, Logic idx) {
      Logic v = lineData.getRange((f - 1) * pw, f * pw);
      for (var i = f - 2; i >= 0; i--) {
        v = mux(
          idx.eq(Const(i, width: iw)),
          lineData.getRange(i * pw, i * pw + pw),
          v,
        );
      }
      return v;
    }

    // The above row and left column of the CURRENT leaf, selected once.
    final aboveRowData = frameRowSel(aboveRow);
    final leftColData = frameColSel(leftCol);
    Logic frameAtAboveRow(Logic c) => pixAt(aboveRowData, c);
    Logic frameAtLeftCol(Logic r) => pixAt(leftColData, r);

    final Logic haveA;
    final Logic haveL;
    final List<Logic> aboveAll;
    final List<Logic> leftAll;
    final Logic corner;

    if (tiled) {
      // Tile-relative availability (mirrors HarborIntraReconWalk): above iff the
      // absolute pixel row exceeds the tile top edge, left iff the abs col
      // exceeds the tile left edge. A leaf on the SB top/left edge whose
      // tile-relative neighbour IS available draws from ext_above / ext_left.
      final sbPyAbs = (input('sb_r') * Const(4, width: miAbsW)).getRange(
        0,
        miAbsW,
      );
      final sbPxAbs = (input('sb_c') * Const(4, width: miAbsW)).getRange(
        0,
        miAbsW,
      );
      final tileTopPx = (input('tile_top_mi') * Const(4, width: miAbsW))
          .getRange(0, miAbsW);
      final tileLeftPx = (input('tile_left_mi') * Const(4, width: miAbsW))
          .getRange(0, miAbsW);
      final pyAbs = (sbPyAbs + py.zeroExtend(miAbsW)).getRange(0, miAbsW);
      final pxAbs = (sbPxAbs + px.zeroExtend(miAbsW)).getRange(0, miAbsW);
      haveA = pyAbs.gt(tileTopPx);
      haveL = pxAbs.gt(tileLeftPx);
      final atSbTop = py.eq(Const(0, width: iw));
      final atSbLeft = px.eq(Const(0, width: iw));
      Logic extAboveAt(Logic col) {
        Logic v = input('ext_above').getRange((f - 1) * 8, f * 8);
        for (var j = f - 2; j >= 0; j--) {
          v = mux(
            col.eq(Const(j, width: iw)),
            input('ext_above').getRange(j * 8, j * 8 + 8),
            v,
          );
        }
        return v;
      }

      Logic extLeftAt(Logic r) {
        Logic v = input('ext_left').getRange((f - 1) * 8, f * 8);
        for (var j = f - 2; j >= 0; j--) {
          v = mux(
            r.eq(Const(j, width: iw)),
            input('ext_left').getRange(j * 8, j * 8 + 8),
            v,
          );
        }
        return v;
      }

      aboveAll = [
        for (var i = 0; i < maxSide; i++)
          mux(
            atSbTop,
            extAboveAt((px + Const(i, width: iw)).getRange(0, iw)),
            frameAtAboveRow((px + Const(i, width: iw)).getRange(0, iw)),
          ),
      ];
      leftAll = [
        for (var i = 0; i < maxSide; i++)
          mux(
            atSbLeft,
            extLeftAt((py + Const(i, width: iw)).getRange(0, iw)),
            frameAtLeftCol((py + Const(i, width: iw)).getRange(0, iw)),
          ),
      ];
      corner = mux(
        atSbTop & atSbLeft,
        input('ext_corner'),
        mux(
          atSbTop,
          extAboveAt(leftCol),
          mux(atSbLeft, extLeftAt(aboveRow), frameAtAboveRow(leftCol)),
        ),
      );
    } else {
      // Origin-pinned availability + neighbour arrays (maxSide-wide prefix).
      haveA = py.gt(Const(0, width: iw));
      haveL = px.gt(Const(0, width: iw));
      aboveAll = [
        for (var i = 0; i < maxSide; i++)
          frameAtAboveRow((px + Const(i, width: iw)).getRange(0, iw)),
      ];
      leftAll = [
        for (var i = 0; i < maxSide; i++)
          frameAtLeftCol((py + Const(i, width: iw)).getRange(0, iw)),
      ];
      corner = frameAtAboveRow(leftCol);
    }

    // directional (angle_delta + edge filter) prelims
    // Computed once per leaf. Only referenced when `edgeFilter`. `directional`
    // gates the whole HarborIntraDirEdge path. `pAngle` = base + delta*3 chooses
    // z1 (needs top-right) / z3 (needs bottom-left) extension.
    late final Logic directional;
    late final Logic deltaPort; // 4-bit two's complement angle_delta (-3..3)
    late final Logic filterType; // intra_edge_filter_type (smooth neighbour)
    if (edgeFilter) {
      final yAngleRaw = selSlice('y_angles', 3); // 0..6
      // The z1 top-right / z3 bottom-left extension is gated on has_top_right /
      // has_bottom_left (below), NOT on pAngle: HarborIntraDirEdge only READS
      // the extension for z1/z3, and there has_top_right/has_bottom_left equal
      // SW's, so no pAngle need-flag is required here.
      deltaPort = (yAngleRaw.zeroExtend(4) - Const(3, width: 4)).getRange(0, 4);
      directional =
          yMode.gte(Const(1, width: 4)) & yMode.lte(Const(8, width: 4));

      // intra_edge_filter_type: 1 if the above or left NEIGHBOUR leaf uses a
      // SMOOTH mode (9/10/11). The neighbour leaf is the one covering the mi
      // directly above (miR-1, miC) / left (miR, miC-1), found by scanning the
      // leaf array (each covered by exactly one leaf, all earlier in decode
      // order). Mirrors SW `_predict`'s aboveSm/leftSm.
      Logic leafSide4(Logic log2L) {
        Logic v = Const(1 << (sizes.length - 1), width: iw);
        for (var s = sizes.length - 2; s >= 0; s--) {
          v = mux(
            log2L.eq(Const(s, width: log2W)),
            Const(1 << s, width: iw),
            v,
          );
        }
        return v;
      }

      final leafCountIn = input('leaf_count');
      Logic neighbourMode(Logic nbR, Logic nbC) {
        Logic v = Const(0, width: 4); // DC (not smooth) when uncovered
        for (var l = 0; l < maxLeaves; l++) {
          final posL = input(
            'positions',
          ).getRange(l * 2 * miBits, (l + 1) * 2 * miBits);
          final lMiR = posL.getRange(0, miBits).zeroExtend(iw);
          final lMiC = posL.getRange(miBits, 2 * miBits).zeroExtend(iw);
          final log2L = input(
            'log2sizes',
          ).getRange(l * log2W, l * log2W + log2W);
          final side4 = leafSide4(log2L);
          final ymL = input('y_modes').getRange(l * 4, l * 4 + 4);
          final valid = Const(l, width: leafCountIn.width).lt(leafCountIn);
          final covers =
              valid &
              nbR.gte(lMiR) &
              nbR.lt((lMiR + side4).getRange(0, iw)) &
              nbC.gte(lMiC) &
              nbC.lt((lMiC + side4).getRange(0, iw));
          v = mux(covers, ymL, v);
        }
        return v;
      }

      Logic isSmooth(Logic m) =>
          m.eq(Const(9, width: 4)) |
          m.eq(Const(10, width: 4)) |
          m.eq(Const(11, width: 4));
      final aboveNb = neighbourMode(
        (miR - Const(1, width: iw)).getRange(0, iw),
        miC,
      );
      final leftNb = neighbourMode(
        miR,
        (miC - Const(1, width: iw)).getRange(0, iw),
      );
      filterType = (haveA & isSmooth(aboveNb)) | (haveL & isSmooth(leftNb));
    } else {
      directional = Const(0);
      deltaPort = Const(0, width: 4);
      filterType = Const(0);
    }

    // filter_intra / palette per-leaf selects (computed once per leaf)
    final Logic useFI;
    final Logic fiModeCur;
    if (filterIntra) {
      useFI = selSlice('leaf_use_filter_intra', 1);
      fiModeCur = selSlice('leaf_filter_intra_modes', 3);
    } else {
      useFI = Const(0);
      fiModeCur = Const(0, width: 3);
    }
    final Logic hasPal;
    final Logic palColorsCur;
    final Logic palMapCur;
    if (palette) {
      hasPal = selSlice('leaf_has_pal_y', 1);
      palColorsCur = selSlice('leaf_pal_y_colors', 64);
      palMapCur = selSlice('leaf_pal_y_map', maxSide * maxSide * 3);
    } else {
      hasPal = Const(0);
      palColorsCur = Const(0, width: 64);
      palMapCur = Const(0, width: maxSide * maxSide * 3);
    }

    // Per-size predictor (row-sequential) + transform. reconRow_s[c] for the
    // current row = clip(predRow_s[c] + residual_s[rowc*side+c]).
    final txStart = Logic(name: 'tx_start');
    final reconRowBySize = <List<Logic>>[]; // [s][c] recon pixel of the row
    final txDoneBySize = <Logic>[];

    for (var s = 0; s < sizes.length; s++) {
      final side = sizes[s];
      final pred = HarborIntraPredRow(
        bs: side,
        bitDepth: bitDepth,
        name: 'pred$side',
      );
      addSubModule(pred);
      pred.input('mode').srcConnection! <= yMode;
      pred.input('have_above').srcConnection! <= haveA;
      pred.input('have_left').srcConnection! <= haveL;
      pred.input('above').srcConnection! <=
          [for (var i = side - 1; i >= 0; i--) aboveAll[i]].swizzle();
      pred.input('left').srcConnection! <=
          [for (var i = side - 1; i >= 0; i--) leftAll[i]].swizzle();
      pred.input('above_left').srcConnection! <= corner;
      pred.input('row').srcConnection! <=
          rowc.getRange(0, pred.input('row').width);
      final predRow = pred.output('pred_row');

      // directional edge-filter lane (angle_delta)
      // For directional leaves (mode V..D67) route the AV1 directional
      // predictor WITH angle_delta + corner/edge filter + edge upsample. The
      // 2*side reference (incl. the z1 top-right / z3 bottom-left extension) is
      // built EXACTLY as SW `predictIntraRaw` (constant fill on the unavailable
      // side), so the filter/upsample is bit-exact at partial availability too.
      final List<Logic> dirRowPix; // per-column selected pixel of row `rowc`
      if (edgeFilter && side <= 16) {
        final bs4 = side ~/ 4; // mi units per side
        // has_top_right / has_bottom_left within the 64x64 SB.
        Logic hasTrBit() {
          Logic v = Const(0);
          for (var br = 0; br < (mw >> s); br++) {
            for (var bc = 0; bc < (mw >> s); bc++) {
              if (_trBit(s, br, bc) == 1) {
                v = mux(
                  miR.eq(Const(br << s, width: iw)) &
                      miC.eq(Const(bc << s, width: iw)),
                  Const(1),
                  v,
                );
              }
            }
          }
          return v;
        }

        Logic hasBlBit() {
          Logic v = Const(0);
          for (var br = 0; br < (mw >> s); br++) {
            for (var bc = 0; bc < (mw >> s); bc++) {
              if (_blBit(s, br, bc) == 1) {
                v = mux(
                  miR.eq(Const(br << s, width: iw)) &
                      miC.eq(Const(bc << s, width: iw)),
                  Const(1),
                  v,
                );
              }
            }
          }
          return v;
        }

        final rightAvail = (miC + Const(bs4, width: iw))
            .getRange(0, iw)
            .lt(Const(mw, width: iw));
        final bottomAvail = (miR + Const(bs4, width: iw))
            .getRange(0, iw)
            .lt(Const(mw, width: iw));
        final hasTR = haveA & rightAvail & hasTrBit();
        final hasBL = bottomAvail & haveL & hasBlBit();

        // reference reads (row py-1 / col px-1), extended to 2*side.
        Logic realA(int i) =>
            frameAtAboveRow((px + Const(i, width: iw)).getRange(0, iw));
        Logic realL(int i) =>
            frameAtLeftCol((py + Const(i, width: iw)).getRange(0, iw));
        final realA0 = realA(0);
        final realL0 = realL(0);
        const bdM1 = 127, bdP1 = 129, bd = 128;

        final aRef = <Logic>[];
        final lRef = <Logic>[];
        for (var i = 0; i < 2 * side; i++) {
          if (i < side) {
            aRef.add(
              mux(haveA, realA(i), mux(haveL, realL0, Const(bdM1, width: 8))),
            );
            lRef.add(
              mux(haveL, realL(i), mux(haveA, realA0, Const(bdP1, width: 8))),
            );
          } else {
            final aRep = mux(
              haveA,
              realA(side - 1),
              mux(haveL, realL0, Const(bdM1, width: 8)),
            );
            aRef.add(mux(hasTR, realA(i), aRep));
            final lRep = mux(
              haveL,
              realL(side - 1),
              mux(haveA, realA0, Const(bdP1, width: 8)),
            );
            lRef.add(mux(hasBL, realL(i), lRep));
          }
        }
        final cornerV = mux(
          haveA & haveL,
          corner,
          mux(haveA, realA0, mux(haveL, realL0, Const(bd, width: 8))),
        );

        final de = HarborIntraDirEdge(bs: side, name: 'diredge$side');
        addSubModule(de);
        de.input('mode').srcConnection! <= yMode;
        de.input('angle_delta').srcConnection! <= deltaPort;
        de.input('above').srcConnection! <=
            [for (var i = 2 * side - 1; i >= 0; i--) aRef[i]].swizzle();
        de.input('left').srcConnection! <=
            [for (var i = 2 * side - 1; i >= 0; i--) lRef[i]].swizzle();
        de.input('corner').srcConnection! <= cornerV;
        de.input('enable_edge_filter').srcConnection! <=
            input('enable_edge_filter');
        de.input('filter_type').srcConnection! <= filterType;
        final dePred = de.output('pred'); // pixel (r,c) at [(r*side+c)*8 +: 8]

        dirRowPix = [
          for (var c = 0; c < side; c++)
            () {
              Logic v = dePred.getRange(
                ((side - 1) * side + c) * 8,
                ((side - 1) * side + c) * 8 + 8,
              );
              for (var r = side - 2; r >= 0; r--) {
                v = mux(
                  rowc.eq(Const(r, width: rowBits)),
                  dePred.getRange((r * side + c) * 8, (r * side + c) * 8 + 8),
                  v,
                );
              }
              return v;
            }(),
        ];
      } else {
        dirRowPix = [for (var c = 0; c < side; c++) Const(0, width: 8)];
      }

      // filter_intra lane (full-block recursive predictor)
      // A filter_intra leaf replaces the DC/directional predictor with
      // [HarborFilterIntra] over the leaf's side x side, fed the neighbour
      // border built with SW `predictIntraRaw`'s constant-fill on the
      // unavailable side (needAbove/needLeft/corner all set, no top-right /
      // bottom-left extension). The residual is added afterwards like any lane.
      final List<Logic> fiRowPix;
      if (filterIntra && side <= 32) {
        Logic aFI(int c) => mux(
          haveA,
          aboveAll[c],
          mux(haveL, leftAll[0], Const(127, width: 8)),
        );
        Logic lFI(int r) => mux(
          haveL,
          leftAll[r],
          mux(haveA, aboveAll[0], Const(129, width: 8)),
        );
        final cornerFI = mux(
          haveA & haveL,
          corner,
          mux(haveA, aboveAll[0], mux(haveL, leftAll[0], Const(128, width: 8))),
        );
        final fi = HarborFilterIntra(bw: side, bh: side, name: 'fi$side');
        addSubModule(fi);
        fi.input('mode').srcConnection! <= fiModeCur;
        // above: entry 0 = corner (buf[0][0]), entry c+1 = above sample c.
        fi.input('above').srcConnection! <=
            [
              for (var i = side; i >= 0; i--) (i == 0 ? cornerFI : aFI(i - 1)),
            ].swizzle();
        fi.input('left').srcConnection! <=
            [for (var r = side - 1; r >= 0; r--) lFI(r)].swizzle();
        final fiPred = fi.output('pred'); // (r,c) at (r*side+c)*8
        fiRowPix = [
          for (var c = 0; c < side; c++)
            () {
              Logic v = fiPred.getRange(
                ((side - 1) * side + c) * 8,
                ((side - 1) * side + c) * 8 + 8,
              );
              for (var r = side - 2; r >= 0; r--) {
                v = mux(
                  rowc.eq(Const(r, width: rowBits)),
                  fiPred.getRange((r * side + c) * 8, (r * side + c) * 8 + 8),
                  v,
                );
              }
              return v;
            }(),
        ];
      } else {
        fiRowPix = [for (var c = 0; c < side; c++) Const(0, width: 8)];
      }

      // palette lane (pure color-index lookup)
      // A palette leaf replaces the predictor with a colour-map lookup
      // ([HarborPaletteRecon]), the (usually zero) residual is still added.
      final List<Logic> palRowPix;
      if (palette) {
        final pr = HarborPaletteRecon(
          n: side * side,
          bitDepth: 8,
          name: 'pal$side',
        );
        addSubModule(pr);
        pr.input('colors').srcConnection! <= palColorsCur;
        pr.input('indices').srcConnection! <=
            palMapCur.getRange(0, side * side * 3);
        final palBlk = pr.output('pixels'); // (r,c) at (r*side+c)*8
        palRowPix = [
          for (var c = 0; c < side; c++)
            () {
              Logic v = palBlk.getRange(
                ((side - 1) * side + c) * 8,
                ((side - 1) * side + c) * 8 + 8,
              );
              for (var r = side - 2; r >= 0; r--) {
                v = mux(
                  rowc.eq(Const(r, width: rowBits)),
                  palBlk.getRange((r * side + c) * 8, (r * side + c) * 8 + 8),
                  v,
                );
              }
              return v;
            }(),
        ];
      } else {
        palRowPix = [for (var c = 0; c < side; c++) Const(0, width: 8)];
      }

      // predRowSel[c] = the active predictor's pixel of row rowc. Priority:
      // palette > filter_intra > directional-edge > HarborIntraPredRow (these
      // are mutually exclusive per SW, so the order only matters for the
      // don't-care lanes). The residual is added to whichever is selected.
      final predRowSel = <Logic>[
        for (var c = 0; c < side; c++)
          () {
            Logic base = (edgeFilter && side <= 16)
                ? mux(
                    directional,
                    dirRowPix[c],
                    predRow.getRange(c * pw, c * pw + pw),
                  )
                : predRow.getRange(c * pw, c * pw + pw);
            if (filterIntra && side <= 32) base = mux(useFI, fiRowPix[c], base);
            if (palette) base = mux(hasPal, palRowPix[c], base);
            return base;
          }(),
      ];

      final rtt = s <= 2;
      final tx = HarborInvTxfm(
        txSize: s,
        txType: 0,
        runtimeTxType: rtt,
        bitDepth: bitDepth,
        name: 'tx$side',
      );
      addSubModule(tx);
      tx.input('clk').srcConnection! <= clk;
      tx.input('reset').srcConnection! <= reset;
      tx.input('start').srcConnection! <= txStart;
      tx.input('coeffs').srcConnection! <=
          coeffsCur.getRange(0, side * side * cw);
      if (rtt) tx.input('tx_type').srcConnection! <= txType;
      txDoneBySize.add(tx.output('done'));
      final residual = tx.output('residual');

      // residual[rowc*side + c] by runtime rowc (cw-bit signed element).
      Logic residualAt(int c) {
        Logic v = residual.getRange(
          ((side - 1) * side + c) * cw,
          ((side - 1) * side + c) * cw + cw,
        );
        for (var r = side - 2; r >= 0; r--) {
          v = mux(
            rowc.eq(Const(r, width: rowBits)),
            residual.getRange((r * side + c) * cw, (r * side + c) * cw + cw),
            v,
          );
        }
        return v;
      }

      // recon = clip(pred + residual, 0, (1<<bd)-1). sumW = cw+2 holds the add.
      final sumW = cw + 2;
      final maxV = (1 << pw) - 1;
      final rr = <Logic>[];
      for (var c = 0; c < side; c++) {
        final p = predRowSel[c].zeroExtend(sumW);
        final res = residualAt(c);
        final sum = (p + [res[cw - 1].replicate(2), res].swizzle()).getRange(
          0,
          sumW,
        );
        final neg = sum[sumW - 1];
        final big = sum.getRange(pw, sumW).or();
        rr.add(
          mux(
            neg,
            Const(0, width: pw),
            mux(big, Const(maxV, width: pw), sum.getRange(0, pw)),
          ),
        );
      }
      reconRowBySize.add(rr);
    }

    // rect lanes (one HarborIntraPredRect + HarborInvTxfm per rect kind)
    // Each rect kind produces a bw-wide recon row of the CURRENT row `rowc`
    // (pred + residual, clipped) and a tx-done. They combine, selected by
    // rectKindCur, into reconRowRect / txDoneRect / bwVal / bhVal, which the
    // final merge muxes over the square path by `isRect`.
    final reconRowByKind = <int, List<Logic>>{};
    final txDoneByKind = <int, Logic>{};
    if (rect) {
      for (final e in _rectDims.entries) {
        final kk = e.key;
        final bw = e.value[0], bh = e.value[1], txSizeR = e.value[2];
        final predR = HarborIntraPredRect(bw: bw, bh: bh, name: 'predr$kk');
        addSubModule(predR);
        predR.input('mode').srcConnection! <= yMode;
        predR.input('have_above').srcConnection! <= haveA;
        predR.input('have_left').srcConnection! <= haveL;
        predR.input('above').srcConnection! <=
            [for (var i = bw - 1; i >= 0; i--) aboveAll[i]].swizzle();
        predR.input('left').srcConnection! <=
            [for (var i = bh - 1; i >= 0; i--) leftAll[i]].swizzle();
        predR.input('above_left').srcConnection! <= corner;
        final predBlk = predR.output('pred'); // (r,c) at (r*bw+c)*8

        final txR = HarborInvTxfm(
          txSize: txSizeR,
          txType: 0,
          runtimeTxType: true,
          name: 'txr$kk',
        );
        addSubModule(txR);
        txR.input('clk').srcConnection! <= clk;
        txR.input('reset').srcConnection! <= reset;
        txR.input('start').srcConnection! <= txStart;
        txR.input('coeffs').srcConnection! <=
            coeffsCur.getRange(0, bw * bh * 16);
        txR.input('tx_type').srcConnection! <= txType;
        txDoneByKind[kk] = txR.output('done');
        final residual = txR.output('residual'); // (r,c) at (r*bw+c)*16

        // recon of row `rowc`, per column c in [0, bw).
        Logic predAt(int c) {
          Logic v = predBlk.getRange(
            ((bh - 1) * bw + c) * 8,
            ((bh - 1) * bw + c) * 8 + 8,
          );
          for (var r = bh - 2; r >= 0; r--) {
            v = mux(
              rowc.eq(Const(r, width: rowBits)),
              predBlk.getRange((r * bw + c) * 8, (r * bw + c) * 8 + 8),
              v,
            );
          }
          return v;
        }

        Logic resAt(int c) {
          Logic v = residual.getRange(
            ((bh - 1) * bw + c) * 16,
            ((bh - 1) * bw + c) * 16 + 16,
          );
          for (var r = bh - 2; r >= 0; r--) {
            v = mux(
              rowc.eq(Const(r, width: rowBits)),
              residual.getRange((r * bw + c) * 16, (r * bw + c) * 16 + 16),
              v,
            );
          }
          return v;
        }

        final rr = <Logic>[];
        for (var c = 0; c < bw; c++) {
          final p = predAt(c).zeroExtend(18);
          final res = resAt(c);
          final sum = (p + [res[15].replicate(2), res].swizzle()).getRange(
            0,
            18,
          );
          final neg = sum[17];
          final big = sum.getRange(8, 18).or();
          rr.add(
            mux(
              neg,
              Const(0, width: 8),
              mux(big, Const(255, width: 8), sum.getRange(0, 8)),
            ),
          );
        }
        reconRowByKind[kk] = rr;
      }
    }

    // Unified maxSide-wide recon row: reconRow[c] = active size's rr[c] for
    // c < side (only c < active side is ever written).
    final reconRow = <Logic>[];
    for (var c = 0; c < maxSide; c++) {
      Logic v = Const(0, width: pw);
      for (var s = 0; s < sizes.length; s++) {
        if (c < sizes[s]) {
          v = mux(log2Cur.eq(Const(s, width: log2W)), reconRowBySize[s][c], v);
        }
      }
      if (rect) {
        Logic vr = Const(0, width: pw);
        for (final e in _rectDims.entries) {
          if (c < e.value[0]) {
            vr = mux(
              rectKindCur.eq(Const(e.key, width: 3)),
              reconRowByKind[e.key]![c],
              vr,
            );
          }
        }
        v = mux(isRect, vr, v);
      }
      reconRow.add(v);
    }

    final txDoneSq = () {
      Logic v = txDoneBySize.last;
      for (var s = sizes.length - 2; s >= 0; s--) {
        v = mux(log2Cur.eq(Const(s, width: log2W)), txDoneBySize[s], v);
      }
      return v;
    }();
    final txDone = rect
        ? mux(isRect, () {
            Logic v = txDoneByKind[_rectDims.keys.last]!;
            for (final kk in _rectDims.keys.toList().reversed.skip(1)) {
              v = mux(
                rectKindCur.eq(Const(kk, width: 3)),
                txDoneByKind[kk]!,
                v,
              );
            }
            return v;
          }(), txDoneSq)
        : txDoneSq;

    // active SIDE (square) as a runtime value. For rect, heightVal drives the
    // row sweep and widthVal the write-column range (they differ for rect).
    final sideVal = () {
      Logic v = Const(sizes.last, width: iw);
      for (var s = sizes.length - 2; s >= 0; s--) {
        v = mux(
          log2Cur.eq(Const(s, width: log2W)),
          Const(sizes[s], width: iw),
          v,
        );
      }
      return v;
    }();
    Logic rectSel(int dimIdx) {
      Logic v = Const(_rectDims.values.last[dimIdx], width: iw);
      final ks = _rectDims.keys.toList();
      for (var i = ks.length - 2; i >= 0; i--) {
        v = mux(
          rectKindCur.eq(Const(ks[i], width: 3)),
          Const(_rectDims[ks[i]]![dimIdx], width: iw),
          v,
        );
      }
      return v;
    }

    final heightVal = rect ? mux(isRect, rectSel(1), sideVal) : sideVal;
    final widthVal = rect ? mux(isRect, rectSel(0), sideVal) : sideVal;

    output('frame') <= [for (var i = nPix - 1; i >= 0; i--) frame[i]].swizzle();

    const sIdle = 0, sTxStart = 1, sTxWait = 2, sRows = 3, sDone = 4;
    final st = Logic(name: 'st', width: 3);
    output('done') <= st.eq(Const(sDone, width: 3));

    final lastLeaf = (input('leaf_count') - Const(1, width: cntW)).getRange(
      0,
      leafW,
    );
    final kr = [for (var k = 0; k < nPix; k++) k ~/ f];
    final kc = [for (var k = 0; k < nPix; k++) k % f];

    // txStart pulses for exactly the cycle spent in sTxStart (single driver).
    txStart <= st.eq(Const(sTxStart, width: 3));

    // current leaf's write-row (frame row) = py + rowc.
    final writeRow = (py + rowc.zeroExtend(iw)).getRange(0, iw);

    // Positioned recon row: posRecon[fc] = reconRow[fc - px] for each frame
    // column fc, computed ONCE (O(f*maxSide)). The write then indexes it by the
    // flop's build-time column (a direct signal, no per-flop mux), dropping the
    // write from O(nPix*maxSide) to O(f*maxSide + nPix): the key to building at
    // sbSize >= 64. Only in-leaf columns (fc in [px, px+side)) are ever written,
    // where fc-px in [0, side) subset [0, maxSide), so the value is valid.
    final posRecon = <Logic>[
      for (var fc = 0; fc < f; fc++)
        () {
          final off = (Const(fc, width: iw) - px).getRange(0, iw);
          Logic v = reconRow.last;
          for (var c = maxSide - 2; c >= 0; c--) {
            v = mux(off.eq(Const(c, width: iw)), reconRow[c], v);
          }
          return v;
        }(),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          leaf < Const(0, width: leafW),
          rowc < Const(0, width: rowBits),
          for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: pw),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  leaf < Const(0, width: leafW),
                  rowc < Const(0, width: rowBits),
                  for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: pw),
                  st < Const(sTxStart, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sTxStart, width: 3), [
              st < Const(sTxWait, width: 3),
            ]),
            CaseItem(Const(sTxWait, width: 3), [
              If(
                txDone,
                then: [
                  rowc < Const(0, width: rowBits),
                  st < Const(sRows, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sRows, width: 3), [
              // write the current recon row into the frame at row (py+rowc).
              for (var k = 0; k < nPix; k++)
                If(
                  Const(kr[k], width: iw).eq(writeRow) &
                      Const(kc[k], width: iw).gte(px) &
                      Const(
                        kc[k],
                        width: iw,
                      ).lt((px + widthVal).getRange(0, iw)),
                  then: [frame[k] < posRecon[kc[k]]],
                ),
              If(
                rowc
                    .zeroExtend(iw)
                    .eq((heightVal - Const(1, width: iw)).getRange(0, iw)),
                then: [
                  If(
                    leaf.eq(lastLeaf),
                    then: [st < Const(sDone, width: 3)],
                    orElse: [
                      leaf < (leaf + Const(1, width: leafW)).getRange(0, leafW),
                      st < Const(sTxStart, width: 3),
                    ],
                  ),
                ],
                orElse: [
                  rowc < (rowc + Const(1, width: rowBits)).getRange(0, rowBits),
                ],
              ),
            ]),
            CaseItem(Const(sDone, width: 3), [
              If(~input('start'), then: [st < Const(sIdle, width: 3)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

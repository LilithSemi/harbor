import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'cdef_frame.dart';
import 'chroma_recon_block.dart';
import 'deblock_frame.dart';
import 'intra_recon_walk_seq.dart';
import 'keyframe_mode_walk.dart';
import 'lr_frame.dart';
import 'superres_upscale.dart';

/// Multi-superblock keyframe intra frame assembly: coded tile bytes to a full
/// ([sbRows]*64)x([sbCols]*64) luma plane plus the collocated 4:2:0 U/V chroma
/// planes, pre in-loop-filter. The multi-SB generalization of the single-64x64-SB
/// end-to-end recon path (mode walk + luma recon + chroma recon): it tiles
/// `sbRows*sbCols` 64x64 superblocks in raster order over one continuous
/// adapting-CDF od_ec window and reconstructs each SB's Y/U/V into the frame,
/// sourcing every SB's above/left intra neighbours from the already-reconstructed
/// neighbouring SBs (the frame RAM).
///
/// Scope: every 64x64 SB is uniformly SPLIT into sixteen 16x16 PARTITION_NONE
/// luma leaves (TX_16X16, DCT/directional-angle-0), 4:2:0 chroma is one TX_8X8
/// block per 16x16 leaf per plane, qband 0. The mode walk decodes a full 64x64
/// root with no frame-dimension-aware force-split, so the frame must be an exact
/// multiple of 64 in both dims, partial-SB edges need mi_rows/mi_cols in the mode
/// walk. In-loop filters (deblock/CDEF/LR/superres) are wired only when their
/// build flags are set.
///
/// Structure (mirrors HarborKeyframeDecodeTileYuvTile with sbSize 64 and the
/// sequential recon):
///  - one [HarborKeyframeModeWalk] (`rootBsize` 12, multiSb, chromaLeaf16,
///    `tileMiW = sbCols*16`), driven `sbRows*sbCols` times in raster order with
///    the multi-SB continuation flags (cont after the first SB, above_open for
///    r>0, cont_left + left_open for c>0, sb_c_mi = c*16). Each SB's per-leaf
///    luma + chroma arrays are latched.
///  - per-SB luma recon ([HarborIntraReconWalkSeq] `tiled`) at SB origin MI
///    (`sb_r=r*16`, `sb_c=c*16`), whole frame = one tile, with the cross-SB luma
///    edges sliced off the neighbour SBs' 64x64 recon frames: ext_above =
///    SB(r-1,c) bottom row, ext_left = SB(r,c-1) right column, ext_corner =
///    SB(r-1,c-1) bottom-right pixel.
///  - per-SB chroma recon: sixteen 8x8 [HarborChromaReconBlock] per plane (a 4x4
///    grid over the chroma plane), one per 16x16 luma leaf, in Z-order. Each
///    block's above/left/corner neighbours come from the earlier leaves in the
///    same SB (Z-order decodes the top/left neighbours first) or, on the SB
///    chroma edge, from the neighbour SBs' edge blocks. CfL AC is subsampled from
///    this SB's reconstructed luma leaf (4:2:0 2x2 sum << 1).
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// frame_y (frameW*frameH*8, pixel (r,c) at [(r*frameW+c)*8 +: 8]), frame_u /
/// frame_v (chW*chH*8, chW=frameW/2, chH=frameH/2).
class HarborKeyframeIntraFrame extends BridgeModule {
  /// Number of 64x64 superblock ROWS (>= 1). frameH = sbRows*64.
  final int sbRows;

  /// Number of 64x64 superblock COLUMNS (>= 1). frameW = sbCols*64.
  final int sbCols;

  /// Maximum coded tile bytes the mode-walk od_ec buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3). This milestone is validated at qband 0 (the
  /// TX_16X16 256-bin eob path is Q0 in the mode walk).
  final int qband;

  /// The frame header tx_mode (2 == TX_MODE_SELECT). All-intra aomenc keyframes
  /// are TX_MODE_LARGEST (== 1) for the uniform-16x16 encode, so no tx_size
  /// symbol is read, pass the ingested `fh.txMode`.
  final int txMode;

  // uv2y: UV mode -> luma-like intra mode (identity, CFL->DC).
  static const _uv2y = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0];
  // intra_mode_to_tx_type (13 entries).
  static const _intraModeToTxType = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3];
  // av1ExtTxUsed[kExtTxSetDtt4Idtx1dDct = 3]: the ext-tx cap row for intra
  // TX_4X4 / TX_8X8 (both map to that set, non-reduced), the chroma tx_type
  // gate for 4:2:0 TX_8X8 chroma.
  static const _av1ExtTxUsed3 = [
    1,
    1,
    1,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    1,
    1,
    0,
    0,
    0,
    0,
  ];

  /// When set, the post-recon in-loop DEBLOCK pass is wired onto the frame
  /// reconstruction and the module's `frame_y/u/v` outputs are the final
  /// filtered frame. This adds the extra `lf_level_*` / `lf_sharpness` input ports and
  /// a full-frame [HarborDeblockFrame] instance. Off by default so the pre-
  /// filter recon tests keep the smaller/faster elaboration.
  final bool applyLoopFilters;

  /// When set (with [applyLoopFilters]), the in-loop CDEF pass is wired after
  /// deblock (SW order: deblock -> CDEF). Adds the CDEF strength-table /
  /// damping metadata ports. [cdefBits] selects `1 << cdefBits` strength sets,
  /// the verified stream uses [cdefBits] 0 (the cdef_idx literal reads zero
  /// bits, so the mode-walk entropy is unchanged and no cdef_idx routing from
  /// decode is needed, the single strength set is always selected).
  final bool enableCdef;

  /// CDEF strength-index bit count (`cdef_bits`). `1 << cdefBits` strength sets.
  final int cdefBits;

  /// When set (with [applyLoopFilters]) AND [upscaledWidth] differs from the
  /// coded luma width (`sbCols*64`), the normative horizontal superres upscale
  /// is wired AFTER CDEF (SW order deblock -> CDEF -> superres -> LR). The
  /// module's `frame_y/u/v` outputs then have the UPSCALED width. When
  /// [upscaledWidth] equals the coded width superres is a no-op and is not
  /// instantiated.
  final bool enableSuperres;

  /// Upscaled (output) luma width. 0 (default) means "no superres" (equal to
  /// the coded luma width `sbCols*64`). Only meaningful with [enableSuperres].
  final int upscaledWidth;

  /// When set (with [applyLoopFilters]), the in-loop LOOP-RESTORATION pass is
  /// wired as the final stage (after superres). Adds the per-plane per-unit
  /// `lr{plane}_rtype/h*/v*/s*/xq*` metadata input ports and a per-plane
  /// [HarborLrFrame]. LR consumes the post-superres frame plus the (superres-
  /// upscaled) DEBLOCK-ONLY snapshot for its stripe boundary lines. Off by
  /// default. A stream whose `frame_restoration_type` is RESTORE_NONE for every
  /// plane simply leaves this off (LR is then a pure pass-through).
  final bool enableLr;

  /// Luma loop-restoration unit size (`loop_restoration_size[0]`). Chroma uses
  /// [lrUnitSizeUV]. Only meaningful with [enableLr].
  final int lrUnitSizeY;

  /// Chroma loop-restoration unit size (`loop_restoration_size[1..2]`), for
  /// 4:2:0 this is [lrUnitSizeY] >> 1. Only meaningful with [enableLr].
  final int lrUnitSizeUV;

  HarborKeyframeIntraFrame({
    required this.sbRows,
    required this.sbCols,
    this.maxBytes = 256,
    this.qband = 0,
    this.txMode = 1,
    this.applyLoopFilters = false,
    this.enableCdef = false,
    this.cdefBits = 0,
    this.enableSuperres = false,
    this.upscaledWidth = 0,
    this.enableLr = false,
    this.lrUnitSizeY = 64,
    this.lrUnitSizeUV = 32,
    String? name,
  }) : assert(sbRows >= 1, 'sbRows >= 1'),
       assert(sbCols >= 1, 'sbCols >= 1'),
       assert(maxBytes > 0, 'maxBytes > 0'),
       assert(qband >= 0 && qband < 4, 'qband 0..3'),
       assert(
         !enableSuperres || applyLoopFilters,
         'enableSuperres requires applyLoopFilters',
       ),
       assert(
         !enableLr || applyLoopFilters,
         'enableLr requires applyLoopFilters',
       ),
       assert(
         upscaledWidth == 0 || upscaledWidth >= sbCols * 64,
         'upscaledWidth must be >= coded width',
       ),
       assert(
         !enableLr || (lrUnitSizeY > 0 && lrUnitSizeUV > 0),
         'lr unit sizes must be positive',
       ),
       super(
         'HarborKeyframeIntraFrame',
         name: name ?? 'keyframe_intra_frame_${sbRows}x$sbCols',
       ) {
    const sbSize = 64; // 64x64 superblock luma
    const f = sbSize; // 64 luma pixels per SB side
    const sbMi = 16; // 64x64 root = 16 MI units
    const maxLeaves = 16; // uniform sixteen 16x16 leaves
    const leafSide = 16; // 16x16 luma leaf
    const lumaCoeffN = 256; // TX_16X16 (recon maxLog2 2 -> maxSide 16 -> 256)
    const recLog2 = 2; // recon log2 index of a 16x16 leaf
    const recMiBits = 5; // bitLength(64/4)
    const recLog2W = 2; // maxLog2 < 4 -> 2-bit log2 field
    const cBs = 8; // 8x8 chroma block (4:2:0 of a 16x16 luma leaf)
    const cN = cBs * cBs; // 64 chroma pixels
    const chromaN = 64; // mode-walk per-leaf chroma coeffs (TX_8X8)
    const cGrid = 4; // 4x4 chroma-block grid per SB
    const cflAcBits = 12;
    const miAbsW = 16;

    final frameW = sbCols * f;
    final frameH = sbRows * f;
    final chW = frameW ~/ 2;
    final chH = frameH ~/ 2;
    final nSb = sbRows * sbCols;

    // Superres output geometry. `upW`/`outChW` are the widths of the module's
    // final `frame_y`/`frame_u`/`frame_v` outputs: the coded (recon) width when
    // superres is off, else the upscaled width. Height is unchanged (superres is
    // a horizontal-only upscale).
    final superresOn =
        applyLoopFilters && enableSuperres && upscaledWidth != frameW;
    final upW = superresOn ? upscaledWidth : frameW;
    final outChW = upW ~/ 2;

    // av1_lr_count_units: number of restoration units across a plane dimension.
    int countUnits(int unitSize, int planeSize) {
      final n = (planeSize + (unitSize >> 1)) ~/ unitSize;
      return n < 1 ? 1 : n;
    }

    // Per-plane LR unit grid (only used when enableLr). Plane 0 luma at the
    // OUTPUT (post-superres) width, planes 1/2 chroma. `loop_restoration`
    // operates on the upscaled plane, so units span the upscaled width.
    final lrUnitSize = [lrUnitSizeY, lrUnitSizeUV, lrUnitSizeUV];
    final lrPlaneW = [upW, outChW, outChW];
    final lrPlaneH = [frameH, chH, chH];
    final lrNumUnits = [
      for (var p = 0; p < 3; p++)
        countUnits(lrUnitSize[p], lrPlaneW[p]) *
            countUnits(lrUnitSize[p], lrPlaneH[p]),
    ];

    int sbIdx(int r, int c) => r * sbCols + c;
    int sbRow(int sb) => sb ~/ sbCols;
    int sbCol(int sb) => sb % sbCols;

    // Z-order leaf -> SB-local MI (miRow, miCol) for a 64x64 SB uniformly split
    // into sixteen 16x16 leaves.
    List<int> leafMi(int leaf) {
      final q = leaf >> 2, s = leaf & 3;
      return [(q >> 1) * 8 + (s >> 1) * 4, (q & 1) * 8 + (s & 1) * 4];
    }

    // leaf -> chroma-grid (br, bc): a 16x16 luma leaf at MI (miR, miC) owns the
    // 8x8 chroma block at grid (miR/4, miC/4).
    List<int> leafGrid(int leaf) {
      final mi = leafMi(leaf);
      return [mi[0] ~/ 4, mi[1] ~/ 4];
    }

    // inverse: chroma grid (br, bc) -> leaf index.
    final leafOfGrid = List.generate(cGrid, (_) => List<int>.filled(cGrid, 0));
    for (var l = 0; l < maxLeaves; l++) {
      final g = leafGrid(l);
      leafOfGrid[g[0]][g[1]] = l;
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    // In-loop DEBLOCK metadata (frame-header derived, uniform for a keyframe):
    // the four adjusted filter-level slots (get_filter_level) and sharpness. All
    // 4x4 mi share one value (all blocks intra, ref=INTRA_FRAME, mode=0, no
    // segmentation for the all-intra encode), so the orchestrator broadcasts each
    // scalar across the per-mi deblock ports. A level of 0 makes the
    // corresponding plane a pass-through (per-plane base-level gate).
    if (applyLoopFilters) {
      createPort('lf_level_yv', PortDirection.input, width: 6);
      createPort('lf_level_yh', PortDirection.input, width: 6);
      createPort('lf_level_u', PortDirection.input, width: 6);
      createPort('lf_level_v', PortDirection.input, width: 6);
      createPort('lf_sharpness', PortDirection.input, width: 3);
    }
    // CDEF frame-header metadata: per-`cdef_idx` primary/secondary strength
    // tables (Y + UV, `1 << cdefBits` entries of 8 bits each) and the frame
    // damping. cdef_idx per 64x64 unit is only meaningful for cdefBits > 0,
    // with cdefBits == 0 the single set is always selected.
    final cdefEntries = 1 << cdefBits;
    if (applyLoopFilters && enableCdef) {
      createPort('cdef_y_pri', PortDirection.input, width: cdefEntries * 8);
      createPort('cdef_y_sec', PortDirection.input, width: cdefEntries * 8);
      createPort('cdef_uv_pri', PortDirection.input, width: cdefEntries * 8);
      createPort('cdef_uv_sec', PortDirection.input, width: cdefEntries * 8);
      createPort('cdef_damping', PortDirection.input, width: 8);
    }
    // Loop-restoration per-plane per-unit metadata (frame-header + read_lr
    // derived): rtype (0 NONE / 1 WIENER / 2 SGRPROJ), the three Wiener half-
    // taps h0..h2 / v0..v2 (8b signed), the two SGR noise params s0/s1 (12b) and
    // the two SGR projection weights xq0/xq1 (8b signed). Units are laid out
    // `rowNum*horzUnits + col` per plane, matching HarborLrFrame. All-zero
    // (rtype 0) makes a plane a pass-through.
    if (applyLoopFilters && enableLr) {
      for (var p = 0; p < 3; p++) {
        for (var u = 0; u < lrNumUnits[p]; u++) {
          createPort('lr${p}_rtype$u', PortDirection.input, width: 2);
          for (final t in ['h0', 'h1', 'h2', 'v0', 'v1', 'v2']) {
            createPort('lr${p}_${t}_$u', PortDirection.input, width: 8);
          }
          createPort('lr${p}_s0_$u', PortDirection.input, width: 12);
          createPort('lr${p}_s1_$u', PortDirection.input, width: 12);
          createPort('lr${p}_xq0_$u', PortDirection.input, width: 8);
          createPort('lr${p}_xq1_$u', PortDirection.input, width: 8);
        }
      }
    }
    addOutput('done');
    addOutput('frame_y', width: upW * frameH * 8);
    addOutput('frame_u', width: outChW * chH * 8);
    addOutput('frame_v', width: outChW * chH * 8);

    final clk = input('clk');
    final reset = input('reset');

    // one continuous mode walk, driven nSb times.
    final walk = HarborKeyframeModeWalk(
      rootBsize: 12,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      maxTxN: 256,
      chroma: true,
      chromaLeaf16: true,
      multiSb: true,
      tileMiW: sbCols * sbMi,
      maxLeafOut: maxLeaves,
      qband: qband,
      txModeSelect: txMode == 2,
      name: 'walk',
    );
    addSubModule(walk);

    final walkStart = Logic(name: 'walk_start');
    final walkCont = Logic(name: 'walk_cont');
    final walkAboveOpen = Logic(name: 'walk_above_open');
    final walkContLeft = Logic(name: 'walk_cont_left');
    final walkLeftOpen = Logic(name: 'walk_left_open');
    final walkSbCol = Logic(
      name: 'walk_sb_col',
      width: walk.input('sb_c_mi').width,
    );

    walk.input('clk').srcConnection! <= clk;
    walk.input('reset').srcConnection! <= reset;
    walk.input('start').srcConnection! <= walkStart;
    walk.input('cont').srcConnection! <= walkCont;
    walk.input('above_open').srcConnection! <= walkAboveOpen;
    walk.input('cont_left').srcConnection! <= walkContLeft;
    walk.input('left_open').srcConnection! <= walkLeftOpen;
    walk.input('sb_c_mi').srcConnection! <= walkSbCol;
    walk.input('bytes').srcConnection! <= input('bytes');
    walk.input('dc_q').srcConnection! <= input('dc_q');
    walk.input('ac_q').srcConnection! <= input('ac_q');

    // per-SB latched leaf arrays (raster order).
    List<Logic> mkCap(int sb) => [
      Logic(name: 'ym_cap$sb', width: maxLeaves * 4), // 0 luma modes
      Logic(name: 'tt_cap$sb', width: maxLeaves * 4), // 1 luma tx types
      Logic(name: 'yc_cap$sb', width: maxLeaves * lumaCoeffN * 16), // 2
      Logic(name: 'uvm_cap$sb', width: maxLeaves * 4), // 3 uv modes
      Logic(name: 'cidx_cap$sb', width: maxLeaves * 8), // 4 cfl alpha idx
      Logic(name: 'csg_cap$sb', width: maxLeaves * 3), // 5 cfl signs
      Logic(name: 'uc_cap$sb', width: maxLeaves * chromaN * 16), // 6 U
      Logic(name: 'vc_cap$sb', width: maxLeaves * chromaN * 16), // 7 V
    ];
    final caps = [for (var sb = 0; sb < nSb; sb++) mkCap(sb)];

    List<Conditional> latch(List<Logic> cap) => [
      cap[0] < walk.output('leaf_ymodes'),
      cap[1] < walk.output('leaf_luma_txtypes'),
      cap[2] < walk.output('leaf_coeffs'),
      cap[3] < walk.output('leaf_uv_modes'),
      cap[4] < walk.output('leaf_cfl_alpha_idxs'),
      cap[5] < walk.output('leaf_cfl_signs_arr'),
      cap[6] < walk.output('leaf_u_coeffs_arr'),
      cap[7] < walk.output('leaf_v_coeffs_arr'),
    ];

    // Constant luma recon geometry (positions/log2 identical for every SB).
    int posVal(int miR, int miC) => miR | (miC << recMiBits);
    final recPositions = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        Const(posVal(leafMi(l)[0], leafMi(l)[1]), width: 2 * recMiBits),
    ].concat();
    final recLog2s = [
      for (var l = maxLeaves - 1; l >= 0; l--) Const(recLog2, width: recLog2W),
    ].concat();

    // ROM select helper.
    Logic romSel(List<int> table, Logic idx, int w) {
      Logic v = Const(table.last, width: w);
      for (var i = table.length - 2; i >= 0; i--) {
        v = mux(
          idx.eq(Const(i, width: idx.width)),
          Const(table[i], width: w),
          v,
        );
      }
      return v;
    }

    // luma edge extractors over a 64x64 SB frame.
    Logic lumaAt(Logic fr, int r, int c) =>
        fr.getRange((r * f + c) * 8, (r * f + c) * 8 + 8);
    Logic lumaBottomRow(Logic fr) =>
        [for (var c = f - 1; c >= 0; c--) lumaAt(fr, f - 1, c)].concat();
    Logic lumaRightCol(Logic fr) =>
        [for (var r = f - 1; r >= 0; r--) lumaAt(fr, r, f - 1)].concat();
    Logic lumaBrPixel(Logic fr) => lumaAt(fr, f - 1, f - 1);

    final zeroLumaRow = Const(0, width: f * 8);
    final zeroLumaPix = Const(0, width: 8);
    final zeroChromaEdge = Const(0, width: cBs * 8);
    final zeroChromaPix = Const(0, width: 8);

    // Chroma RAM edge extractors over the FULL chroma plane (chW x chH).
    Logic cRamAt(List<Logic> ram, int r, int c) => ram[r * chW + c];

    // Persistent frame RAMs (the module outputs). Reconstruction writes each SB's
    // luma / each 8x8 block's chroma into these sized flop RAMs once (at the
    // recon-done latch), rather than holding a live per-SB / per-leaf submodule
    // for every tile position. Recon reuses a single luma-recon-walk (driven nSb
    // times) and a single U + single V chroma block (driven nSb*16 times) whose
    // inputs are muxed by the current SB / chroma-block step. This collapses the
    // O(nSb*leaves) live submodules of a flat build to O(1), and the full-frame
    // output swizzles only change at the once-per-step latch.
    final yRam = [
      for (var i = 0; i < frameW * frameH; i++) Logic(name: 'y_$i', width: 8),
    ];
    final uRam = [
      for (var i = 0; i < chW * chH; i++) Logic(name: 'u_$i', width: 8),
    ];
    final vRam = [
      for (var i = 0; i < chW * chH; i++) Logic(name: 'v_$i', width: 8),
    ];
    final chromaRam = [uRam, vRam];

    // Frozen recon snapshot for the in-loop filters. The filter chain is a large
    // combinational block, feeding it directly from yRam/uRam/vRam would force it
    // to re-settle on EVERY recon FSM clock (the RAMs change each cycle). Instead
    // the recon RAMs are latched ONCE into these stable registers at recon
    // completion (state `sFreeze`), so the filter chain settles only twice (init
    // + freeze) over the whole run. Only allocated when the filters are wired.
    final yFrozen = applyLoopFilters
        ? [
            for (var i = 0; i < frameW * frameH; i++)
              Logic(name: 'yf_$i', width: 8),
          ]
        : const <Logic>[];
    final uFrozen = applyLoopFilters
        ? [for (var i = 0; i < chW * chH; i++) Logic(name: 'uf_$i', width: 8)]
        : const <Logic>[];
    final vFrozen = applyLoopFilters
        ? [for (var i = 0; i < chW * chH; i++) Logic(name: 'vf_$i', width: 8)]
        : const <Logic>[];

    // In-loop filter chain (combinational, post-recon). The recon FSM fills
    // yRam/uRam/vRam with the full-frame pre-filter Y/U/V. Once `done` asserts the
    // RAMs hold the complete reconstruction, so the combinational filter chain
    // below produces the final filtered frame. The AV1 filter order is deblock,
    // snapshot, CDEF, superres, LR, wired here in that order under the
    // [enableCdef]/[enableSuperres]/[enableLr] build flags: deblock, then CDEF,
    // then the deblock-only snapshot (captured pre-CDEF) is upscaled alongside the
    // frame by superres, then loop restoration consumes the post-superres plane
    // plus that upscaled snapshot for its stripe boundaries. Each stage is a
    // pass-through when its flag is off.
    if (!applyLoopFilters) {
      output('frame_y') <=
          [for (var i = frameW * frameH - 1; i >= 0; i--) yRam[i]].concat();
      output('frame_u') <=
          [for (var i = chW * chH - 1; i >= 0; i--) uRam[i]].concat();
      output('frame_v') <=
          [for (var i = chW * chH - 1; i >= 0; i--) vRam[i]].concat();
    } else {
      final reconY = [
        for (var i = frameW * frameH - 1; i >= 0; i--) yFrozen[i],
      ].concat();
      final reconU = [
        for (var i = chW * chH - 1; i >= 0; i--) uFrozen[i],
      ].concat();
      final reconV = [
        for (var i = chW * chH - 1; i >= 0; i--) vFrozen[i],
      ].concat();

      final miRows = sbRows * sbMi;
      final miCols = sbCols * sbMi;
      final nMi = miRows * miCols;

      final deblock = HarborDeblockFrame(
        width: frameW,
        height: frameH,
        numPlanes: 3,
        subX: 1,
        subY: 1,
        name: 'deblock',
      );
      addSubModule(deblock);
      deblock.input('frame').srcConnection! <= reconY;
      deblock.input('frame_u').srcConnection! <= reconU;
      deblock.input('frame_v').srcConnection! <= reconV;
      deblock.input('sharpness').srcConnection! <= input('lf_sharpness');
      // Uniform per-mi metadata: every 4x4 mi is a TX_16X16 luma leaf (tx idx
      // 2) whose 4:2:0 chroma is TX_8X8 (tx idx 1), all blocks intra (is_inter
      // 0), 16x16 prediction blocks. Levels broadcast the frame-header slots.
      Logic bcast(Logic v, int count) =>
          [for (var i = 0; i < count; i++) v].concat();
      deblock.input('mi_tx_y').srcConnection! <= bcast(Const(2, width: 5), nMi);
      deblock.input('mi_tx_uv').srcConnection! <=
          bcast(Const(1, width: 5), nMi);
      deblock.input('mi_level_yv').srcConnection! <=
          bcast(input('lf_level_yv'), nMi);
      deblock.input('mi_level_yh').srcConnection! <=
          bcast(input('lf_level_yh'), nMi);
      deblock.input('mi_level_u').srcConnection! <=
          bcast(input('lf_level_u'), nMi);
      deblock.input('mi_level_v').srcConnection! <=
          bcast(input('lf_level_v'), nMi);
      deblock.input('mi_skip').srcConnection! <= Const(0, width: nMi);
      deblock.input('mi_is_inter').srcConnection! <= Const(0, width: nMi);
      deblock.input('mi_block_w').srcConnection! <=
          bcast(Const(16, width: 8), nMi);
      deblock.input('mi_block_h').srcConnection! <=
          bcast(Const(16, width: 8), nMi);

      // Deblocked planes: the CDEF input (SW: deblock -> snapshot -> CDEF). The
      // snapshot (deblock-only) plane feeds LR stripe boundaries, so capture it
      // BEFORE CDEF overwrites filt*. It is upscaled alongside the CDEF output
      // when superres runs, then handed to LR as its `deblocked` boundary source.
      Logic filtY = deblock.output('out');
      Logic filtU = deblock.output('out_u');
      Logic filtV = deblock.output('out_v');
      Logic deblockedY = filtY;
      Logic deblockedU = filtU;
      Logic deblockedV = filtV;

      if (enableCdef) {
        final cdef = HarborCdefFrame(
          lumaW: frameW,
          lumaH: frameH,
          subX: 1,
          subY: 1,
          numPlanes: 3,
          cdefBits: cdefBits,
          name: 'cdef',
        );
        addSubModule(cdef);
        cdef.input('plane_y').srcConnection! <= filtY;
        cdef.input('plane_u').srcConnection! <= filtU;
        cdef.input('plane_v').srcConnection! <= filtV;
        // All 4x4 mi non-skip for the verified all-intra ramp, the CDEF
        // 8x8-block skip gate reads the real per-mi skip (broadcast 0).
        cdef.input('skip').srcConnection! <= Const(0, width: nMi);
        // cdef_idx: unmeaningful when cdefBits == 0 (single set). The module
        // widths cdef_idx to `numUnits * max(cdefBits,1)`.
        cdef.input('cdef_idx').srcConnection! <=
            Const(0, width: cdef.input('cdef_idx').width);
        cdef.input('y_pri').srcConnection! <= input('cdef_y_pri');
        cdef.input('y_sec').srcConnection! <= input('cdef_y_sec');
        cdef.input('uv_pri').srcConnection! <= input('cdef_uv_pri');
        cdef.input('uv_sec').srcConnection! <= input('cdef_uv_sec');
        cdef.input('cdef_damping').srcConnection! <= input('cdef_damping');
        filtY = cdef.output('out_y');
        filtU = cdef.output('out_u');
        filtV = cdef.output('out_v');
      }

      // Superres: normative horizontal upscale from the coded width to the
      // upscaled width (SW: after CDEF, before LR). Both the post-CDEF frame AND
      // the deblock-only snapshot are upscaled so LR's stripe boundaries line up
      // with the restored (upscaled) plane.
      if (superresOn) {
        var srCount = 0;
        Logic ups(Logic plane, int downWp, int upWp, int hp) {
          final u = HarborSuperresUpscale(
            downW: downWp,
            upW: upWp,
            height: hp,
            name: 'superres${srCount++}',
          );
          addSubModule(u);
          u.input('plane').srcConnection! <= plane;
          return u.output('out');
        }

        filtY = ups(filtY, frameW, upW, frameH);
        deblockedY = ups(deblockedY, frameW, upW, frameH);
        filtU = ups(filtU, chW, outChW, chH);
        deblockedU = ups(deblockedU, chW, outChW, chH);
        filtV = ups(filtV, chW, outChW, chH);
        deblockedV = ups(deblockedV, chW, outChW, chH);
      }

      // Loop restoration: the FINAL in-loop stage (after superres). Each plane's
      // HarborLrFrame reads the post-superres plane (`postCdef`) plus the
      // upscaled deblock-only snapshot (`deblocked`) for the saved stripe
      // boundary lines, driven per unit by the lr{plane}_* metadata ports.
      if (enableLr) {
        Logic wireLr(int p, Logic post, Logic deb, int ssX, int ssY) {
          final lr = HarborLrFrame(
            planeW: lrPlaneW[p],
            planeH: lrPlaneH[p],
            unitSize: lrUnitSize[p],
            ssX: ssX,
            ssY: ssY,
            name: 'lr_p$p',
          );
          addSubModule(lr);
          lr.input('postCdef').srcConnection! <= post;
          lr.input('deblocked').srcConnection! <= deb;
          final n = lr.horzUnits * lr.vertUnits;
          for (var u = 0; u < n; u++) {
            lr.input('rtype$u').srcConnection! <= input('lr${p}_rtype$u');
            for (final t in [
              'h0',
              'h1',
              'h2',
              'v0',
              'v1',
              'v2',
              's0',
              's1',
              'xq0',
              'xq1',
            ]) {
              lr.input('${t}_$u').srcConnection! <= input('lr${p}_${t}_$u');
            }
          }
          return lr.output('out');
        }

        filtY = wireLr(0, filtY, deblockedY, 0, 0);
        filtU = wireLr(1, filtU, deblockedU, 1, 1);
        filtV = wireLr(2, filtV, deblockedV, 1, 1);
      }

      output('frame_y') <= filtY;
      output('frame_u') <= filtU;
      output('frame_v') <= filtV;
    }

    // Luma: per-SB recon walk (tiled), latched into yRam. Each SB's recon sources
    // its cross-SB above/left/corner intra neighbours from the already-
    // reconstructed neighbour SBs' recon frames (raster order: left and above SBs
    // finish first). frame_y is assembled from yRam.
    final lumaFrames = List<Logic?>.filled(nSb, null);
    final lumaRecons = List<HarborIntraReconWalkSeq?>.filled(nSb, null);
    final reconStart = [
      for (var sb = 0; sb < nSb; sb++) Logic(name: 'recon${sb}_start'),
    ];

    for (var r = 0; r < sbRows; r++) {
      for (var c = 0; c < sbCols; c++) {
        final sb = sbIdx(r, c);
        final cap = caps[sb];
        final extAbove = (r > 0)
            ? lumaBottomRow(lumaFrames[sbIdx(r - 1, c)]!)
            : zeroLumaRow;
        final extLeft = (c > 0)
            ? lumaRightCol(lumaFrames[sbIdx(r, c - 1)]!)
            : zeroLumaRow;
        final extCorner = (r > 0 && c > 0)
            ? lumaBrPixel(lumaFrames[sbIdx(r - 1, c - 1)]!)
            : zeroLumaPix;

        final lrec = HarborIntraReconWalkSeq(
          sbSize: sbSize,
          maxLeaves: maxLeaves,
          maxLog2: recLog2,
          tiled: true,
          name: 'lrecon$sb',
        );
        addSubModule(lrec);
        lrec.input('clk').srcConnection! <= clk;
        lrec.input('reset').srcConnection! <= reset;
        lrec.input('start').srcConnection! <= reconStart[sb];
        lrec.input('leaf_count').srcConnection! <=
            Const(maxLeaves, width: lrec.input('leaf_count').width);
        lrec.input('positions').srcConnection! <= recPositions;
        lrec.input('log2sizes').srcConnection! <= recLog2s;
        lrec.input('y_modes').srcConnection! <= cap[0];
        lrec.input('tx_types').srcConnection! <= cap[1];
        lrec.input('coeffs').srcConnection! <= cap[2];
        lrec.input('sb_r').srcConnection! <= Const(r * sbMi, width: miAbsW);
        lrec.input('sb_c').srcConnection! <= Const(c * sbMi, width: miAbsW);
        lrec.input('tile_top_mi').srcConnection! <= Const(0, width: miAbsW);
        lrec.input('tile_left_mi').srcConnection! <= Const(0, width: miAbsW);
        lrec.input('ext_above').srcConnection! <= extAbove;
        lrec.input('ext_left').srcConnection! <= extLeft;
        lrec.input('ext_corner').srcConnection! <= extCorner;
        lumaRecons[sb] = lrec;
        lumaFrames[sb] = lrec.output('frame');
      }
    }

    // Chroma: one reused U + one reused V block, driven per chroma block in
    // full-plane raster order. Every block's above/left/corner intra neighbours
    // come from the chroma RAM (raster order guarantees the top/left blocks,
    // intra-SB and cross-SB, are already reconstructed), and its CfL luma-AC from
    // the collocated SB luma recon frame. Inputs are muxed by the running block
    // step `curBlk`.
    final chGridW = chW ~/ cBs; // sbCols*4 blocks across
    final chGridH = chH ~/ cBs; // sbRows*4 blocks down
    final blkPos = <List<int>>[];
    for (var br = 0; br < chGridH; br++) {
      for (var bc = 0; bc < chGridW; bc++) {
        blkPos.add([br, bc]);
      }
    }
    final nBlk = blkPos.length; // nSb*16
    final curBlkW = ((nBlk - 1) < 1) ? 1 : (nBlk - 1).bitLength;
    final curBlk = Logic(name: 'cur_blk', width: curBlkW);
    final chromaStart = Logic(name: 'chroma_start');

    // Per-block derived input signals (indexed by block step).
    final uvIntraB = <Logic>[];
    final useCflB = <Logic>[];
    final cflIdxB = <Logic>[];
    final cflSgnB = <Logic>[];
    final cTxTypeB = <Logic>[];
    final cflAcB = <Logic>[];
    final uCoeffB = <Logic>[];
    final vCoeffB = <Logic>[];
    final haveAboveB = <Logic>[];
    final haveLeftB = <Logic>[];
    final aboveB = [<Logic>[], <Logic>[]]; // [plane][blk]
    final leftB = [<Logic>[], <Logic>[]];
    final cornerB = [<Logic>[], <Logic>[]];

    for (var bi = 0; bi < nBlk; bi++) {
      final gbr = blkPos[bi][0], gbc = blkPos[bi][1];
      final sbR = gbr ~/ cGrid, sbC = gbc ~/ cGrid;
      final sb = sbR * sbCols + sbC;
      final localBr = gbr % cGrid, localBc = gbc % cGrid;
      final leaf = leafOfGrid[localBr][localBc];
      final cap = caps[sb];

      final uvModeCap = cap[3].getRange(leaf * 4, leaf * 4 + 4);
      uvIntraB.add(romSel(_uv2y, uvModeCap, 4));
      useCflB.add(uvModeCap.eq(Const(13, width: 4)));
      cflIdxB.add(cap[4].getRange(leaf * 8, leaf * 8 + 8));
      cflSgnB.add(cap[5].getRange(leaf * 3, leaf * 3 + 3));
      uCoeffB.add(
        cap[6].getRange(leaf * chromaN * 16, (leaf + 1) * chromaN * 16),
      );
      vCoeffB.add(
        cap[7].getRange(leaf * chromaN * 16, (leaf + 1) * chromaN * 16),
      );
      final cTxRaw = romSel(_intraModeToTxType, uvIntraB[bi], 4);
      final cTxUsed = romSel(_av1ExtTxUsed3, cTxRaw, 1);
      cTxTypeB.add(
        mux(cTxUsed.eq(Const(1, width: 1)), cTxRaw, Const(0, width: 4)),
      );

      // CfL luma-AC from the SB's LOCAL luma recon frame (2x2 4:2:0 subsample).
      final lumaFrame = lumaFrames[sb]!;
      final ly0 = localBr * leafSide, lx0 = localBc * leafSide;
      final cflAc = <Logic>[];
      for (var cy = 0; cy < cBs; cy++) {
        for (var cx = 0; cx < cBs; cx++) {
          final a = lumaAt(
            lumaFrame,
            ly0 + cy * 2,
            lx0 + cx * 2,
          ).zeroExtend(cflAcBits);
          final b = lumaAt(
            lumaFrame,
            ly0 + cy * 2,
            lx0 + cx * 2 + 1,
          ).zeroExtend(cflAcBits);
          final cc = lumaAt(
            lumaFrame,
            ly0 + cy * 2 + 1,
            lx0 + cx * 2,
          ).zeroExtend(cflAcBits);
          final d = lumaAt(
            lumaFrame,
            ly0 + cy * 2 + 1,
            lx0 + cx * 2 + 1,
          ).zeroExtend(cflAcBits);
          cflAc.add(((a + b + cc + d) << 1).getRange(0, cflAcBits));
        }
      }
      cflAcB.add([for (var k = cN - 1; k >= 0; k--) cflAc[k]].concat());

      // FULL-PLANE availability + neighbours from the chroma RAM.
      haveAboveB.add(Const(gbr > 0 ? 1 : 0));
      haveLeftB.add(Const(gbc > 0 ? 1 : 0));
      final r0 = gbr * cBs, c0 = gbc * cBs;
      for (var p = 0; p < 2; p++) {
        final ram = chromaRam[p];
        aboveB[p].add(
          gbr > 0
              ? [for (var x = cBs - 1; x >= 0; x--) cRamAt(ram, r0 - 1, c0 + x)]
                    .concat()
              : zeroChromaEdge,
        );
        leftB[p].add(
          gbc > 0
              ? [for (var y = cBs - 1; y >= 0; y--) cRamAt(ram, r0 + y, c0 - 1)]
                    .concat()
              : zeroChromaEdge,
        );
        cornerB[p].add(
          (gbr > 0 && gbc > 0) ? cRamAt(ram, r0 - 1, c0 - 1) : zeroChromaPix,
        );
      }
    }

    // Mux a per-block signal list by the running block step.
    Logic selBlk(List<Logic> per) {
      Logic v = per.last;
      for (var b = nBlk - 2; b >= 0; b--) {
        v = mux(curBlk.eq(Const(b, width: curBlkW)), per[b], v);
      }
      return v;
    }

    final chromaRecon = <Logic>[]; // [plane]
    final chromaDone = <Logic>[];
    for (var p = 0; p < 2; p++) {
      final blk = HarborChromaReconBlock(
        bs: cBs,
        cflAcBits: cflAcBits,
        name: 'crecon$p',
      );
      addSubModule(blk);
      blk.input('clk').srcConnection! <= clk;
      blk.input('reset').srcConnection! <= reset;
      blk.input('start').srcConnection! <= chromaStart;
      blk.input('uv_mode').srcConnection! <= selBlk(uvIntraB);
      blk.input('use_cfl').srcConnection! <= selBlk(useCflB);
      blk.input('have_above').srcConnection! <= selBlk(haveAboveB);
      blk.input('have_left').srcConnection! <= selBlk(haveLeftB);
      blk.input('above').srcConnection! <= selBlk(aboveB[p]);
      blk.input('left').srcConnection! <= selBlk(leftB[p]);
      blk.input('above_left').srcConnection! <= selBlk(cornerB[p]);
      blk.input('cfl_luma_ac').srcConnection! <= selBlk(cflAcB);
      blk.input('cfl_alpha_idx').srcConnection! <= selBlk(cflIdxB);
      blk.input('cfl_signs').srcConnection! <= selBlk(cflSgnB);
      blk.input('plane').srcConnection! <= Const(p, width: 1);
      blk.input('tx_type').srcConnection! <= selBlk(cTxTypeB);
      blk.input('coeffs').srcConnection! <= selBlk(p == 0 ? uCoeffB : vCoeffB);
      blk.input('skip').srcConnection! <= Const(0);
      blk.input('eob_zero').srcConnection! <= Const(0);
      chromaRecon.add(blk.output('recon'));
      chromaDone.add(blk.output('done'));
    }

    Logic cReconAt(Logic recon, int r, int c) =>
        recon.getRange((r * cBs + c) * 8, (r * cBs + c) * 8 + 8);

    // sequencing FSM: mode phase (per SB), luma phase (per SB: run/wait, latch
    // into yRam), chroma phase (per block step: run/wait, latch into
    // uRam/vRam), done.
    const sIdle = 0;
    int sModeRun(int sb) => 1 + 2 * sb;
    int sModeLatch(int sb) => 2 + 2 * sb;
    final lumaBase = 1 + 2 * nSb;
    int sLumaRun(int sb) => lumaBase + 2 * sb;
    int sLumaWait(int sb) => lumaBase + 2 * sb + 1;
    final chromaBase = lumaBase + 2 * nSb;
    int sChromaRun(int bi) => chromaBase + 2 * bi;
    int sChromaWait(int bi) => chromaBase + 2 * bi + 1;
    // sFreeze latches the completed recon RAMs into the stable filter-input
    // registers (one cycle) before done, only used when the filters are wired
    // (else the last chroma step goes straight to sDone).
    final sFreeze = chromaBase + 2 * nBlk;
    final sDone = sFreeze + (applyLoopFilters ? 1 : 0);
    final stW = (sDone + 1).bitLength;
    final chromaTail = applyLoopFilters ? sFreeze : sDone;

    final st = Logic(name: 'st', width: stW);
    output('done') <= st.eq(Const(sDone, width: stW));

    // Combinational: mode-walk drive flags + luma/chroma start pulses.
    Combinational([
      walkStart < Const(0),
      walkCont < Const(0),
      walkAboveOpen < Const(0),
      walkContLeft < Const(0),
      walkLeftOpen < Const(0),
      walkSbCol < Const(0, width: walkSbCol.width),
      for (final rs in reconStart) rs < Const(0),
      chromaStart < Const(0),
      Case(st, [
        CaseItem(Const(sIdle, width: stW), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        for (var sb = 0; sb + 1 < nSb; sb++)
          CaseItem(Const(sModeLatch(sb), width: stW), () {
            final next = sb + 1;
            final r = sbRow(next), c = sbCol(next);
            return <Conditional>[
              walkStart < Const(1),
              walkCont < Const(1),
              if (r > 0) walkAboveOpen < Const(1),
              if (c > 0) ...[walkContLeft < Const(1), walkLeftOpen < Const(1)],
              walkSbCol < Const(c * sbMi, width: walkSbCol.width),
            ];
          }()),
        for (var sb = 0; sb < nSb; sb++)
          CaseItem(Const(sLumaRun(sb), width: stW), [
            reconStart[sb] < Const(1),
          ]),
        for (var bi = 0; bi < nBlk; bi++)
          CaseItem(Const(sChromaRun(bi), width: stW), [chromaStart < Const(1)]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: stW),
          curBlk < Const(0, width: curBlkW),
          for (final cap in caps)
            for (final fld in cap) fld < Const(0, width: fld.width),
          for (final px in yRam) px < Const(0, width: 8),
          for (final px in uRam) px < Const(0, width: 8),
          for (final px in vRam) px < Const(0, width: 8),
          for (final px in yFrozen) px < Const(0, width: 8),
          for (final px in uFrozen) px < Const(0, width: 8),
          for (final px in vFrozen) px < Const(0, width: 8),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: stW), [
              If(input('start'), then: [st < Const(sModeRun(0), width: stW)]),
            ]),
            for (var sb = 0; sb < nSb; sb++) ...[
              CaseItem(Const(sModeRun(sb), width: stW), [
                If(
                  walk.output('done'),
                  then: [st < Const(sModeLatch(sb), width: stW)],
                ),
              ]),
              CaseItem(Const(sModeLatch(sb), width: stW), [
                ...latch(caps[sb]),
                st <
                    Const(
                      sb + 1 < nSb ? sModeRun(sb + 1) : sLumaRun(0),
                      width: stW,
                    ),
              ]),
            ],
            // luma phase: run each SB's recon, then latch its 64x64 frame into
            // yRam at the SB origin.
            for (var sb = 0; sb < nSb; sb++) ...[
              CaseItem(Const(sLumaRun(sb), width: stW), [
                st < Const(sLumaWait(sb), width: stW),
              ]),
              CaseItem(Const(sLumaWait(sb), width: stW), [
                If(
                  lumaRecons[sb]!.output('done'),
                  then: [
                    for (var pr = 0; pr < f; pr++)
                      for (var pc = 0; pc < f; pc++)
                        yRam[(sbRow(sb) * f + pr) * frameW +
                                (sbCol(sb) * f + pc)] <
                            lumaAt(lumaFrames[sb]!, pr, pc),
                    if (sb + 1 == nSb) curBlk < Const(0, width: curBlkW),
                    st <
                        Const(
                          sb + 1 < nSb ? sLumaRun(sb + 1) : sChromaRun(0),
                          width: stW,
                        ),
                  ],
                ),
              ]),
            ],
            // chroma phase: run each block step, then latch its 8x8 U/V recon into
            // the chroma RAMs at the block's plane position.
            for (var bi = 0; bi < nBlk; bi++) ...[
              CaseItem(Const(sChromaRun(bi), width: stW), [
                st < Const(sChromaWait(bi), width: stW),
              ]),
              CaseItem(Const(sChromaWait(bi), width: stW), [
                If(
                  chromaDone[0] & chromaDone[1],
                  then: [
                    for (var yy = 0; yy < cBs; yy++)
                      for (var xx = 0; xx < cBs; xx++) ...[
                        uRam[(blkPos[bi][0] * cBs + yy) * chW +
                                (blkPos[bi][1] * cBs + xx)] <
                            cReconAt(chromaRecon[0], yy, xx),
                        vRam[(blkPos[bi][0] * cBs + yy) * chW +
                                (blkPos[bi][1] * cBs + xx)] <
                            cReconAt(chromaRecon[1], yy, xx),
                      ],
                    if (bi + 1 < nBlk) curBlk < Const(bi + 1, width: curBlkW),
                    st <
                        Const(
                          bi + 1 < nBlk ? sChromaRun(bi + 1) : chromaTail,
                          width: stW,
                        ),
                  ],
                ),
              ]),
            ],
            // Freeze the completed recon RAMs into the stable filter-input
            // registers (one cycle), so the combinational filter chain settles
            // once instead of on every recon clock.
            if (applyLoopFilters)
              CaseItem(Const(sFreeze, width: stW), [
                for (var i = 0; i < frameW * frameH; i++) yFrozen[i] < yRam[i],
                for (var i = 0; i < chW * chH; i++) uFrozen[i] < uRam[i],
                for (var i = 0; i < chW * chH; i++) vFrozen[i] < vRam[i],
                st < Const(sDone, width: stW),
              ]),
            CaseItem(Const(sDone, width: stW), [
              If(~input('start'), then: [st < Const(sIdle, width: stW)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

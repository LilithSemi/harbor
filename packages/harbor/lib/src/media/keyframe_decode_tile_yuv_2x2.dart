import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'chroma_recon_block.dart';
import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// 2x2 multi-superblock keyframe intra decode with chroma: coded bytes to four
/// reconstructed 8x8 4:2:0 superblocks in raster order (SB(0,0) SB(0,1) /
/// SB(1,0) SB(1,1)), assembling a 16x16 luma frame plus 8x8 U and 8x8 V. This
/// combines the horizontal and vertical single-axis chroma recon wrappers into a
/// full 2x2 tile, exercising the chroma left, above, and above-left stitches and
/// the tile-width chroma above-context at once.
///
/// Each SB is a NONE 8x8 leaf (one TX_8X8 luma block, depth-0) in 4:2:0. All
/// four SBs decode on one continuous od_ec window with persistent adapting CDFs:
///  - [HarborKeyframeModeWalk] with `multiSb` + `chroma` + `tileMiW = 4`, driven
///    4 times in raster order. Per-position flags: cont after the first SB,
///    above_open for r>0, cont_left + left_open for c>0, sb_c_mi = c*2.
///  - per-SB luma recon ([HarborIntraReconWalk] with `tiled`) at its tile-origin
///    MI position (sb_r = r*2, sb_c = c*2), with the cross-SB luma stitches:
///    ext_above = (r>0) ? SB(r-1,c) bottom row : 0,
///    ext_left  = (c>0) ? SB(r,c-1) right col  : 0,
///    ext_corner= (r>0&&c>0) ? SB(r-1,c-1) bottom-right px : 0.
///  - per-SB CfL luma-AC subsample (4:2:0) of the SB's own recon luma frame.
///  - per-SB chroma recon ([HarborChromaReconBlock] U + V) with the chroma
///    stitches mirroring the luma stitches on the 4-px chroma edges, per plane.
///
/// Recon is strictly raster-ordered: each SB's recon (luma then chroma) starts
/// only after the previous SB's recon is done and its neighbour SBs' recon
/// outputs are stable, so the combinational slices feeding the stitches are valid.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// luma0..luma3 (512 each), u0..u3 / v0..v3 (128 each), in raster order
/// sb = r*2 + c.
class HarborKeyframeDecodeTileYuv2x2 extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3) for the mode walk's coeff decode.
  final int qband;

  // uv2y[]: UV mode -> luma intra mode (identity, CFL->DC).
  static const _uv2y = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0];
  // intra_mode_to_tx_type, 13 entries.
  static const _intraModeToTxType = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3];
  // av1ExtTxUsed[kExtTxSetDtt4Idtx1dDct=3], the TX_4X4 intra
  // (reducedTxSet=false) ext-tx cap row.
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

  HarborKeyframeDecodeTileYuv2x2({
    this.maxBytes = 64,
    this.qband = 0,
    String? name,
  }) : assert(maxBytes > 0, 'maxBytes must be positive'),
       assert(qband >= 0 && qband < 4, 'qband 0..3'),
       super(
         'HarborKeyframeDecodeTileYuv2x2',
         name: name ?? 'keyframe_decode_tile_yuv_2x2',
       ) {
    const sbSize = 8; // 8x8 superblock luma
    const maxLeaves = 4; // sized like the var decoder (NONE uses 1)
    const f = sbSize; // 8 luma pixels per side
    const nPix = f * f; // 64 luma
    const cBs = 4; // chroma block side (4:2:0)
    const cN = cBs * cBs; // 16 chroma pixels
    const miBits = 2; // bitLength(sbSize/4) = bitLength(2) = 2
    const cntW = 3; // (maxLeaves + 1).bitLength
    const miAbsW = 16; // recon tiled coordinate width
    const sbMi = 2; // 8x8 root = 2 MI units
    const sbCols = 2, sbRows = 2;
    const nSb = sbRows * sbCols; // 4
    // CfL luma-AC per-pixel width: (a+b+c+d) << 1 over the 2x2 collocated luma
    // is up to 255*4*2 = 2040 at bd8 -> 11 bits, use 12 for margin.
    const cflAcBits = 12;

    int sbIdx(int r, int c) => r * sbCols + c;
    int sbRow(int sb) => sb ~/ sbCols;
    int sbCol(int sb) => sb % sbCols;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    addOutput('done');
    for (var sb = 0; sb < nSb; sb++) {
      addOutput('luma$sb', width: nPix * 8);
      addOutput('u$sb', width: cN * 8);
      addOutput('v$sb', width: cN * 8);
    }

    final clk = input('clk');
    final reset = input('reset');

    // single continuous mode walk (driven nSb times), tileMiW = 4.
    final walk = HarborKeyframeModeWalk(
      rootBsize: 3,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      chroma: true,
      multiSb: true,
      tileMiW: sbCols * sbMi,
      qband: qband,
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

    // one latched leaf-array + chroma capture per SB, in raster order.
    List<Logic> mkCap(int sb) => [
      Logic(name: 'lc_cap$sb', width: 12),
      Logic(name: 'l2_cap$sb', width: 4 * 3),
      Logic(name: 'ym_cap$sb', width: 4 * 4),
      Logic(name: 'tt_cap$sb', width: 4 * 4),
      Logic(name: 'coeff_cap$sb', width: 4 * 64 * 16),
      Logic(name: 'uvmode_cap$sb', width: 4),
      Logic(name: 'cflidx_cap$sb', width: 8),
      Logic(name: 'cflsigns_cap$sb', width: 3),
      Logic(name: 'ucoeff_cap$sb', width: 16 * 16),
      Logic(name: 'vcoeff_cap$sb', width: 16 * 16),
    ];
    final caps = [for (var sb = 0; sb < nSb; sb++) mkCap(sb)];

    // Map a latched leaf-array set (NONE single 8x8 leaf) into luma recon-walk
    // inputs. Mirrors the NONE/SPLIT mapping of HarborKeyframeDecodeYuv.
    ({
      Logic leafCount,
      Logic positions,
      Logic log2,
      Logic ymodes,
      Logic txtypes,
      Logic coeffs,
    })
    mapRecon(List<Logic> cap) {
      final lcCap = cap[0],
          l2Cap = cap[1],
          ymCap = cap[2],
          ttCap = cap[3],
          coeffCap = cap[4];
      final reconLeafCount = lcCap.getRange(0, cntW);
      final reconLog2 = [
        for (var l = maxLeaves - 1; l >= 0; l--)
          (l2Cap.getRange(l * 3, l * 3 + 3) - Const(2, width: 3)).getRange(
            0,
            2,
          ),
      ].concat();
      final reconYModes = ymCap;
      final reconTxTypes = ttCap;
      final reconCoeffs = [
        for (var l = maxLeaves - 1; l >= 0; l--) ...[
          Const(0, width: 192 * 16),
          coeffCap.getRange(l * 64 * 16, l * 64 * 16 + 64 * 16),
        ],
      ].concat();
      int posVal(int row, int col) => row | (col << miBits);
      final posNone = Const(posVal(0, 0), width: maxLeaves * 2 * miBits);
      final posSplit = [
        for (var l = maxLeaves - 1; l >= 0; l--)
          Const(posVal(l >> 1, l & 1), width: 2 * miBits),
      ].concat();
      final reconPositions = mux(
        reconLeafCount.eq(Const(4, width: cntW)),
        posSplit,
        posNone,
      );
      return (
        leafCount: reconLeafCount,
        positions: reconPositions,
        log2: reconLog2,
        ymodes: reconYModes,
        txtypes: reconTxTypes,
        coeffs: reconCoeffs,
      );
    }

    final maps = [for (final cap in caps) mapRecon(cap)];

    // chroma derivations (const muxes on a latched uv_mode).
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

    ({Logic uvIntra, Logic useCfl, Logic txType}) chromaDerive(
      Logic uvModeCap,
    ) {
      final uvIntra = romSel(_uv2y, uvModeCap, 4); // chroma intra mode 0..12
      final useCfl = uvModeCap.eq(Const(13, width: 4));
      final txTypeRaw = romSel(_intraModeToTxType, uvIntra, 4);
      final txUsed = romSel(_av1ExtTxUsed3, txTypeRaw, 1);
      final txType = mux(
        txUsed.eq(Const(1, width: 1)),
        txTypeRaw,
        Const(0, width: 4),
      );
      return (uvIntra: uvIntra, useCfl: useCfl, txType: txType);
    }

    final lumaRecons = List<HarborIntraReconWalk?>.filled(nSb, null);
    final lumaFrames = List<Logic?>.filled(nSb, null);
    final chromaUs = List<HarborChromaReconBlock?>.filled(nSb, null);
    final chromaVs = List<HarborChromaReconBlock?>.filled(nSb, null);
    final reconStart = [
      for (var sb = 0; sb < nSb; sb++) Logic(name: 'recon${sb}_start'),
    ];
    final chromaStart = [
      for (var sb = 0; sb < nSb; sb++) Logic(name: 'chroma${sb}_start'),
    ];

    // luma SB edge extractors over an 8x8 luma frame.
    // bottom row: frame[(7*f + c)] for c = 0..7.
    Logic lumaBottomRow(Logic fr) => [
      for (var c = f - 1; c >= 0; c--)
        fr.getRange((7 * f + c) * 8, (7 * f + c) * 8 + 8),
    ].concat();
    // right column: frame[(r*f + 7)] for r = 0..7.
    Logic lumaRightCol(Logic fr) => [
      for (var rr = f - 1; rr >= 0; rr--)
        fr.getRange((rr * f + (f - 1)) * 8, (rr * f + (f - 1)) * 8 + 8),
    ].concat();
    // bottom-right luma pixel: frame[(7*f + 7)].
    Logic lumaBrPixel(Logic fr) =>
        fr.getRange((7 * f + (f - 1)) * 8, (7 * f + (f - 1)) * 8 + 8);

    // chroma 4x4 edge extractors over a chroma recon.
    // bottom row (row cBs-1, cols 0..cBs-1).
    Logic chromaBottomRow(Logic recon) => [
      for (var cc = cBs - 1; cc >= 0; cc--)
        recon.getRange(
          ((cBs - 1) * cBs + cc) * 8,
          ((cBs - 1) * cBs + cc) * 8 + 8,
        ),
    ].concat();
    // right column (col cBs-1, rows 0..cBs-1).
    Logic chromaRightCol(Logic recon) => [
      for (var rr = cBs - 1; rr >= 0; rr--)
        recon.getRange(
          (rr * cBs + (cBs - 1)) * 8,
          (rr * cBs + (cBs - 1)) * 8 + 8,
        ),
    ].concat();
    // bottom-right chroma pixel (row cBs-1, col cBs-1): the above_left corner
    // source for SB(1,1).
    Logic chromaBrPixel(Logic recon) => recon.getRange(
      ((cBs - 1) * cBs + (cBs - 1)) * 8,
      ((cBs - 1) * cBs + (cBs - 1)) * 8 + 8,
    );

    final zeroLumaRow = Const(0, width: f * 8);
    final zeroLumaPix = Const(0, width: 8);
    final zeroChromaEdge = Const(0, width: cBs * 8);
    final zeroChromaPix = Const(0, width: 8);

    // Build one SB's luma + CfL + chroma U/V recon, with the cross-SB stitches.
    // `extAboveLuma` / `extLeftLuma` / `extCornerLuma` are the luma neighbour
    // edges. The chroma neighbour edges are supplied per plane via the
    // `chromaNbrFor` callback (invoked AFTER this SB's luma recon is built and
    // AFTER the prior SBs' chroma recons exist: raster order).
    void buildSb(
      int sb, {
      required Logic extAboveLuma,
      required Logic extLeftLuma,
      required Logic extCornerLuma,
      required Logic chromaHaveAbove,
      required Logic chromaHaveLeft,
      required ({Logic above, Logic left, Logic aboveLeft}) Function(int plane)
      chromaNbrFor,
    }) {
      final m = maps[sb];
      final cap = caps[sb];
      final uvModeCap = cap[5],
          cflIdxCap = cap[6],
          cflSignsCap = cap[7],
          uCoeffCap = cap[8],
          vCoeffCap = cap[9];
      final r = sbRow(sb), c = sbCol(sb);

      // luma recon (tiled). SB at sb_r = r*sbMi, sb_c = c*sbMi.
      final lrec = HarborIntraReconWalk(
        sbSize: sbSize,
        maxLeaves: maxLeaves,
        tiled: true,
        name: 'recon$sb',
      );
      addSubModule(lrec);
      lrec.input('clk').srcConnection! <= clk;
      lrec.input('reset').srcConnection! <= reset;
      lrec.input('start').srcConnection! <= reconStart[sb];
      lrec.input('leaf_count').srcConnection! <= m.leafCount;
      lrec.input('positions').srcConnection! <= m.positions;
      lrec.input('log2sizes').srcConnection! <= m.log2;
      lrec.input('y_modes').srcConnection! <= m.ymodes;
      lrec.input('tx_types').srcConnection! <= m.txtypes;
      lrec.input('coeffs').srcConnection! <= m.coeffs;
      lrec.input('sb_r').srcConnection! <= Const(r * sbMi, width: miAbsW);
      lrec.input('sb_c').srcConnection! <= Const(c * sbMi, width: miAbsW);
      lrec.input('tile_top_mi').srcConnection! <= Const(0, width: miAbsW);
      lrec.input('tile_left_mi').srcConnection! <= Const(0, width: miAbsW);
      lrec.input('ext_above').srcConnection! <= extAboveLuma;
      lrec.input('ext_left').srcConnection! <= extLeftLuma;
      lrec.input('ext_corner').srcConnection! <= extCornerLuma;
      lumaRecons[sb] = lrec;
      final lumaFrame = lrec.output('frame');
      lumaFrames[sb] = lumaFrame;
      output('luma$sb') <= lumaFrame;

      // CfL luma-AC subsample (combinational on this SB's recon luma frame).
      Logic lumaAt(int rr, int cc) =>
          lumaFrame.getRange((rr * f + cc) * 8, (rr * f + cc) * 8 + 8);
      final cflAc = [
        for (var j = 0; j < cBs; j++)
          for (var i = 0; i < cBs; i++)
            (() {
              final ly = j * 2, lx = i * 2;
              final a = lumaAt(ly, lx).zeroExtend(cflAcBits);
              final b = lumaAt(ly, lx + 1).zeroExtend(cflAcBits);
              final cc2 = lumaAt(ly + 1, lx).zeroExtend(cflAcBits);
              final d = lumaAt(ly + 1, lx + 1).zeroExtend(cflAcBits);
              return ((a + b + cc2 + d) << 1).getRange(0, cflAcBits);
            })(),
      ];
      final cflAcPacked = [for (var k = cN - 1; k >= 0; k--) cflAc[k]].concat();

      final cd = chromaDerive(uvModeCap);

      void wireChroma(HarborChromaReconBlock blk, int planeNum, Logic coeffs) {
        final cn = chromaNbrFor(planeNum);
        blk.input('clk').srcConnection! <= clk;
        blk.input('reset').srcConnection! <= reset;
        blk.input('start').srcConnection! <= chromaStart[sb];
        blk.input('uv_mode').srcConnection! <= cd.uvIntra;
        blk.input('use_cfl').srcConnection! <= cd.useCfl;
        blk.input('have_above').srcConnection! <= chromaHaveAbove;
        blk.input('have_left').srcConnection! <= chromaHaveLeft;
        blk.input('above').srcConnection! <= cn.above;
        blk.input('left').srcConnection! <= cn.left;
        blk.input('above_left').srcConnection! <= cn.aboveLeft;
        blk.input('cfl_luma_ac').srcConnection! <= cflAcPacked;
        blk.input('cfl_alpha_idx').srcConnection! <= cflIdxCap;
        blk.input('cfl_signs').srcConnection! <= cflSignsCap;
        blk.input('plane').srcConnection! <= Const(planeNum, width: 1);
        blk.input('tx_type').srcConnection! <= cd.txType;
        blk.input('coeffs').srcConnection! <= coeffs;
        blk.input('skip').srcConnection! <= Const(0);
        blk.input('eob_zero').srcConnection! <= Const(0);
      }

      // Register the U/V blocks BEFORE wiring so chromaNbrFor (which reads
      // chromaUs/chromaVs of the PREVIOUS SBs) is valid.
      final cu = HarborChromaReconBlock(
        bs: cBs,
        cflAcBits: cflAcBits,
        name: 'cu$sb',
      );
      addSubModule(cu);
      final cv = HarborChromaReconBlock(
        bs: cBs,
        cflAcBits: cflAcBits,
        name: 'cv$sb',
      );
      addSubModule(cv);
      chromaUs[sb] = cu;
      chromaVs[sb] = cv;
      wireChroma(cu, 0, uCoeffCap);
      wireChroma(cv, 1, vCoeffCap);
      output('u$sb') <= cu.output('recon');
      output('v$sb') <= cv.output('recon');
    }

    // Build the 4 SBs in RASTER order so each SB's neighbour edges (taken from
    // already-built recon outputs) are available when it is wired.
    for (var r = 0; r < sbRows; r++) {
      for (var c = 0; c < sbCols; c++) {
        final sb = sbIdx(r, c);
        // LUMA stitches (exactly HarborKeyframeDecodeTile's 2x2).
        final extAboveLuma = (r > 0)
            ? lumaBottomRow(lumaFrames[sbIdx(r - 1, c)]!)
            : zeroLumaRow;
        final extLeftLuma = (c > 0)
            ? lumaRightCol(lumaFrames[sbIdx(r, c - 1)]!)
            : zeroLumaRow;
        final extCornerLuma = (r > 0 && c > 0)
            ? lumaBrPixel(lumaFrames[sbIdx(r - 1, c - 1)]!)
            : zeroLumaPix;
        // CHROMA stitches mirror the luma stitches per plane.
        ({Logic above, Logic left, Logic aboveLeft}) chromaNbrFor(int plane) {
          List<HarborChromaReconBlock?> blocks = plane == 0
              ? chromaUs
              : chromaVs;
          final above = (r > 0)
              ? chromaBottomRow(blocks[sbIdx(r - 1, c)]!.output('recon'))
              : zeroChromaEdge;
          final left = (c > 0)
              ? chromaRightCol(blocks[sbIdx(r, c - 1)]!.output('recon'))
              : zeroChromaEdge;
          final aboveLeft = (r > 0 && c > 0)
              ? chromaBrPixel(blocks[sbIdx(r - 1, c - 1)]!.output('recon'))
              : zeroChromaPix;
          return (above: above, left: left, aboveLeft: aboveLeft);
        }

        buildSb(
          sb,
          extAboveLuma: extAboveLuma,
          extLeftLuma: extLeftLuma,
          extCornerLuma: extCornerLuma,
          chromaHaveAbove: Const(r > 0 ? 1 : 0),
          chromaHaveLeft: Const(c > 0 ? 1 : 0),
          chromaNbrFor: chromaNbrFor,
        );
      }
    }

    // sequencing FSM. For each SB in raster: run mode (one window pulse), latch
    // its leaves. Then recon each SB in raster: luma, wait, chroma, wait. Strict
    // raster keeps every stitch source stable before its consumer. States per
    // SB: 2 mode (run, latch) + 4 recon (reconRun, reconWait, chromaRun,
    // chromaWait), plus idle/done.
    final sIdle = 0;
    int sModeRun(int sb) => 1 + 2 * sb;
    int sModeLatch(int sb) => 2 + 2 * sb;
    int sReconRun(int sb) => 1 + 2 * nSb + 4 * sb;
    int sReconWait(int sb) => 2 + 2 * nSb + 4 * sb;
    int sChromaRun(int sb) => 3 + 2 * nSb + 4 * sb;
    int sChromaWait(int sb) => 4 + 2 * nSb + 4 * sb;
    final sDone = 1 + 2 * nSb + 4 * nSb;
    final stW = (sDone + 1).bitLength;

    final st = Logic(name: 'st', width: stW);
    output('done') <= st.eq(Const(sDone, width: stW));

    // Combinational mode-walk drive + recon/chroma start pulses by state.
    Combinational([
      walkStart < Const(0),
      walkCont < Const(0),
      walkAboveOpen < Const(0),
      walkContLeft < Const(0),
      walkLeftOpen < Const(0),
      walkSbCol < Const(0, width: walkSbCol.width),
      for (final rs in reconStart) rs < Const(0),
      for (final cs in chromaStart) cs < Const(0),
      Case(st, [
        // SB 0 is kicked from idle on `start` (fresh window, all flags 0).
        CaseItem(Const(sIdle, width: stW), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        // Each latch state kicks the NEXT SB's mode walk with its flags.
        for (var sb = 0; sb + 1 < nSb; sb++)
          CaseItem(Const(sModeLatch(sb), width: stW), () {
            final next = sb + 1;
            final r = sbRow(next), c = sbCol(next);
            return <Conditional>[
              walkStart < Const(1),
              walkCont < Const(1), // every SB after the first continues
              if (r > 0) walkAboveOpen < Const(1),
              if (c > 0) ...[walkContLeft < Const(1), walkLeftOpen < Const(1)],
              walkSbCol < Const(c * sbMi, width: walkSbCol.width),
            ];
          }()),
        // recon/chroma run states pulse the matching start.
        for (var sb = 0; sb < nSb; sb++) ...[
          CaseItem(Const(sReconRun(sb), width: stW), [
            reconStart[sb] < Const(1),
          ]),
          CaseItem(Const(sChromaRun(sb), width: stW), [
            chromaStart[sb] < Const(1),
          ]),
        ],
      ]),
    ]);

    List<Conditional> latch(List<Logic> cap) => [
      cap[0] < walk.output('leaf_count'),
      cap[1] < walk.output('leaf_log2size'),
      cap[2] < walk.output('leaf_ymodes'),
      // leaf_luma_txtypes: the chroma decode clobbers leaf_txtypes to 0.
      cap[3] < walk.output('leaf_luma_txtypes'),
      cap[4] < walk.output('leaf_coeffs'),
      cap[5] < walk.output('leaf_uv_mode'),
      cap[6] < walk.output('leaf_cfl_alpha_idx'),
      cap[7] < walk.output('leaf_cfl_signs'),
      cap[8] < walk.output('leaf_u_coeffs'),
      cap[9] < walk.output('leaf_v_coeffs'),
    ];

    final chromaDone = [
      for (var sb = 0; sb < nSb; sb++)
        chromaUs[sb]!.output('done') & chromaVs[sb]!.output('done'),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: stW),
          for (final cap in caps) ...[
            cap[0] < Const(0, width: 12),
            cap[1] < Const(0, width: 4 * 3),
            cap[2] < Const(0, width: 4 * 4),
            cap[3] < Const(0, width: 4 * 4),
            cap[4] < Const(0, width: 4 * 64 * 16),
            cap[5] < Const(0, width: 4),
            cap[6] < Const(0, width: 8),
            cap[7] < Const(0, width: 3),
            cap[8] < Const(0, width: 16 * 16),
            cap[9] < Const(0, width: 16 * 16),
          ],
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: stW), [
              If(input('start'), then: [st < Const(sModeRun(0), width: stW)]),
            ]),
            // mode run/latch chain over all SBs.
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
                      sb + 1 < nSb ? sModeRun(sb + 1) : sReconRun(0),
                      width: stW,
                    ),
              ]),
            ],
            // recon (luma then chroma) run/wait chain over all SBs in raster.
            for (var sb = 0; sb < nSb; sb++) ...[
              CaseItem(Const(sReconRun(sb), width: stW), [
                st < Const(sReconWait(sb), width: stW),
              ]),
              CaseItem(Const(sReconWait(sb), width: stW), [
                If(
                  lumaRecons[sb]!.output('done'),
                  then: [st < Const(sChromaRun(sb), width: stW)],
                ),
              ]),
              CaseItem(Const(sChromaRun(sb), width: stW), [
                st < Const(sChromaWait(sb), width: stW),
              ]),
              CaseItem(Const(sChromaWait(sb), width: stW), [
                If(
                  chromaDone[sb],
                  then: [
                    st <
                        Const(
                          sb + 1 < nSb ? sReconRun(sb + 1) : sDone,
                          width: stW,
                        ),
                  ],
                ),
              ]),
            ],
            CaseItem(Const(sDone, width: stW), [
              If(~input('start'), then: [st < Const(sIdle, width: stW)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

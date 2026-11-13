import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'chroma_recon_block.dart';
import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// Vertical multi-superblock keyframe intra decode with chroma: coded bytes to
/// two reconstructed 8x8 4:2:0 superblocks stacked vertically (SB0 at sb_row 0,
/// SB1 directly below at sb_row 1, both in tile column 0), each emitting full YUV
/// (8x8 luma + 4x4 U + 4x4 V). The vertical counterpart of the horizontal chroma
/// recon tile: it exercises the chroma above-EC entropy propagation and the
/// chroma above-pixel recon stitch.
///
/// Each SB is a NONE 8x8 leaf (one TX_8X8 luma block, depth-0) in 4:2:0. The two
/// SBs decode on one continuous od_ec window with persistent adapting CDFs:
///  - [HarborKeyframeModeWalk] with `multiSb` + `chroma` + `tileMiW = 4`. SB0 is
///    a fresh start (all flags 0). SB1 continues (cont = 1) one 8x8 below with a
///    decoded SB-row above it (above_open = 1), in the same tile column
///    (sb_c_mi = 0), with the horizontal-continuation ports inert. SB1's chroma
///    txb_skip / dc_sign ctx thus depend on SB0's chroma EC carried by the
///    tile-width aboveEcU/V arrays plus the continuous window.
///  - per-SB luma recon ([HarborIntraReconWalk] with `tiled`): SB0 at the tile
///    origin (sb_r = 0), SB1 at sb_r = 2 with `ext_above` = SB0's reconstructed
///    luma bottom row. Both SBs are tile-left, so ext_left / ext_corner are 0.
///  - per-SB CfL luma-AC subsample (4:2:0) of the SB's own recon luma frame.
///  - per-SB chroma recon ([HarborChromaReconBlock] U + V): SB0's 4x4 chroma is
///    plane-origin. SB1's above neighbour is SB0's chroma bottom row per plane
///    (have_above = 1, above_left = SB0 chroma bottom row col 0, since the
///    predictor resolves the corner from above[0] when only above is available).
///
/// Recon is strictly raster-ordered: SB1's recon starts only after SB0's recon
/// has produced its bottom rows, so the combinational slices are stable.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// luma0 / luma1 (512 each), u0 / v0 / u1 / v1 (128 each).
class HarborKeyframeDecodeTileYuvVert extends BridgeModule {
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

  HarborKeyframeDecodeTileYuvVert({
    this.maxBytes = 48,
    this.qband = 0,
    String? name,
  }) : assert(maxBytes > 0, 'maxBytes must be positive'),
       assert(qband >= 0 && qband < 4, 'qband 0..3'),
       super(
         'HarborKeyframeDecodeTileYuvVert',
         name: name ?? 'keyframe_decode_tile_yuv_vert',
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
    // CfL luma-AC per-pixel width: (a+b+c+d) << 1 over the 2x2 collocated luma
    // is up to 255*4*2 = 2040 at bd8 -> 11 bits. Use 12 for margin.
    const cflAcBits = 12;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    addOutput('done');
    addOutput('luma0', width: nPix * 8);
    addOutput('u0', width: cN * 8);
    addOutput('v0', width: cN * 8);
    addOutput('luma1', width: nPix * 8);
    addOutput('u1', width: cN * 8);
    addOutput('v1', width: cN * 8);

    final clk = input('clk');
    final reset = input('reset');

    // single continuous mode walk (driven twice), tileMiW = 2 SBs * 2 MI.
    final walk = HarborKeyframeModeWalk(
      rootBsize: 3,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      chroma: true,
      multiSb: true,
      tileMiW: 4,
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

    // one latched leaf-array + chroma capture per SB.
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
    final caps = [for (var sb = 0; sb < 2; sb++) mkCap(sb)];

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

    final lumaRecons = List<HarborIntraReconWalk?>.filled(2, null);
    final lumaFrames = List<Logic?>.filled(2, null);
    final chromaUs = List<HarborChromaReconBlock?>.filled(2, null);
    final chromaVs = List<HarborChromaReconBlock?>.filled(2, null);
    final reconStart = [
      for (var sb = 0; sb < 2; sb++) Logic(name: 'recon${sb}_start'),
    ];
    final chromaStart = [
      for (var sb = 0; sb < 2; sb++) Logic(name: 'chroma${sb}_start'),
    ];

    // SB bottom-row extractor for an 8x8 luma frame (row 7, cols 0..7), packed
    // as ext_above[i*8 +: 8] = frame pixel (row 7, col i).
    Logic lumaBottomRow(Logic fr) => [
      for (var cc = f - 1; cc >= 0; cc--)
        fr.getRange(((f - 1) * f + cc) * 8, ((f - 1) * f + cc) * 8 + 8),
    ].concat();
    // chroma 4x4 bottom-row extractor (row cBs-1, cols 0..cBs-1), packed as
    // above[i*8 +: 8] = chroma pixel (row cBs-1, col i).
    Logic chromaBottomRow(Logic recon) => [
      for (var cc = cBs - 1; cc >= 0; cc--)
        recon.getRange(
          ((cBs - 1) * cBs + cc) * 8,
          ((cBs - 1) * cBs + cc) * 8 + 8,
        ),
    ].concat();
    // chroma 4x4 bottom-row pixel at col 0 (the SB1 above_left corner source).
    // The predictor resolves the corner from above[0] when only above is
    // available.
    Logic chromaBottomRow0(Logic recon) =>
        recon.getRange(((cBs - 1) * cBs) * 8, ((cBs - 1) * cBs) * 8 + 8);

    // Build one SB's luma + CfL + chroma U/V recon. `extAboveLuma` is the luma
    // above row (SB0 bottom row for SB1, else 0). The chroma above neighbour is
    // supplied per plane via the `chromaAboveFor` callback, which is invoked
    // AFTER this SB's luma recon is built (so SB0's chroma recon outputs, the
    // source of SB1's chroma above, exist by the time SB1 is built, raster
    // order). `chromaHaveAbove` is the shared availability flag.
    void buildSb(
      int sb, {
      required Logic extAboveLuma,
      required Logic chromaHaveAbove,
      required ({Logic above, Logic aboveLeft}) Function(int plane)
      chromaAboveFor,
    }) {
      final m = maps[sb];
      final cap = caps[sb];
      final uvModeCap = cap[5],
          cflIdxCap = cap[6],
          cflSignsCap = cap[7],
          uCoeffCap = cap[8],
          vCoeffCap = cap[9];

      // luma recon (tiled). SB0 at sb_r = 0, SB1 at sb_r = 2 (8px below). tile
      // column 0: left unavailable, so ext_left / ext_corner driven 0.
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
      lrec.input('sb_r').srcConnection! <= Const(sb * 2, width: miAbsW);
      lrec.input('sb_c').srcConnection! <= Const(0, width: miAbsW);
      lrec.input('tile_top_mi').srcConnection! <= Const(0, width: miAbsW);
      lrec.input('tile_left_mi').srcConnection! <= Const(0, width: miAbsW);
      lrec.input('ext_above').srcConnection! <= extAboveLuma;
      lrec.input('ext_left').srcConnection! <= Const(0, width: f * 8);
      lrec.input('ext_corner').srcConnection! <= Const(0, width: 8);
      lumaRecons[sb] = lrec;
      final lumaFrame = lrec.output('frame');
      lumaFrames[sb] = lumaFrame;
      output(sb == 0 ? 'luma0' : 'luma1') <= lumaFrame;

      // CfL luma-AC subsample (combinational on this SB's recon luma frame).
      Logic lumaAt(int r, int c) =>
          lumaFrame.getRange((r * f + c) * 8, (r * f + c) * 8 + 8);
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
        final ca = chromaAboveFor(planeNum);
        blk.input('clk').srcConnection! <= clk;
        blk.input('reset').srcConnection! <= reset;
        blk.input('start').srcConnection! <= chromaStart[sb];
        blk.input('uv_mode').srcConnection! <= cd.uvIntra;
        blk.input('use_cfl').srcConnection! <= cd.useCfl;
        blk.input('have_above').srcConnection! <= chromaHaveAbove;
        blk.input('have_left').srcConnection! <= Const(0);
        blk.input('above').srcConnection! <= ca.above;
        blk.input('left').srcConnection! <= Const(0, width: cBs * 8);
        blk.input('above_left').srcConnection! <= ca.aboveLeft;
        blk.input('cfl_luma_ac').srcConnection! <= cflAcPacked;
        blk.input('cfl_alpha_idx').srcConnection! <= cflIdxCap;
        blk.input('cfl_signs').srcConnection! <= cflSignsCap;
        blk.input('plane').srcConnection! <= Const(planeNum, width: 1);
        blk.input('tx_type').srcConnection! <= cd.txType;
        blk.input('coeffs').srcConnection! <= coeffs;
        blk.input('skip').srcConnection! <= Const(0);
        blk.input('eob_zero').srcConnection! <= Const(0);
      }

      // Register the U/V blocks BEFORE wiring so chromaAboveFor (which reads
      // chromaUs/chromaVs of the PREVIOUS SB) is valid.
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
      output(sb == 0 ? 'u0' : 'u1') <= cu.output('recon');
      output(sb == 0 ? 'v0' : 'v1') <= cv.output('recon');
    }

    // SB0: tile-origin. No luma above, no chroma above.
    buildSb(
      0,
      extAboveLuma: Const(0, width: f * 8),
      chromaHaveAbove: Const(0),
      chromaAboveFor: (plane) =>
          (above: Const(0, width: cBs * 8), aboveLeft: Const(0, width: 8)),
    );

    // SB1: luma above = SB0's reconstructed luma bottom row, chroma above =
    // SB0's SAME-plane chroma bottom row (U from SB0.U, V from SB0.V).
    // have_above = 1, above_left resolves to above[0] in the predictor since
    // have_left is false.
    buildSb(
      1,
      extAboveLuma: lumaBottomRow(lumaFrames[0]!),
      chromaHaveAbove: Const(1),
      chromaAboveFor: (plane) {
        final src = (plane == 0 ? chromaUs[0]! : chromaVs[0]!).output('recon');
        return (above: chromaBottomRow(src), aboveLeft: chromaBottomRow0(src));
      },
    );

    // sequencing FSM: walk SB0, latch, walk SB1 (cont + above_open), latch,
    // then recon SB0 (luma, wait, chroma, wait) and SB1, then done. Strict
    // raster: SB1 recon only after SB0's bottom edges are stable (SB0 chroma
    // done before SB1 chroma start).
    const sIdle = 0,
        sRunMode0 = 1,
        sLatch0 = 2,
        sRunMode1 = 3,
        sLatch1 = 4,
        sRunRecon0 = 5,
        sRecon0Wait = 6,
        sRunChroma0 = 7,
        sChroma0Wait = 8,
        sRunRecon1 = 9,
        sRecon1Wait = 10,
        sRunChroma1 = 11,
        sChroma1Wait = 12,
        sDone = 13;
    final st = Logic(name: 'st', width: 4);
    output('done') <= st.eq(Const(sDone, width: 4));

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
        // SB0: fresh start (all flags 0).
        CaseItem(Const(sIdle, width: 4), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        // SB1: continue the window (cont = 1) one 8x8 below, with a decoded
        // SB-row above it (above_open = 1), in the SAME tile column
        // (sb_c_mi = 0). The horizontal-continuation ports stay inert.
        CaseItem(Const(sLatch0, width: 4), [
          walkStart < Const(1),
          walkCont < Const(1),
          walkAboveOpen < Const(1),
          walkSbCol < Const(0, width: walkSbCol.width),
        ]),
        CaseItem(Const(sRunRecon0, width: 4), [reconStart[0] < Const(1)]),
        CaseItem(Const(sRunChroma0, width: 4), [chromaStart[0] < Const(1)]),
        CaseItem(Const(sRunRecon1, width: 4), [reconStart[1] < Const(1)]),
        CaseItem(Const(sRunChroma1, width: 4), [chromaStart[1] < Const(1)]),
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

    final chroma0Done =
        chromaUs[0]!.output('done') & chromaVs[0]!.output('done');
    final chroma1Done =
        chromaUs[1]!.output('done') & chromaVs[1]!.output('done');

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 4),
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
            CaseItem(Const(sIdle, width: 4), [
              If(input('start'), then: [st < Const(sRunMode0, width: 4)]),
            ]),
            CaseItem(Const(sRunMode0, width: 4), [
              If(walk.output('done'), then: [st < Const(sLatch0, width: 4)]),
            ]),
            CaseItem(Const(sLatch0, width: 4), [
              ...latch(caps[0]),
              st < Const(sRunMode1, width: 4),
            ]),
            CaseItem(Const(sRunMode1, width: 4), [
              If(walk.output('done'), then: [st < Const(sLatch1, width: 4)]),
            ]),
            CaseItem(Const(sLatch1, width: 4), [
              ...latch(caps[1]),
              st < Const(sRunRecon0, width: 4),
            ]),
            CaseItem(Const(sRunRecon0, width: 4), [
              st < Const(sRecon0Wait, width: 4),
            ]),
            CaseItem(Const(sRecon0Wait, width: 4), [
              If(
                lumaRecons[0]!.output('done'),
                then: [st < Const(sRunChroma0, width: 4)],
              ),
            ]),
            CaseItem(Const(sRunChroma0, width: 4), [
              st < Const(sChroma0Wait, width: 4),
            ]),
            CaseItem(Const(sChroma0Wait, width: 4), [
              If(chroma0Done, then: [st < Const(sRunRecon1, width: 4)]),
            ]),
            CaseItem(Const(sRunRecon1, width: 4), [
              st < Const(sRecon1Wait, width: 4),
            ]),
            CaseItem(Const(sRecon1Wait, width: 4), [
              If(
                lumaRecons[1]!.output('done'),
                then: [st < Const(sRunChroma1, width: 4)],
              ),
            ]),
            CaseItem(Const(sRunChroma1, width: 4), [
              st < Const(sChroma1Wait, width: 4),
            ]),
            CaseItem(Const(sChroma1Wait, width: 4), [
              If(chroma1Done, then: [st < Const(sDone, width: 4)]),
            ]),
            CaseItem(Const(sDone, width: 4), [
              If(~input('start'), then: [st < Const(sIdle, width: 4)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

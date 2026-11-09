import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// 2x2 superblock keyframe intra decode: coded bytes -> a 16x16 luma frame from
/// four 8x8 superblocks in raster order (SB(0,0) top-left, SB(0,1) top-right,
/// SB(1,0) bottom-left, SB(1,1) bottom-right), all in one tile on one continuous
/// od_ec window. Exercises tile-width above-context: the mode walk's above-*
/// arrays span the whole 4-MI-wide tile, indexed by absolute MI column
/// (`sb_c_mi` + the leaf's local column), so SB(0,0) writes above context for
/// tile cols 0..1, SB(0,1) writes cols 2..3, and the bottom-row SBs each read
/// their own top neighbour's band.
///
/// Entropy walk ([HarborKeyframeModeWalk] with `multiSb` + `tileMiW: 4`): one
/// continuous window driven four times with per-position continuation flags:
///  - SB(0,0): fresh start (cont = 0, above_open = 0, cont_left = 0,
///    left_open = 0, sb_c_mi = 0).
///  - SB(0,1): cont = 1, cont_left = 1 (preserve left = SB(0,0) right edge),
///    left_open = 1, above_open = 0 (tile top), sb_c_mi = 2.
///  - SB(1,0): cont = 1, cont_left = 0 (clear left, tile-left new SB row),
///    left_open = 0, above_open = 1 (SB row above), sb_c_mi = 0.
///  - SB(1,1): cont = 1, cont_left = 1 (preserve left = SB(1,0) right edge),
///    left_open = 1, above_open = 1, sb_c_mi = 2.
///
/// Recon (four [HarborIntraReconWalk] with `tiled`): each SB at its tile-origin
/// position. Cross-SB neighbour stitches (driven by reconstructed edges):
///  - SB(0,1).ext_left   = SB(0,0) recon right column.
///  - SB(1,0).ext_above  = SB(0,0) recon bottom row.
///  - SB(1,1).ext_above  = SB(0,1) recon bottom row.
///  - SB(1,1).ext_left   = SB(1,0) recon right column.
///  - SB(1,1).ext_corner = SB(0,0) recon bottom-right pixel.
/// The predictor does not model above-right / below-left extension (no such
/// inputs, implicitly 0), so no above-right wiring across SBs is needed.
///
/// Scope: each SB is an 8x8 root SPLIT into four 4x4 leaves, mono luma, bd 8.
/// The leaf -> recon mapping is the SPLIT branch of [HarborKeyframeDecodeVar]
/// (leaf l at mi (l>>1, l&1), 4x4, 16 coeffs in the low 16 of a 256-coeff slot).
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// frame (2048, row-major over the assembled 16x16 tile). Pulse `start`. The
/// module walks the 4 SBs on one continuous window, recons them in raster (each
/// SB's neighbour inputs stable before it runs), then asserts `done`.
class HarborKeyframeDecodeTile2x2 extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3) for the mode walk's coeff decode.
  final int qband;

  HarborKeyframeDecodeTile2x2({
    this.maxBytes = 64,
    this.qband = 0,
    String? name,
  }) : assert(maxBytes > 0, 'maxBytes must be positive'),
       assert(qband >= 0 && qband < 4, 'qband 0..3'),
       super(
         'HarborKeyframeDecodeTile2x2',
         name: name ?? 'keyframe_decode_tile2x2',
       ) {
    const sbSize = 8; // 8x8 superblock
    const maxLeaves = 4; // SPLIT (4 leaves)
    const f = sbSize; // 8 pixels per SB side
    const tileW = 2 * f; // 16-pixel tile side
    const miBits = 2; // bitLength(sbSize/4) = bitLength(2) = 2
    const cntW = 3; // (maxLeaves + 1).bitLength = 5.bitLength = 3
    const miAbsW = 16; // recon tiled coordinate width
    const sbMi = 2; // 8x8 root = 2 MI units

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    addOutput('done');
    // assembled 16x16 luma tile, row-major: frame[(r*16 + c)*8 +: 8].
    addOutput('frame', width: tileW * tileW * 8);

    final clk = input('clk');
    final reset = input('reset');

    // single continuous mode walk (driven four times) with tile-width above
    // context (tileMiW = 4 = 2 SBs of 2 MI each).
    final walk = HarborKeyframeModeWalk(
      rootBsize: 3,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      multiSb: true,
      tileMiW: 2 * sbMi,
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

    // four latched leaf-array captures (one per SB), in raster order.
    List<Logic> mkCap(int sb) => [
      Logic(name: 'lc_cap$sb', width: 12),
      Logic(name: 'l2_cap$sb', width: 4 * 3),
      Logic(name: 'ym_cap$sb', width: 4 * 4),
      Logic(name: 'tt_cap$sb', width: 4 * 4),
      Logic(name: 'coeff_cap$sb', width: 4 * 64 * 16),
    ];
    final caps = [for (var sb = 0; sb < 4; sb++) mkCap(sb)];

    // Map a latched leaf-array set (SPLIT-to-4x4 only) into recon-walk inputs.
    // Mirrors the SPLIT branch of HarborKeyframeDecodeVar exactly.
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
      final reconPositions = [
        for (var l = maxLeaves - 1; l >= 0; l--)
          Const(posVal(l >> 1, l & 1), width: 2 * miBits),
      ].concat();
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
    final reconStart = [
      for (var sb = 0; sb < 4; sb++) Logic(name: 'recon${sb}_start'),
    ];

    // Build a tiled recon walk for SB index `sb` at SB-row `sbR` (MI) / SB-col
    // `sbC` (MI), with the external neighbour stitches.
    HarborIntraReconWalk mkRecon(
      int sb,
      int sbR,
      int sbC, {
      required Logic extAbove,
      required Logic extLeft,
      required Logic extCorner,
    }) {
      final r = HarborIntraReconWalk(
        sbSize: sbSize,
        maxLeaves: maxLeaves,
        tiled: true,
        name: 'recon$sb',
      );
      addSubModule(r);
      final m = maps[sb];
      r.input('clk').srcConnection! <= clk;
      r.input('reset').srcConnection! <= reset;
      r.input('start').srcConnection! <= reconStart[sb];
      r.input('leaf_count').srcConnection! <= m.leafCount;
      r.input('positions').srcConnection! <= m.positions;
      r.input('log2sizes').srcConnection! <= m.log2;
      r.input('y_modes').srcConnection! <= m.ymodes;
      r.input('tx_types').srcConnection! <= m.txtypes;
      r.input('coeffs').srcConnection! <= m.coeffs;
      r.input('sb_r').srcConnection! <= Const(sbR, width: miAbsW);
      r.input('sb_c').srcConnection! <= Const(sbC, width: miAbsW);
      r.input('tile_top_mi').srcConnection! <= Const(0, width: miAbsW);
      r.input('tile_left_mi').srcConnection! <= Const(0, width: miAbsW);
      r.input('ext_above').srcConnection! <= extAbove;
      r.input('ext_left').srcConnection! <= extLeft;
      r.input('ext_corner').srcConnection! <= extCorner;
      return r;
    }

    // SB(0,0): tile origin, no external neighbours.
    final recon00 = mkRecon(
      0,
      0,
      0,
      extAbove: Const(0, width: f * 8),
      extLeft: Const(0, width: f * 8),
      extCorner: Const(0, width: 8),
    );
    final frame00 = recon00.output('frame');

    // SB(0,0) reconstructed edges (packed for ext_* inputs of neighbours).
    // bottom row: frame[(7*f + c)] for c = 0..7.
    Logic bottomRow(Logic fr) => [
      for (var c = f - 1; c >= 0; c--)
        fr.getRange((7 * f + c) * 8, (7 * f + c) * 8 + 8),
    ].concat();
    // right column: frame[(r*f + 7)] for r = 0..7.
    Logic rightCol(Logic fr) => [
      for (var rr = f - 1; rr >= 0; rr--)
        fr.getRange((rr * f + (f - 1)) * 8, (rr * f + (f - 1)) * 8 + 8),
    ].concat();
    // bottom-right pixel: frame[(7*f + 7)].
    Logic brPixel(Logic fr) =>
        fr.getRange((7 * f + (f - 1)) * 8, (7 * f + (f - 1)) * 8 + 8);

    final sb00Bottom = bottomRow(frame00);
    final sb00Right = rightCol(frame00);
    final sb00Br = brPixel(frame00);

    // SB(0,1): top-right. left = SB(0,0) right column, tile top so above unused.
    final recon01 = mkRecon(
      1,
      0,
      sbMi,
      extAbove: Const(0, width: f * 8),
      extLeft: sb00Right,
      extCorner: Const(0, width: 8),
    );
    final frame01 = recon01.output('frame');
    final sb01Bottom = bottomRow(frame01);

    // SB(1,0): bottom-left. above = SB(0,0) bottom row, tile left so left unused.
    final recon10 = mkRecon(
      2,
      sbMi,
      0,
      extAbove: sb00Bottom,
      extLeft: Const(0, width: f * 8),
      extCorner: Const(0, width: 8),
    );
    final frame10 = recon10.output('frame');
    final sb10Right = rightCol(frame10);

    // SB(1,1): bottom-right. above = SB(0,1) bottom row, left = SB(1,0) right
    // column, corner = SB(0,0) bottom-right pixel (above-left of SB(1,1) origin).
    final recon11 = mkRecon(
      3,
      sbMi,
      sbMi,
      extAbove: sb01Bottom,
      extLeft: sb10Right,
      extCorner: sb00Br,
    );
    final frame11 = recon11.output('frame');

    // assemble the 16x16 tile frame from the four 8x8 SB frames.
    // tile pixel (R, C): top-left SB if R<8 && C<8, etc. Each SB frame is
    // row-major 8x8: sbFrame[(sr*8 + sc)].
    final tilePix = <Logic>[];
    for (var R = 0; R < tileW; R++) {
      for (var C = 0; C < tileW; C++) {
        final sr = R % f, sc = C % f;
        final Logic src;
        if (R < f && C < f) {
          src = frame00;
        } else if (R < f) {
          src = frame01;
        } else if (C < f) {
          src = frame10;
        } else {
          src = frame11;
        }
        tilePix.add(src.getRange((sr * f + sc) * 8, (sr * f + sc) * 8 + 8));
      }
    }
    // swizzle: tilePix[0] is tile pixel (0,0) -> low byte of frame.
    output('frame') <=
        [for (var i = tilePix.length - 1; i >= 0; i--) tilePix[i]].concat();

    // sequencing FSM. walk SB0..SB3 (latching each), then recon SB0..SB3 in
    // raster (each recon's neighbour inputs are stable before it runs).
    const sIdle = 0,
        sRunMode0 = 1,
        sLatch0 = 2,
        sRunMode1 = 3,
        sLatch1 = 4,
        sRunMode2 = 5,
        sLatch2 = 6,
        sRunMode3 = 7,
        sLatch3 = 8,
        sRunRecon0 = 9,
        sRecon0Wait = 10,
        sRunRecon1 = 11,
        sRecon1Wait = 12,
        sRunRecon2 = 13,
        sRecon2Wait = 14,
        sRunRecon3 = 15,
        sRecon3Wait = 16,
        sDone = 17;
    final st = Logic(name: 'st', width: 5);
    output('done') <= st.eq(Const(sDone, width: 5));

    Combinational([
      walkStart < Const(0),
      walkCont < Const(0),
      walkAboveOpen < Const(0),
      walkContLeft < Const(0),
      walkLeftOpen < Const(0),
      walkSbCol < Const(0, width: walkSbCol.width),
      for (final rs in reconStart) rs < Const(0),
      Case(st, [
        // SB(0,0): fresh start.
        CaseItem(Const(sIdle, width: 5), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        // SB(0,1): cont + cont_left + left_open, sb_c_mi = 2.
        CaseItem(Const(sLatch0, width: 5), [
          walkStart < Const(1),
          walkCont < Const(1),
          walkContLeft < Const(1),
          walkLeftOpen < Const(1),
          walkSbCol < Const(sbMi, width: walkSbCol.width),
        ]),
        // SB(1,0): cont + above_open, cont_left = 0 (tile-left, new SB row),
        // sb_c_mi = 0.
        CaseItem(Const(sLatch1, width: 5), [
          walkStart < Const(1),
          walkCont < Const(1),
          walkAboveOpen < Const(1),
          walkSbCol < Const(0, width: walkSbCol.width),
        ]),
        // SB(1,1): cont + above_open + cont_left + left_open, sb_c_mi = 2.
        CaseItem(Const(sLatch2, width: 5), [
          walkStart < Const(1),
          walkCont < Const(1),
          walkAboveOpen < Const(1),
          walkContLeft < Const(1),
          walkLeftOpen < Const(1),
          walkSbCol < Const(sbMi, width: walkSbCol.width),
        ]),
        CaseItem(Const(sRunRecon0, width: 5), [reconStart[0] < Const(1)]),
        CaseItem(Const(sRunRecon1, width: 5), [reconStart[1] < Const(1)]),
        CaseItem(Const(sRunRecon2, width: 5), [reconStart[2] < Const(1)]),
        CaseItem(Const(sRunRecon3, width: 5), [reconStart[3] < Const(1)]),
      ]),
    ]);

    List<Conditional> latch(List<Logic> cap) => [
      cap[0] < walk.output('leaf_count'),
      cap[1] < walk.output('leaf_log2size'),
      cap[2] < walk.output('leaf_ymodes'),
      cap[3] < walk.output('leaf_txtypes'),
      cap[4] < walk.output('leaf_coeffs'),
    ];

    final recons = [recon00, recon01, recon10, recon11];

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 5),
          for (final cap in caps) ...[
            cap[0] < Const(0, width: 12),
            cap[1] < Const(0, width: 4 * 3),
            cap[2] < Const(0, width: 4 * 4),
            cap[3] < Const(0, width: 4 * 4),
            cap[4] < Const(0, width: 4 * 64 * 16),
          ],
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 5), [
              If(input('start'), then: [st < Const(sRunMode0, width: 5)]),
            ]),
            CaseItem(Const(sRunMode0, width: 5), [
              If(walk.output('done'), then: [st < Const(sLatch0, width: 5)]),
            ]),
            CaseItem(Const(sLatch0, width: 5), [
              ...latch(caps[0]),
              st < Const(sRunMode1, width: 5),
            ]),
            CaseItem(Const(sRunMode1, width: 5), [
              If(walk.output('done'), then: [st < Const(sLatch1, width: 5)]),
            ]),
            CaseItem(Const(sLatch1, width: 5), [
              ...latch(caps[1]),
              st < Const(sRunMode2, width: 5),
            ]),
            CaseItem(Const(sRunMode2, width: 5), [
              If(walk.output('done'), then: [st < Const(sLatch2, width: 5)]),
            ]),
            CaseItem(Const(sLatch2, width: 5), [
              ...latch(caps[2]),
              st < Const(sRunMode3, width: 5),
            ]),
            CaseItem(Const(sRunMode3, width: 5), [
              If(walk.output('done'), then: [st < Const(sLatch3, width: 5)]),
            ]),
            CaseItem(Const(sLatch3, width: 5), [
              ...latch(caps[3]),
              st < Const(sRunRecon0, width: 5),
            ]),
            CaseItem(Const(sRunRecon0, width: 5), [
              st < Const(sRecon0Wait, width: 5),
            ]),
            CaseItem(Const(sRecon0Wait, width: 5), [
              If(
                recons[0].output('done'),
                then: [st < Const(sRunRecon1, width: 5)],
              ),
            ]),
            CaseItem(Const(sRunRecon1, width: 5), [
              st < Const(sRecon1Wait, width: 5),
            ]),
            CaseItem(Const(sRecon1Wait, width: 5), [
              If(
                recons[1].output('done'),
                then: [st < Const(sRunRecon2, width: 5)],
              ),
            ]),
            CaseItem(Const(sRunRecon2, width: 5), [
              st < Const(sRecon2Wait, width: 5),
            ]),
            CaseItem(Const(sRecon2Wait, width: 5), [
              If(
                recons[2].output('done'),
                then: [st < Const(sRunRecon3, width: 5)],
              ),
            ]),
            CaseItem(Const(sRunRecon3, width: 5), [
              st < Const(sRecon3Wait, width: 5),
            ]),
            CaseItem(Const(sRecon3Wait, width: 5), [
              If(recons[3].output('done'), then: [st < Const(sDone, width: 5)]),
            ]),
            CaseItem(Const(sDone, width: 5), [
              If(~input('start'), then: [st < Const(sIdle, width: 5)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

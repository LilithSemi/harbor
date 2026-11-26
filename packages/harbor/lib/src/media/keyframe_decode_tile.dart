import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// General superblock keyframe intra decode: coded bytes -> a
/// ([sbRows]*8) x ([sbCols]*8) luma frame built from an `sbRows x sbCols` raster
/// of 8x8 superblocks, all in one tile on one continuous od_ec window. The
/// (r, c)-loop generalization of [HarborKeyframeDecodeTile2x2], parameterized by
/// build-time [sbRows] and [sbCols] (each >= 1).
///
/// Entropy walk ([HarborKeyframeModeWalk] with `multiSb` + `tileMiW =
/// sbCols*sbMi`): one continuous window driven `sbRows*sbCols` times in raster
/// order (r outer, c inner) with per-position continuation flags:
///  - `cont`      = NOT(r==0 && c==0): only the first SB is fresh, every later
///    SB continues the same window + adapting CDFs.
///  - `above_open`= (r > 0): a decoded SB row exists above (carries `sb_r`).
///  - `cont_left` = (c > 0): preserve left-context stepping right within a row,
///    cleared at c==0 (tile-left, new SB row). `left_open` mirrors it.
///  - `sb_c_mi`   = c*sbMi: absolute MI column, so each top-row SB owns its
///    tile-wide above-context band and bottom-row SBs read their own band.
///
/// Recon (`sbRows*sbCols` [HarborIntraReconWalk] with `tiled`): each SB at its
/// tile-origin MI position (`sb_r = r*sbMi`, `sb_c = c*sbMi`), sequenced in
/// raster order so each SB's neighbour inputs (from already-reconstructed SBs)
/// are stable before it runs. Cross-SB neighbour stitches:
///  - `ext_above`  = (r>0) ? SB(r-1,c) recon bottom row : 0.
///  - `ext_left`   = (c>0) ? SB(r,c-1) recon right column : 0.
///  - `ext_corner` = (r>0 && c>0) ? SB(r-1,c-1) recon bottom-right pixel : 0.
/// Tile-edge availability (haveA false at r==0, haveL false at c==0) is handled
/// by the tiled recon walk itself. The predictor does not model above-right /
/// below-left extension (no such ports, implicitly 0), so no above-right wiring
/// across SBs is needed.
///
/// Scope: each SB is an 8x8 root SPLIT into four 4x4 leaves, mono luma, bd 8.
/// The leaf -> recon mapping is the SPLIT branch of [HarborKeyframeDecodeVar].
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// frame ((sbRows*8)*(sbCols*8)*8, row-major over the assembled tile). Pulse
/// `start`. The module walks all SBs on one continuous window, recons them in
/// raster, then asserts `done`.
///
/// The `sbRows*sbCols` recon instances are unrolled here (fine for small tiles).
/// Time-multiplexing onto RAM line buffers for large frames is a later step.
class HarborKeyframeDecodeTile extends BridgeModule {
  /// Number of 8x8 superblock ROWS in the tile (>= 1).
  final int sbRows;

  /// Number of 8x8 superblock COLUMNS in the tile (>= 1).
  final int sbCols;

  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3) for the mode walk's coeff decode.
  final int qband;

  HarborKeyframeDecodeTile({
    required this.sbRows,
    required this.sbCols,
    this.maxBytes = 64,
    this.qband = 0,
    String? name,
  }) : assert(sbRows >= 1, 'sbRows must be >= 1'),
       assert(sbCols >= 1, 'sbCols must be >= 1'),
       assert(maxBytes > 0, 'maxBytes must be positive'),
       assert(qband >= 0 && qband < 4, 'qband 0..3'),
       super('HarborKeyframeDecodeTile', name: name ?? 'keyframe_decode_tile') {
    const sbSize = 8; // 8x8 superblock
    const maxLeaves = 4; // SPLIT (4 leaves)
    const f = sbSize; // 8 pixels per SB side
    final tileWpx = sbCols * f; // tile width in pixels
    final tileHpx = sbRows * f; // tile height in pixels
    const miBits = 2; // bitLength(sbSize/4) = bitLength(2) = 2
    const cntW = 3; // (maxLeaves + 1).bitLength = 5.bitLength = 3
    const miAbsW = 16; // recon tiled coordinate width
    const sbMi = 2; // 8x8 root = 2 MI units

    final nSb = sbRows * sbCols;
    int sbIdx(int r, int c) => r * sbCols + c;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    addOutput('done');
    // assembled luma tile, row-major: frame[(R*tileWpx + C)*8 +: 8].
    addOutput('frame', width: tileWpx * tileHpx * 8);

    final clk = input('clk');
    final reset = input('reset');

    // single continuous mode walk (driven nSb times) with tile-width above
    // context (tileMiW = sbCols * sbMi).
    final walk = HarborKeyframeModeWalk(
      rootBsize: 3,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
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

    // one latched leaf-array capture per SB, in raster order.
    List<Logic> mkCap(int sb) => [
      Logic(name: 'lc_cap$sb', width: 12),
      Logic(name: 'l2_cap$sb', width: 4 * 3),
      Logic(name: 'ym_cap$sb', width: 4 * 4),
      Logic(name: 'tt_cap$sb', width: 4 * 4),
      Logic(name: 'coeff_cap$sb', width: 4 * 64 * 16),
    ];
    final caps = [for (var sb = 0; sb < nSb; sb++) mkCap(sb)];

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
      for (var sb = 0; sb < nSb; sb++) Logic(name: 'recon${sb}_start'),
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

    // SB recon-edge extractors (over the SB's own 8x8 frame output).
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

    final zeroRow = Const(0, width: f * 8);
    final zeroPix = Const(0, width: 8);

    // Build the recon instances in RASTER order so each SB's neighbour edges
    // are available (already constructed) when it is wired. `frames[sb]` holds
    // each SB's 8x8 frame output.
    final recons = List<HarborIntraReconWalk?>.filled(nSb, null);
    final frames = List<Logic?>.filled(nSb, null);
    for (var r = 0; r < sbRows; r++) {
      for (var c = 0; c < sbCols; c++) {
        final sb = sbIdx(r, c);
        final extAbove = (r > 0)
            ? bottomRow(frames[sbIdx(r - 1, c)]!)
            : zeroRow;
        final extLeft = (c > 0) ? rightCol(frames[sbIdx(r, c - 1)]!) : zeroRow;
        final extCorner = (r > 0 && c > 0)
            ? brPixel(frames[sbIdx(r - 1, c - 1)]!)
            : zeroPix;
        final rec = mkRecon(
          sb,
          r * sbMi,
          c * sbMi,
          extAbove: extAbove,
          extLeft: extLeft,
          extCorner: extCorner,
        );
        recons[sb] = rec;
        frames[sb] = rec.output('frame');
      }
    }

    // assemble the full tile frame from the per-SB 8x8 frames.
    // tile pixel (R, C) maps to SB (R~/f, C~/f) at local (R%f, C%f), which is
    // row-major sbFrame[((R%f)*f + (C%f))].
    final tilePix = <Logic>[];
    for (var R = 0; R < tileHpx; R++) {
      for (var C = 0; C < tileWpx; C++) {
        final sb = sbIdx(R ~/ f, C ~/ f);
        final sr = R % f, sc = C % f;
        tilePix.add(
          frames[sb]!.getRange((sr * f + sc) * 8, (sr * f + sc) * 8 + 8),
        );
      }
    }
    // swizzle: tilePix[0] is tile pixel (0,0) -> low byte of frame.
    output('frame') <=
        [for (var i = tilePix.length - 1; i >= 0; i--) tilePix[i]].concat();

    // sequencing FSM. For each SB in raster: run mode (one window pulse), latch
    // its leaves. Then recon each SB in raster (neighbour edges stable).
    // State layout (per SB): 2 mode states + 2 recon states, plus idle/done.
    //   modeRun(sb)   = 1 + 2*sb
    //   modeLatch(sb) = 2 + 2*sb
    //   reconRun(sb)  = 1 + 2*nSb + 2*sb
    //   reconWait(sb) = 2 + 2*nSb + 2*sb
    //   done          = 1 + 4*nSb
    final sIdle = 0;
    int sModeRun(int sb) => 1 + 2 * sb;
    int sModeLatch(int sb) => 2 + 2 * sb;
    int sReconRun(int sb) => 1 + 2 * nSb + 2 * sb;
    int sReconWait(int sb) => 2 + 2 * nSb + 2 * sb;
    final sDone = 1 + 4 * nSb;
    final stW = (sDone + 1).bitLength;

    final st = Logic(name: 'st', width: stW);
    output('done') <= st.eq(Const(sDone, width: stW));

    // Per-SB raster (r, c) for flag derivation.
    int sbRow(int sb) => sb ~/ sbCols;
    int sbCol(int sb) => sb % sbCols;

    // Combinational mode-walk drive + recon-start pulses by state.
    Combinational([
      walkStart < Const(0),
      walkCont < Const(0),
      walkAboveOpen < Const(0),
      walkContLeft < Const(0),
      walkLeftOpen < Const(0),
      walkSbCol < Const(0, width: walkSbCol.width),
      for (final rs in reconStart) rs < Const(0),
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
        // recon run states pulse the matching recon start.
        for (var sb = 0; sb < nSb; sb++)
          CaseItem(Const(sReconRun(sb), width: stW), [
            reconStart[sb] < Const(1),
          ]),
      ]),
    ]);

    List<Conditional> latch(List<Logic> cap) => [
      cap[0] < walk.output('leaf_count'),
      cap[1] < walk.output('leaf_log2size'),
      cap[2] < walk.output('leaf_ymodes'),
      cap[3] < walk.output('leaf_txtypes'),
      cap[4] < walk.output('leaf_coeffs'),
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
            // recon run/wait chain over all SBs in raster.
            for (var sb = 0; sb < nSb; sb++) ...[
              CaseItem(Const(sReconRun(sb), width: stW), [
                st < Const(sReconWait(sb), width: stW),
              ]),
              CaseItem(Const(sReconWait(sb), width: stW), [
                If(
                  recons[sb]!.output('done'),
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

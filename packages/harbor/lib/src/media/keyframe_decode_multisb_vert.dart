import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// Multi-superblock VERTICAL keyframe intra decode: coded bytes -> two 8x8 luma
/// superblocks stacked vertically (SB0 at sb_row 0, SB1 directly below, both in
/// tile column 0), where SB1's intra above row is SB0's reconstructed bottom
/// row.
///
/// The vertical counterpart of [HarborKeyframeDecodeMultiSbHoriz]:
///  - [HarborKeyframeModeWalk] with `multiSb` (continuous entropy walk): SB0 is
///    a fresh `start` (cont = 0, above_open = 0). SB1 continues the same window
///    (cont = 1, adapted CDFs + propagated above-context) with a decoded SB-row
///    above it (above_open = 1).
///  - [HarborIntraReconWalk] with `tiled` (tile-relative availability + external
///    neighbour inputs). SB0 recons at the tile-origin SB (sb_r = 0), SB1 at
///    sb_r = 2 (2 mi units below) with `ext_above` = SB0's reconstructed bottom
///    row (frame0 row 7). At tile column 0 both SBs are tile-left (haveL false),
///    so the left/corner inputs are unused and driven 0.
///
/// Scope: each SB is an 8x8 root SPLIT into four 4x4 leaves, mono luma, bd 8.
/// The leaf -> recon mapping is the SPLIT branch of [HarborKeyframeDecodeVar]
/// (leaf l at mi (l>>1, l&1), 4x4, 16 coeffs in the low 16 of a 256-coeff slot).
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// frame0 (512), frame1 (512). Pulse `start`. The module walks SB0 then SB1 on
/// one continuous window, recons SB0, then SB1 (above = SB0 bottom row), then
/// asserts `done`.
class HarborKeyframeDecodeMultiSbVert extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3) for the mode walk's coeff decode.
  final int qband;

  HarborKeyframeDecodeMultiSbVert({
    this.maxBytes = 48,
    this.qband = 0,
    String? name,
  }) : assert(maxBytes > 0, 'maxBytes must be positive'),
       assert(qband >= 0 && qband < 4, 'qband 0..3'),
       super(
         'HarborKeyframeDecodeMultiSbVert',
         name: name ?? 'keyframe_decode_multisb_vert',
       ) {
    const sbSize = 8; // 8x8 superblock
    const maxLeaves = 4; // SPLIT (4 leaves)
    const f = sbSize; // 8 pixels
    const nPix = f * f; // 64
    const miBits = 2; // bitLength(sbSize/4) = bitLength(2) = 2
    const cntW = 3; // (maxLeaves + 1).bitLength = 5.bitLength = 3
    const miAbsW = 16; // recon tiled coordinate width

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    addOutput('done');
    addOutput('frame0', width: nPix * 8);
    addOutput('frame1', width: nPix * 8);

    final clk = input('clk');
    final reset = input('reset');

    // single continuous mode walk (driven twice)
    final walk = HarborKeyframeModeWalk(
      rootBsize: 3,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      multiSb: true,
      qband: qband,
      name: 'walk',
    );
    addSubModule(walk);

    final walkStart = Logic(name: 'walk_start');
    final walkCont = Logic(name: 'walk_cont');
    final walkAboveOpen = Logic(name: 'walk_above_open');

    walk.input('clk').srcConnection! <= clk;
    walk.input('reset').srcConnection! <= reset;
    walk.input('start').srcConnection! <= walkStart;
    walk.input('cont').srcConnection! <= walkCont;
    walk.input('above_open').srcConnection! <= walkAboveOpen;
    // VERTICAL pair: the horizontal-continuation ports are inert (each SB column
    // starts with a fresh, cleared left context and no left-open edge).
    walk.input('cont_left').srcConnection! <= Const(0);
    walk.input('left_open').srcConnection! <= Const(0);
    walk.input('bytes').srcConnection! <= input('bytes');
    walk.input('dc_q').srcConnection! <= input('dc_q');
    walk.input('ac_q').srcConnection! <= input('ac_q');

    // two latched leaf-arrays (one per SB), latched the cycle the walk holds
    // done.
    List<Logic> mkCap() => [
      Logic(name: 'lc_cap', width: 12),
      Logic(name: 'l2_cap', width: 4 * 3),
      Logic(name: 'ym_cap', width: 4 * 4),
      Logic(name: 'tt_cap', width: 4 * 4),
      Logic(name: 'coeff_cap', width: 4 * 64 * 16),
    ];
    final cap0 = mkCap();
    final cap1 = mkCap();

    // Map a latched leaf-array set (SPLIT-to-4x4 only) into recon-walk inputs.
    // This mirrors the SPLIT branch of HarborKeyframeDecodeVar exactly.
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
      // log2sizes: per leaf recon_log2 = walk_log2 - 2. swizzle index 0 = MSB.
      final reconLog2 = [
        for (var l = maxLeaves - 1; l >= 0; l--)
          (l2Cap.getRange(l * 3, l * 3 + 3) - Const(2, width: 3)).getRange(
            0,
            2,
          ),
      ].concat();
      final reconYModes = ymCap;
      final reconTxTypes = ttCap;
      // coeffs: each leaf's low-16 coeffs into the low 16 of a 256-coeff slot.
      final reconCoeffs = [
        for (var l = maxLeaves - 1; l >= 0; l--) ...[
          Const(0, width: 192 * 16),
          coeffCap.getRange(l * 64 * 16, l * 64 * 16 + 64 * 16),
        ],
      ].concat();
      // positions: SPLIT layout, leaf l at mi (l>>1, l&1). slot [l*4 +: 4],
      // miRow low miBits, miCol high miBits.
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

    final m0 = mapRecon(cap0);
    final m1 = mapRecon(cap1);

    final recon0Start = Logic(name: 'recon0_start');
    final recon1Start = Logic(name: 'recon1_start');

    // recon SB0 (tile-origin SB, ext_* unused at the tile top/left edge)
    final recon0 = HarborIntraReconWalk(
      sbSize: sbSize,
      maxLeaves: maxLeaves,
      tiled: true,
      name: 'recon0',
    );
    addSubModule(recon0);
    recon0.input('clk').srcConnection! <= clk;
    recon0.input('reset').srcConnection! <= reset;
    recon0.input('start').srcConnection! <= recon0Start;
    recon0.input('leaf_count').srcConnection! <= m0.leafCount;
    recon0.input('positions').srcConnection! <= m0.positions;
    recon0.input('log2sizes').srcConnection! <= m0.log2;
    recon0.input('y_modes').srcConnection! <= m0.ymodes;
    recon0.input('tx_types').srcConnection! <= m0.txtypes;
    recon0.input('coeffs').srcConnection! <= m0.coeffs;
    // tile-origin SB: sb_r = sb_c = tile_top = tile_left = 0, no externals.
    recon0.input('sb_r').srcConnection! <= Const(0, width: miAbsW);
    recon0.input('sb_c').srcConnection! <= Const(0, width: miAbsW);
    recon0.input('tile_top_mi').srcConnection! <= Const(0, width: miAbsW);
    recon0.input('tile_left_mi').srcConnection! <= Const(0, width: miAbsW);
    recon0.input('ext_above').srcConnection! <= Const(0, width: f * 8);
    recon0.input('ext_left').srcConnection! <= Const(0, width: f * 8);
    recon0.input('ext_corner').srcConnection! <= Const(0, width: 8);

    output('frame0') <= recon0.output('frame');

    // SB0's reconstructed BOTTOM row (frame row 7), the 8 pixels, packed as the
    // ext_above input for SB1: ext_above[i*8 +: 8] = frame0 pixel (row 7, col i).
    final frame0 = recon0.output('frame');
    final sb0Bottom = [
      for (var c = f - 1; c >= 0; c--)
        frame0.getRange((7 * f + c) * 8, (7 * f + c) * 8 + 8),
    ].concat();

    // recon SB1 (sb_r = 2 mi units below, above = SB0 bottom row)
    final recon1 = HarborIntraReconWalk(
      sbSize: sbSize,
      maxLeaves: maxLeaves,
      tiled: true,
      name: 'recon1',
    );
    addSubModule(recon1);
    recon1.input('clk').srcConnection! <= clk;
    recon1.input('reset').srcConnection! <= reset;
    recon1.input('start').srcConnection! <= recon1Start;
    recon1.input('leaf_count').srcConnection! <= m1.leafCount;
    recon1.input('positions').srcConnection! <= m1.positions;
    recon1.input('log2sizes').srcConnection! <= m1.log2;
    recon1.input('y_modes').srcConnection! <= m1.ymodes;
    recon1.input('tx_types').srcConnection! <= m1.txtypes;
    recon1.input('coeffs').srcConnection! <= m1.coeffs;
    // SB1 sits one 8x8 (2 mi units) below the tile top, same tile column 0.
    recon1.input('sb_r').srcConnection! <= Const(2, width: miAbsW);
    recon1.input('sb_c').srcConnection! <= Const(0, width: miAbsW);
    recon1.input('tile_top_mi').srcConnection! <= Const(0, width: miAbsW);
    recon1.input('tile_left_mi').srcConnection! <= Const(0, width: miAbsW);
    // ABOVE row = SB0's reconstructed bottom row. At tile column 0 the left edge
    // is the tile-left boundary (haveL = false), so ext_left / ext_corner are
    // not consulted by any predictor and are driven 0 (the corner for a top-row
    // px>0 leaf comes from ext_above[px-1], handled inside the recon walk).
    recon1.input('ext_above').srcConnection! <= sb0Bottom;
    recon1.input('ext_left').srcConnection! <= Const(0, width: f * 8);
    recon1.input('ext_corner').srcConnection! <= Const(0, width: 8);

    output('frame1') <= recon1.output('frame');

    // sequencing FSM: walk SB0 -> latch -> walk SB1 (cont) -> latch -> recon
    // SB0 -> wait -> recon SB1 (needs frame0) -> wait -> done.
    const sIdle = 0,
        sRunMode0 = 1,
        sLatch0 = 2,
        sRunMode1 = 3,
        sLatch1 = 4,
        sRunRecon0 = 5,
        sRecon0Wait = 6,
        sRunRecon1 = 7,
        sRecon1Wait = 8,
        sDone = 9;
    final st = Logic(name: 'st', width: 4);
    output('done') <= st.eq(Const(sDone, width: 4));

    Combinational([
      walkStart < Const(0),
      walkCont < Const(0),
      walkAboveOpen < Const(0),
      recon0Start < Const(0),
      recon1Start < Const(0),
      Case(st, [
        // SB0: fresh start (cont = 0, above_open = 0).
        CaseItem(Const(sIdle, width: 4), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        // SB1: continue the window (cont = 1) with a row above (above_open = 1).
        CaseItem(Const(sLatch0, width: 4), [
          walkStart < Const(1),
          walkCont < Const(1),
          walkAboveOpen < Const(1),
        ]),
        CaseItem(Const(sRunRecon0, width: 4), [recon0Start < Const(1)]),
        CaseItem(Const(sRunRecon1, width: 4), [recon1Start < Const(1)]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 4),
          for (final cap in [cap0, cap1]) ...[
            cap[0] < Const(0, width: 12),
            cap[1] < Const(0, width: 4 * 3),
            cap[2] < Const(0, width: 4 * 4),
            cap[3] < Const(0, width: 4 * 4),
            cap[4] < Const(0, width: 4 * 64 * 16),
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
            // SB0's walk holds done with stable outputs, latch + pulse SB1 start.
            CaseItem(Const(sLatch0, width: 4), [
              ...latchConds(cap0, walk),
              st < Const(sRunMode1, width: 4),
            ]),
            CaseItem(Const(sRunMode1, width: 4), [
              If(walk.output('done'), then: [st < Const(sLatch1, width: 4)]),
            ]),
            CaseItem(Const(sLatch1, width: 4), [
              ...latchConds(cap1, walk),
              st < Const(sRunRecon0, width: 4),
            ]),
            CaseItem(Const(sRunRecon0, width: 4), [
              st < Const(sRecon0Wait, width: 4),
            ]),
            CaseItem(Const(sRecon0Wait, width: 4), [
              If(
                recon0.output('done'),
                then: [st < Const(sRunRecon1, width: 4)],
              ),
            ]),
            CaseItem(Const(sRunRecon1, width: 4), [
              st < Const(sRecon1Wait, width: 4),
            ]),
            CaseItem(Const(sRecon1Wait, width: 4), [
              If(recon1.output('done'), then: [st < Const(sDone, width: 4)]),
            ]),
            CaseItem(Const(sDone, width: 4), [
              If(~input('start'), then: [st < Const(sIdle, width: 4)]),
            ]),
          ]),
        ],
      ),
    ]);
  }

  /// Latch the walk's leaf-array outputs into `cap` (returned as conditionals so
  /// they compose inside the FSM's [Case]).
  static List<Conditional> latchConds(
    List<Logic> cap,
    HarborKeyframeModeWalk walk,
  ) => [
    cap[0] < walk.output('leaf_count'),
    cap[1] < walk.output('leaf_log2size'),
    cap[2] < walk.output('leaf_ymodes'),
    cap[3] < walk.output('leaf_txtypes'),
    cap[4] < walk.output('leaf_coeffs'),
  ];
}

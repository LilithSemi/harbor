import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk_seq.dart';
import 'keyframe_mode_walk.dart';

/// Harbor 2-SB HORIZONTAL keyframe intra decode with LARGER (16x16) superblocks
/// via the SEQUENTIAL recon walk: two 16x16 superblocks side by side (SB0 at
/// sb_col 0 / tile origin, SB1 directly to its RIGHT), each a single
/// PARTITION_NONE TX_16X16 leaf, on ONE continuous od_ec window. SB1's intra
/// LEFT column is SB0's reconstructed RIGHT column.
///
/// This is the multi-SB analog of [HarborKeyframeDecodeMultiSbHoriz] but with
/// 16x16 SBs (rootBsize 6) and [HarborIntraReconWalkSeq] (the build-scalable
/// recon that handles SBs larger than 8x8). It proves the mode walk's multiSb
/// continuation works past its 8x8-root pinning AND that the tiled sequential
/// recon threads cross-SB neighbours for real-sized SBs.
///
/// The mode walk (rootBsize 6, multiSb, tx16, maxLeafOut 1) decodes SB0 (fresh
/// start) then SB1 (cont + cont_left + left_open) on one window. Each SB's leaf
/// is reconstructed by a tiled [HarborIntraReconWalkSeq] (sbSize 16). SB1's
/// ext_left = SB0's right column.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q/ac_q (16) -> done,
/// frame0 (16*16*8), frame1 (16*16*8). Scope: two 16x16 NONE TX_16X16 leaves,
/// monochrome luma.
class HarborKeyframeDecode2Sb16Seq extends BridgeModule {
  final int maxBytes;

  HarborKeyframeDecode2Sb16Seq({this.maxBytes = 512, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      super(
        'HarborKeyframeDecode2Sb16Seq',
        name: name ?? 'keyframe_decode_2sb16_seq',
      ) {
    const sbSize = 16, f = 16, nPix = f * f;
    const miAbsW = 16, leafCoeffN = 256; // TX_16X16

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

    // One continuous mode walk (rootBsize 6, multiSb, tx16, single leaf/SB).
    final walk = HarborKeyframeModeWalk(
      rootBsize: 6,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      maxTxN: 256,
      maxLeafOut: 1,
      multiSb: true,
      qband: 0,
      name: 'walk',
    );
    addSubModule(walk);

    final walkStart = Logic(name: 'walk_start');
    final walkCont = Logic(name: 'walk_cont');
    final walkAboveOpen = Logic(name: 'walk_above_open');
    final walkContLeft = Logic(name: 'walk_cont_left');
    final walkLeftOpen = Logic(name: 'walk_left_open');
    walk.input('clk').srcConnection! <= clk;
    walk.input('reset').srcConnection! <= reset;
    walk.input('start').srcConnection! <= walkStart;
    walk.input('cont').srcConnection! <= walkCont;
    walk.input('above_open').srcConnection! <= walkAboveOpen;
    walk.input('cont_left').srcConnection! <= walkContLeft;
    walk.input('left_open').srcConnection! <= walkLeftOpen;
    walk.input('bytes').srcConnection! <= input('bytes');
    walk.input('dc_q').srcConnection! <= input('dc_q');
    walk.input('ac_q').srcConnection! <= input('ac_q');

    // Per-SB latched leaf (one 16x16 leaf).
    List<Logic> mkCap() => [
      Logic(name: 'ym_cap', width: 4),
      Logic(name: 'tt_cap', width: 4),
      Logic(name: 'coeff_cap', width: leafCoeffN * 16),
    ];
    final cap0 = mkCap();
    final cap1 = mkCap();

    List<Conditional> latch(List<Logic> cap) => [
      cap[0] < walk.output('leaf_ymodes').getRange(0, 4),
      cap[1] < walk.output('leaf_txtypes').getRange(0, 4),
      cap[2] < walk.output('leaf_coeffs').getRange(0, leafCoeffN * 16),
    ];

    final recon0Start = Logic(name: 'recon0_start');
    final recon1Start = Logic(name: 'recon1_start');

    HarborIntraReconWalkSeq mkRecon(
      List<Logic> cap,
      Logic startSig,
      int sbC,
      Logic extLeft,
      String nm,
    ) {
      final recon = HarborIntraReconWalkSeq(
        sbSize: sbSize,
        maxLeaves: 1,
        maxLog2: 2,
        tiled: true,
        name: nm,
      );
      addSubModule(recon);
      recon.input('clk').srcConnection! <= clk;
      recon.input('reset').srcConnection! <= reset;
      recon.input('start').srcConnection! <= startSig;
      recon.input('leaf_count').srcConnection! <=
          Const(1, width: recon.input('leaf_count').width);
      recon.input('positions').srcConnection! <=
          Const(0, width: recon.input('positions').width); // MI (0,0)
      recon.input('log2sizes').srcConnection! <= Const(2, width: 2); // 16x16
      recon.input('y_modes').srcConnection! <= cap[0];
      recon.input('tx_types').srcConnection! <= cap[1];
      recon.input('coeffs').srcConnection! <= cap[2];
      recon.input('sb_r').srcConnection! <= Const(0, width: miAbsW);
      recon.input('sb_c').srcConnection! <= Const(sbC, width: miAbsW);
      recon.input('tile_top_mi').srcConnection! <= Const(0, width: miAbsW);
      recon.input('tile_left_mi').srcConnection! <= Const(0, width: miAbsW);
      recon.input('ext_above').srcConnection! <= Const(0, width: f * 8);
      recon.input('ext_left').srcConnection! <= extLeft;
      recon.input('ext_corner').srcConnection! <= Const(0, width: 8);
      return recon;
    }

    final recon0 = mkRecon(
      cap0,
      recon0Start,
      0,
      Const(0, width: f * 8),
      'recon0',
    );
    output('frame0') <= recon0.output('frame');
    final frame0 = recon0.output('frame');
    // SB0's reconstructed right column (col f-1), packed as ext_left for SB1.
    final sb0Right = [
      for (var rr = f - 1; rr >= 0; rr--)
        frame0.getRange((rr * f + (f - 1)) * 8, (rr * f + (f - 1)) * 8 + 8),
    ].concat();

    // SB1 sits 4 MI (one 16x16) right of the tile left.
    final recon1 = mkRecon(cap1, recon1Start, 4, sb0Right, 'recon1');
    output('frame1') <= recon1.output('frame');

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
      walkContLeft < Const(0),
      walkLeftOpen < Const(0),
      recon0Start < Const(0),
      recon1Start < Const(0),
      Case(st, [
        CaseItem(Const(sIdle, width: 4), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        CaseItem(Const(sLatch0, width: 4), [
          walkStart < Const(1),
          walkCont < Const(1),
          walkContLeft < Const(1),
          walkLeftOpen < Const(1),
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
            cap[0] < Const(0, width: 4),
            cap[1] < Const(0, width: 4),
            cap[2] < Const(0, width: leafCoeffN * 16),
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
              ...latch(cap0),
              st < Const(sRunMode1, width: 4),
            ]),
            CaseItem(Const(sRunMode1, width: 4), [
              If(walk.output('done'), then: [st < Const(sLatch1, width: 4)]),
            ]),
            CaseItem(Const(sLatch1, width: 4), [
              ...latch(cap1),
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
}

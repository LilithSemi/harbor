import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_recon_walk_seq.dart';
import 'keyframe_mode_walk.dart';

/// General sbRows x sbCols multi-superblock keyframe intra decode with 16x16 SBs
/// via the sequential recon walk: a raster of `sbRows*sbCols` 16x16 superblocks
/// (each a single PARTITION_NONE TX_16X16 leaf) decoded on one continuous od_ec
/// window with tile-width above context, reconstructed into a full
/// ([sbRows]*16)x([sbCols]*16) luma frame. The raster generalization of the 2-SB
/// horizontal / vertical seq pairs to an arbitrary grid, on the build-scalable
/// [HarborIntraReconWalkSeq].
///
/// The 16x16 analogue of [HarborKeyframeDecodeTile]: rootBsize 6, maxTxN 256
/// (TX_16X16 inline coeff), maxLeafOut 1 (one leaf per SB), tiled sequential
/// recon. The mode walk (multiSb, tileMiW = sbCols*sbMi) is driven `nSb` times
/// in raster order with per-SB cont/above_open/cont_left/left_open/sb_c_mi
/// flags. Each SB's seq recon draws ext_above from SB(r-1,c)'s bottom row,
/// ext_left from SB(r,c-1)'s right column, ext_corner from SB(r-1,c-1)'s
/// bottom-right.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q/ac_q (16) -> done, frame
/// (tileW*tileH*8, row-major). Scope: 16x16 NONE TX_16X16 leaves, mono luma.
class HarborKeyframeDecodeTile16Seq extends BridgeModule {
  final int sbRows;
  final int sbCols;
  final int maxBytes;

  HarborKeyframeDecodeTile16Seq({
    required this.sbRows,
    required this.sbCols,
    this.maxBytes = 1024,
    String? name,
  }) : assert(sbRows >= 1 && sbCols >= 1, 'sbRows/sbCols >= 1'),
       assert(maxBytes > 0, 'maxBytes must be positive'),
       super(
         'HarborKeyframeDecodeTile16Seq',
         name: name ?? 'keyframe_decode_tile16_seq',
       ) {
    const sbSize = 16, f = 16, sbMi = 4, miAbsW = 16, leafCoeffN = 256;
    final tileWpx = sbCols * f, tileHpx = sbRows * f;
    final nSb = sbRows * sbCols;
    int sbIdx(int r, int c) => r * sbCols + c;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    addOutput('done');
    addOutput('frame', width: tileWpx * tileHpx * 8);

    final clk = input('clk');
    final reset = input('reset');

    final walk = HarborKeyframeModeWalk(
      rootBsize: 6,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      maxTxN: 256,
      maxLeafOut: 1,
      multiSb: true,
      tileMiW: sbCols * sbMi,
      qband: 0,
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

    // one latched (ym, tx_type, coeffs) per SB, in raster order.
    List<Logic> mkCap(int sb) => [
      Logic(name: 'ym$sb', width: 4),
      Logic(name: 'tt$sb', width: 4),
      Logic(name: 'co$sb', width: leafCoeffN * 16),
    ];
    final caps = [for (var sb = 0; sb < nSb; sb++) mkCap(sb)];

    final reconStart = [
      for (var sb = 0; sb < nSb; sb++) Logic(name: 'recon${sb}_start'),
    ];

    HarborIntraReconWalkSeq mkRecon(
      int sb,
      int sbR,
      int sbC, {
      required Logic extAbove,
      required Logic extLeft,
      required Logic extCorner,
    }) {
      final r = HarborIntraReconWalkSeq(
        sbSize: sbSize,
        maxLeaves: 1,
        maxLog2: 2,
        tiled: true,
        name: 'recon$sb',
      );
      addSubModule(r);
      final cap = caps[sb];
      r.input('clk').srcConnection! <= clk;
      r.input('reset').srcConnection! <= reset;
      r.input('start').srcConnection! <= reconStart[sb];
      r.input('leaf_count').srcConnection! <=
          Const(1, width: r.input('leaf_count').width);
      r.input('positions').srcConnection! <=
          Const(0, width: r.input('positions').width);
      r.input('log2sizes').srcConnection! <= Const(2, width: 2);
      r.input('y_modes').srcConnection! <= cap[0];
      r.input('tx_types').srcConnection! <= cap[1];
      r.input('coeffs').srcConnection! <= cap[2];
      r.input('sb_r').srcConnection! <= Const(sbR, width: miAbsW);
      r.input('sb_c').srcConnection! <= Const(sbC, width: miAbsW);
      r.input('tile_top_mi').srcConnection! <= Const(0, width: miAbsW);
      r.input('tile_left_mi').srcConnection! <= Const(0, width: miAbsW);
      r.input('ext_above').srcConnection! <= extAbove;
      r.input('ext_left').srcConnection! <= extLeft;
      r.input('ext_corner').srcConnection! <= extCorner;
      return r;
    }

    Logic bottomRow(Logic fr) => [
      for (var c = f - 1; c >= 0; c--)
        fr.getRange(((f - 1) * f + c) * 8, ((f - 1) * f + c) * 8 + 8),
    ].concat();
    Logic rightCol(Logic fr) => [
      for (var rr = f - 1; rr >= 0; rr--)
        fr.getRange((rr * f + (f - 1)) * 8, (rr * f + (f - 1)) * 8 + 8),
    ].concat();
    Logic brPixel(Logic fr) => fr.getRange(
      ((f - 1) * f + (f - 1)) * 8,
      ((f - 1) * f + (f - 1)) * 8 + 8,
    );

    final zeroRow = Const(0, width: f * 8);
    final zeroPix = Const(0, width: 8);

    final recons = List<HarborIntraReconWalkSeq?>.filled(nSb, null);
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

    // assemble the tile frame from per-SB 16x16 frames.
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
    output('frame') <=
        [for (var i = tilePix.length - 1; i >= 0; i--) tilePix[i]].concat();

    // sequencing FSM (mirrors HarborKeyframeDecodeTile).
    final sIdle = 0;
    int sModeRun(int sb) => 1 + 2 * sb;
    int sModeLatch(int sb) => 2 + 2 * sb;
    int sReconRun(int sb) => 1 + 2 * nSb + 2 * sb;
    int sReconWait(int sb) => 2 + 2 * nSb + 2 * sb;
    final sDone = 1 + 4 * nSb;
    final stW = (sDone + 1).bitLength;
    final st = Logic(name: 'st', width: stW);
    output('done') <= st.eq(Const(sDone, width: stW));

    int sbRow(int sb) => sb ~/ sbCols;
    int sbCol(int sb) => sb % sbCols;

    Combinational([
      walkStart < Const(0),
      walkCont < Const(0),
      walkAboveOpen < Const(0),
      walkContLeft < Const(0),
      walkLeftOpen < Const(0),
      walkSbCol < Const(0, width: walkSbCol.width),
      for (final rs in reconStart) rs < Const(0),
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
          CaseItem(Const(sReconRun(sb), width: stW), [
            reconStart[sb] < Const(1),
          ]),
      ]),
    ]);

    List<Conditional> latch(List<Logic> cap) => [
      cap[0] < walk.output('leaf_ymodes').getRange(0, 4),
      cap[1] < walk.output('leaf_txtypes').getRange(0, 4),
      cap[2] < walk.output('leaf_coeffs').getRange(0, leafCoeffN * 16),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: stW),
          for (final cap in caps) ...[
            cap[0] < Const(0, width: 4),
            cap[1] < Const(0, width: 4),
            cap[2] < Const(0, width: leafCoeffN * 16),
          ],
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
                      sb + 1 < nSb ? sModeRun(sb + 1) : sReconRun(0),
                      width: stW,
                    ),
              ]),
            ],
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

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'chroma_recon_block.dart';
import 'intra_recon_walk_seq.dart';
import 'keyframe_mode_walk.dart';

/// End-to-end keyframe intra decode for one NONE-partition 16x16 superblock in
/// 4:2:0: coded bytes to reconstructed 16x16 luma + 8x8 U + 8x8 V pixels. The
/// 16x16 analogue of [HarborKeyframeDecodeYuv]: the luma leaf is TX_16X16 and
/// each 4:2:0 chroma plane is an 8x8 block, one TX_8X8.
///
/// On `start`, runs [HarborKeyframeModeWalk] (rootBsize 6, maxTxN 256,
/// coeffPrefix, txLeaf, chroma) over `bytes`. When the walk asserts done the
/// per-leaf luma and chroma outputs are latched. The 16x16 luma plane is
/// reconstructed via [HarborIntraReconWalkSeq] (sbSize 16, one NONE leaf). The
/// reconstructed luma is subsampled (4:2:0) into the CfL luma-AC source, and
/// [HarborChromaReconBlock] (bs 8) runs for U then V with the derived chroma
/// intra mode / CfL / tx_type. `done` asserts with the three reconstructed planes.
///
/// Chroma derivations (const muxes on the latched `leaf_uv_mode`):
///  - chroma intra mode `uvIntra = _uv2y[uv_mode]` (identity 0..12, 13 -> DC).
///  - `use_cfl = (uv_mode == 13)`.
///  - chroma tx_type: `_intraModeToTxType` then cap by `av1ExtTxUsed[setType]`.
///    For TX_8X8 intra (reducedTxSet=false) setType == kExtTxSetDtt4Idtx1dDct = 3
///    (same as TX_4X4), whose row caps txTypes {0,1,2,3} to themselves.
///  - CfL luma-AC subsample (4:2:0): chroma pixel (i=col, j=row) takes the 2x2
///    collocated luma summed and `<<1`. cN = 64 chroma pixels over the 16x16
///    luma, kept full width (cflAcBits per pixel).
///  - isolated single 16x16 SB, so the 8x8 chroma block is at the plane top-left
///    (have_above = 0, have_left = 0).
///  - skip / eob_zero driven 0 (zero coeffs transform to a zero add).
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// luma (2048), u (512), v (512).
class HarborKeyframeDecodeYuv16 extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3) for the mode walk's coeff decode.
  final int qband;

  // uv2y[]: UV mode -> luma intra mode (identity, CFL->DC).
  static const _uv2y = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0];
  // intra_mode_to_tx_type, 13 entries.
  static const _intraModeToTxType = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3];
  // av1ExtTxUsed[kExtTxSetDtt4Idtx1dDct=3], the TX_4X4/TX_8X8 intra ext-tx cap.
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

  HarborKeyframeDecodeYuv16({this.maxBytes = 320, this.qband = 0, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      assert(qband >= 0 && qband < 4, 'qband 0..3'),
      super(
        'HarborKeyframeDecodeYuv16',
        name: name ?? 'keyframe_decode_yuv16',
      ) {
    const sbSize = 16; // 16x16 superblock luma
    const f = sbSize; // 16 luma pixels per side
    const nPix = f * f; // 256 luma
    const cBs = 8; // chroma block side (4:2:0 of 16x16)
    const cN = cBs * cBs; // 64 chroma pixels
    const leafCoeffN = 256; // TX_16X16 luma leaf coeffs
    const cflAcBits = 12; // (a+b+c+d)<<1 over 2x2 luma <= 2040 -> 11b, +margin

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    addOutput('done');
    addOutput('luma', width: nPix * 8);
    addOutput('u', width: cN * 8);
    addOutput('v', width: cN * 8);

    final clk = input('clk');
    final reset = input('reset');

    final walk = HarborKeyframeModeWalk(
      rootBsize: 6,
      maxTxN: 256,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      chroma: true,
      qband: qband,
      maxLeafOut: 1,
      name: 'walk',
    );
    addSubModule(walk);
    final recon = HarborIntraReconWalkSeq(
      sbSize: sbSize,
      maxLeaves: 1,
      maxLog2: 2,
      tiled: true,
      name: 'recon',
    );
    addSubModule(recon);
    final chromaU = HarborChromaReconBlock(
      bs: cBs,
      cflAcBits: cflAcBits,
      name: 'chroma_u',
    );
    addSubModule(chromaU);
    final chromaV = HarborChromaReconBlock(
      bs: cBs,
      cflAcBits: cflAcBits,
      name: 'chroma_v',
    );
    addSubModule(chromaV);

    final walkStart = Logic(name: 'walk_start');
    final reconStart = Logic(name: 'recon_start');
    final chromaStart = Logic(name: 'chroma_start');

    walk.input('clk').srcConnection! <= clk;
    walk.input('reset').srcConnection! <= reset;
    walk.input('start').srcConnection! <= walkStart;
    walk.input('bytes').srcConnection! <= input('bytes');
    walk.input('dc_q').srcConnection! <= input('dc_q');
    walk.input('ac_q').srcConnection! <= input('ac_q');

    // latched walk outputs
    final ymCap = Logic(name: 'leaf_ymode_cap', width: 4);
    final ttCap = Logic(name: 'leaf_luma_txtype_cap', width: 4);
    final coeffCap = Logic(name: 'leaf_coeffs_cap', width: leafCoeffN * 16);
    final uvModeCap = Logic(name: 'leaf_uv_mode_cap', width: 4);
    final cflIdxCap = Logic(name: 'leaf_cfl_alpha_idx_cap', width: 8);
    final cflSignsCap = Logic(name: 'leaf_cfl_signs_cap', width: 3);
    final uCoeffCap = Logic(name: 'leaf_u_coeffs_cap', width: cN * 16);
    final vCoeffCap = Logic(name: 'leaf_v_coeffs_cap', width: cN * 16);

    // luma recon: single NONE 16x16 leaf via the sequential walk.
    final miAbsW = recon.input('sb_c').width;
    recon.input('clk').srcConnection! <= clk;
    recon.input('reset').srcConnection! <= reset;
    recon.input('start').srcConnection! <= reconStart;
    recon.input('leaf_count').srcConnection! <=
        Const(1, width: recon.input('leaf_count').width);
    recon.input('positions').srcConnection! <=
        Const(0, width: recon.input('positions').width); // MI (0,0)
    recon.input('log2sizes').srcConnection! <= Const(2, width: 2); // 16x16
    recon.input('y_modes').srcConnection! <= ymCap;
    recon.input('tx_types').srcConnection! <= ttCap;
    recon.input('coeffs').srcConnection! <= coeffCap;
    recon.input('sb_r').srcConnection! <= Const(0, width: miAbsW);
    recon.input('sb_c').srcConnection! <= Const(0, width: miAbsW);
    recon.input('tile_top_mi').srcConnection! <= Const(0, width: miAbsW);
    recon.input('tile_left_mi').srcConnection! <= Const(0, width: miAbsW);
    recon.input('ext_above').srcConnection! <= Const(0, width: f * 8);
    recon.input('ext_left').srcConnection! <= Const(0, width: f * 8);
    recon.input('ext_corner').srcConnection! <= Const(0, width: 8);

    final lumaFrame = recon.output('frame'); // 16*16*8
    output('luma') <= lumaFrame;

    // CfL luma-AC subsample (combinational on the recon luma frame).
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
    final cflAcPacked = [
      for (var k = cN - 1; k >= 0; k--) cflAc[k],
    ].concat(); // cN*cflAcBits

    // chroma derivations (const muxes on uvModeCap).
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

    final uvIntra = romSel(_uv2y, uvModeCap, 4);
    final useCfl = uvModeCap.eq(Const(13, width: 4));
    final txTypeRaw = romSel(_intraModeToTxType, uvIntra, 4);
    final txUsed = romSel(_av1ExtTxUsed3, txTypeRaw, 1);
    final chromaTxType = mux(
      txUsed.eq(Const(1, width: 1)),
      txTypeRaw,
      Const(0, width: 4),
    );

    // chroma recon blocks (U then V).
    void wireChroma(HarborChromaReconBlock blk, Logic plane, Logic coeffs) {
      blk.input('clk').srcConnection! <= clk;
      blk.input('reset').srcConnection! <= reset;
      blk.input('start').srcConnection! <= chromaStart;
      blk.input('uv_mode').srcConnection! <= uvIntra;
      blk.input('use_cfl').srcConnection! <= useCfl;
      blk.input('have_above').srcConnection! <= Const(0);
      blk.input('have_left').srcConnection! <= Const(0);
      blk.input('above').srcConnection! <= Const(0, width: cBs * 8);
      blk.input('left').srcConnection! <= Const(0, width: cBs * 8);
      blk.input('above_left').srcConnection! <= Const(0, width: 8);
      blk.input('cfl_luma_ac').srcConnection! <= cflAcPacked;
      blk.input('cfl_alpha_idx').srcConnection! <= cflIdxCap;
      blk.input('cfl_signs').srcConnection! <= cflSignsCap;
      blk.input('plane').srcConnection! <= plane;
      blk.input('tx_type').srcConnection! <= chromaTxType;
      blk.input('coeffs').srcConnection! <= coeffs;
      blk.input('skip').srcConnection! <= Const(0);
      blk.input('eob_zero').srcConnection! <= Const(0);
    }

    wireChroma(chromaU, Const(0), uCoeffCap);
    wireChroma(chromaV, Const(1), vCoeffCap);

    output('u') <= chromaU.output('recon');
    output('v') <= chromaV.output('recon');

    // sequencing FSM
    const sIdle = 0,
        sRunMode = 1,
        sLatch = 2,
        sRunRecon = 3,
        sReconWait = 4,
        sRunChroma = 5,
        sChromaWait = 6,
        sDone = 7;
    final st = Logic(name: 'st', width: 3);
    output('done') <= st.eq(Const(sDone, width: 3));

    Combinational([
      walkStart < Const(0),
      reconStart < Const(0),
      chromaStart < Const(0),
      Case(st, [
        CaseItem(Const(sIdle, width: 3), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        CaseItem(Const(sRunRecon, width: 3), [reconStart < Const(1)]),
        CaseItem(Const(sRunChroma, width: 3), [chromaStart < Const(1)]),
      ]),
    ]);

    final chromaDone = chromaU.output('done') & chromaV.output('done');

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          ymCap < Const(0, width: 4),
          ttCap < Const(0, width: 4),
          coeffCap < Const(0, width: leafCoeffN * 16),
          uvModeCap < Const(0, width: 4),
          cflIdxCap < Const(0, width: 8),
          cflSignsCap < Const(0, width: 3),
          uCoeffCap < Const(0, width: cN * 16),
          vCoeffCap < Const(0, width: cN * 16),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(input('start'), then: [st < Const(sRunMode, width: 3)]),
            ]),
            CaseItem(Const(sRunMode, width: 3), [
              If(walk.output('done'), then: [st < Const(sLatch, width: 3)]),
            ]),
            CaseItem(Const(sLatch, width: 3), [
              ymCap < walk.output('leaf_ymodes').getRange(0, 4),
              // leaf_luma_txtypes: the chroma decode clobbers leaf_txtypes, the
              // preserved luma ext-tx type is here.
              ttCap < walk.output('leaf_luma_txtypes').getRange(0, 4),
              coeffCap <
                  walk.output('leaf_coeffs').getRange(0, leafCoeffN * 16),
              uvModeCap < walk.output('leaf_uv_mode'),
              cflIdxCap < walk.output('leaf_cfl_alpha_idx'),
              cflSignsCap < walk.output('leaf_cfl_signs'),
              uCoeffCap < walk.output('leaf_u_coeffs'),
              vCoeffCap < walk.output('leaf_v_coeffs'),
              st < Const(sRunRecon, width: 3),
            ]),
            CaseItem(Const(sRunRecon, width: 3), [
              st < Const(sReconWait, width: 3),
            ]),
            CaseItem(Const(sReconWait, width: 3), [
              If(
                recon.output('done'),
                then: [st < Const(sRunChroma, width: 3)],
              ),
            ]),
            CaseItem(Const(sRunChroma, width: 3), [
              st < Const(sChromaWait, width: 3),
            ]),
            CaseItem(Const(sChromaWait, width: 3), [
              If(chromaDone, then: [st < Const(sDone, width: 3)]),
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

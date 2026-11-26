import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'chroma_recon_block.dart';
import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// End-to-end keyframe intra decode for one NONE-partition 8x8 superblock in
/// 4:2:0: coded bytes to reconstructed 8x8 luma + 4x4 U + 4x4 V pixels, joining
/// the mode walk, luma recon, and chroma recon on a small sequencing + derivation
/// FSM.
///
/// On `start`, runs [HarborKeyframeModeWalk] (rootBsize 3, coeffPrefix, txLeaf,
/// chroma) over `bytes`. When the walk asserts done, the per-leaf luma and chroma
/// outputs are latched. The 8x8 luma plane is reconstructed via
/// [HarborIntraReconWalk] (same walk -> recon mapping as [HarborKeyframeDecodeVar]
/// for the single NONE 8x8 leaf). The reconstructed luma is subsampled (4:2:0)
/// into the CfL luma-AC source, and [HarborChromaReconBlock] runs for U then V
/// with the derived chroma intra mode / CfL / tx_type. `done` asserts with the
/// three reconstructed planes.
///
/// Chroma derivations (const muxes on the latched `leaf_uv_mode`):
///  - chroma intra mode `uvIntra = _uv2y[uv_mode]`: identity 0..12, 13
///    (UV_CFL_PRED) -> DC (0). Fed as the chroma block's `uv_mode`.
///  - `use_cfl = (uv_mode == 13)`.
///  - chroma tx_type: `_intraModeToTxType[uvIntra]` then, if
///    `av1ExtTxUsed[setType][txType] == 0`, force 0. For TX_4X4 intra
///    (reducedTxSet=false) setType = kExtTxSetDtt4Idtx1dDct = 3, whose row caps
///    txTypes {0,1,2,3} to themselves, so the cap is a no-op for the 13 entries
///    but is implemented exactly for correctness.
///  - CfL luma-AC subsample (4:2:0): chroma pixel (i=col, j=row) takes the 2x2
///    collocated luma summed and `<<1`: `cflRecon[j*4+i] = (a+b+c+d) << 1`,
///    computed combinationally from the recon luma `frame`. Kept full-width and
///    treated as unsigned by the chroma block.
///  - chroma neighbours: an isolated single 8x8 SB, so the 4x4 chroma block is at
///    the top-left of the chroma plane (have_above = 0, have_left = 0).
///  - skip / eob_zero driven 0: the mode walk emits the dequantized chroma coeffs
///    (zero when skipped / eob 0), so a zero-coeff transform is a no-op add.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// luma (512), u (128), v (128). Out of scope on this path: SPLIT / sub-8x8
/// chroma, tx-split 8x8 leaves, the skipped-leaf chroma plane.
class HarborKeyframeDecodeYuv extends BridgeModule {
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

  HarborKeyframeDecodeYuv({this.maxBytes = 48, this.qband = 0, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      assert(qband >= 0 && qband < 4, 'qband 0..3'),
      super('HarborKeyframeDecodeYuv', name: name ?? 'keyframe_decode_yuv') {
    const sbSize = 8; // 8x8 superblock luma
    const maxLeaves = 4; // sized like the var decoder (NONE uses 1)
    const f = sbSize; // 8 luma pixels per side
    const nPix = f * f; // 64 luma
    const cBs = 4; // chroma block side (4:2:0)
    const cN = cBs * cBs; // 16 chroma pixels
    const miBits = 2; // bitLength(sbSize/4) = bitLength(2) = 2
    const cntW = 3; // (maxLeaves + 1).bitLength

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
      rootBsize: 3,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
      chroma: true,
      qband: qband,
      name: 'walk',
    );
    addSubModule(walk);
    // An 8x8 SB's largest leaf is 8x8 -> maxLog2 1 (64-coeff slot per leaf, the
    // default maxLog2 2 would over-provision 16x16 lanes / a 256-coeff slot).
    final recon = HarborIntraReconWalk(
      sbSize: sbSize,
      maxLeaves: maxLeaves,
      maxLog2: 1,
      name: 'recon',
    );
    addSubModule(recon);
    // CfL luma-AC per-pixel width: (a+b+c+d) << 1 over the 2x2 collocated luma
    // is up to 255*4*2 = 2040 at bd8 -> 11 bits, use 12 for margin.
    const cflAcBits = 12;
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
    final lcCap = Logic(name: 'leaf_count_cap', width: 12);
    final l2Cap = Logic(name: 'leaf_log2size_cap', width: 4 * 3);
    final ymCap = Logic(name: 'leaf_ymodes_cap', width: 4 * 4);
    final ttCap = Logic(name: 'leaf_txtypes_cap', width: 4 * 4);
    final coeffCap = Logic(name: 'leaf_coeffs_cap', width: 4 * 64 * 16);
    final uvModeCap = Logic(name: 'leaf_uv_mode_cap', width: 4);
    final cflIdxCap = Logic(name: 'leaf_cfl_alpha_idx_cap', width: 8);
    final cflSignsCap = Logic(name: 'leaf_cfl_signs_cap', width: 3);
    final uCoeffCap = Logic(name: 'leaf_u_coeffs_cap', width: 16 * 16);
    final vCoeffCap = Logic(name: 'leaf_v_coeffs_cap', width: 16 * 16);

    // luma mapping (walk -> recon), like HarborKeyframeDecodeVar restricted to
    // the NONE single 8x8 leaf.
    final reconLeafCount = lcCap.getRange(0, cntW);
    final reconLog2 = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        (l2Cap.getRange(l * 3, l * 3 + 3) - Const(2, width: 3)).getRange(0, 2),
    ].concat();
    final reconYModes = ymCap;
    final reconTxTypes = ttCap;
    // maxLog2 1 -> 64-coeff slot per leaf (an 8x8 leaf's TX_8X8, or a 4x4 leaf's
    // TX_4X4 in the low 16 with the rest zero as the walk placed them).
    final reconCoeffs = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        coeffCap.getRange(l * 64 * 16, l * 64 * 16 + 64 * 16),
    ].concat();
    int posVal(int row, int col) => row | (col << miBits);
    // Positions derived from leaf_count (matching HarborKeyframeDecodeVar):
    // NONE (count 1) -> leaf 0 at mi (0,0). SPLIT (count 4) -> leaf l at
    // mi (l>>1, l&1) in DFS=raster order.
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

    recon.input('clk').srcConnection! <= clk;
    recon.input('reset').srcConnection! <= reset;
    recon.input('start').srcConnection! <= reconStart;
    recon.input('leaf_count').srcConnection! <= reconLeafCount;
    recon.input('positions').srcConnection! <= reconPositions;
    recon.input('log2sizes').srcConnection! <= reconLog2;
    recon.input('y_modes').srcConnection! <= reconYModes;
    recon.input('tx_types').srcConnection! <= reconTxTypes;
    recon.input('coeffs').srcConnection! <= reconCoeffs;

    final lumaFrame = recon.output('frame'); // 8*8*8
    output('luma') <= lumaFrame;

    // CfL luma-AC subsample (combinational on the recon luma frame).
    // chroma (i=col, j=row): the 2x2 collocated luma at (2j,2i),(2j,2i+1),
    // (2j+1,2i),(2j+1,2i+1), summed and <<1 (up to 2040 at bd8). Kept full-width
    // (cflAcBits per pixel), not truncated.
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

    final uvIntra = romSel(_uv2y, uvModeCap, 4); // chroma intra mode 0..12
    final useCfl = uvModeCap.eq(Const(13, width: 4));
    // chroma tx_type: _intraModeToTxType[uvIntra], capped by av1ExtTxUsed3.
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

    // sequencing FSM: mode, latch, luma recon (wait), chroma (wait), done. The
    // luma recon must finish before chroma since the CfL source reads the recon
    // luma frame. U and V run in parallel (separate blocks sharing the start
    // pulse).
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
          lcCap < Const(0, width: 12),
          l2Cap < Const(0, width: 4 * 3),
          ymCap < Const(0, width: 4 * 4),
          ttCap < Const(0, width: 4 * 4),
          coeffCap < Const(0, width: 4 * 64 * 16),
          uvModeCap < Const(0, width: 4),
          cflIdxCap < Const(0, width: 8),
          cflSignsCap < Const(0, width: 3),
          uCoeffCap < Const(0, width: 16 * 16),
          vCoeffCap < Const(0, width: 16 * 16),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(input('start'), then: [st < Const(sRunMode, width: 3)]),
            ]),
            CaseItem(Const(sRunMode, width: 3), [
              If(walk.output('done'), then: [st < Const(sLatch, width: 3)]),
            ]),
            // walk outputs are stable while it holds done. latch all leaf data.
            CaseItem(Const(sLatch, width: 3), [
              lcCap < walk.output('leaf_count'),
              l2Cap < walk.output('leaf_log2size'),
              ymCap < walk.output('leaf_ymodes'),
              // leaf_luma_txtypes: the chroma decode clobbers the shared
              // leaf_txtypes to 0, so the preserved luma ext-tx type is here.
              ttCap < walk.output('leaf_luma_txtypes'),
              coeffCap < walk.output('leaf_coeffs'),
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

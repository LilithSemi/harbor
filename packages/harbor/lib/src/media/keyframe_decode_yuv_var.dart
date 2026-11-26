import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'chroma_recon_block.dart';
import 'intra_recon_walk.dart';
import 'keyframe_mode_walk.dart';

/// End-to-end keyframe intra decode for one 8x8 superblock in 4:2:0 with
/// variable luma transform depth: coded bytes to reconstructed 8x8 luma + 4x4 U
/// + 4x4 V pixels. Unifies [HarborKeyframeDecodeVar]'s depth-1 (tx-split) luma
/// expansion with [HarborKeyframeDecodeYuv]'s full 4:2:0 chroma recon, so a NONE
/// 8x8 leaf whose tx_size split into four TX_4X4 sub-blocks is decoded to pixels
/// with its U/V chroma planes.
///
/// On `start`, runs [HarborKeyframeModeWalk] (rootBsize 3, coeffPrefix, txLeaf,
/// chroma) over `bytes`. When the walk asserts done, the per-leaf luma and chroma
/// outputs are latched.
///
/// Luma mapping (walk -> recon), identical to [HarborKeyframeDecodeVar]:
///  - NONE depth-0 (one 8x8 TX_8X8 leaf) and SPLIT (four 4x4 leaves) map as in
///    [HarborKeyframeDecodeYuv].
///  - A depth-1 8x8 leaf expands into four 4x4 recon leaves sharing the leaf's
///    single y_mode, each sub-block taking its own tx_type from
///    `leaf_sub_txtypes[l*4 +: 4]` and its de-interleaved 16-coeff 4x4-raster
///    block from the leaf's 64-coeff slot. The depth-1 path is mux-guarded, so
///    the NONE/SPLIT mappings are used unchanged when not depth-1.
///
/// Chroma recon (identical to [HarborKeyframeDecodeYuv]): the reconstructed luma
/// is subsampled (4:2:0) into the CfL luma-AC source and [HarborChromaReconBlock]
/// runs for U then V with the derived chroma intra mode, use_cfl, and tx_type.
/// The 4:2:0 chroma block is collocated with the whole 8x8 luma SB for both the
/// depth-0 and depth-1 NONE leaf, so the chroma path is unchanged by the depth-1
/// luma expansion.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16) -> done,
/// luma (512), u (128), v (128).
class HarborKeyframeDecodeYuvVar extends BridgeModule {
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

  HarborKeyframeDecodeYuvVar({this.maxBytes = 48, this.qband = 0, String? name})
    : assert(maxBytes > 0, 'maxBytes must be positive'),
      assert(qband >= 0 && qband < 4, 'qband 0..3'),
      super(
        'HarborKeyframeDecodeYuvVar',
        name: name ?? 'keyframe_decode_yuv_var',
      ) {
    const sbSize = 8; // 8x8 superblock luma
    const maxLeaves = 4; // NONE (1) / depth-1-expanded (4) / SPLIT (4)
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
    final recon = HarborIntraReconWalk(
      sbSize: sbSize,
      maxLeaves: maxLeaves,
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
    final tdCap = Logic(name: 'leaf_tx_depth_cap', width: 4 * 2);
    // depth-1 per-sub-block luma ext-tx types (sub-block s at [s*4 +: 4]).
    final stxCap = Logic(name: 'leaf_sub_txtypes_cap', width: 4 * 4);
    final uvModeCap = Logic(name: 'leaf_uv_mode_cap', width: 4);
    final cflIdxCap = Logic(name: 'leaf_cfl_alpha_idx_cap', width: 8);
    final cflSignsCap = Logic(name: 'leaf_cfl_signs_cap', width: 3);
    final uCoeffCap = Logic(name: 'leaf_u_coeffs_cap', width: 16 * 16);
    final vCoeffCap = Logic(name: 'leaf_v_coeffs_cap', width: 16 * 16);

    // luma mapping (walk -> recon).
    // Base NONE/SPLIT mapping (identical to HarborKeyframeDecodeYuv).
    final reconLeafCount = lcCap.getRange(0, cntW);
    final reconLog2 = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        (l2Cap.getRange(l * 3, l * 3 + 3) - Const(2, width: 3)).getRange(0, 2),
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
    final splitPositions = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        Const(posVal(l >> 1, l & 1), width: 2 * miBits),
    ].concat();
    final reconPositions = mux(
      reconLeafCount.eq(Const(4, width: cntW)),
      splitPositions,
      posNone,
    );

    // tx-split (depth-1) NONE leaf expansion (identical to
    // HarborKeyframeDecodeVar).
    // A depth-1 8x8 leaf (one leaf, log2 pixel size 3, tx_depth 1) is recon-
    // equivalent to FOUR 4x4 leaves that all share the leaf's single y_mode,
    // each transforming with its own sub-block tx_type. Expand into four 4x4
    // recon leaves, the recon walk needs no change. This is additive and
    // mux-guarded: the NONE depth-0 and SPLIT mappings above are used unchanged
    // when not depth-1.
    final isDepth1 =
        reconLeafCount.eq(Const(1, width: cntW)) &
        l2Cap.getRange(0, 3).eq(Const(3, width: 3)) &
        tdCap.getRange(0, 2).eq(Const(1, width: 2));
    final d1LeafCount = Const(4, width: cntW);
    final d1Positions = splitPositions;
    final d1Log2 = Const(0, width: maxLeaves * 2);
    final ym0 = ymCap.getRange(0, 4);
    final d1YModes = [for (var l = 0; l < maxLeaves; l++) ym0].concat();
    final d1TxTypes = [
      for (var l = maxLeaves - 1; l >= 0; l--)
        stxCap.getRange(l * 4, l * 4 + 4),
    ].concat();
    final leaf0Coeffs = coeffCap.getRange(0, 64 * 16);
    Logic d1SlotCoeff(int rowOff, int colOff, int r4, int c4) {
      final slot = (rowOff * 4 + r4) * 8 + (colOff * 4 + c4);
      return leaf0Coeffs.getRange(slot * 16, slot * 16 + 16);
    }

    final d1Coeffs = [
      for (var l = maxLeaves - 1; l >= 0; l--) ...[
        Const(0, width: 240 * 16),
        [
          for (var i = 15; i >= 0; i--)
            d1SlotCoeff(l >> 1, l & 1, i >> 2, i & 3),
        ].concat(),
      ],
    ].concat();

    // mux every recon input by the depth-1 detection.
    final muxLeafCount = mux(isDepth1, d1LeafCount, reconLeafCount);
    final muxPositions = mux(isDepth1, d1Positions, reconPositions);
    final muxLog2 = mux(isDepth1, d1Log2, reconLog2);
    final muxYModes = mux(isDepth1, d1YModes, reconYModes);
    final muxTxTypes = mux(isDepth1, d1TxTypes, reconTxTypes);
    final muxCoeffs = mux(isDepth1, d1Coeffs, reconCoeffs);

    recon.input('clk').srcConnection! <= clk;
    recon.input('reset').srcConnection! <= reset;
    recon.input('start').srcConnection! <= reconStart;
    recon.input('leaf_count').srcConnection! <= muxLeafCount;
    recon.input('positions').srcConnection! <= muxPositions;
    recon.input('log2sizes').srcConnection! <= muxLog2;
    recon.input('y_modes').srcConnection! <= muxYModes;
    recon.input('tx_types').srcConnection! <= muxTxTypes;
    recon.input('coeffs').srcConnection! <= muxCoeffs;

    final lumaFrame = recon.output('frame'); // 8*8*8
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

    final uvIntra = romSel(_uv2y, uvModeCap, 4); // chroma intra mode 0..12
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
          lcCap < Const(0, width: 12),
          l2Cap < Const(0, width: 4 * 3),
          ymCap < Const(0, width: 4 * 4),
          ttCap < Const(0, width: 4 * 4),
          coeffCap < Const(0, width: 4 * 64 * 16),
          tdCap < Const(0, width: 4 * 2),
          stxCap < Const(0, width: 4 * 4),
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
              tdCap < walk.output('leaf_tx_depth'),
              stxCap < walk.output('leaf_sub_txtypes'),
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

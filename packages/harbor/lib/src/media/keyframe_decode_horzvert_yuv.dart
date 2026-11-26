import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'chroma_recon_block.dart';
import 'intra_pred_rect.dart';
import 'inv_txfm.dart';
import 'keyframe_mode_walk.dart';
import 'recon_add.dart';

/// AV1 keyframe intra decode for one 8x8 superblock split by a HORZ or VERT
/// partition into two rectangular luma leaves, in 4:2:0, decoding to full YUV:
/// coded bytes -> 8x8 luma + 4x4 U + 4x4 V pixels.
///
/// The chroma-bearing sibling of [HarborKeyframeDecodeHorzVert] (luma-only
/// HORZ/VERT recon) and the rect analogue of [HarborKeyframeDecodeYuvVar]. A
/// HORZ partition tiles the 8x8 luma into two 8x4 (TX_8X4) leaves stacked
/// vertically, a VERT one into two 4x8 (TX_4X8) leaves side by side. In 4:2:0
/// the chroma is collocated with the whole 8x8 SB and owned by leaf 1
/// (chromaRef), leaf 0 is luma only.
///
/// On `start`, runs [HarborKeyframeModeWalk] (rootBsize 3, coeffPrefix, txLeaf,
/// chroma) over `bytes`. When it asserts done the per-leaf luma and chroma
/// outputs are latched. The two rect luma leaves are reconstructed in order on a
/// local 8x8 frame RAM (as in [HarborKeyframeDecodeHorzVert]). That luma is
/// subsampled (4:2:0) into the CfL luma-AC source, then [HarborChromaReconBlock]
/// runs for U then V with the derived chroma intra mode (`uvIntra =
/// _uv2y[uv_mode]`), `use_cfl = (uv_mode == 13)`, and chroma tx_type. The 4x4
/// chroma block of the isolated SB has no above/left neighbours.
///
/// The chroma decode clobbers the shared `leaf_txtypes` to 0, so the preserved
/// luma ext-tx type is latched from `leaf_luma_txtypes`.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16),
/// have_above (1), have_left (1), above (8*8), left (8*8), above_left (8) ->
/// done, luma (512), u (128), v (128). Scope: one HORZ or VERT 8x8 SB in 4:2:0,
/// depth-0 rect tx, full YUV.
class HarborKeyframeDecodeHorzVertYuv extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3) for the mode walk's coeff decode.
  final int qband;

  // Rect tx_types a HORZ/VERT luma leaf can decode (ext-tx set DTT4_IDTX_1DDCT).
  static const _rectTxTypes = [0, 1, 2, 3, 9, 10, 11];

  // uv2y[]: UV mode -> luma intra mode (identity, CFL->DC).
  static const _uv2y = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0];
  // intra_mode_to_tx_type, 13 entries.
  static const _intraModeToTxType = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3];
  // av1ExtTxUsed[3] (TX_4X4 intra ext-tx cap row).
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

  HarborKeyframeDecodeHorzVertYuv({
    this.maxBytes = 48,
    this.qband = 0,
    String? name,
  }) : assert(maxBytes > 0, 'maxBytes must be positive'),
       assert(qband >= 0 && qband < 4, 'qband 0..3'),
       super(
         'HarborKeyframeDecodeHorzVertYuv',
         name: name ?? 'keyframe_decode_horzvert_yuv',
       ) {
    const f = 8; // 8x8 superblock
    const nPix = f * f; // 64 luma
    const cBs = 4; // chroma block side (4:2:0)
    const cN = cBs * cBs; // 16 chroma pixels

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16);
    createPort('ac_q', PortDirection.input, width: 16);
    createPort('have_above', PortDirection.input);
    createPort('have_left', PortDirection.input);
    createPort('above', PortDirection.input, width: f * 8);
    createPort('left', PortDirection.input, width: f * 8);
    createPort('above_left', PortDirection.input, width: 8);
    addOutput('done');
    addOutput('luma', width: nPix * 8);
    addOutput('u', width: cN * 8);
    addOutput('v', width: cN * 8);

    final clk = input('clk');
    final reset = input('reset');

    // mode walk (bytes -> per-leaf mode info + dequant rect coeffs + chroma)
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
    final walkStart = Logic(name: 'walk_start');
    walk.input('clk').srcConnection! <= clk;
    walk.input('reset').srcConnection! <= reset;
    walk.input('start').srcConnection! <= walkStart;
    walk.input('bytes').srcConnection! <= input('bytes');
    walk.input('dc_q').srcConnection! <= input('dc_q');
    walk.input('ac_q').srcConnection! <= input('ac_q');

    // latched walk outputs
    final l2Cap = Logic(name: 'leaf_log2size_cap', width: 4 * 3);
    final ymCap = Logic(name: 'leaf_ymodes_cap', width: 4 * 4);
    final ttCap = Logic(name: 'leaf_txtypes_cap', width: 4 * 4);
    final coeffCap = Logic(name: 'leaf_coeffs_cap', width: 4 * 64 * 16);
    final uvModeCap = Logic(name: 'leaf_uv_mode_cap', width: 4);
    final cflIdxCap = Logic(name: 'leaf_cfl_alpha_idx_cap', width: 8);
    final cflSignsCap = Logic(name: 'leaf_cfl_signs_cap', width: 3);
    final uCoeffCap = Logic(name: 'leaf_u_coeffs_cap', width: 16 * 16);
    final vCoeffCap = Logic(name: 'leaf_v_coeffs_cap', width: 16 * 16);

    // HORZ when leaf 0 is an 8x4 (pixel log2 3), VERT when 4x8 (pixel log2 2).
    final isHorz = l2Cap.getRange(0, 3).eq(Const(3, width: 3));

    // 8x8 frame RAM (reconstructed luma)
    final frame = [
      for (var i = 0; i < nPix; i++) Logic(name: 'f_$i', width: 8),
    ];

    // current leaf index (0 or 1).
    final leaf = Logic(name: 'leaf');

    Logic selLeaf(Logic packed, int w) =>
        mux(leaf, packed.getRange(w, 2 * w), packed.getRange(0, w));
    final yMode = selLeaf(ymCap, 4);
    final txType = selLeaf(ttCap, 4);
    final coeffsCur = selLeaf(coeffCap, 64 * 16);

    // leaf footprint (pixel origin + neighbour construction)
    final isLeaf1 = leaf;
    final py = mux(
      isHorz,
      mux<Logic>(isLeaf1, Const(4, width: 4), Const(0, width: 4)),
      Const(0, width: 4),
    );
    final px = mux(
      isHorz,
      Const(0, width: 4),
      mux<Logic>(isLeaf1, Const(4, width: 4), Const(0, width: 4)),
    );

    final haveA = mux(
      isHorz,
      mux(isLeaf1, Const(1), input('have_above')),
      input('have_above'),
    );
    final haveL = mux(
      isHorz,
      input('have_left'),
      mux(isLeaf1, Const(1), input('have_left')),
    );

    Logic frameAt(int row, int col) => frame[row * f + col];
    Logic abovePort(int i) => input('above').getRange(i * 8, i * 8 + 8);
    Logic leftPort(int i) => input('left').getRange(i * 8, i * 8 + 8);

    final aboveSel = <Logic>[
      for (var i = 0; i < f; i++)
        mux(
          isHorz,
          mux(isLeaf1, frameAt(3, i), abovePort(i)),
          mux(isLeaf1, abovePort(i < 4 ? 4 + i : i), abovePort(i)),
        ),
    ];
    final leftSel = <Logic>[
      for (var i = 0; i < f; i++)
        mux(
          isHorz,
          mux(isLeaf1, leftPort(i < 4 ? 4 + i : i), leftPort(i)),
          mux(isLeaf1, frameAt(i, 3), leftPort(i)),
        ),
    ];
    final cornerSel = mux(
      isHorz,
      mux(isLeaf1, leftPort(3), input('above_left')),
      mux(isLeaf1, abovePort(3), input('above_left')),
    );

    // rectangular predictor: one 8x4 + one 4x8 instance.
    final pred84 = HarborIntraPredRect(bw: 8, bh: 4, name: 'pred84');
    addSubModule(pred84);
    pred84.input('mode').srcConnection! <= yMode;
    pred84.input('have_above').srcConnection! <= haveA;
    pred84.input('have_left').srcConnection! <= haveL;
    pred84.input('above').srcConnection! <=
        [for (var i = 8 - 1; i >= 0; i--) aboveSel[i]].concat();
    pred84.input('left').srcConnection! <=
        [for (var i = 4 - 1; i >= 0; i--) leftSel[i]].concat();
    pred84.input('above_left').srcConnection! <= cornerSel;

    final pred48 = HarborIntraPredRect(bw: 4, bh: 8, name: 'pred48');
    addSubModule(pred48);
    pred48.input('mode').srcConnection! <= yMode;
    pred48.input('have_above').srcConnection! <= haveA;
    pred48.input('have_left').srcConnection! <= haveL;
    pred48.input('above').srcConnection! <=
        [for (var i = 4 - 1; i >= 0; i--) aboveSel[i]].concat();
    pred48.input('left').srcConnection! <=
        [for (var i = 8 - 1; i >= 0; i--) leftSel[i]].concat();
    pred48.input('above_left').srcConnection! <= cornerSel;

    // rect inverse transforms: one per (kind, tx_type).
    final txStart = Logic(name: 'tx_start');
    Logic txCoeffsFor(int kindW, int kindH) =>
        coeffsCur.getRange(0, kindW * kindH * 16);

    final done84 = <Logic>[];
    final done48 = <Logic>[];
    final res84ByType = <int, Logic>{};
    final res48ByType = <int, Logic>{};
    for (final tt in _rectTxTypes) {
      final tx84 = HarborInvTxfm(txSize: 6, txType: tt, name: 'tx84_$tt');
      addSubModule(tx84);
      tx84.input('clk').srcConnection! <= clk;
      tx84.input('reset').srcConnection! <= reset;
      tx84.input('start').srcConnection! <= txStart;
      tx84.input('coeffs').srcConnection! <= txCoeffsFor(8, 4);
      done84.add(tx84.output('done'));
      res84ByType[tt] = tx84.output('residual');

      final tx48 = HarborInvTxfm(txSize: 5, txType: tt, name: 'tx48_$tt');
      addSubModule(tx48);
      tx48.input('clk').srcConnection! <= clk;
      tx48.input('reset').srcConnection! <= reset;
      tx48.input('start').srcConnection! <= txStart;
      tx48.input('coeffs').srcConnection! <= txCoeffsFor(4, 8);
      done48.add(tx48.output('done'));
      res48ByType[tt] = tx48.output('residual');
    }
    Logic selResType(Map<int, Logic> m) {
      Logic v = m[_rectTxTypes.last]!;
      for (var i = _rectTxTypes.length - 2; i >= 0; i--) {
        v = mux(
          txType.eq(Const(_rectTxTypes[i], width: 4)),
          m[_rectTxTypes[i]]!,
          v,
        );
      }
      return v;
    }

    final res84 = selResType(res84ByType);
    final res48 = selResType(res48ByType);
    final txDone = mux(isHorz, done84.first, done48.first);

    // recon-add per kind (32 pixels)
    final ra84 = HarborReconAdd(n: 32, name: 'ra84');
    addSubModule(ra84);
    ra84.input('pred').srcConnection! <= pred84.output('pred');
    ra84.input('residual').srcConnection! <= res84;
    final recon84 = ra84.output('recon');

    final ra48 = HarborReconAdd(n: 32, name: 'ra48');
    addSubModule(ra48);
    ra48.input('pred').srcConnection! <= pred48.output('pred');
    ra48.input('residual').srcConnection! <= res48;
    final recon48 = ra48.output('recon');

    Logic recon84Px(int idx) => recon84.getRange(idx * 8, idx * 8 + 8);
    Logic recon48Px(int idx) => recon48.getRange(idx * 8, idx * 8 + 8);

    final lumaFrame = [for (var i = nPix - 1; i >= 0; i--) frame[i]].concat();
    output('luma') <= lumaFrame;

    // chroma recon blocks (U then V)
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
    final chromaStart = Logic(name: 'chroma_start');

    // CfL luma-AC subsample (combinational on the recon luma frame).
    Logic lumaAt(int r, int c) => frame[r * f + c];
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

    final chromaDone = chromaU.output('done') & chromaV.output('done');

    // FSM
    const sIdle = 0,
        sRunMode = 1,
        sLatch = 2,
        sPred = 3,
        sTxWait = 4,
        sWrite = 5,
        sRunChroma = 6,
        sChromaWait = 7,
        sDone = 8;
    final st = Logic(name: 'st', width: 4);
    output('done') <= st.eq(Const(sDone, width: 4));

    Combinational([
      walkStart < Const(0),
      txStart < Const(0),
      chromaStart < Const(0),
      Case(st, [
        CaseItem(Const(sIdle, width: 4), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        CaseItem(Const(sPred, width: 4), [txStart < Const(1)]),
        CaseItem(Const(sRunChroma, width: 4), [chromaStart < Const(1)]),
      ]),
    ]);

    final kr = [for (var k = 0; k < nPix; k++) k ~/ f];
    final kc = [for (var k = 0; k < nPix; k++) k % f];
    List<Conditional> writeBack() {
      final conds = <Conditional>[];
      for (var k = 0; k < nPix; k++) {
        final inH =
            Const(kr[k], width: 4).gte(py) &
            Const(kr[k], width: 4).lt((py + Const(4, width: 4)).getRange(0, 4));
        final liH =
            ((Const(kr[k], width: 4) - py).getRange(0, 4).zeroExtend(7) *
                        Const(8, width: 7) +
                    Const(kc[k], width: 7))
                .getRange(0, 7);
        Logic sampleH = recon84Px(31);
        for (var j = 30; j >= 0; j--) {
          sampleH = mux(liH.eq(Const(j, width: 7)), recon84Px(j), sampleH);
        }
        final inV =
            Const(kc[k], width: 4).gte(px) &
            Const(kc[k], width: 4).lt((px + Const(4, width: 4)).getRange(0, 4));
        final liV =
            (Const(kr[k], width: 7) * Const(4, width: 7) +
                    (Const(kc[k], width: 4) - px).getRange(0, 4).zeroExtend(7))
                .getRange(0, 7);
        Logic sampleV = recon48Px(31);
        for (var j = 30; j >= 0; j--) {
          sampleV = mux(liV.eq(Const(j, width: 7)), recon48Px(j), sampleV);
        }
        conds.add(
          If(
            isHorz,
            then: [
              If(inH, then: [frame[k] < sampleH]),
            ],
            orElse: [
              If(inV, then: [frame[k] < sampleV]),
            ],
          ),
        );
      }
      return conds;
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 4),
          leaf < Const(0),
          l2Cap < Const(0, width: 4 * 3),
          ymCap < Const(0, width: 4 * 4),
          ttCap < Const(0, width: 4 * 4),
          coeffCap < Const(0, width: 4 * 64 * 16),
          uvModeCap < Const(0, width: 4),
          cflIdxCap < Const(0, width: 8),
          cflSignsCap < Const(0, width: 3),
          uCoeffCap < Const(0, width: 16 * 16),
          vCoeffCap < Const(0, width: 16 * 16),
          for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: 8),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 4), [
              If(
                input('start'),
                then: [
                  leaf < Const(0),
                  for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: 8),
                  st < Const(sRunMode, width: 4),
                ],
              ),
            ]),
            CaseItem(Const(sRunMode, width: 4), [
              If(walk.output('done'), then: [st < Const(sLatch, width: 4)]),
            ]),
            CaseItem(Const(sLatch, width: 4), [
              l2Cap < walk.output('leaf_log2size'),
              ymCap < walk.output('leaf_ymodes'),
              // use leaf_luma_txtypes: the chroma decode clobbers the shared
              // leaf_txtypes to 0, so the preserved luma ext-tx type is here.
              ttCap < walk.output('leaf_luma_txtypes'),
              coeffCap < walk.output('leaf_coeffs'),
              uvModeCap < walk.output('leaf_uv_mode'),
              cflIdxCap < walk.output('leaf_cfl_alpha_idx'),
              cflSignsCap < walk.output('leaf_cfl_signs'),
              uCoeffCap < walk.output('leaf_u_coeffs'),
              vCoeffCap < walk.output('leaf_v_coeffs'),
              st < Const(sPred, width: 4),
            ]),
            CaseItem(Const(sPred, width: 4), [st < Const(sTxWait, width: 4)]),
            CaseItem(Const(sTxWait, width: 4), [
              If(txDone, then: [st < Const(sWrite, width: 4)]),
            ]),
            CaseItem(Const(sWrite, width: 4), [
              ...writeBack(),
              If(
                leaf.eq(Const(1)),
                then: [st < Const(sRunChroma, width: 4)],
                orElse: [leaf < Const(1), st < Const(sPred, width: 4)],
              ),
            ]),
            CaseItem(Const(sRunChroma, width: 4), [
              st < Const(sChromaWait, width: 4),
            ]),
            CaseItem(Const(sChromaWait, width: 4), [
              If(chromaDone, then: [st < Const(sDone, width: 4)]),
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

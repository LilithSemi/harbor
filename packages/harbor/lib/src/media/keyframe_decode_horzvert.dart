import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_pred_rect.dart';
import 'inv_txfm.dart';
import 'keyframe_mode_walk.dart';
import 'recon_add.dart';

/// AV1 keyframe intra decode for one 8x8 superblock split by a HORZ or VERT
/// partition into two rectangular luma leaves: coded bytes -> 8x8 luma picture.
///
/// The rectangular-leaf sibling of [HarborKeyframeDecodeVar] (NONE / SPLIT /
/// depth-1 square leaves). A HORZ partition tiles the 8x8 into two 8x4 (TX_8X4)
/// leaves stacked vertically (leaf 0 rows 0..3, leaf 1 rows 4..7), a VERT one
/// into two 4x8 (TX_4X8) leaves side by side (leaf 0 cols 0..3, leaf 1 cols
/// 4..7). Both are depth-0 rect tx.
///
/// On `start`, runs [HarborKeyframeModeWalk] (rootBsize 3, coeffPrefix, txLeaf)
/// over `bytes`. When it asserts done the per-leaf arrays are latched. HORZ vs
/// VERT is resolved from `leaf_log2size`: an 8x4 leaf emits pixel log2 3, a 4x8
/// leaf emits 2. The two rect leaves are reconstructed in order on a local 8x8
/// frame RAM, leaf 0 first so leaf 1 can read leaf 0's samples as neighbours
/// (HORZ: leaf 1 above row = leaf 0 bottom row, VERT: leaf 1 left column =
/// leaf 0 right column). The whole block's above/left neighbours come from
/// `above`/`left`/`above_left`, availability from `have_above`/`have_left`.
///
/// Above-right / below-left neighbours are unavailable (repeat) for an isolated
/// 8x8 SB, as [HarborIntraPredRect] implements.
///
/// Per leaf: predict -> rect inverse transform (TX_8X4 / TX_4X8 by leaf kind,
/// tx_type muxed from fixed-tx_type transforms) -> recon-add -> write the 8x8
/// frame RAM. A zero-coeff leaf yields all-zero residual, so recon = pred.
///
/// Ports: clk, reset, start, bytes (maxBytes*8), dc_q (16), ac_q (16),
/// have_above (1), have_left (1), above (8*8), left (8*8), above_left (8) ->
/// done, frame (512). Scope: one HORZ or VERT 8x8 SB, mono luma, depth-0 rect
/// tx. Out of scope: depth-1 rect-tx split, chroma.
class HarborKeyframeDecodeHorzVert extends BridgeModule {
  /// Maximum coded bytes the internal mode-walk buffer holds.
  final int maxBytes;

  /// Coeff-table q-band (0..3) for the mode walk's coeff decode.
  final int qband;

  // Rect tx_types a HORZ/VERT luma leaf can decode (ext-tx set DTT4_IDTX_1DDCT
  // -> {DCT_DCT, ADST_DCT, DCT_ADST, ADST_ADST, IDTX, V_DCT, H_DCT}). One fixed
  // inv-transform instance per kind per tx_type, the result muxed by the
  // decoded tx_type.
  static const _rectTxTypes = [0, 1, 2, 3, 9, 10, 11];

  HarborKeyframeDecodeHorzVert({
    this.maxBytes = 48,
    this.qband = 0,
    String? name,
  }) : assert(maxBytes > 0, 'maxBytes must be positive'),
       assert(qband >= 0 && qband < 4, 'qband 0..3'),
       super(
         'HarborKeyframeDecodeHorzVert',
         name: name ?? 'keyframe_decode_horzvert',
       ) {
    const f = 8; // 8x8 superblock
    const nPix = f * f; // 64

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
    addOutput('frame', width: nPix * 8);

    final clk = input('clk');
    final reset = input('reset');

    // mode walk (bytes -> per-leaf mode info + dequant rect coeffs)
    final walk = HarborKeyframeModeWalk(
      rootBsize: 3,
      maxBytes: maxBytes,
      coeffPrefix: true,
      txLeaf: true,
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

    // HORZ when leaf 0 is an 8x4 (pixel log2 3), VERT when 4x8 (pixel log2 2).
    final isHorz = l2Cap.getRange(0, 3).eq(Const(3, width: 3));

    // 8x8 frame RAM (reconstructed luma)
    final frame = [
      for (var i = 0; i < nPix; i++) Logic(name: 'f_$i', width: 8),
    ];

    // current leaf index (0 or 1).
    final leaf = Logic(name: 'leaf');

    // per-leaf y_mode / tx_type / coeffs, selected by the leaf index.
    Logic selLeaf(Logic packed, int w) =>
        mux(leaf, packed.getRange(w, 2 * w), packed.getRange(0, w));
    final yMode = selLeaf(ymCap, 4);
    final txType = selLeaf(ttCap, 4);
    final coeffsCur = selLeaf(coeffCap, 64 * 16); // 64 raster coeffs

    // leaf footprint (pixel origin + neighbour construction).
    // HORZ: 8 wide x 4 high, leaf0 py=0, leaf1 py=4 (both px=0).
    // VERT: 4 wide x 8 high, leaf0 px=0, leaf1 px=4 (both py=0).
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

    // have_above / have_left for THIS leaf. Block-edge availability comes from
    // the ports. An interior leaf gains availability from leaf 0's recon.
    //  HORZ leaf0: above = block above (have_above), left = block left.
    //  HORZ leaf1: above = leaf0 bottom row (always avail), left = block left.
    //  VERT leaf0: above = block above, left = block left (have_left).
    //  VERT leaf1: above = block above, left = leaf0 right col (always avail).
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

    // Frame read at (row, col).
    Logic frameAt(int row, int col) => frame[row * f + col];

    // above neighbour samples (block width = 8 max, rect uses bw entries).
    //  HORZ leaf0: block above row (above port, cols 0..7).
    //  HORZ leaf1: leaf0 recon bottom row (frame row 3, cols 0..7).
    //  VERT leaf0: block above row (above port, cols 0..3).
    //  VERT leaf1: block above row (above port, cols 4..7).
    Logic abovePort(int i) => input('above').getRange(i * 8, i * 8 + 8);
    Logic leftPort(int i) => input('left').getRange(i * 8, i * 8 + 8);

    // above[i] for the current leaf (i in 0..bw-1). bw is 8 (HORZ) or 4 (VERT),
    // but we wire a width-8 above bus and the predictor reads only bw entries.
    // Only the first bw entries are read per kind (HORZ bw=8, VERT bw=4), so
    // the VERT leaf1 source `abovePort(4 + i)` is referenced only for i < 4.
    // Clamp the constant index for i >= 4 (never selected on the VERT path) so
    // the build-time getRange stays in the 8-wide above bus.
    final aboveSel = <Logic>[
      for (var i = 0; i < f; i++)
        mux(
          isHorz,
          // HORZ: leaf0 above port col i, leaf1 frame row 3 col i.
          mux(isLeaf1, frameAt(3, i), abovePort(i)),
          // VERT: above port col (px + i). px is 0 (leaf0) or 4 (leaf1).
          mux(isLeaf1, abovePort(i < 4 ? 4 + i : i), abovePort(i)),
        ),
    ];

    // left[i] for the current leaf (i in 0..bh-1). bh is 4 (HORZ) or 8 (VERT).
    //  HORZ leaf0: block left rows 0..3 (left port).
    //  HORZ leaf1: block left rows 4..7 (left port).
    //  VERT leaf0: block left rows 0..7 (left port).
    //  VERT leaf1: leaf0 recon right column (frame col 3, rows 0..7).
    // Only the first bh entries are read per kind (HORZ bh=4, VERT bh=8), so
    // the HORZ leaf1 source `leftPort(4 + i)` is referenced only for i < 4.
    final leftSel = <Logic>[
      for (var i = 0; i < f; i++)
        mux(
          isHorz,
          // HORZ: leaf0 left rows 0..3, leaf1 left rows 4..7.
          mux(isLeaf1, leftPort(i < 4 ? 4 + i : i), leftPort(i)),
          // VERT: leaf0 left port rows 0..7, leaf1 frame col 3 rows 0..7.
          mux(isLeaf1, frameAt(i, 3), leftPort(i)),
        ),
    ];

    // corner (above-left) for the current leaf.
    //  HORZ leaf0: block above_left (have_above & have_left).
    //  HORZ leaf1: leaf0 recon (frame row 3, col -1) = block left row 3.
    //  VERT leaf0: block above_left.
    //  VERT leaf1: leaf0 recon (frame row -1, col 3) = block above col 3.
    final cornerSel = mux(
      isHorz,
      mux(isLeaf1, leftPort(3), input('above_left')),
      mux(isLeaf1, abovePort(3), input('above_left')),
    );

    // rectangular predictor: one 8x4 + one 4x8 instance.
    // 8x4 (HORZ): above = 8 wide, left = 4 high.
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

    // 4x8 (VERT): above = 4 wide, left = 8 high.
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
    // coeffsCur is laid out in the leaf 64-slot raster: HORZ 8x4 occupies a
    // 4-row x 8-col raster (slots (r*8+c), r<4, c<8), VERT 4x8 an 8-row x 4-col
    // raster (slots (r*4+c), r<8, c<4). The rect transform expects (r, c) at
    // [(r*W + c)*16], W = 8 (8x4) or 4 (4x8). Both already match the leaf
    // raster's element order, so the low 32 coeffs feed directly.
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
    // select the active residual (32 elements) by kind + tx_type.
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
    // tx done: all fixed transforms share txStart and run identically, so any
    // one tracks completion. Pick the active kind's selected one.
    final txDone = mux(isHorz, done84.first, done48.first);

    // a zero-coeff leaf has all coeffs 0, so the transform yields all zeros and
    // recon-add naturally gives pred. No explicit residual gate is needed.

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

    // FSM
    const sIdle = 0,
        sRunMode = 1,
        sLatch = 2,
        sPred = 3,
        sTxWait = 4,
        sWrite = 5,
        sDone = 6;
    final st = Logic(name: 'st', width: 3);
    output('done') <= st.eq(Const(sDone, width: 3));
    output('frame') <= [for (var i = nPix - 1; i >= 0; i--) frame[i]].concat();

    Combinational([
      walkStart < Const(0),
      txStart < Const(0),
      Case(st, [
        CaseItem(Const(sIdle, width: 3), [
          If(input('start'), then: [walkStart < Const(1)]),
        ]),
        CaseItem(Const(sPred, width: 3), [txStart < Const(1)]),
      ]),
    ]);

    // write-back: for each frame pixel k, if it lies in the current leaf's rect
    // footprint, write the matching recon sample (kind-selected).
    final kr = [for (var k = 0; k < nPix; k++) k ~/ f];
    final kc = [for (var k = 0; k < nPix; k++) k % f];
    List<Conditional> writeBack() {
      final conds = <Conditional>[];
      for (var k = 0; k < nPix; k++) {
        // HORZ footprint: rows [py, py+4), cols [0, 8), local (kr-py)*8 + kc.
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
        // VERT footprint: cols [px, px+4), rows [0, 8), local kr*4 + (kc-px).
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
          st < Const(sIdle, width: 3),
          leaf < Const(0),
          l2Cap < Const(0, width: 4 * 3),
          ymCap < Const(0, width: 4 * 4),
          ttCap < Const(0, width: 4 * 4),
          coeffCap < Const(0, width: 4 * 64 * 16),
          for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: 8),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  leaf < Const(0),
                  for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: 8),
                  st < Const(sRunMode, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sRunMode, width: 3), [
              If(walk.output('done'), then: [st < Const(sLatch, width: 3)]),
            ]),
            CaseItem(Const(sLatch, width: 3), [
              l2Cap < walk.output('leaf_log2size'),
              ymCap < walk.output('leaf_ymodes'),
              ttCap < walk.output('leaf_txtypes'),
              coeffCap < walk.output('leaf_coeffs'),
              st < Const(sPred, width: 3),
            ]),
            CaseItem(Const(sPred, width: 3), [st < Const(sTxWait, width: 3)]),
            CaseItem(Const(sTxWait, width: 3), [
              If(txDone, then: [st < Const(sWrite, width: 3)]),
            ]),
            CaseItem(Const(sWrite, width: 3), [
              ...writeBack(),
              If(
                leaf.eq(Const(1)),
                then: [st < Const(sDone, width: 3)],
                orElse: [leaf < Const(1), st < Const(sPred, width: 3)],
              ),
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

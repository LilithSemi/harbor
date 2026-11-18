import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_pred_avail.dart';
import 'inv_txfm.dart';
import 'recon_add.dart';

/// Harbor keyframe RECON-side frame assembly: a `gridN` x `gridN` grid of 4x4
/// intra luma blocks reconstructed in raster order into a frame-buffer RAM, each
/// block predicting from its already-reconstructed neighbours (the cross-block
/// neighbour propagation the full tile decoder needs).
///
/// Per block (raster order): read the above row / left column / corner from the
/// frame RAM (availability from the block's grid position), intra-predict via
/// [HarborIntraPredAvail] using the block's `y_mode`, inverse-transform the
/// block's `coeffs` by its `tx_type` ([HarborInvTxfm] runtime), add + clip, and
/// write the 4x4 result back to the frame RAM. The coefficients/modes are inputs
/// (decoded elsewhere). This isolates and proves the recon walk + frame RAM +
/// neighbour propagation, time-multiplexing ONE transform / predictor / adder.
///
/// Inputs pack per block b (b = row*gridN + col): `y_modes` at `[b*4 +: 4]`,
/// `tx_types` at `[b*4 +: 4]`, `coeffs` at `[b*256 +: 256]` (16 signed 16-bit,
/// row-major). `frame` output is the F x F luma plane (F = 4*gridN), pixel
/// (r, c) at `[(r*F + c)*8 +: 8]`. Pulse `start`, `done` asserts with `frame`.
class HarborKeyframeReconGrid extends BridgeModule {
  /// Blocks per side (grid is gridN x gridN of 4x4 blocks).
  final int gridN;

  HarborKeyframeReconGrid({this.gridN = 2, String? name})
    : assert(gridN >= 1 && gridN <= 4, 'gridN 1..4'),
      super('HarborKeyframeReconGrid', name: name ?? 'kf_recon_grid_$gridN') {
    final nBlk = gridN * gridN;
    final f = 4 * gridN; // frame side in pixels
    final nPix = f * f;
    final blkW = (nBlk).bitLength;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('y_modes', PortDirection.input, width: nBlk * 4);
    createPort('tx_types', PortDirection.input, width: nBlk * 4);
    createPort('coeffs', PortDirection.input, width: nBlk * 256);
    addOutput('done');
    addOutput('frame', width: nPix * 8);

    final clk = input('clk');
    final reset = input('reset');

    // Frame-buffer RAM.
    final frame = [
      for (var i = 0; i < nPix; i++) Logic(name: 'f_$i', width: 8),
    ];
    final blk = Logic(name: 'blk', width: blkW);

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

    Logic selFrame(Logic idx) {
      Logic v = frame.last;
      for (var i = nPix - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), frame[i], v);
      }
      return v;
    }

    // block row/col by raster index.
    final brTab = [for (var b = 0; b < nBlk; b++) b ~/ gridN];
    final bcTab = [for (var b = 0; b < nBlk; b++) b % gridN];
    const iw =
        8; // index width for frame linear addressing (f<=16 -> nPix<=256)
    final br = romSel(brTab, blk, iw);
    final bc = romSel(bcTab, blk, iw);
    final py = (br * Const(4, width: iw)).getRange(0, iw); // top pixel row
    final px = (bc * Const(4, width: iw)).getRange(0, iw);
    final haveA = br.gt(Const(0, width: iw));
    final haveL = bc.gt(Const(0, width: iw));

    // neighbour reads (gated by availability in the predictor).
    Logic frameAt(Logic row, Logic col) =>
        selFrame((row * Const(f, width: iw) + col).getRange(0, iw));
    final aboveRow = (py - Const(1, width: iw)).getRange(0, iw);
    final leftCol = (px - Const(1, width: iw)).getRange(0, iw);
    final above = [
      for (var i = 0; i < 4; i++)
        frameAt(aboveRow, (px + Const(i, width: iw)).getRange(0, iw)),
    ];
    final left = [
      for (var i = 0; i < 4; i++)
        frameAt((py + Const(i, width: iw)).getRange(0, iw), leftCol),
    ];
    final corner = frameAt(aboveRow, leftCol);

    // current-block mode / tx_type / coeffs (select by blk).
    Logic selSlice(String port, int w) {
      Logic v = input(port).getRange((nBlk - 1) * w, nBlk * w);
      for (var b = nBlk - 2; b >= 0; b--) {
        v = mux(
          blk.eq(Const(b, width: blkW)),
          input(port).getRange(b * w, b * w + w),
          v,
        );
      }
      return v;
    }

    final yMode = selSlice('y_modes', 4);
    final txType = selSlice('tx_types', 4);
    final coeffsCur = selSlice('coeffs', 256);

    // predictor (combinational).
    final pred = HarborIntraPredAvail(bs: 4, name: 'pred');
    addSubModule(pred);
    pred.input('mode').srcConnection! <= yMode;
    pred.input('have_above').srcConnection! <= haveA;
    pred.input('have_left').srcConnection! <= haveL;
    pred.input('above').srcConnection! <=
        [for (var i = 3; i >= 0; i--) above[i]].concat();
    pred.input('left').srcConnection! <=
        [for (var i = 3; i >= 0; i--) left[i]].concat();
    pred.input('above_left').srcConnection! <= corner;

    // transform (runtime tx_type, sequential).
    final tx = HarborInvTxfm(
      txSize: 0,
      txType: 0,
      runtimeTxType: true,
      name: 'tx',
    );
    addSubModule(tx);
    final txStart = Logic(name: 'tx_start');
    tx.input('clk').srcConnection! <= clk;
    tx.input('reset').srcConnection! <= reset;
    tx.input('start').srcConnection! <= txStart;
    tx.input('coeffs').srcConnection! <= coeffsCur;
    tx.input('tx_type').srcConnection! <= txType;

    // recon add (combinational).
    final ra = HarborReconAdd(n: 16, name: 'ra');
    addSubModule(ra);
    ra.input('pred').srcConnection! <= pred.output('pred');
    ra.input('residual').srcConnection! <= tx.output('residual');
    final recon = ra.output('recon');
    Logic reconPix(int li) => recon.getRange(li * 8, li * 8 + 8);

    const sIdle = 0, sPred = 1, sTxWait = 2, sWrite = 3, sDone = 4;
    final st = Logic(name: 'st', width: 3);
    output('done') <= st.eq(Const(sDone, width: 3));
    output('frame') <= [for (var i = nPix - 1; i >= 0; i--) frame[i]].concat();

    Combinational([
      txStart < Const(0),
      Case(st, [
        CaseItem(Const(sPred, width: 3), [txStart < Const(1)]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          blk < Const(0, width: blkW),
          for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: 8),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  blk < Const(0, width: blkW),
                  for (var i = 0; i < nPix; i++) frame[i] < Const(0, width: 8),
                  st < Const(sPred, width: 3),
                ],
              ),
            ]),
            // sPred pulses txStart (combinational). pred is combinational.
            CaseItem(Const(sPred, width: 3), [st < Const(sTxWait, width: 3)]),
            CaseItem(Const(sTxWait, width: 3), [
              If(tx.output('done'), then: [st < Const(sWrite, width: 3)]),
            ]),
            CaseItem(Const(sWrite, width: 3), [
              // write the 4x4 recon into this block's footprint.
              for (var k = 0; k < nPix; k++)
                If(
                  Const(k ~/ f ~/ 4, width: iw).eq(br) &
                      Const(k % f ~/ 4, width: iw).eq(bc),
                  then: [frame[k] < reconPix((k ~/ f % 4) * 4 + (k % f % 4))],
                ),
              If(
                blk.eq(Const(nBlk - 1, width: blkW)),
                then: [st < Const(sDone, width: 3)],
                orElse: [
                  blk < (blk + Const(1, width: blkW)),
                  st < Const(sPred, width: 3),
                ],
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

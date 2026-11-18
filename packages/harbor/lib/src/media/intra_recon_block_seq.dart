import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_pred_row.dart';
import 'inv_txfm.dart';

/// Harbor SEQUENTIAL single-block intra reconstruction: reconstructs one square
/// `bs` x `bs` intra block (predict + inverse transform + add/clip) ROW BY ROW,
/// so the flat combinational build cost that explodes at bs >= 32 (the O(bs^2)
/// predictor multipliers + O(bs^2) writeback) collapses to O(bs) predictor work
/// per cycle. The block is reconstructed over ~bs cycles after the transform
/// finishes.
///
/// Pipeline: on `start`, pulse [HarborInvTxfm] (runtime tx_type for bs <= 16,
/// fixed DCT for bs = 32, which is EXT_TX_SET_DCTONLY); when it asserts done,
/// sweep `row` 0..bs-1 through [HarborIntraPredRow], adding the size-selected
/// residual row and clipping, writing each recon row into the block RAM. `done`
/// asserts with the full `block`.
///
/// Ports: clk, reset, start, mode (4b), have_above / have_left (1b), above /
/// left (`bs` px, 8b), above_left (8b), coeffs (`bs*bs` signed 16b, row-major),
/// tx_type (4b, only for bs <= 16) -> done, block (`bs*bs` px, 8b, pixel (r,c)
/// at `[(r*bs+c)*8 +: 8]`).
class HarborIntraReconBlockSeq extends BridgeModule {
  /// Square block size (4, 8, 16, 32).
  final int bs;

  HarborIntraReconBlockSeq({required this.bs, String? name})
    : assert(
        bs == 4 || bs == 8 || bs == 16 || bs == 32 || bs == 64,
        'bs in {4,8,16,32,64}',
      ),
      super(
        'HarborIntraReconBlockSeq',
        name: name ?? 'intra_recon_block_seq_$bs',
      ) {
    final rowBits = (bs - 1).bitLength;
    final txSize = bs.bitLength - 3; // 4->0, 8->1, 16->2, 32->3
    final rtt = txSize <= 2; // runtime tx_type only for 4/8/16

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('mode', PortDirection.input, width: 4);
    createPort('have_above', PortDirection.input);
    createPort('have_left', PortDirection.input);
    createPort('above', PortDirection.input, width: bs * 8);
    createPort('left', PortDirection.input, width: bs * 8);
    createPort('above_left', PortDirection.input, width: 8);
    createPort('coeffs', PortDirection.input, width: bs * bs * 16);
    if (rtt) createPort('tx_type', PortDirection.input, width: 4);
    addOutput('done');
    addOutput('block', width: bs * bs * 8);

    final clk = input('clk');
    final reset = input('reset');

    // Row counter drives the predictor + residual-row select each cycle.
    final rowc = Logic(name: 'rowc', width: rowBits);

    // Predictor (combinational, one row for the runtime rowc).
    final pred = HarborIntraPredRow(bs: bs, name: 'pred');
    addSubModule(pred);
    pred.input('mode').srcConnection! <= input('mode');
    pred.input('have_above').srcConnection! <= input('have_above');
    pred.input('have_left').srcConnection! <= input('have_left');
    pred.input('above').srcConnection! <= input('above');
    pred.input('left').srcConnection! <= input('left');
    pred.input('above_left').srcConnection! <= input('above_left');
    pred.input('row').srcConnection! <= rowc;
    final predRow = pred.output('pred_row'); // bs*8

    // Inverse transform (sequential). Produces the full residual block.
    final txStart = Logic(name: 'tx_start');
    final tx = HarborInvTxfm(
      txSize: txSize,
      txType: 0,
      runtimeTxType: rtt,
      name: 'tx',
    );
    addSubModule(tx);
    tx.input('clk').srcConnection! <= clk;
    tx.input('reset').srcConnection! <= reset;
    tx.input('start').srcConnection! <= txStart;
    tx.input('coeffs').srcConnection! <= input('coeffs');
    if (rtt) tx.input('tx_type').srcConnection! <= input('tx_type');
    final residual = tx.output('residual'); // bs*bs signed 16b, row-major

    // residual row for the runtime rowc: residual[rowc*bs + c] per column c.
    Logic residualAt(int c) {
      Logic v = residual.getRange(
        ((bs - 1) * bs + c) * 16,
        ((bs - 1) * bs + c) * 16 + 16,
      );
      for (var r = bs - 2; r >= 0; r--) {
        v = mux(
          rowc.eq(Const(r, width: rowBits)),
          residual.getRange((r * bs + c) * 16, (r * bs + c) * 16 + 16),
          v,
        );
      }
      return v;
    }

    // recon_row[c] = clip(pred_row[c] + residual_row[c], 0, 255).
    List<Logic> reconRow() {
      final out = <Logic>[];
      for (var c = 0; c < bs; c++) {
        final p = predRow.getRange(c * 8, c * 8 + 8).zeroExtend(18);
        final res = residualAt(c); // 16b two's complement
        final sum = (p + [res[15].replicate(2), res].concat()).getRange(0, 18);
        // signed clip to [0, 255]: negative -> 0, > 255 -> 255.
        final neg = sum[17];
        final big = sum.getRange(8, 18).or(); // any bit >= 8 set -> > 255
        out.add(
          mux(
            neg,
            Const(0, width: 8),
            mux(big, Const(255, width: 8), sum.getRange(0, 8)),
          ),
        );
      }
      return out;
    }

    final rr = reconRow();

    // Block RAM: each flop knows its (row, col) at build time, so it writes
    // rr[col] directly when rowc == its row (no per-flop mux).
    final blk = [
      for (var i = 0; i < bs * bs; i++) Logic(name: 'b_$i', width: 8),
    ];
    output('block') <= [for (var i = bs * bs - 1; i >= 0; i--) blk[i]].concat();

    const sIdle = 0, sTxWait = 1, sRows = 2, sDone = 3;
    final st = Logic(name: 'st', width: 2);
    output('done') <= st.eq(Const(sDone, width: 2));

    Combinational([
      txStart < Const(0),
      Case(st, [
        CaseItem(Const(sIdle, width: 2), [
          If(input('start'), then: [txStart < Const(1)]),
        ]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 2),
          rowc < Const(0, width: rowBits),
          for (var i = 0; i < bs * bs; i++) blk[i] < Const(0, width: 8),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 2), [
              If(
                input('start'),
                then: [
                  rowc < Const(0, width: rowBits),
                  st < Const(sTxWait, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(sTxWait, width: 2), [
              If(tx.output('done'), then: [st < Const(sRows, width: 2)]),
            ]),
            CaseItem(Const(sRows, width: 2), [
              // write the current recon row into the block RAM.
              for (var r = 0; r < bs; r++)
                for (var c = 0; c < bs; c++)
                  If(
                    rowc.eq(Const(r, width: rowBits)),
                    then: [blk[r * bs + c] < rr[c]],
                  ),
              If(
                rowc.eq(Const(bs - 1, width: rowBits)),
                then: [st < Const(sDone, width: 2)],
                orElse: [
                  rowc < (rowc + Const(1, width: rowBits)).getRange(0, rowBits),
                ],
              ),
            ]),
            CaseItem(Const(sDone, width: 2), [
              If(~input('start'), then: [st < Const(sIdle, width: 2)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

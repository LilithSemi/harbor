import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_block_decode.dart';
import 'reconstruct4.dart';

/// Harbor end-to-end intra decode of a row of 4x4 blocks (bitstream -> pixels).
///
/// The full intra-decode pipeline on a simple geometry: a horizontal strip of
/// [blocks] 4x4 blocks decoded from ONE entropy stream (mode + coefficients,
/// persistent adaptive CDFs via the block decoder's `next_blk`) and
/// reconstructed in order. Each block predicts from its real left neighbour (the
/// previous block's right column) with the top row off-frame (default 128), then
/// adds the dequantized inverse-transformed residual. The reconstructed pixels
/// land in `frame` (4 rows x blocks*4 columns).
///
/// Demonstrates that decoded syntax becomes pixels: entropy decode ->
/// dequant -> inverse DCT -> intra predict -> reconstructed frame. `frame` packs
/// pixel (r, x) at `[(r*(blocks*4) + x)*8 +: 8]`. Pulse `start`. `done` asserts
/// when the row is reconstructed. CDF/mode/quant fidelity follow the underlying
/// modules' simplifications.
class HarborDecodeRowIntra extends BridgeModule {
  HarborDecodeRowIntra({int blocks = 4, String? name})
    : super('HarborDecodeRowIntra', name: name ?? 'decode_row') {
    final fw = blocks * 4; // frame width in pixels
    final gcW = (blocks + 1).bitLength;

    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('start', PortDirection.input, width: 1);
    createPort('bytes_in', PortDirection.input, width: 24);
    createPort('dc_q', PortDirection.input, width: 8);
    createPort('ac_q', PortDirection.input, width: 8);
    addOutput('byte_pop', width: 2);
    addOutput('frame', width: fw * 4 * 8);
    addOutput('done', width: 1);

    final clk = input('clk');
    final reset = input('reset');

    final state = Logic(name: 'f_state', width: 2);
    final gc = Logic(name: 'gc', width: gcW); // current block column
    final leftCol = [
      for (var r = 0; r < 4; r++) Logic(name: 'left$r', width: 8),
    ];
    final frame = [
      for (var i = 0; i < fw * 4; i++) Logic(name: 'fpx$i', width: 8),
    ];

    const fIdle = 0, fDecode = 1, fStore = 2, fDone = 3;

    // Block decoder (mode + coeffs, continuing stream).
    final blk = HarborIntraBlockDecode(name: 'blk');
    addSubModule(blk);
    blk.input('clk').srcConnection! <= clk;
    blk.input('reset').srcConnection! <= reset;
    blk.input('start').srcConnection! <=
        (state.eq(Const(fIdle, width: 2)) & input('start'));
    blk.input('next_blk').srcConnection! <=
        (state.eq(Const(fStore, width: 2)) &
            ~gc.eq(Const(blocks - 1, width: gcW)));
    blk.input('bytes_in').srcConnection! <= input('bytes_in');
    blk.input('coeff_addr').srcConnection! <= Const(0, width: 5);
    output('byte_pop') <= blk.output('byte_pop');

    // Reconstruct (dequant + inverse DCT + intra predict).
    final rec = HarborReconstruct4(name: 'rec');
    addSubModule(rec);
    rec.input('coeffs').srcConnection! <= blk.output('coeffs_out');
    rec.input('dc_q').srcConnection! <= input('dc_q');
    rec.input('ac_q').srcConnection! <= input('ac_q');
    // Intra mode: map the decoded y_mode (0..12) into the predictor's 3-bit set.
    rec.input('mode').srcConnection! <= blk.output('y_mode').getRange(0, 3);
    // Neighbours: top off-frame (128), left = previous block's right column.
    final firstCol = gc.eq(Const(0, width: gcW));
    final aboveBus = [
      for (var i = 0; i < 8; i++) Const(128, width: 8),
    ].concat();
    final leftBus = [
      for (var i = 7; i >= 0; i--)
        (i < 4
            ? mux(firstCol, Const(128, width: 8), leftCol[i])
            : Const(128, width: 8)),
    ].concat();
    rec.input('above').srcConnection! <= aboveBus;
    rec.input('left').srcConnection! <= leftBus;
    rec.input('above_left').srcConnection! <= Const(128, width: 8);
    Logic recon(int r, int c) =>
        rec.output('recon').getRange((r * 8 + c) * 8, (r * 8 + c) * 8 + 8);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(fIdle, width: 2),
          gc < Const(0, width: gcW),
          for (final l in leftCol) l < Const(128, width: 8),
          for (final f in frame) f < Const(0, width: 8),
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(fIdle, width: 2), [
              If(
                input('start'),
                then: [
                  gc < Const(0, width: gcW),
                  state < Const(fDecode, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(fDecode, width: 2), [
              If(blk.output('done'), then: [state < Const(fStore, width: 2)]),
            ]),
            CaseItem(Const(fStore, width: 2), [
              // Write this block's reconstructed 4x4 into the frame and capture
              // its right column for the next block's left neighbour.
              for (var r = 0; r < 4; r++) ...[
                for (var c = 0; c < 4; c++) ...[
                  for (var col = 0; col < blocks; col++)
                    If(
                      gc.eq(Const(col, width: gcW)),
                      then: [frame[r * fw + col * 4 + c] < recon(r, c)],
                    ),
                ],
                leftCol[r] < recon(r, 3),
              ],
              If(
                gc.eq(Const(blocks - 1, width: gcW)),
                then: [state < Const(fDone, width: 2)],
                orElse: [
                  gc < (gc + Const(1, width: gcW)).getRange(0, gcW),
                  state < Const(fDecode, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(fDone, width: 2), [state < Const(fDone, width: 2)]),
          ]),
        ],
      ),
    ]);

    output('frame') <=
        [for (var i = fw * 4 - 1; i >= 0; i--) frame[i]].concat();
    output('done') <= state.eq(Const(fDone, width: 2));
  }
}

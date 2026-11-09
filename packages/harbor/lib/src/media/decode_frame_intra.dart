import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'intra_block_decode.dart';
import 'reconstruct4.dart';

/// Harbor end-to-end intra frame decode (bitstream -> a 2D picture).
///
/// Extends the row decoder to a full 2D grid of [gridW] x [gridH] 4x4 blocks.
/// Blocks are decoded in raster order from ONE entropy stream (persistent
/// adaptive CDFs) and reconstructed against their real neighbours: the left
/// column comes from the previous block in the row, and the above row comes from
/// the bottom row of the block above (kept in an `aboveRow` line buffer that is
/// refreshed from `botRow` at each row boundary, the standard intra
/// neighbour-line approach, no full-frame mux). Off-frame neighbours default to
/// 128.
///
/// `frame` packs pixel (y, x) at `[(y*W + x)*8 +: 8]` with W = gridW*4. Pulse
/// `start`. `done` asserts when the picture is reconstructed. This is a complete
/// (simplified-fidelity) intra picture decoder: bitstream -> entropy ->
/// dequant -> inverse DCT -> intra predict -> reconstructed frame.
class HarborDecodeFrameIntra extends BridgeModule {
  HarborDecodeFrameIntra({int gridW = 4, int gridH = 4, String? name})
    : super('HarborDecodeFrameIntra', name: name ?? 'decode_frame') {
    final fw = gridW * 4;
    final fh = gridH * 4;
    final gcW = (gridW + 1).bitLength;
    final grW = (gridH + 1).bitLength;

    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('start', PortDirection.input, width: 1);
    createPort('bytes_in', PortDirection.input, width: 24);
    createPort('dc_q', PortDirection.input, width: 8);
    createPort('ac_q', PortDirection.input, width: 8);
    addOutput('byte_pop', width: 2);
    addOutput('frame', width: fw * fh * 8);
    addOutput('done', width: 1);

    final clk = input('clk');
    final reset = input('reset');

    final state = Logic(name: 'f_state', width: 2);
    final gc = Logic(name: 'gc', width: gcW);
    final gr = Logic(name: 'gr', width: grW);
    final leftCol = [for (var r = 0; r < 4; r++) Logic(name: 'lc$r', width: 8)];
    final aboveRow = [
      for (var x = 0; x < fw; x++) Logic(name: 'ar$x', width: 8),
    ];
    final botRow = [for (var x = 0; x < fw; x++) Logic(name: 'br$x', width: 8)];
    final frame = [
      for (var i = 0; i < fw * fh; i++) Logic(name: 'fp$i', width: 8),
    ];

    const fIdle = 0, fDecode = 1, fStore = 2, fDone = 3;

    final firstCol = gc.eq(Const(0, width: gcW));
    final firstRow = gr.eq(Const(0, width: grW));
    final lastCol = gc.eq(Const(gridW - 1, width: gcW));
    final lastRow = gr.eq(Const(gridH - 1, width: grW));

    final blk = HarborIntraBlockDecode(name: 'blk');
    addSubModule(blk);
    blk.input('clk').srcConnection! <= clk;
    blk.input('reset').srcConnection! <= reset;
    blk.input('start').srcConnection! <=
        (state.eq(Const(fIdle, width: 2)) & input('start'));
    // Continue the stream for every block after the first (not the last store).
    final atLast = lastCol & lastRow;
    blk.input('next_blk').srcConnection! <=
        (state.eq(Const(fStore, width: 2)) & ~atLast);
    blk.input('bytes_in').srcConnection! <= input('bytes_in');
    blk.input('coeff_addr').srcConnection! <= Const(0, width: 5);
    output('byte_pop') <= blk.output('byte_pop');

    // Select an aboveRow pixel at column (gc*4 + c) via a mux over gc.
    Logic aboveAt(int c) {
      Logic out = Const(128, width: 8);
      for (var g = 0; g < gridW; g++) {
        final x = g * 4 + c;
        if (x < fw) {
          out = mux(gc.eq(Const(g, width: gcW)), aboveRow[x], out);
        }
      }
      return mux(firstRow, Const(128, width: 8), out);
    }

    Logic aboveLeftPix() {
      Logic out = Const(128, width: 8);
      for (var g = 1; g < gridW; g++) {
        final x = g * 4 - 1;
        out = mux(gc.eq(Const(g, width: gcW)), aboveRow[x], out);
      }
      return mux(firstRow | firstCol, Const(128, width: 8), out);
    }

    final rec = HarborReconstruct4(name: 'rec');
    addSubModule(rec);
    rec.input('coeffs').srcConnection! <= blk.output('coeffs_out');
    rec.input('dc_q').srcConnection! <= input('dc_q');
    rec.input('ac_q').srcConnection! <= input('ac_q');
    rec.input('mode').srcConnection! <= blk.output('y_mode').getRange(0, 3);
    rec.input('above').srcConnection! <=
        [for (var c = 7; c >= 0; c--) aboveAt(c)].concat();
    rec.input('left').srcConnection! <=
        [
          for (var r = 7; r >= 0; r--)
            (r < 4
                ? mux(firstCol, Const(128, width: 8), leftCol[r])
                : Const(128, width: 8)),
        ].concat();
    rec.input('above_left').srcConnection! <= aboveLeftPix();
    Logic recon(int r, int c) =>
        rec.output('recon').getRange((r * 8 + c) * 8, (r * 8 + c) * 8 + 8);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(fIdle, width: 2),
          gc < Const(0, width: gcW),
          gr < Const(0, width: grW),
          for (final l in leftCol) l < Const(128, width: 8),
          for (final a in aboveRow) a < Const(128, width: 8),
          for (final b in botRow) b < Const(128, width: 8),
          for (final f in frame) f < Const(0, width: 8),
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(fIdle, width: 2), [
              If(
                input('start'),
                then: [
                  gc < Const(0, width: gcW),
                  gr < Const(0, width: grW),
                  state < Const(fDecode, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(fDecode, width: 2), [
              If(blk.output('done'), then: [state < Const(fStore, width: 2)]),
            ]),
            CaseItem(Const(fStore, width: 2), [
              // Write the reconstructed 4x4 into the frame, update the left column
              // and this row's bottom-row line buffer.
              for (var r = 0; r < 4; r++) ...[
                for (var c = 0; c < 4; c++)
                  for (var g = 0; g < gridW; g++)
                    for (var rg = 0; rg < gridH; rg++)
                      If(
                        gc.eq(Const(g, width: gcW)) &
                            gr.eq(Const(rg, width: grW)),
                        then: [
                          frame[(rg * 4 + r) * fw + g * 4 + c] < recon(r, c),
                        ],
                      ),
                leftCol[r] < recon(r, 3),
              ],
              for (var c = 0; c < 4; c++)
                for (var g = 0; g < gridW; g++)
                  If(
                    gc.eq(Const(g, width: gcW)),
                    then: [botRow[g * 4 + c] < recon(3, c)],
                  ),
              If(
                atLast,
                then: [state < Const(fDone, width: 2)],
                orElse: [
                  If(
                    lastCol,
                    then: [
                      // Row boundary: the next aboveRow is this row's bottom. Earlier
                      // blocks come from botRow. The current (last) block's bottom is
                      // written this same cycle, so take it from recon directly.
                      for (var x = 0; x < fw; x++)
                        if (x >= (gridW - 1) * 4)
                          aboveRow[x] < recon(3, x - (gridW - 1) * 4)
                        else
                          aboveRow[x] < botRow[x],
                      for (final l in leftCol) l < Const(128, width: 8),
                      gc < Const(0, width: gcW),
                      gr < (gr + Const(1, width: grW)).getRange(0, grW),
                    ],
                    orElse: [gc < (gc + Const(1, width: gcW)).getRange(0, gcW)],
                  ),
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
        [for (var i = fw * fh - 1; i >= 0; i--) frame[i]].concat();
    output('done') <= state.eq(Const(fDone, width: 2));
  }
}

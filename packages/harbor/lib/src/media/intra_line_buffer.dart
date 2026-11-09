import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor intra-prediction neighbour line buffer.
///
/// Instead of re-fetching reconstructed neighbours from memory for every block,
/// a decoder keeps them on chip. As blocks are reconstructed in raster order
/// (left to right, top to bottom) this buffer holds, per block column, the
/// bottom row of the block above (the "above" neighbours for the block below),
/// plus the right column of the block just to the left (the "left" neighbours)
/// and the above-left corner.
///
/// The corner needs care: the above-left of the block at column `p+1` is the
/// row-above bottom-right pixel of block `p`, but storing the current row's
/// block `p` overwrites that slot. A one-entry delay register (`cornerReg`)
/// captures the old value at store time so it survives for the next block, the
/// classic line-buffer top-left delay.
///
/// Block storage is at block-column granularity: each slot holds a full 8-pixel
/// bottom row. 4x4 blocks use the low four. `size` selects 4x4 or 8x8.
class HarborIntraLineBuffer extends BridgeModule {
  /// Pixel bit depth.
  final int bitDepth;

  /// Number of block columns the line buffer spans (frame width / block).
  final int maxBlockCols;

  int get pixWidth => bitDepth;

  HarborIntraLineBuffer({
    this.bitDepth = 8,
    this.maxBlockCols = 8,
    String? name,
  }) : super('HarborIntraLineBuffer', name: name ?? 'intra_linebuf') {
    final pw = pixWidth;
    final colW = maxBlockCols <= 1 ? 1 : (maxBlockCols - 1).bitLength;
    // Default neighbour value for unavailable edges (AV1 uses 1 << (bd-1)).
    final fill = 1 << (bitDepth - 1);

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('size', PortDirection.input); // 0 = 4x4, 1 = 8x8
    createPort('bw_col', PortDirection.input, width: colW);
    createPort('store', PortDirection.input); // commit a completed block
    createPort(
      'new_row',
      PortDirection.input,
    ); // reset left/corner at row start
    createPort('block_bottom', PortDirection.input, width: 8 * pw);
    createPort('block_right', PortDirection.input, width: 8 * pw);
    addOutput('above', width: 8 * pw);
    addOutput('left', width: 8 * pw);
    addOutput('above_left', width: pw);

    final clk = input('clk');
    final reset = input('reset');
    final size8 = input('size');
    final bwCol = input('bw_col');
    final store = input('store');
    final newRow = input('new_row');
    final blockBottom = input('block_bottom');
    final blockRight = input('block_right');

    // Per-block-column slots holding the bottom row of the block above.
    final slot = [
      for (var i = 0; i < maxBlockCols; i++)
        Logic(name: 'slot_$i', width: 8 * pw),
    ];
    final leftReg = Logic(name: 'left_reg', width: 8 * pw);
    final cornerReg = Logic(name: 'corner_reg', width: pw);

    // Selects slot[bw_col].
    Logic selSlot() {
      Logic v = slot.last;
      for (var i = maxBlockCols - 2; i >= 0; i--) {
        v = mux(bwCol.eq(Const(i, width: colW)), slot[i], v);
      }
      return v;
    }

    final curSlot = selSlot();
    // Old bottom-right pixel of the addressed block: above-left of the next.
    final slotLast = mux(
      size8,
      curSlot.getRange(7 * pw, 8 * pw),
      curSlot.getRange(3 * pw, 4 * pw),
    );

    output('above') <= curSlot;
    output('left') <= leftReg;
    output('above_left') <= cornerReg;

    final fillRow = [
      for (var i = 0; i < 8; i++) Const(fill, width: pw),
    ].concat();

    Sequential(clk, [
      If(
        reset,
        then: [
          for (var i = 0; i < maxBlockCols; i++) slot[i] < fillRow,
          leftReg < fillRow,
          cornerReg < Const(fill, width: pw),
        ],
        orElse: [
          If(
            newRow,
            then: [
              leftReg < fillRow,
              cornerReg < Const(fill, width: pw),
            ],
          ),
          If(
            store,
            then: [
              // Capture the old bottom-right as the next block's above-left, then
              // overwrite this column's slot and rotate the right column to left.
              cornerReg < slotLast,
              leftReg < blockRight,
              for (var i = 0; i < maxBlockCols; i++)
                If(
                  bwCol.eq(Const(i, width: colW)),
                  then: [slot[i] < blockBottom],
                ),
            ],
          ),
        ],
      ),
    ]);
  }
}

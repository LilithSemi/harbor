import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 superblock walker: emits the raster sequence of superblock
/// top-left MI positions within a tile, the iteration backbone for runtime-sized
/// frame assembly (driving the per-superblock decode of a tile).
///
/// A tile spans `[mi_col_start, mi_col_end)` x `[mi_row_start, mi_row_end)` in
/// MI (4x4-luma) units. Superblocks are 64x64 (16 MI) or, when
/// `use_128x128_superblock`, 128x128 (32 MI). On `start` the walker presents the
/// first SB (top-left of the tile) with `valid` asserted. The consumer decodes
/// it and pulses `next` to advance in raster order (left to right, then down a
/// superblock row). When the last SB has been consumed `done` asserts and
/// `valid` deasserts.
///
/// Outputs `sb_mi_row`/`sb_mi_col` (the current SB's top-left MI position) and
/// `sb_index` (raster index from 0). For a single-tile frame, pass
/// `mi_col_start=0`, `mi_col_end=mi_cols`, etc.
class HarborSbWalk extends BridgeModule {
  HarborSbWalk({String? name})
    : super('HarborSbWalk', name: name ?? 'sb_walk') {
    const mw = 12; // MI coordinate width

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('next', PortDirection.input);
    createPort('use_128x128_superblock', PortDirection.input);
    createPort('mi_col_start', PortDirection.input, width: mw);
    createPort('mi_col_end', PortDirection.input, width: mw);
    createPort('mi_row_start', PortDirection.input, width: mw);
    createPort('mi_row_end', PortDirection.input, width: mw);

    addOutput('valid');
    addOutput('done');
    addOutput('sb_mi_row', width: mw);
    addOutput('sb_mi_col', width: mw);
    addOutput('sb_index', width: mw);

    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');
    final nxt = input('next');
    final use128 = input('use_128x128_superblock');
    final colStart = input('mi_col_start');
    final colEnd = input('mi_col_end');
    final rowStart = input('mi_row_start');
    final rowEnd = input('mi_row_end');

    // MI per superblock side: 32 (128x128) or 16 (64x64).
    final sbMi = mux<Logic>(use128, Const(32, width: mw), Const(16, width: mw));

    final state = Logic(name: 'state', width: 2);
    final sbRow = Logic(name: 'sb_row', width: mw);
    final sbCol = Logic(name: 'sb_col', width: mw);
    final idx = Logic(name: 'idx', width: mw);

    const sIdle = 0, sActive = 1, sDone = 2;
    Logic st(int v) => Const(v, width: 2);

    // candidate next column / row when advancing.
    final nextCol = (sbCol + sbMi).getRange(0, mw);
    final wrapCol = nextCol.gte(colEnd); // step past tile right edge -> new row
    final nextRow = (sbRow + sbMi).getRange(0, mw);
    final atEnd = wrapCol & nextRow.gte(rowEnd);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < st(sIdle),
          sbRow < Const(0, width: mw),
          sbCol < Const(0, width: mw),
          idx < Const(0, width: mw),
        ],
        orElse: [
          // start (re)initializes from either sIdle or sDone.
          Case(state, [
            CaseItem(st(sIdle), [
              If(
                start,
                then: [
                  sbRow < rowStart,
                  sbCol < colStart,
                  idx < Const(0, width: mw),
                  // empty tile -> immediately done.
                  If(
                    colStart.gte(colEnd) | rowStart.gte(rowEnd),
                    then: [state < st(sDone)],
                    orElse: [state < st(sActive)],
                  ),
                ],
              ),
            ]),
            CaseItem(st(sActive), [
              If(
                nxt,
                then: [
                  idx < (idx + Const(1, width: mw)).getRange(0, mw),
                  If(
                    atEnd,
                    then: [state < st(sDone)],
                    orElse: [
                      If(
                        wrapCol,
                        then: [sbCol < colStart, sbRow < nextRow],
                        orElse: [sbCol < nextCol],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(st(sDone), [
              // hold done until a new start (re)initializes the walk.
              If(
                start,
                then: [
                  sbRow < rowStart,
                  sbCol < colStart,
                  idx < Const(0, width: mw),
                  If(
                    colStart.gte(colEnd) | rowStart.gte(rowEnd),
                    then: [state < st(sDone)],
                    orElse: [state < st(sActive)],
                  ),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);

    output('valid') <= state.eq(st(sActive));
    output('done') <= state.eq(st(sDone));
    output('sb_mi_row') <= sbRow;
    output('sb_mi_col') <= sbCol;
    output('sb_index') <= idx;
  }
}

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'bit_reader.dart';

/// Harbor AV1 `tile_info()` parser (uniform tile spacing path).
///
/// Derives the tile grid from the frame's superblock dimensions and reads the
/// tile-layout syntax. From `mi_cols`/`mi_rows` and the superblock size it
/// computes sbCols/sbRows and, via `tile_log2`, the min/max tile column and row
/// log2 counts. It then reads `uniform_tile_spacing_flag` and, on the uniform
/// path, the unary increment bits that raise `TileColsLog2`/`TileRowsLog2` from
/// their minimums toward their maximums. When more than one tile is present it
/// reads `context_update_tile_id` (f(rowsLog2+colsLog2)) and
/// `tile_size_bytes_minus_1` (f(2)). Combinational.
///
/// SCOPE: only `uniform_tile_spacing_flag == 1` is decoded exactly. The
/// non-uniform (explicit per-tile widths via ns()) path needs a data-dependent
/// loop and is a follow-up. `tile_log2(blk, target)` = smallest k with
/// `blk << k >= target`.
class HarborTileInfoParser extends BridgeModule {
  HarborTileInfoParser({int maxBytes = 16, String? name})
    : super('HarborTileInfoParser', name: name ?? 'tile_info') {
    final totalBits = maxBytes * 8;
    final offW = totalBits.bitLength;

    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('mi_cols', PortDirection.input, width: 16);
    createPort('mi_rows', PortDirection.input, width: 16);
    createPort('use_128x128_superblock', PortDirection.input, width: 1);
    addOutput('uniform_tile_spacing_flag', width: 1);
    addOutput('tile_cols_log2', width: 5);
    addOutput('tile_rows_log2', width: 5);
    addOutput('tile_cols', width: 7);
    addOutput('tile_rows', width: 7);
    addOutput('context_update_tile_id', width: 16);
    addOutput('tile_size_bytes', width: 3);
    addOutput('bits_consumed', width: 8);

    final bytesIn = input('bytes');
    final use128 = input('use_128x128_superblock');
    final miCols = input('mi_cols').zeroExtend(32);
    final miRows = input('mi_rows').zeroExtend(32);
    final one = Const(1, width: 1);

    var idx = 0;
    (Logic, Logic) condFnL(Logic off, Logic cond, Logic n, Logic dflt) {
      final r = HarborBitReader(maxBytes: maxBytes, name: 'fn${idx++}');
      addSubModule(r);
      r.input('bytes').srcConnection! <= bytesIn;
      r.input('bit_offset').srcConnection! <= off;
      r.input('n').srcConnection! <= n;
      return (
        mux(cond, r.output('value'), dflt),
        mux(cond, r.output('next_offset'), off),
      );
    }

    (Logic, Logic) condFn(Logic off, Logic cond, int n, Logic dflt) =>
        condFnL(off, cond, Const(n, width: 6), dflt);

    Logic shr(Logic v, int n) => (v >>> n).getRange(0, 32);
    Logic minL(Logic a, Logic b) => mux(a.lt(b), a, b);
    Logic maxL(Logic a, Logic b) => mux(a.gt(b), a, b);

    // tile_log2(blk, target) = smallest k with (blk << k) >= target.
    Logic tileLog2(Logic blk, Logic target) {
      Logic val = blk.getRange(0, 32);
      Logic k = Const(0, width: 5);
      for (var step = 0; step < 20; step++) {
        final need = val.lt(target);
        k = (k + need.zeroExtend(5)).getRange(0, 5);
        val = mux(need, (val << 1).getRange(0, 32), val);
      }
      return k;
    }

    // Superblock grid.
    final sbCols = mux(
      use128,
      shr((miCols + Const(31, width: 32)).getRange(0, 32), 5),
      shr((miCols + Const(15, width: 32)).getRange(0, 32), 4),
    );
    final sbRows = mux(
      use128,
      shr((miRows + Const(31, width: 32)).getRange(0, 32), 5),
      shr((miRows + Const(15, width: 32)).getRange(0, 32), 4),
    );
    final maxTileWidthSb = mux<Logic>(
      use128,
      Const(32, width: 32),
      Const(64, width: 32),
    );
    final maxTileAreaSb = mux<Logic>(
      use128,
      Const(576, width: 32),
      Const(2304, width: 32),
    );

    final minLog2TileCols = tileLog2(maxTileWidthSb, sbCols);
    final maxLog2TileCols = tileLog2(
      Const(1, width: 32),
      minL(sbCols, Const(64, width: 32)),
    );
    final maxLog2TileRows = tileLog2(
      Const(1, width: 32),
      minL(sbRows, Const(64, width: 32)),
    );
    final areaLog2 = tileLog2(maxTileAreaSb, (sbRows * sbCols).getRange(0, 32));
    final minLog2Tiles = maxL(minLog2TileCols, areaLog2);

    final off0 = Const(0, width: offW);
    final (utsV, o1) = condFn(off0, one, 1, Const(0, width: 32));
    final uts = utsV.getRange(0, 1);

    // Uniform column increments.
    Logic colLog2 = minLog2TileCols;
    Logic active = one;
    var off = o1;
    for (var step = 0; step < 7; step++) {
      final canRead = uts & active & colLog2.lt(maxLog2TileCols);
      final (bV, on) = condFn(off, canRead, 1, Const(0, width: 32));
      final b = bV.getRange(0, 1);
      colLog2 = (colLog2 + (canRead & b).zeroExtend(5)).getRange(0, 5);
      active = (active & ~(canRead & ~b)).getRange(0, 1);
      off = on;
    }

    final minLog2TileRows = mux(
      minLog2Tiles.gte(colLog2),
      (minLog2Tiles - colLog2).getRange(0, 5),
      Const(0, width: 5),
    );
    Logic rowLog2 = minLog2TileRows;
    Logic activeR = one;
    for (var step = 0; step < 7; step++) {
      final canRead = uts & activeR & rowLog2.lt(maxLog2TileRows);
      final (bV, on) = condFn(off, canRead, 1, Const(0, width: 32));
      final b = bV.getRange(0, 1);
      rowLog2 = (rowLog2 + (canRead & b).zeroExtend(5)).getRange(0, 5);
      activeR = (activeR & ~(canRead & ~b)).getRange(0, 1);
      off = on;
    }

    // context_update_tile_id + tile_size_bytes when more than one tile.
    final anyTiles = colLog2.or() | rowLog2.or();
    final ctxWidth = (colLog2.zeroExtend(6) + rowLog2.zeroExtend(6)).getRange(
      0,
      6,
    );
    final (ctxV, oA) = condFnL(off, anyTiles, ctxWidth, Const(0, width: 32));
    final (tsbV, oB) = condFn(oA, anyTiles, 2, Const(0, width: 32));
    final tileSizeBytes = mux(
      anyTiles,
      (tsbV.getRange(0, 3) + Const(1, width: 3)).getRange(0, 3),
      Const(1, width: 3),
    );

    output('uniform_tile_spacing_flag') <= uts;
    output('tile_cols_log2') <= colLog2;
    output('tile_rows_log2') <= rowLog2;
    output('tile_cols') <=
        (Const(1, width: 7) << colLog2.zeroExtend(7)).getRange(0, 7);
    output('tile_rows') <=
        (Const(1, width: 7) << rowLog2.zeroExtend(7)).getRange(0, 7);
    output('context_update_tile_id') <= ctxV.getRange(0, 16);
    output('tile_size_bytes') <= tileSizeBytes;
    output('bits_consumed') <= oB.getRange(0, 8);
  }
}

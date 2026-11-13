import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 `tile_group_obu` parser: splits a tile-group OBU payload into each
/// tile's coded-byte slice (offset + size), the last framing step before the
/// per-tile entropy decode.
///
/// Per the spec: when `NumTiles == 1` the whole payload is the single tile. When
/// `NumTiles > 1`, `tile_start_and_end_present_flag` is read (this module
/// supports the common `== 0` case where the group spans every tile, the `== 1`
/// large-scale / tile-list path raises `unsupported`), the header byte-aligns,
/// and then each tile EXCEPT the last is prefixed by a little-endian
/// `tile_size_minus_1` of `TileSizeBytes` bytes (`tileSize = that + 1`). The last
/// tile takes the remaining payload.
///
/// Pulse `start` with `bytes` (the payload, byte 0 at bit 0), `sz` (payload byte
/// count), `num_tiles` (= TileCols*TileRows), and `tile_size_bytes` (1..4). When
/// `done`, `tile_count` tiles are described in `tile_offsets`/`tile_sizes`
/// (`maxTiles` slots of `cw` bits each, tile i at `[i*cw +: cw]`), each a byte
/// offset + size within the payload.
class HarborTileGroupParse extends BridgeModule {
  /// Payload window size in bytes.
  final int bufBytes;

  /// Maximum number of tiles described.
  final int maxTiles;

  HarborTileGroupParse({this.bufBytes = 256, this.maxTiles = 8, String? name})
    : assert(bufBytes >= 4, 'need a payload window'),
      assert(maxTiles >= 1, 'at least one tile'),
      super('HarborTileGroupParse', name: name ?? 'tile_group_parse') {
    final totalBits = bufBytes * 8;
    const cw = 12; // byte offset / size width

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: totalBits);
    createPort('sz', PortDirection.input, width: cw);
    createPort('num_tiles', PortDirection.input, width: 8);
    createPort('tile_size_bytes', PortDirection.input, width: 3);

    addOutput('done');
    addOutput('unsupported');
    addOutput('tile_count', width: 8);
    addOutput('tile_offsets', width: maxTiles * cw);
    addOutput('tile_sizes', width: maxTiles * cw);

    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');
    final bytesIn = input('bytes');
    final sz = input('sz');
    final numTiles = input('num_tiles');
    final tsb = input('tile_size_bytes');

    final state = Logic(name: 'state', width: 3);
    final bpos = Logic(name: 'bpos', width: cw);
    final tileIdx = Logic(name: 'tile_idx', width: 8);
    final remaining = Logic(name: 'remaining', width: cw);
    final tileCount = Logic(name: 'tile_count_r', width: 8);
    final offsets = [
      for (var i = 0; i < maxTiles; i++) Logic(name: 'off$i', width: cw),
    ];
    final sizes = [
      for (var i = 0; i < maxTiles; i++) Logic(name: 'size$i', width: cw),
    ];

    const sIdle = 0,
        sHeaderFlag = 1,
        sTileLoop = 2,
        sDone = 3,
        sUnsupported = 4;
    Logic st(int v) => Const(v, width: 3);

    // byte 0 at the current header position (for the f(1) flag at bit 0).
    final byte0 = bytesIn.getRange(0, 8);
    final headerFlag = byte0[7]; // MSB-first bit 0

    // little-endian tile_size_minus_1 of tile_size_bytes bytes at bpos.
    final posShift = [bpos, Const(0, width: 3)].concat(); // bpos*8
    final posView = (bytesIn >>> posShift.zeroExtend(totalBits)).getRange(
      0,
      32,
    );
    // mask = (1 << (tile_size_bytes*8)) - 1.
    final tsbBits = (tsb.zeroExtend(8) * Const(8, width: 8)).getRange(0, 8);
    final leMask =
        ((Const(1, width: 40) << tsbBits.zeroExtend(40)) - Const(1, width: 40))
            .getRange(0, 32);
    final leVal = (posView & leMask).getRange(0, cw);
    final tileSize = (leVal + Const(1, width: cw)).getRange(0, cw);
    final lastIdx = (numTiles - Const(1, width: 8)).getRange(0, 8);

    List<Conditional> writeTile(Logic idx, Logic off, Logic size) => [
      for (var k = 0; k < maxTiles; k++)
        If(
          idx.eq(Const(k, width: 8)),
          then: [offsets[k] < off, sizes[k] < size],
        ),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          state < st(sIdle),
          bpos < Const(0, width: cw),
          tileIdx < Const(0, width: 8),
          remaining < Const(0, width: cw),
          tileCount < Const(0, width: 8),
          for (var i = 0; i < maxTiles; i++) offsets[i] < Const(0, width: cw),
          for (var i = 0; i < maxTiles; i++) sizes[i] < Const(0, width: cw),
        ],
        orElse: [
          Case(state, [
            CaseItem(st(sIdle), [
              If(
                start,
                then: [
                  If(
                    numTiles.lte(Const(1, width: 8)),
                    then: [
                      // single tile: whole payload.
                      ...writeTile(Const(0, width: 8), Const(0, width: cw), sz),
                      tileCount < Const(1, width: 8),
                      state < st(sDone),
                    ],
                    orElse: [
                      bpos < Const(0, width: cw),
                      tileIdx < Const(0, width: 8),
                      remaining < sz,
                      state < st(sHeaderFlag),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(st(sHeaderFlag), [
              // tile_start_and_end_present_flag (MSB of byte 0).
              If(
                headerFlag,
                then: [state < st(sUnsupported)],
                orElse: [
                  // 1 header bit -> byte_alignment consumes the rest of byte 0.
                  bpos < Const(1, width: cw),
                  remaining < (sz - Const(1, width: cw)).getRange(0, cw),
                  tileIdx < Const(0, width: 8),
                  tileCount < numTiles,
                  state < st(sTileLoop),
                ],
              ),
            ]),
            CaseItem(st(sTileLoop), [
              If(
                tileIdx.eq(lastIdx),
                then: [
                  // last tile: the remaining payload.
                  ...writeTile(tileIdx, bpos, remaining),
                  state < st(sDone),
                ],
                orElse: [
                  // tile_size_minus_1 = le(TileSizeBytes), then data follows.
                  ...writeTile(
                    tileIdx,
                    (bpos + tsb.zeroExtend(cw)).getRange(0, cw),
                    tileSize,
                  ),
                  bpos < (bpos + tsb.zeroExtend(cw) + tileSize).getRange(0, cw),
                  remaining <
                      (remaining - tsb.zeroExtend(cw) - tileSize).getRange(
                        0,
                        cw,
                      ),
                  tileIdx < (tileIdx + Const(1, width: 8)).getRange(0, 8),
                  state < st(sTileLoop),
                ],
              ),
            ]),
            CaseItem(st(sDone), [
              If(~start, then: [state < st(sIdle)]),
            ]),
            CaseItem(st(sUnsupported), [
              If(~start, then: [state < st(sIdle)]),
            ]),
          ]),
        ],
      ),
    ]);

    output('done') <= state.eq(st(sDone)) | state.eq(st(sUnsupported));
    output('unsupported') <= state.eq(st(sUnsupported));
    output('tile_count') <= tileCount;
    output('tile_offsets') <=
        [for (var i = maxTiles - 1; i >= 0; i--) offsets[i]].concat();
    output('tile_sizes') <=
        [for (var i = maxTiles - 1; i >= 0; i--) sizes[i]].concat();
  }
}

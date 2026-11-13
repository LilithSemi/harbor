import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'av1_cdf_tables.dart' as cdf;
import 'od_ec_decoder.dart';

// build-time av1 tx_size tables from the AV1 spec / libaom (av1/common/blockd.h).
// resolve cat/maxDepth/depthToTxSize to constants once the build-time bSize is
// fixed.

// bsize_to_tx_size_depth_table[BLOCK_SIZES_ALL]. bsize_to_tx_size_cat = -1.
const List<int> _bsizeToTxSizeDepthTable = [
  0,
  1,
  1,
  1,
  2,
  2,
  2,
  3,
  3,
  3,
  4,
  4,
  4,
  4,
  4,
  4,
  2,
  2,
  3,
  3,
  4,
  4,
];

// bsize_to_max_depth_table[BLOCK_SIZES_ALL].
const List<int> _bsizeToMaxDepthTable = [
  0,
  1,
  1,
  1,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
];

// max_txsize_rect_lookup[BLOCK_SIZES_ALL] -> TX_SIZE.
const List<int> _maxTxsizeRectLookup = [
  0,
  5,
  6,
  1,
  7,
  8,
  2,
  9,
  10,
  3,
  11,
  12,
  4,
  4,
  4,
  4,
  13,
  14,
  15,
  16,
  17,
  18,
];

// sub_tx_size_map[TX_SIZES_ALL] -> TX_SIZE.
const List<int> _subTxSizeMap = [
  0,
  0,
  1,
  2,
  3,
  0,
  0,
  1,
  1,
  2,
  2,
  3,
  3,
  5,
  6,
  7,
  8,
  9,
  10,
];

int _bsizeToTxSizeCat(int bsize) => _bsizeToTxSizeDepthTable[bsize] - 1;
int _bsizeToMaxDepth(int bsize) => _bsizeToMaxDepthTable[bsize];

int _depthToTxSize(int depth, int bsize) {
  var txSize = _maxTxsizeRectLookup[bsize];
  for (var d = 0; d < depth; d++) {
    txSize = _subTxSizeMap[txSize];
  }
  return txSize;
}

/// Harbor bit-exact AV1 intra `tx_size` decode (`_readTxSize`, TX_MODE_SELECT
/// path).
///
/// Constructed for a build-time [bSize], so `cat = bsize_to_tx_size_cat`,
/// `maxDepth = bsize_to_max_depth`, and the `depth -> TX_SIZE` map
/// (`depth_to_tx_size`) are all constants. The runtime tx-size context `ctx`
/// (0..2, derived by the block walk) selects one of the three CDF rows
/// `kAv1DefaultTxSizeCdf[cat][ctx]`, which is loaded into a [HarborOdEcDecoder]
/// context and decoded with `num_syms = maxDepth + 1` (`decodeN`). The decoded
/// `depth` is mapped to the resulting `TX_SIZE` through a small const mux.
///
/// For a non-signalling [bSize] (`maxDepth == 0`, e.g. BLOCK_4X4) there is no
/// coded symbol: `tx_size` is the const `max_txsize_rect_lookup[bSize]` and
/// `done` asserts immediately after `start`. Prefer constructing for a
/// signalling [bSize] so the decode path is exercised.
///
/// `bytes` holds the coded data (byte i at `[i*8 +: 8]`, up to [maxBytes]).
/// Pulse `start`. `done` asserts with `tx_size` valid.
class HarborTxSizeDecode extends BridgeModule {
  /// The build-time block size (BLOCK_SIZES_ALL index) this decoder is wired
  /// for. Fixes cat, maxDepth and the depth->TX_SIZE map.
  final int bSize;

  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  /// `bsize_to_tx_size_cat(bSize)`.
  late final int cat = _bsizeToTxSizeCat(bSize);

  /// `bsize_to_max_depth(bSize)`.
  late final int maxDepth = _bsizeToMaxDepth(bSize);

  static const _maxSyms = 5; // largest CDF row is cat 3 (5 symbols)

  HarborTxSizeDecode({required this.bSize, this.maxBytes = 16, String? name})
    : super('HarborTxSizeDecode', name: name ?? 'tx_size_decode') {
    if (bSize < 0 || bSize >= _bsizeToMaxDepthTable.length) {
      throw ArgumentError('HarborTxSizeDecode.bSize out of range: $bSize');
    }

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('ctx', PortDirection.input, width: 2);
    addOutput('done');
    addOutput('tx_size', width: 5);

    final clk = input('clk');
    final reset = input('reset');
    final ctxIn = input('ctx');

    // depth -> TX_SIZE const mux (bSize fixed).
    Logic depthToTxSize(Logic depth) {
      Logic v = Const(_depthToTxSize(maxDepth, bSize), width: 5);
      for (var d = maxDepth - 1; d >= 0; d--) {
        v = mux(
          depth.eq(Const(d, width: depth.width)),
          Const(_depthToTxSize(d, bSize), width: 5),
          v,
        );
      }
      return v;
    }

    // Non-signalling block: no coded symbol, emit the const tx size.
    if (maxDepth == 0) {
      final st = Logic(name: 'st', width: 2);
      const sIdle = 0, sDone = 1;
      output('done') <= st.eq(Const(sDone, width: 2));
      output('tx_size') <= Const(_maxTxsizeRectLookup[bSize], width: 5);
      Sequential(clk, [
        If(
          reset,
          then: [st < Const(sIdle, width: 2)],
          orElse: [
            Case(st, [
              CaseItem(Const(sIdle, width: 2), [
                If(input('start'), then: [st < Const(sDone, width: 2)]),
              ]),
              CaseItem(Const(sDone, width: 2), [
                If(~input('start'), then: [st < Const(sIdle, width: 2)]),
              ]),
            ]),
          ],
        ),
      ]);
      return;
    }

    final ec = HarborOdEcDecoder(maxSyms: _maxSyms, numCtx: 1, name: 'ec');
    addSubModule(ec);
    final cw = ec.ctxWidth;

    // byte buffer + cursor feeding od_ec.
    final buf = [
      for (var i = 0; i < maxBytes; i++) Logic(name: 'b_$i', width: 8),
    ];
    final cursor = Logic(name: 'cursor', width: (maxBytes + 4).bitLength);
    Logic byteAt(Logic ix) {
      Logic v = buf.last;
      for (var i = maxBytes - 2; i >= 0; i--) {
        v = mux(ix.eq(Const(i, width: cursor.width)), buf[i], v);
      }
      return mux(
        ix.gte(Const(maxBytes, width: cursor.width)),
        Const(0, width: 8),
        v,
      );
    }

    Logic packCdf(List<int> icdf) => [
      for (var s = _maxSyms - 1; s >= 0; s--)
        Const(s < icdf.length ? icdf[s] : 0, width: 16),
    ].concat();

    // select the ctx (0..2) CDF row at runtime. cat is a const.
    Logic selCdf() {
      Logic v = packCdf(cdf.kAv1DefaultTxSizeCdf[cat][2]);
      for (var i = 1; i >= 0; i--) {
        v = mux(
          ctxIn.eq(Const(i, width: 2)),
          packCdf(cdf.kAv1DefaultTxSizeCdf[cat][i]),
          v,
        );
      }
      return v;
    }

    // od_ec control signals (driven combinationally from the state).
    final ecInit = Logic(name: 'ec_init');
    final ecLoad = Logic(name: 'ec_load');
    final ecDecode = Logic(name: 'ec_decode');
    ec.input('clk').srcConnection! <= clk;
    ec.input('reset').srcConnection! <= reset;
    ec.input('init').srcConnection! <= ecInit;
    ec.input('load').srcConnection! <= ecLoad;
    ec.input('decode').srcConnection! <= ecDecode;
    ec.input('ctx').srcConnection! <= Const(0, width: cw);
    ec.input('cdf').srcConnection! <= selCdf();
    ec.input('num_syms').srcConnection! <= Const(maxDepth + 1, width: 5);
    ec.input('bytes_in').srcConnection! <=
        [
          byteAt(cursor),
          byteAt((cursor + Const(1, width: cursor.width))),
          byteAt((cursor + Const(2, width: cursor.width))),
        ].concat();
    final sym = ec.output('symbol');
    final bytePop = ec.output('byte_pop');

    const sIdle = 0, sLoad = 1, sInit = 2, sDec = 3, sCap = 4, sDone = 5;
    final st = Logic(name: 'st', width: 3);
    final txReg = Logic(name: 'tx_r', width: 5);

    output('done') <= st.eq(Const(sDone, width: 3));
    output('tx_size') <= txReg;

    Combinational([
      ecInit < Const(0),
      ecLoad < Const(0),
      ecDecode < Const(0),
      Case(st, [
        CaseItem(Const(sLoad, width: 3), [ecLoad < Const(1)]),
        CaseItem(Const(sInit, width: 3), [ecInit < Const(1)]),
        CaseItem(Const(sDec, width: 3), [ecDecode < Const(1)]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          cursor < Const(0, width: cursor.width),
          txReg < Const(0, width: 5),
          for (var i = 0; i < maxBytes; i++) buf[i] < Const(0, width: 8),
        ],
        orElse: [
          cursor <
              (cursor + bytePop.zeroExtend(cursor.width)).getRange(
                0,
                cursor.width,
              ),
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(
                input('start'),
                then: [
                  for (var i = 0; i < maxBytes; i++)
                    buf[i] < input('bytes').getRange(i * 8, i * 8 + 8),
                  cursor < Const(0, width: cursor.width),
                  st < Const(sLoad, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sLoad, width: 3), [st < Const(sInit, width: 3)]),
            CaseItem(Const(sInit, width: 3), [st < Const(sDec, width: 3)]),
            CaseItem(Const(sDec, width: 3), [st < Const(sCap, width: 3)]),
            CaseItem(Const(sCap, width: 3), [
              txReg < depthToTxSize(sym),
              st < Const(sDone, width: 3),
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

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'od_ec_decoder.dart';

/// Harbor bit-exact AV1 transform-type read for TX_4X4 / TX_8X8 intra, DC mode,
/// the default (non-reduced) ext-tx set (`av1_read_tx_type`).
///
/// For TX_4X4 and TX_8X8 intra the ext-tx set is `EXT_TX_SET_DTT4_IDTX_1DDCT`
/// (7 types). A single 7-symbol decode from the intra ext-tx CDF (selected by
/// the square tx size) gives an in-set index, mapped to a TX_TYPE by
/// `av1_ext_tx_inv[DTT4_IDTX_1DDCT]`:
///   idx 0..6 -> {IDTX, DCT_DCT, V_DCT, H_DCT, ADST_ADST, ADST_DCT, DCT_ADST}.
/// The decoded TX_TYPE selects the transform's row/col 1D types and the
/// coefficient scan (2D / VERT / HORIZ) downstream.
///
/// This is the building block for a real intra block decode (where tx_type is
/// read inside `read_coeffs_txb`, after txb_skip, before eob). `bytes` holds the
/// coded data (byte i at `[i*8 +: 8]`), pulse `start`, `done` asserts with
/// `tx_type` (and the raw `ext_tx_sym`) valid.
class HarborTxTypeRead extends BridgeModule {
  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  /// libaom TX_SIZE (TX_4X4 = 0 or TX_8X8 = 1, both use the DTT4_IDTX_1DDCT set).
  final int txSize;

  // Intra ext-tx CDFs (kIntraExtTxCdf[1][squareTx][DC=0]) for set 1.
  static const _extTxCdf4 = [31233, 24733, 23307, 20017, 9301, 4943, 0];
  static const _extTxCdf8 = [30898, 19026, 18238, 16270, 8998, 5070, 0];
  // av1_ext_tx_inv[EXT_TX_SET_DTT4_IDTX_1DDCT] (first 7 entries).
  static const _extTxInv = [9, 0, 10, 11, 3, 1, 2];
  static const _maxSyms = 7;

  HarborTxTypeRead({this.maxBytes = 16, this.txSize = 0, String? name})
    : assert(txSize == 0 || txSize == 1, 'TX_4X4 / TX_8X8'),
      super('HarborTxTypeRead', name: name ?? 'tx_type_read_$txSize') {
    final extTxCdf = txSize == 0 ? _extTxCdf4 : _extTxCdf8;
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    addOutput('done');
    addOutput('ext_tx_sym', width: 3);
    addOutput('tx_type', width: 4);

    final clk = input('clk');
    final reset = input('reset');

    final ec = HarborOdEcDecoder(maxSyms: _maxSyms, numCtx: 1, name: 'ec');
    addSubModule(ec);
    final cw = ec.ctxWidth;

    final buf = [
      for (var i = 0; i < maxBytes; i++) Logic(name: 'b_$i', width: 8),
    ];
    final cursor = Logic(name: 'cursor', width: (maxBytes + 4).bitLength);
    Logic byteAt(Logic idx) {
      Logic v = buf.last;
      for (var i = maxBytes - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: cursor.width)), buf[i], v);
      }
      return mux(
        idx.gte(Const(maxBytes, width: cursor.width)),
        Const(0, width: 8),
        v,
      );
    }

    final ecInit = Logic(name: 'ec_init');
    final ecLoad = Logic(name: 'ec_load');
    final ecDecode = Logic(name: 'ec_decode');
    ec.input('clk').srcConnection! <= clk;
    ec.input('reset').srcConnection! <= reset;
    ec.input('init').srcConnection! <= ecInit;
    ec.input('load').srcConnection! <= ecLoad;
    ec.input('decode').srcConnection! <= ecDecode;
    ec.input('ctx').srcConnection! <= Const(0, width: cw);
    ec.input('cdf').srcConnection! <=
        [
          for (var s = _maxSyms - 1; s >= 0; s--) Const(extTxCdf[s], width: 16),
        ].concat();
    ec.input('num_syms').srcConnection! <= Const(_maxSyms, width: 5);
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
    final symReg = Logic(name: 'sym_r', width: 3);
    final txTypeReg = Logic(name: 'txtype_r', width: 4);

    output('done') <= st.eq(Const(sDone, width: 3));
    output('ext_tx_sym') <= symReg;
    output('tx_type') <= txTypeReg;

    // ext_tx in-set index -> TX_TYPE.
    Logic mapTxType(Logic s) {
      Logic v = Const(_extTxInv.last, width: 4);
      for (var i = _extTxInv.length - 2; i >= 0; i--) {
        v = mux(s.eq(Const(i, width: 3)), Const(_extTxInv[i], width: 4), v);
      }
      return v;
    }

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
          symReg < Const(0, width: 3),
          txTypeReg < Const(0, width: 4),
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
              symReg < sym,
              txTypeReg < mapTxType(sym),
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

import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'av1_cdf_tables.dart' as cdf;
import 'od_ec_decoder.dart';

/// Harbor bit-exact AV1 chroma intra-mode decode (`read_intra_mode_uv`,
/// `uv_mode_cdf[cfl_allowed][y_mode]`).
///
/// The chroma intra mode is decoded from a CDF selected by the already-decoded
/// luma `y_mode` (0..12). Wraps the proven [HarborOdEcDecoder]: selects the
/// `y_mode` row, loads it, one decode gives `uv_mode`.
///
/// Two cases, picked by [cflAllowed]:
/// - `cflAllowed == false` (default): `kAv1DefaultUvModeCdfCflNotAllowed`, a
///   13-symbol CDF, `decodeN(ec, 13)`, `uv_mode` in 0..12.
/// - `cflAllowed == true`: `kAv1DefaultUvModeCdfCflAllowed`, a 14-symbol CDF,
///   `decodeN(ec, 14)`, `uv_mode` in 0..13 where 13 == UV_CFL_PRED.
///
/// `bytes` holds the coded data, `y_mode` the luma mode. Pulse `start`, `done`
/// asserts with `uv_mode` valid.
class HarborUvModeDecode extends BridgeModule {
  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  /// When true, decode the 14-symbol CfL-allowed CDF (UV_CFL_PRED = 13
  /// reachable). When false, the 13-symbol CfL-not-allowed CDF.
  final bool cflAllowed;

  /// Symbol count: 14 (UV_INTRA_MODES + CfL) when allowed, else 13.
  int get _maxSyms => cflAllowed ? 14 : 13;

  HarborUvModeDecode({
    this.maxBytes = 16,
    this.cflAllowed = false,
    String? name,
  }) : super('HarborUvModeDecode', name: name ?? 'uv_mode_decode') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('y_mode', PortDirection.input, width: 4);
    addOutput('done');
    addOutput('uv_mode', width: 4);

    final clk = input('clk');
    final reset = input('reset');
    final yMode = input('y_mode');

    final table = cflAllowed
        ? cdf.kAv1DefaultUvModeCdfCflAllowed
        : cdf.kAv1DefaultUvModeCdfCflNotAllowed;
    Logic packCdf(List<int> icdf) => [
      for (var s = _maxSyms - 1; s >= 0; s--)
        Const(s < icdf.length ? icdf[s] : 0, width: 16),
    ].concat();
    Logic selCdf() {
      Logic v = packCdf(table[12]);
      for (var i = 11; i >= 0; i--) {
        v = mux(yMode.eq(Const(i, width: 4)), packCdf(table[i]), v);
      }
      return v;
    }

    final ec = HarborOdEcDecoder(maxSyms: _maxSyms, numCtx: 1, name: 'ec');
    addSubModule(ec);
    final cw = ec.ctxWidth;

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
    final uvReg = Logic(name: 'uv_r', width: 4);

    output('done') <= st.eq(Const(sDone, width: 3));
    output('uv_mode') <= uvReg;

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
          uvReg < Const(0, width: 4),
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
              uvReg < sym.zeroExtend(4),
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

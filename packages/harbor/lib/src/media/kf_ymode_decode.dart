import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'av1_cdf_tables.dart' as cdf;
import 'kf_ymode_context.dart';
import 'od_ec_decoder.dart';

/// Harbor bit-exact AV1 keyframe luma intra-mode decode (`read_kf_y_mode`).
///
/// On a key frame the luma intra mode (one of the 13 INTRA_MODES) is decoded
/// from `default_kf_y_mode_cdf[above_ctx][left_ctx]`, where each neighbour's
/// mode is mapped to one of five buckets by the `Intra_Mode_Context` table
/// (done by [HarborKfYModeContext]). This wraps the proven [HarborOdEcDecoder]:
/// the 25-context CDF row for the computed `(above_ctx, left_ctx)` is selected
/// and loaded, then one 13-symbol decode gives the mode.
///
/// `bytes` holds the coded data (byte i at `[i*8 +: 8]`). `above_mode` /
/// `left_mode` are the neighbour intra modes (DC = 0 when unavailable). Pulse
/// `start`. `done` asserts with `y_mode` valid.
class HarborKfYModeDecode extends BridgeModule {
  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  static const _maxSyms = 13; // INTRA_MODES

  HarborKfYModeDecode({this.maxBytes = 16, String? name})
    : super('HarborKfYModeDecode', name: name ?? 'kf_ymode_decode') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('above_mode', PortDirection.input, width: 4);
    createPort('left_mode', PortDirection.input, width: 4);
    addOutput('done');
    addOutput('y_mode', width: 4);

    final clk = input('clk');
    final reset = input('reset');

    // Neighbour-mode -> 5-bucket context mapping.
    final cx = HarborKfYModeContext(name: 'ctx');
    addSubModule(cx);
    cx.input('above_mode').srcConnection! <= input('above_mode');
    cx.input('left_mode').srcConnection! <= input('left_mode');
    // idx = above_ctx * 5 + left_ctx  (0..24).
    final idx =
        ((cx.output('above_ctx').zeroExtend(6) * Const(5, width: 6)) +
                cx.output('left_ctx').zeroExtend(6))
            .getRange(0, 6);

    // Select the 13-symbol CDF row for idx from the default table.
    Logic packCdf(List<int> icdf) => [
      for (var s = _maxSyms - 1; s >= 0; s--)
        Const(s < icdf.length ? icdf[s] : 0, width: 16),
    ].concat();
    Logic selCdf() {
      Logic v = packCdf(cdf.kAv1DefaultKfYModeCdf[24]);
      for (var i = 23; i >= 0; i--) {
        v = mux(
          idx.eq(Const(i, width: 6)),
          packCdf(cdf.kAv1DefaultKfYModeCdf[i]),
          v,
        );
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
    final yModeReg = Logic(name: 'ymode_r', width: 4);

    output('done') <= st.eq(Const(sDone, width: 3));
    output('y_mode') <= yModeReg;

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
          yModeReg < Const(0, width: 4),
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
              yModeReg < sym.zeroExtend(4),
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

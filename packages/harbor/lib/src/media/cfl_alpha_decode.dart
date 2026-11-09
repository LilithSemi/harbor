import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'od_ec_decoder.dart';

/// Harbor bit-exact AV1 Chroma-from-Luma (CfL) alpha + joint-sign decoder
/// (`read_cfl_alphas`).
///
/// Wraps the proven [HarborOdEcDecoder] range coder and runs the exact libaom
/// CfL syntax (mirrors `_readCflAlphas`, tile_decode.dart line 1614):
/// 1. `js` = cfl joint signs symbol (8-symbol `cfl_sign_cdf`),
/// 2. `signU = (js+1)/3`, `signV = (js+1) - 3*signU`,
/// 3. if `signU != 0`: `cfl_alpha_u` = `cfl_alpha_cdf[js+1-3]` symbol (16-sym),
///    `idx = cfl_alpha_u << 4`,
/// 4. if `signV != 0`: `cfl_alpha_v` = `cfl_alpha_cdf[signV*3+signU-3]` symbol,
///    `idx += cfl_alpha_v`.
///
/// The default CDFs are preloaded into od_ec contexts: the sign CDF is loaded
/// once into context 0. The alpha context (context 1) is reloaded just before
/// each alpha decode with the data-dependent `cfl_alpha_cdf` row selected by the
/// running `js`/`signU`/`signV` (muxed from the 6 default rows). The 2nd/3rd
/// decodes only fire when `signU`/`signV` are nonzero, so the FSM branches on
/// the decoded `js`. `idx` is built across the steps in a register.
///
/// `bytes` holds the coded data (byte i at `[i*8 +: 8]`, up to [maxBytes]).
/// Pulse `start`. `done` asserts with `cfl_alpha_idx` (8b) and `cfl_signs`
/// (3b, = `js` 0..7) valid. `cfl_alpha_idx` packs `cfl_alpha_u` in bits [7:4]
/// and `cfl_alpha_v` in bits [3:0] (libaom `_cflAlpha`: U = `idx >> 4`,
/// V = `idx & 0xf`). Each is a 4-bit `CFL_ALPHABET_SIZE=16` symbol, so the
/// index needs 8 bits to be bit-exact with `_readCflAlphas`.
class HarborCflAlphaDecode extends BridgeModule {
  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  static const _maxSyms = 16; // CFL_ALPHABET_SIZE (alpha); sign uses 8.
  static const _numCtx =
      2; // ctx 0 = sign, ctx 1 = alpha (reloaded per decode).
  static const _ctxSign = 0;
  static const _ctxAlpha = 1;

  // ICDF convention matches extra_cdfs.dart::_icdf: row = [32768-x ..] + [0].
  static List<int> _ic(List<int> fwd) => [for (final x in fwd) 32768 - x, 0];

  // default_cfl_sign_cdf[CFL_JOINT_SIGNS=8] -> 8 ICDF entries.
  static final List<int> _signCdf = _ic([
    1418,
    2123,
    13340,
    18405,
    26972,
    28343,
    32294,
  ]);

  // default_cfl_alpha_cdf[CFL_ALPHA_CONTEXTS=6][CFL_ALPHABET_SIZE=16].
  static final List<List<int>> _alphaCdf = [
    _ic([
      7637,
      20719,
      31401,
      32481,
      32657,
      32688,
      32692,
      32696,
      32700,
      32704,
      32708,
      32712,
      32716,
      32720,
      32724,
    ]),
    _ic([
      14365,
      23603,
      28135,
      31168,
      32167,
      32395,
      32487,
      32573,
      32620,
      32647,
      32668,
      32672,
      32676,
      32680,
      32684,
    ]),
    _ic([
      11532,
      22380,
      28445,
      31360,
      32349,
      32523,
      32584,
      32649,
      32673,
      32677,
      32681,
      32685,
      32689,
      32693,
      32697,
    ]),
    _ic([
      26990,
      31402,
      32282,
      32571,
      32692,
      32696,
      32700,
      32704,
      32708,
      32712,
      32716,
      32720,
      32724,
      32728,
      32732,
    ]),
    _ic([
      17248,
      26058,
      28904,
      30608,
      31305,
      31877,
      32126,
      32321,
      32394,
      32464,
      32516,
      32560,
      32576,
      32593,
      32622,
    ]),
    _ic([
      14738,
      21678,
      25779,
      27901,
      29024,
      30302,
      30980,
      31843,
      32144,
      32413,
      32520,
      32594,
      32622,
      32656,
      32660,
    ]),
  ];

  HarborCflAlphaDecode({this.maxBytes = 16, String? name})
    : super('HarborCflAlphaDecode', name: name ?? 'cfl_alpha_decode') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    addOutput('done');
    addOutput('cfl_alpha_idx', width: 8);
    addOutput('cfl_signs', width: 3);

    final clk = input('clk');
    final reset = input('reset');

    final ec = HarborOdEcDecoder(
      maxSyms: _maxSyms,
      numCtx: _numCtx,
      name: 'ec',
    );
    addSubModule(ec);
    final cw = ec.ctxWidth;

    // byte buffer + cursor feeding od_ec
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

    // od_ec control signals (driven combinationally from the state).
    final ecInit = Logic(name: 'ec_init');
    final ecLoad = Logic(name: 'ec_load');
    final ecDecode = Logic(name: 'ec_decode');
    final ecCtx = Logic(name: 'ec_ctx', width: cw);
    final ecCdf = Logic(name: 'ec_cdf', width: _maxSyms * 16);
    final ecNsyms = Logic(name: 'ec_nsyms', width: 5);
    ec.input('clk').srcConnection! <= clk;
    ec.input('reset').srcConnection! <= reset;
    ec.input('init').srcConnection! <= ecInit;
    ec.input('load').srcConnection! <= ecLoad;
    ec.input('decode').srcConnection! <= ecDecode;
    ec.input('ctx').srcConnection! <= ecCtx;
    ec.input('cdf').srcConnection! <= ecCdf;
    ec.input('num_syms').srcConnection! <= ecNsyms;
    ec.input('bytes_in').srcConnection! <=
        [
          byteAt(cursor),
          byteAt((cursor + Const(1, width: cursor.width))),
          byteAt((cursor + Const(2, width: cursor.width))),
        ].concat();
    final sym = ec.output('symbol');
    final bytePop = ec.output('byte_pop');

    Logic packCdf(List<int> icdf) => [
      for (var s = _maxSyms - 1; s >= 0; s--)
        Const(s < icdf.length ? icdf[s] : 0, width: 16),
    ].concat();

    // Mux the 6 default alpha CDF rows by a runtime row index (0..5).
    Logic selAlphaCdf(Logic row) {
      Logic v = packCdf(_alphaCdf.last);
      for (var i = _alphaCdf.length - 2; i >= 0; i--) {
        v = mux(row.eq(Const(i, width: row.width)), packCdf(_alphaCdf[i]), v);
      }
      return v;
    }

    // state + data registers
    const sIdle = 0;
    const sLoadSign = 1;
    const sInit = 2;
    const sSign = 3, sSignCap = 4;
    const sLoadU = 5, sU = 6, sUCap = 7;
    const sLoadV = 8, sV = 9, sVCap = 10;
    const sDone = 11;
    final st = Logic(name: 'st', width: 4);

    final jsReg = Logic(name: 'js_r', width: 3); // 0..7
    final idxReg = Logic(name: 'idx_r', width: 8); // u<<4 | v, 0..255

    output('done') <= st.eq(Const(sDone, width: 4));
    output('cfl_signs') <= jsReg;
    output('cfl_alpha_idx') <= idxReg;

    // signU = (js+1) ~/ 3, signV = (js+1) - 3*signU, from the captured js.
    // js in 0..7 so (js+1) in 1..8. Compute on a widened value to avoid wrap.
    final jsP1 = (jsReg.zeroExtend(5) + Const(1, width: 5)).getRange(0, 5);
    final signU = _divBy3(jsP1); // 0..2
    final signV = (jsP1 - (signU * Const(3, width: 5)).getRange(0, 5)).getRange(
      0,
      5,
    );
    // Alpha CDF row indices (each 0..5).
    // U row = js + 1 - 3 = jsP1 - 3.
    final rowU = (jsP1 - Const(3, width: 5)).getRange(0, 3);
    // V row = signV*3 + signU - 3.
    final rowV =
        ((signV * Const(3, width: 5)).getRange(0, 5) +
                signU.zeroExtend(5) -
                Const(3, width: 5))
            .getRange(0, 3);

    final signUnz = signU.neq(Const(0, width: signU.width));
    final signVnz = signV.neq(Const(0, width: signV.width));
    // SW keeps 6 independently-adapting cfl_alpha contexts. When the U and V
    // decodes select the SAME row (js in {3,7}), the V decode must see the
    // context the U decode already adapted, NOT a fresh default reload. So skip
    // the V reload exactly when U ran (signU!=0) and rowV == rowU. ctx1 then
    // still holds the U-adapted CDF. (js in {0,1} never decode U, so V always
    // reloads there.)
    final reuseAlphaCtx = signUnz & rowU.eq(rowV);

    // combinational od_ec control, aligned to the current state
    Combinational([
      ecInit < Const(0),
      ecLoad < Const(0),
      ecDecode < Const(0),
      ecCtx < Const(0, width: cw),
      ecCdf < Const(0, width: _maxSyms * 16),
      ecNsyms < Const(0, width: 5),
      Case(st, [
        CaseItem(Const(sLoadSign, width: 4), [
          ecLoad < Const(1),
          ecCtx < Const(_ctxSign, width: cw),
          ecCdf < packCdf(_signCdf),
          ecNsyms < Const(8, width: 5),
        ]),
        CaseItem(Const(sInit, width: 4), [ecInit < Const(1)]),
        CaseItem(Const(sSign, width: 4), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxSign, width: cw),
        ]),
        CaseItem(Const(sLoadU, width: 4), [
          ecLoad < Const(1),
          ecCtx < Const(_ctxAlpha, width: cw),
          ecCdf < selAlphaCdf(rowU),
          ecNsyms < Const(16, width: 5),
        ]),
        CaseItem(Const(sU, width: 4), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxAlpha, width: cw),
        ]),
        CaseItem(Const(sLoadV, width: 4), [
          // Reuse the U-adapted ctx1 when rows match, otherwise load default
          // rowV. Either way the state advances to sV next cycle.
          If(
            ~reuseAlphaCtx,
            then: [
              ecLoad < Const(1),
              ecCtx < Const(_ctxAlpha, width: cw),
              ecCdf < selAlphaCdf(rowV),
              ecNsyms < Const(16, width: 5),
            ],
          ),
        ]),
        CaseItem(Const(sV, width: 4), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxAlpha, width: cw),
        ]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 4),
          cursor < Const(0, width: cursor.width),
          jsReg < Const(0, width: 3),
          idxReg < Const(0, width: 8),
          for (var i = 0; i < maxBytes; i++) buf[i] < Const(0, width: 8),
        ],
        orElse: [
          // advance the byte cursor by whatever od_ec consumed this cycle
          cursor <
              (cursor + bytePop.zeroExtend(cursor.width)).getRange(
                0,
                cursor.width,
              ),
          Case(st, [
            CaseItem(Const(sIdle, width: 4), [
              If(
                input('start'),
                then: [
                  for (var i = 0; i < maxBytes; i++)
                    buf[i] < input('bytes').getRange(i * 8, i * 8 + 8),
                  cursor < Const(0, width: cursor.width),
                  jsReg < Const(0, width: 3),
                  idxReg < Const(0, width: 8),
                  st < Const(sLoadSign, width: 4),
                ],
              ),
            ]),
            CaseItem(Const(sLoadSign, width: 4), [st < Const(sInit, width: 4)]),
            CaseItem(Const(sInit, width: 4), [st < Const(sSign, width: 4)]),
            CaseItem(Const(sSign, width: 4), [st < Const(sSignCap, width: 4)]),
            CaseItem(Const(sSignCap, width: 4), [
              jsReg < sym.getRange(0, 3),
              // branch on signU/signV computed from the just-captured js: the
              // mux above already sees `sym` only via jsReg, so decide using the
              // freshly-read symbol directly here.
              If(
                _signUnzOf(sym),
                then: [st < Const(sLoadU, width: 4)],
                orElse: [
                  If(
                    _signVnzOf(sym),
                    then: [st < Const(sLoadV, width: 4)],
                    orElse: [st < Const(sDone, width: 4)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sLoadU, width: 4), [st < Const(sU, width: 4)]),
            CaseItem(Const(sU, width: 4), [st < Const(sUCap, width: 4)]),
            CaseItem(Const(sUCap, width: 4), [
              // idx = cfl_alpha_u << 4 (cfl_alpha_u is the 4-bit symbol 0..15).
              idxReg <
                  (sym.getRange(0, 4).zeroExtend(8) << Const(4, width: 4))
                      .getRange(0, 8),
              If(
                signVnz,
                then: [st < Const(sLoadV, width: 4)],
                orElse: [st < Const(sDone, width: 4)],
              ),
            ]),
            CaseItem(Const(sLoadV, width: 4), [st < Const(sV, width: 4)]),
            CaseItem(Const(sV, width: 4), [st < Const(sVCap, width: 4)]),
            CaseItem(Const(sVCap, width: 4), [
              // idx += cfl_alpha_v
              idxReg <
                  (idxReg + sym.getRange(0, 4).zeroExtend(8)).getRange(0, 8),
              st < Const(sDone, width: 4),
            ]),
            CaseItem(Const(sDone, width: 4), [
              If(~input('start'), then: [st < Const(sIdle, width: 4)]),
            ]),
          ]),
        ],
      ),
    ]);
  }

  // signU = (js+1)/3 != 0  <=>  js+1 >= 3  <=>  js >= 2.
  static Logic _signUnzOf(Logic symbol) =>
      symbol.getRange(0, 3).gte(Const(2, width: 3));

  // signV = (js+1) - 3*signU != 0  <=>  (js+1) not a multiple of 3.
  // js+1 in 1..8, multiples of 3 are 3 (js=2) and 6 (js=5). So signV==0 iff
  // js in {2,5}.
  static Logic _signVnzOf(Logic symbol) {
    final js = symbol.getRange(0, 3);
    final isMul = js.eq(Const(2, width: 3)) | js.eq(Const(5, width: 3));
    return ~isMul;
  }
}

// Combinational divide-by-3 for a small value (0..8). Returns 0..2.
Logic _divBy3(Logic v) {
  // v is up to 5 bits (0..8). q = (v >= 6) ? 2 : (v >= 3) ? 1 : 0.
  final w = v.width;
  return mux(
    v.gte(Const(6, width: w)),
    Const(2, width: w),
    mux<Logic>(
      v.gte(Const(3, width: w)),
      Const(1, width: w),
      Const(0, width: w),
    ),
  ).getRange(0, w);
}

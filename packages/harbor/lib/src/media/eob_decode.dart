import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'od_ec_decoder.dart';

/// Harbor bit-exact AV1 end-of-block (eob) decoder for TX_4X4, TX_CLASS_2D,
/// luma (the first slice of `read_coeffs_txb`).
///
/// Wraps the proven [HarborOdEcDecoder] range coder and runs the exact libaom
/// eob syntax over a coded byte buffer:
/// 1. `all_zero` = txb_skip symbol (if set, eob = 0),
/// 2. `eob_pt` = eob_pt_16 symbol + 1 (5-symbol multi-CDF),
/// 3. `eob_extra` = an adaptive first bit + bypass tail bits when
///    `av1_eob_offset_bits[eob_pt] > 0`,
/// 4. `eob = av1_eob_group_start[eob_pt] (+ eob_extra when > 2)`.
///
/// The default (Q0) CDFs are preloaded into od_ec contexts at `start`.
/// Bypass bits reload a `[16384, 0]` context (libaom decodes them against a
/// fixed uniform ICDF with no adaptation). The od_ec control strobes are
/// driven combinationally from the state so they align with the cycle they
/// act on. `bytes` holds the coded block (byte i at `[i*8 +: 8]`, up to
/// [maxBytes]). Pulse `start`. `done` asserts with `eob`/`all_zero` valid.
class HarborEobDecode extends BridgeModule {
  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  // Q0 default CDFs (TX_4X4 txsCtx 0, luma, 2D)
  static const _txbSkip = [919, 0]; // kAv1CoefSkipCdfQ0[0]
  static const _eobPt16 = [31928, 31729, 30788, 27873, 0]; // [plane0][ctx0]
  static const _eobExtra = [
    [15807, 0], [15545, 0], [25147, 0], [16384, 0], [16384, 0], //
    [16384, 0], [16384, 0], [16384, 0], [16384, 0], // ctx 0..8
  ];
  static const _bypass = [16384, 0];
  static const _eobOffsetBits = [0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
  static const _eobGroupStart = [0, 1, 2, 3, 5, 9, 17, 33, 65, 129, 257, 513];

  // od_ec context map (flat indices).
  static const _ctxSkip = 0;
  static const _ctxEobPt = 1;
  static const _ctxEobExtra0 = 2; // eob_extra ctx 0..8 -> 2..10
  static const _ctxBypass = 11;
  static const _numCtx = 12;
  static const _maxSyms = 5;

  HarborEobDecode({this.maxBytes = 32, String? name})
    : super('HarborEobDecode', name: name ?? 'eob_decode') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    addOutput('done');
    addOutput('all_zero');
    addOutput('eob', width: 11);

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

    Logic romSel(List<int> table, Logic idx, int w) {
      Logic v = Const(table.last, width: w);
      for (var i = table.length - 2; i >= 0; i--) {
        v = mux(
          idx.eq(Const(i, width: idx.width)),
          Const(table[i], width: w),
          v,
        );
      }
      return v;
    }

    // state + data registers
    const sIdle = 0;
    const sPreload = 1;
    const sInit = 2;
    const sSkip = 3, sSkipCap = 4;
    const sEobPt = 5, sEobPtCap = 6;
    const sExtra = 7, sExtraCap = 8;
    const sByp = 9, sBypDec = 10, sBypCap = 11;
    const sDone = 12;
    final st = Logic(name: 'st', width: 4);
    final plReg = Logic(name: 'pl_r', width: 4);
    final allZeroReg = Logic(name: 'all_zero_r');
    final eobReg = Logic(name: 'eob_r', width: 11);
    final eobPtReg = Logic(name: 'eob_pt_r', width: 4);
    final eobExtraReg = Logic(name: 'eob_extra_r', width: 11);
    final offBitsReg = Logic(name: 'off_bits_r', width: 4);
    final bypIdxReg = Logic(name: 'byp_idx_r', width: 4);

    output('done') <= st.eq(Const(sDone, width: 4));
    output('all_zero') <= allZeroReg;
    output('eob') <= eobReg;

    // Preload schedule: plReg directly indexes the context to load.
    final preloadCdf = <List<int>>[
      _txbSkip,
      _eobPt16,
      for (final c in _eobExtra) c,
      _bypass,
    ];
    final preloadNsyms = <int>[2, 5, for (var i = 0; i < 9; i++) 2, 2];
    Logic selCdfByPl() {
      Logic v = packCdf(preloadCdf.last);
      for (var i = preloadCdf.length - 2; i >= 0; i--) {
        v = mux(plReg.eq(Const(i, width: 4)), packCdf(preloadCdf[i]), v);
      }
      return v;
    }

    Logic selNsymsByPl() {
      Logic v = Const(preloadNsyms.last, width: 5);
      for (var i = preloadNsyms.length - 2; i >= 0; i--) {
        v = mux(
          plReg.eq(Const(i, width: 4)),
          Const(preloadNsyms[i], width: 5),
          v,
        );
      }
      return v;
    }

    final eobCtx = (eobPtReg - Const(3, width: 4)).getRange(0, 4);
    final offBits = romSel(_eobOffsetBits, eobPtReg, 4);
    final groupStart = romSel(_eobGroupStart, eobPtReg, 11);

    // combinational od_ec control, aligned to the current state
    Combinational([
      ecInit < Const(0),
      ecLoad < Const(0),
      ecDecode < Const(0),
      ecCtx < Const(0, width: cw),
      ecCdf < Const(0, width: _maxSyms * 16),
      ecNsyms < Const(0, width: 5),
      Case(st, [
        CaseItem(Const(sPreload, width: 4), [
          ecLoad < Const(1),
          ecCtx < plReg.getRange(0, cw),
          ecCdf < selCdfByPl(),
          ecNsyms < selNsymsByPl(),
        ]),
        CaseItem(Const(sInit, width: 4), [ecInit < Const(1)]),
        CaseItem(Const(sSkip, width: 4), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxSkip, width: cw),
        ]),
        CaseItem(Const(sEobPt, width: 4), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxEobPt, width: cw),
        ]),
        CaseItem(Const(sExtra, width: 4), [
          If(
            offBits.gt(Const(0, width: 4)),
            then: [
              ecDecode < Const(1),
              ecCtx <
                  (Const(_ctxEobExtra0, width: cw) + eobCtx.getRange(0, cw))
                      .getRange(0, cw),
            ],
          ),
        ]),
        CaseItem(Const(sByp, width: 4), [
          If(
            bypIdxReg.lt(offBitsReg),
            then: [
              ecLoad < Const(1),
              ecCtx < Const(_ctxBypass, width: cw),
              ecCdf < packCdf(_bypass),
              ecNsyms < Const(2, width: 5),
            ],
          ),
        ]),
        CaseItem(Const(sBypDec, width: 4), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxBypass, width: cw),
        ]),
      ]),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 4),
          cursor < Const(0, width: cursor.width),
          plReg < Const(0, width: 4),
          allZeroReg < Const(0),
          eobReg < Const(0, width: 11),
          eobPtReg < Const(0, width: 4),
          eobExtraReg < Const(0, width: 11),
          offBitsReg < Const(0, width: 4),
          bypIdxReg < Const(0, width: 4),
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
                  plReg < Const(0, width: 4),
                  st < Const(sPreload, width: 4),
                ],
              ),
            ]),
            CaseItem(Const(sPreload, width: 4), [
              If(
                plReg.eq(Const(_numCtx - 1, width: 4)),
                then: [st < Const(sInit, width: 4)],
                orElse: [plReg < (plReg + Const(1, width: 4))],
              ),
            ]),
            CaseItem(Const(sInit, width: 4), [st < Const(sSkip, width: 4)]),
            CaseItem(Const(sSkip, width: 4), [st < Const(sSkipCap, width: 4)]),
            CaseItem(Const(sSkipCap, width: 4), [
              allZeroReg < sym[0],
              If(
                sym[0],
                then: [
                  eobReg < Const(0, width: 11),
                  st < Const(sDone, width: 4),
                ],
                orElse: [st < Const(sEobPt, width: 4)],
              ),
            ]),
            CaseItem(Const(sEobPt, width: 4), [
              st < Const(sEobPtCap, width: 4),
            ]),
            CaseItem(Const(sEobPtCap, width: 4), [
              eobPtReg <
                  (sym.zeroExtend(4) + Const(1, width: 4)).getRange(0, 4),
              st < Const(sExtra, width: 4),
            ]),
            CaseItem(Const(sExtra, width: 4), [
              offBitsReg < offBits,
              eobExtraReg < Const(0, width: 11),
              If(
                offBits.eq(Const(0, width: 4)),
                then: [eobReg < groupStart, st < Const(sDone, width: 4)],
                orElse: [st < Const(sExtraCap, width: 4)],
              ),
            ]),
            CaseItem(Const(sExtraCap, width: 4), [
              If(
                sym[0],
                then: [
                  eobExtraReg <
                      (Const(1, width: 11) <<
                              (offBitsReg - Const(1, width: 4)).getRange(0, 4))
                          .getRange(0, 11),
                ],
              ),
              bypIdxReg < Const(1, width: 4),
              st < Const(sByp, width: 4),
            ]),
            CaseItem(Const(sByp, width: 4), [
              If(
                bypIdxReg.gte(offBitsReg),
                then: [
                  eobReg <
                      mux(
                        groupStart.gt(Const(2, width: 11)),
                        (groupStart + eobExtraReg).getRange(0, 11),
                        groupStart,
                      ),
                  st < Const(sDone, width: 4),
                ],
                orElse: [st < Const(sBypDec, width: 4)],
              ),
            ]),
            CaseItem(Const(sBypDec, width: 4), [st < Const(sBypCap, width: 4)]),
            CaseItem(Const(sBypCap, width: 4), [
              If(
                sym[0],
                then: [
                  eobExtraReg <
                      (eobExtraReg |
                              (Const(1, width: 11) <<
                                      (offBitsReg -
                                              Const(1, width: 4) -
                                              bypIdxReg)
                                          .getRange(0, 4))
                                  .getRange(0, 11))
                          .getRange(0, 11),
                ],
              ),
              bypIdxReg < (bypIdxReg + Const(1, width: 4)),
              st < Const(sByp, width: 4),
            ]),
            CaseItem(Const(sDone, width: 4), [
              If(~input('start'), then: [st < Const(sIdle, width: 4)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

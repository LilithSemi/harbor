import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'od_ec_decoder.dart';

/// Harbor AV1 intra block decoder: mode_info + coefficients over ONE od_ec.
///
/// This is the real decode-block pattern: a single arithmetic-coder window feeds
/// every syntax element of a block in order. It decodes skip, y_mode, uv_mode,
/// then (when not skipped) an end-of-block count followed by per-coefficient
/// base level (0..3) and a sign for each nonzero level, all from the same od_ec
/// with persistent adaptive CDFs. The point is that mode_info and the
/// coefficient read share one entropy window, the architectural piece a tile
/// decoder needs, not that each runs in isolation.
///
/// CDF values are runtime data (uniform defaults here). The syntax/timing is the
/// verified logic. SCOPE (simplifications, all follow-ups): raster coefficient
/// order, one context per element, base levels capped at 3 with no range/golomb
/// tail, no tx_size/angle/palette/cfl. `coeff_addr` reads the decoded level
/// array after `done`.
class HarborIntraBlockDecode extends BridgeModule {
  HarborIntraBlockDecode({int maxCoeffs = 16, String? name})
    : super('HarborIntraBlockDecode', name: name ?? 'intra_block') {
    final addrW = (maxCoeffs).bitLength;

    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort(
      'start',
      PortDirection.input,
      width: 1,
    ); // first block: load + init
    createPort(
      'next_blk',
      PortDirection.input,
      width: 1,
    ); // continue stream + CDFs
    createPort('bytes_in', PortDirection.input, width: 24);
    createPort('coeff_addr', PortDirection.input, width: addrW);
    addOutput('byte_pop', width: 2);
    addOutput('skip', width: 1);
    addOutput('y_mode', width: 4);
    addOutput('uv_mode', width: 4);
    addOutput('eob', width: addrW + 1);
    addOutput('coeff_out', width: 8); // signed level at coeff_addr
    addOutput('coeffs_out', width: maxCoeffs * 16); // full vector (16-bit each)
    addOutput('done', width: 1);

    final clk = input('clk');
    final reset = input('reset');

    BigInt packIcdf(List<int> icdf) {
      var v = BigInt.zero;
      for (var s = 0; s < 16; s++) {
        v |= BigInt.from((s < icdf.length ? icdf[s] : 0) & 0xFFFF) << (s * 16);
      }
      return v;
    }

    List<int> uniform(int n) => [
      for (var i = 0; i < n; i++) 32768 - ((i + 1) * 32768 / n).round(),
    ];

    // Context CDFs: skip(2), y(13), uv(13), eob(maxCoeffs), base(4), sign(2).
    // eob uses maxCoeffs symbols (0..maxCoeffs-1) to fit the 16-symbol od_ec.
    final ctxCdf = [
      uniform(2),
      uniform(13),
      uniform(13),
      uniform(maxCoeffs),
      uniform(4),
      uniform(2),
    ];
    final ctxNsyms = [2, 13, 13, maxCoeffs, 4, 2];
    final numCtx = ctxCdf.length;

    final state = Logic(name: 'state', width: 3);
    final loadIdx = Logic(name: 'load_idx', width: 3);
    final phase = Logic(name: 'phase', width: 3); // 0 skip..5 sign
    final coeffIdx = Logic(name: 'coeff_idx', width: addrW + 1);
    final skipReg = Logic(name: 'skip_r');
    final yReg = Logic(name: 'y_r', width: 4);
    final uvReg = Logic(name: 'uv_r', width: 4);
    final eobReg = Logic(name: 'eob_r', width: addrW + 1);
    final baseReg = Logic(name: 'base_r', width: 3);
    final coeffs = [
      for (var i = 0; i < maxCoeffs; i++) Logic(name: 'coeff$i', width: 8),
    ];

    const sIdle = 0, sLoad = 1, sIssue = 2, sCapture = 3, sDone = 4;
    const pSkip = 0, pY = 1, pUv = 2, pEob = 3, pBase = 4, pSign = 5;

    final od = HarborOdEcDecoder(name: 'od');
    addSubModule(od);

    final inLoad = state.eq(Const(sLoad, width: 3));
    final issuing = state.eq(Const(sIssue, width: 3));

    od.input('clk').srcConnection! <= clk;
    od.input('reset').srcConnection! <= reset;
    od.input('init').srcConnection! <=
        (inLoad & loadIdx.eq(Const(0, width: 3)));
    od.input('load').srcConnection! <= inLoad;
    od.input('decode').srcConnection! <= issuing;
    // Context: load index while loading, else the phase (= context index).
    od.input('ctx').srcConnection! <=
        mux(inLoad, loadIdx, phase).zeroExtend(od.input('ctx').width);
    Logic muxN(Logic sel, List<int> vals, int w) {
      Logic out = Const(vals[0], width: w);
      for (var i = 1; i < vals.length; i++) {
        out = mux(sel.eq(Const(i, width: 3)), Const(vals[i], width: w), out);
      }
      return out;
    }

    Logic cdfMux(Logic sel) {
      Logic out = Const(packIcdf(ctxCdf[0]), width: 256);
      for (var i = 1; i < numCtx; i++) {
        out = mux(
          sel.eq(Const(i, width: 3)),
          Const(packIcdf(ctxCdf[i]), width: 256),
          out,
        );
      }
      return out;
    }

    od.input('cdf').srcConnection! <= cdfMux(loadIdx);
    od.input('num_syms').srcConnection! <= muxN(loadIdx, ctxNsyms, 5);
    od.input('bytes_in').srcConnection! <= input('bytes_in');
    output('byte_pop') <= od.output('byte_pop');

    final sym = od.output('symbol');
    // eob symbol (0..maxCoeffs-1) -> eob count directly.
    final eobClamped = sym.zeroExtend(addrW + 1);
    final lastCoeff = (coeffIdx + Const(1, width: addrW + 1))
        .getRange(0, addrW + 1)
        .eq(eobReg);
    final signedLevel = baseReg.zeroExtend(8); // base, sign applied in pSign

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 3),
          loadIdx < Const(0, width: 3),
          phase < Const(0, width: 3),
          coeffIdx < Const(0, width: addrW + 1),
          skipReg < Const(0),
          yReg < Const(0, width: 4),
          uvReg < Const(0, width: 4),
          eobReg < Const(0, width: addrW + 1),
          baseReg < Const(0, width: 3),
          for (final c in coeffs) c < Const(0, width: 8),
        ],
        orElse: [
          Case(state, [
            CaseItem(Const(sIdle, width: 3), [
              // Only `start` is valid from idle (loads CDFs + inits the window).
              // `next_blk` is a continuation and is only honoured from sDone, so
              // it never decodes from an uninitialised od_ec (rtl-review finding).
              If(
                input('start'),
                then: [
                  loadIdx < Const(0, width: 3),
                  phase < Const(pSkip, width: 3),
                  coeffIdx < Const(0, width: addrW + 1),
                  for (final c in coeffs) c < Const(0, width: 8),
                  state < Const(sLoad, width: 3),
                ],
              ),
            ]),
            CaseItem(Const(sLoad, width: 3), [
              If(
                loadIdx.eq(Const(numCtx - 1, width: 3)),
                then: [state < Const(sIssue, width: 3)],
                orElse: [
                  loadIdx < (loadIdx + Const(1, width: 3)).getRange(0, 3),
                ],
              ),
            ]),
            CaseItem(Const(sIssue, width: 3), [
              state < Const(sCapture, width: 3),
            ]),
            CaseItem(Const(sCapture, width: 3), [
              Case(phase, [
                CaseItem(Const(pSkip, width: 3), [
                  skipReg < sym.getRange(0, 1),
                  phase < Const(pY, width: 3),
                  state < Const(sIssue, width: 3),
                ]),
                CaseItem(Const(pY, width: 3), [
                  yReg < sym.getRange(0, 4),
                  phase < Const(pUv, width: 3),
                  state < Const(sIssue, width: 3),
                ]),
                CaseItem(Const(pUv, width: 3), [
                  uvReg < sym.getRange(0, 4),
                  If(
                    skipReg,
                    then: [state < Const(sDone, width: 3)],
                    orElse: [
                      phase < Const(pEob, width: 3),
                      state < Const(sIssue, width: 3),
                    ],
                  ),
                ]),
                CaseItem(Const(pEob, width: 3), [
                  eobReg < eobClamped,
                  If(
                    eobClamped.eq(Const(0, width: addrW + 1)),
                    then: [state < Const(sDone, width: 3)],
                    orElse: [
                      coeffIdx < Const(0, width: addrW + 1),
                      phase < Const(pBase, width: 3),
                      state < Const(sIssue, width: 3),
                    ],
                  ),
                ]),
                CaseItem(Const(pBase, width: 3), [
                  baseReg < sym.getRange(0, 3),
                  If(
                    sym.getRange(0, 3).or(),
                    then: [
                      // Nonzero level: read its sign next.
                      phase < Const(pSign, width: 3),
                      state < Const(sIssue, width: 3),
                    ],
                    orElse: [
                      // Zero level: store 0, advance.
                      If(
                        lastCoeff,
                        then: [state < Const(sDone, width: 3)],
                        orElse: [
                          coeffIdx <
                              (coeffIdx + Const(1, width: addrW + 1)).getRange(
                                0,
                                addrW + 1,
                              ),
                          phase < Const(pBase, width: 3),
                          state < Const(sIssue, width: 3),
                        ],
                      ),
                    ],
                  ),
                ]),
                CaseItem(Const(pSign, width: 3), [
                  // Apply sign to the latched base level at coeffIdx.
                  for (var i = 0; i < maxCoeffs; i++)
                    If(
                      coeffIdx.eq(Const(i, width: addrW + 1)),
                      then: [
                        coeffs[i] <
                            mux(
                              sym.getRange(0, 1),
                              (Const(0, width: 8) - signedLevel).getRange(0, 8),
                              signedLevel,
                            ),
                      ],
                    ),
                  If(
                    lastCoeff,
                    then: [state < Const(sDone, width: 3)],
                    orElse: [
                      coeffIdx <
                          (coeffIdx + Const(1, width: addrW + 1)).getRange(
                            0,
                            addrW + 1,
                          ),
                      phase < Const(pBase, width: 3),
                      state < Const(sIssue, width: 3),
                    ],
                  ),
                ]),
              ]),
            ]),
            CaseItem(Const(sDone, width: 3), [
              // Continue the stream + persistent CDFs into the next block.
              If(
                input('next_blk'),
                then: [
                  phase < Const(pSkip, width: 3),
                  coeffIdx < Const(0, width: addrW + 1),
                  for (final c in coeffs) c < Const(0, width: 8),
                  state < Const(sIssue, width: 3),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);

    // coeff_out read mux.
    Logic coeffRead = Const(0, width: 8);
    for (var i = 0; i < maxCoeffs; i++) {
      coeffRead = mux(
        input('coeff_addr').eq(Const(i, width: addrW)),
        coeffs[i],
        coeffRead,
      );
    }

    output('skip') <= skipReg;
    output('y_mode') <= yReg;
    output('uv_mode') <= uvReg;
    output('eob') <= eobReg;
    output('coeff_out') <= coeffRead;
    output('coeffs_out') <=
        [
          for (var i = maxCoeffs - 1; i >= 0; i--) coeffs[i].signExtend(16),
        ].concat();
    output('done') <= state.eq(Const(sDone, width: 3));
  }
}

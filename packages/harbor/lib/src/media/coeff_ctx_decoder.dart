import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'entropy_decoder.dart';

/// Harbor transform-coefficient decoder with AV1 neighbour-derived contexts.
///
/// This is the fuller AV1 coefficient model (vs [HarborCoeffDecoder]'s single
/// fixed context per syntax element). For a 4x4 or 8x8 2D transform block it
/// decodes the base levels in REVERSE scan order (libaom `default_scan_4x4` /
/// `default_scan_8x8`), so the template neighbours to the right and below are
/// already decoded. The entropy context for each base level is derived from
/// those neighbours' levels:
///   mag = sum over the 5-neighbour 2D template of clip3(level)
///   ctx = min((mag + 1) >> 1, 4)
/// and the last coded position (c == eob-1) uses a dedicated base-EOB context.
/// A levels buffer (clipped to 3) tracks already-decoded magnitudes. Range
/// extension and sign follow per coefficient.
///
/// Context map (9 contexts): 0 EOB(16), 1 base-EOB(4), 2..6 base(4) by ctx,
/// 7 range(4), 8 sign(2). Driven by the simplified [HarborEntropyDecoder].
/// `size` selects 4x4 / 8x8. Directional (HORIZ/VERT) templates and AV1's exact
/// per-position offset tables are follow-ups.
class HarborCoeffCtxDecoder extends BridgeModule {
  /// Coefficients per block (64 for the 8x8 case).
  int get maxCoeffs => 64;

  int get posWidth => 6;

  /// Asserted when a block has finished decoding.
  Logic get done => output('done');

  HarborCoeffCtxDecoder({String? name})
    : super('HarborCoeffCtxDecoder', name: name ?? 'coeff_ctx_decoder') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('stall', PortDirection.input);
    createPort('size', PortDirection.input); // 0 = 4x4, 1 = 8x8
    createPort('stream', PortDirection.input, width: 64);
    createPort('bytes_in', PortDirection.input, width: 16);
    createPort('coeff_addr', PortDirection.input, width: posWidth);
    addOutput('byte_pop', width: 2);
    addOutput('done');
    addOutput('coeff_out', width: 16);

    final clk = input('clk');
    final reset = input('reset');
    final size8 = input('size');

    // default CDFs
    BigInt packCdf(List<int> c) {
      var v = BigInt.zero;
      for (var s = 0; s < 16; s++) {
        v |= BigInt.from((s < c.length ? c[s] : 0x8000) & 0xFFFF) << (s * 16);
      }
      return v;
    }

    const numCtx = 9;
    final eobCdf = packCdf([for (var i = 0; i < 16; i++) (i + 1) * 2048]);
    final baseCdf = packCdf([16384, 24576, 30720, 32768]);
    final brCdf = packCdf([8192, 16384, 24576, 32768]);
    final signCdf = packCdf([16384, 32768]);
    final ctxCdf = [
      eobCdf, // 0 EOB
      baseCdf, // 1 base-EOB
      baseCdf, baseCdf, baseCdf, baseCdf, baseCdf, // 2..6 base
      brCdf, // 7 range
      signCdf, // 8 sign
    ];
    const ctxNsyms = [16, 4, 4, 4, 4, 4, 4, 4, 2];

    // AV1 default scans (scan position -> block raster index).
    const scan4 = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];
    const scan8 = [
      0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, //
      12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, //
      35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, //
      58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ];
    const maxBr = 4;

    // FSM
    const sIdle = 0;
    const sLoad = 1;
    const sEob = 2;
    const sBase = 3;
    const sBr = 4;
    const sSign = 5;
    const sDone = 6;

    final state = Logic(name: 'state', width: 3);
    final phase = Logic(name: 'phase');
    final loadIdx = Logic(name: 'load_idx', width: 4);
    final eobM1 = Logic(name: 'eob_m1', width: posWidth);
    final cReg = Logic(name: 'c_reg', width: posWidth);
    final level = Logic(name: 'level', width: 16);
    final brCnt = Logic(name: 'br_cnt', width: 3);
    final doneReg = Logic(name: 'done_reg');
    final coeffBuf = [
      for (var i = 0; i < 64; i++) Logic(name: 'coeff_$i', width: 16),
    ];
    final levels = [
      for (var i = 0; i < 64; i++) Logic(name: 'lvl_$i', width: 2),
    ];

    final entDec = HarborEntropyDecoder(
      maxSyms: 16,
      numCtx: numCtx,
      name: 'ent',
    );
    addSubModule(entDec);
    const entCtxWidth = 4; // numCtx = 9 -> 4 bits

    Logic selByIdx(List<Logic> arr, Logic idx, int idxW) {
      Logic v = arr.last;
      for (var i = arr.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idxW)), arr[i], v);
      }
      return v;
    }

    // Current block position = scan[cReg].
    final blockPos = mux(
      size8,
      selByIdx(
        [for (final p in scan8) Const(p, width: posWidth)],
        cReg,
        posWidth,
      ),
      selByIdx(
        [for (final p in scan4) Const(p, width: posWidth)],
        cReg,
        posWidth,
      ),
    );
    // Block geometry (column/row within the NxN block).
    final col = mux(
      size8,
      blockPos.getRange(0, 3),
      blockPos.getRange(0, 2).zeroExtend(3),
    );
    final row = mux(
      size8,
      blockPos.getRange(3, 6),
      blockPos.getRange(2, 4).zeroExtend(3),
    );
    final wM1 = mux<Logic>(size8, Const(7, width: 3), Const(3, width: 3));
    final wM2 = mux<Logic>(size8, Const(6, width: 3), Const(2, width: 3));
    final colLtM1 = col.lt(wM1);
    final colLtM2 = col.lt(wM2);
    final rowLtM1 = row.lt(wM1);
    final rowLtM2 = row.lt(wM2);

    // 5-neighbour 2D template magnitude (each level already clipped to 3). The
    // template strides by the block width.
    Logic lvlAt(Logic idx) =>
        selByIdx(levels, idx.getRange(0, posWidth), posWidth).zeroExtend(4);
    Logic gate(Logic en, Logic v) =>
        mux(en, v.getRange(0, 4), Const(0, width: 4)).zeroExtend(5);
    final dBelow = mux<Logic>(
      size8,
      Const(8, width: posWidth),
      Const(4, width: posWidth),
    );
    final dBR = mux<Logic>(
      size8,
      Const(9, width: posWidth),
      Const(5, width: posWidth),
    );
    final dBelow2 = mux<Logic>(
      size8,
      Const(16, width: posWidth),
      Const(8, width: posWidth),
    );
    final pRight = (blockPos + Const(1, width: posWidth)).getRange(0, posWidth);
    final pBelow = (blockPos + dBelow).getRange(0, posWidth);
    final pBR = (blockPos + dBR).getRange(0, posWidth);
    final pRight2 = (blockPos + Const(2, width: posWidth)).getRange(
      0,
      posWidth,
    );
    final pBelow2 = (blockPos + dBelow2).getRange(0, posWidth);
    final mag =
        (gate(colLtM1, lvlAt(pRight)) +
                gate(rowLtM1, lvlAt(pBelow)) +
                gate(colLtM1 & rowLtM1, lvlAt(pBR)) +
                gate(colLtM2, lvlAt(pRight2)) +
                gate(rowLtM2, lvlAt(pBelow2)))
            .getRange(0, 5); // 0..15
    final ctxSumRaw = ((mag + Const(1, width: 5)) >>> 1).getRange(0, 5);
    final ctxSum = mux(
      ctxSumRaw.gt(Const(4, width: 5)),
      Const(4, width: 3),
      ctxSumRaw.getRange(0, 3),
    );
    final isLastC = cReg.eq(eobM1);
    final baseCtx = mux(
      isLastC,
      Const(1, width: entCtxWidth),
      (Const(2, width: entCtxWidth) + ctxSum.zeroExtend(entCtxWidth)),
    );

    final inLoad = state.eq(Const(sLoad, width: 3));
    final decCtx = mux(
      inLoad,
      loadIdx,
      mux(
        state.eq(Const(sEob, width: 3)),
        Const(0, width: entCtxWidth),
        mux(
          state.eq(Const(sBase, width: 3)),
          baseCtx,
          mux<Logic>(
            state.eq(Const(sBr, width: 3)),
            Const(7, width: entCtxWidth),
            Const(8, width: entCtxWidth),
          ),
        ),
      ),
    );
    final isDecodeState =
        state.eq(Const(sEob, width: 3)) |
        state.eq(Const(sBase, width: 3)) |
        state.eq(Const(sBr, width: 3)) |
        state.eq(Const(sSign, width: 3));

    entDec.input('clk').srcConnection! <= clk;
    entDec.input('reset').srcConnection! <= reset;
    entDec.input('init').srcConnection! <=
        (inLoad & loadIdx.eq(Const(0, width: 4)));
    entDec.input('load').srcConnection! <= inLoad;
    entDec.input('decode').srcConnection! <=
        (isDecodeState & ~phase & ~input('stall'));
    entDec.input('stream').srcConnection! <= input('stream');
    entDec.input('ctx').srcConnection! <= decCtx;
    entDec.input('cdf').srcConnection! <=
        selByIdx([for (final c in ctxCdf) Const(c, width: 256)], loadIdx, 4);
    entDec.input('num_syms').srcConnection! <=
        selByIdx([for (final n in ctxNsyms) Const(n, width: 5)], loadIdx, 4);
    entDec.input('bytes_in').srcConnection! <= input('bytes_in');
    output('byte_pop') <= entDec.output('byte_pop');
    output('done') <= doneReg;

    final sym = entDec.output('symbol');
    // EOB symbol (0..15) clamped to the block's coefficient count.
    final numCoeffs = mux<Logic>(
      size8,
      Const(64, width: posWidth),
      Const(16, width: posWidth),
    );
    final eobClamped = mux(
      sym.zeroExtend(posWidth).lt(numCoeffs),
      sym.zeroExtend(posWidth),
      numCoeffs,
    );

    Logic rd = Const(0, width: 16);
    for (var i = 63; i >= 0; i--) {
      rd = mux(
        input('coeff_addr').eq(Const(i, width: posWidth)),
        coeffBuf[i],
        rd,
      );
    }
    output('coeff_out') <= rd;

    final levelClip = mux(
      level.gt(Const(3, width: 16)),
      Const(3, width: 2),
      level.getRange(0, 2),
    );
    final signedCoeff = mux(
      sym[0],
      (Const(0, width: 16) - level).getRange(0, 16),
      level,
    );
    List<Conditional> finishCoeff(Logic coeffVal, Logic lvlVal) => [
      for (var i = 0; i < 64; i++)
        If(
          blockPos.eq(Const(i, width: posWidth)),
          then: [coeffBuf[i] < coeffVal, levels[i] < lvlVal],
        ),
      phase < Const(0),
      If(
        cReg.eq(Const(0, width: posWidth)),
        then: [state < Const(sDone, width: 3)],
        orElse: [
          cReg < (cReg - Const(1, width: posWidth)),
          state < Const(sBase, width: 3),
        ],
      ),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(sIdle, width: 3),
          phase < Const(0),
          loadIdx < Const(0, width: 4),
          eobM1 < Const(0, width: posWidth),
          cReg < Const(0, width: posWidth),
          level < Const(0, width: 16),
          brCnt < Const(0, width: 3),
          doneReg < Const(0),
          for (var i = 0; i < 64; i++) ...[
            coeffBuf[i] < Const(0, width: 16),
            levels[i] < Const(0, width: 2),
          ],
        ],
        orElse: [
          If(
            ~input('stall'),
            then: [
              Case(state, [
                CaseItem(Const(sIdle, width: 3), [
                  If(
                    input('start'),
                    then: [
                      doneReg < Const(0),
                      loadIdx < Const(0, width: 4),
                      phase < Const(0),
                      for (var i = 0; i < 64; i++) ...[
                        coeffBuf[i] < Const(0, width: 16),
                        levels[i] < Const(0, width: 2),
                      ],
                      state < Const(sLoad, width: 3),
                    ],
                  ),
                ]),
                CaseItem(Const(sLoad, width: 3), [
                  If(
                    loadIdx.eq(Const(numCtx - 1, width: 4)),
                    then: [state < Const(sEob, width: 3)],
                    orElse: [loadIdx < (loadIdx + Const(1, width: 4))],
                  ),
                ]),
                CaseItem(Const(sEob, width: 3), [
                  If(
                    phase,
                    then: [
                      phase < Const(0),
                      If(
                        eobClamped.eq(Const(0, width: posWidth)),
                        then: [state < Const(sDone, width: 3)],
                        orElse: [
                          eobM1 < (eobClamped - Const(1, width: posWidth)),
                          cReg < (eobClamped - Const(1, width: posWidth)),
                          state < Const(sBase, width: 3),
                        ],
                      ),
                    ],
                    orElse: [phase < Const(1)],
                  ),
                ]),
                CaseItem(Const(sBase, width: 3), [
                  If(
                    phase,
                    then: [
                      level < sym.zeroExtend(16),
                      If(
                        sym.eq(Const(0, width: 4)),
                        then: finishCoeff(
                          Const(0, width: 16),
                          Const(0, width: 2),
                        ),
                        orElse: [
                          If(
                            sym.lt(Const(3, width: 4)),
                            then: [
                              phase < Const(0),
                              state < Const(sSign, width: 3),
                            ],
                            orElse: [
                              phase < Const(0),
                              brCnt < Const(0, width: 3),
                              state < Const(sBr, width: 3),
                            ],
                          ),
                        ],
                      ),
                    ],
                    orElse: [phase < Const(1)],
                  ),
                ]),
                CaseItem(Const(sBr, width: 3), [
                  If(
                    phase,
                    then: [
                      level < (level + sym.zeroExtend(16)),
                      phase < Const(0),
                      If(
                        sym.lt(Const(3, width: 4)) |
                            brCnt.eq(Const(maxBr - 1, width: 3)),
                        then: [state < Const(sSign, width: 3)],
                        orElse: [brCnt < (brCnt + Const(1, width: 3))],
                      ),
                    ],
                    orElse: [phase < Const(1)],
                  ),
                ]),
                CaseItem(Const(sSign, width: 3), [
                  If(
                    phase,
                    then: finishCoeff(signedCoeff, levelClip),
                    orElse: [phase < Const(1)],
                  ),
                ]),
                CaseItem(Const(sDone, width: 3), [
                  doneReg < Const(1),
                  state < Const(sIdle, width: 3),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }
}

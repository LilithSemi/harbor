import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'entropy_decoder.dart';
import 'od_ec_decoder.dart';

/// Harbor transform-coefficient decoder.
///
/// Decodes a block of transform coefficients from the coded bitstream using a
/// [HarborEntropyDecoder], following an AV1-flavored coefficient syntax:
/// - an **end-of-block** symbol giving how many coefficients are coded,
/// - per scan position a **base level** (0..3),
/// - a **range extension** loop when the base saturates (each step adds 0..3,
///   continuing while it saturates, up to a cap), and
/// - a **sign** for every non-zero coefficient.
///
/// Each syntax element uses its own adaptive CDF context. This is a compact
/// model of AV1's coefficient coding. Neighbour-derived contexts, the exact
/// scan orders and the Golomb tail for very large levels are simplifications.
///
/// Interface:
/// - start / num_coeffs : begin decoding a block of `num_coeffs` positions.
/// - stream / bytes_in / byte_pop : the coded-bit feed (passed to the decoder).
/// - done : asserted when the block is decoded.
/// - coeff_addr / coeff_out : read back the decoded (signed) coefficients.
class HarborCoeffDecoder extends BridgeModule {
  /// Maximum coefficients per block (scan positions).
  final int maxCoeffs;

  /// Address width for the coefficient buffer.
  int get posWidth => (maxCoeffs - 1).bitLength + 1;

  /// Asserted when a block has finished decoding.
  Logic get done => output('done');

  /// Use the real libaom od_ec range coder ([HarborOdEcDecoder]) instead of the
  /// simplified [HarborEntropyDecoder]. With od_ec the window initializes from
  /// the byte feed (no 64-bit `stream` port) and `bytes_in` carries three bytes.
  final bool useOdEc;

  HarborCoeffDecoder({this.maxCoeffs = 16, this.useOdEc = false, String? name})
    : super('HarborCoeffDecoder', name: name ?? 'coeff_decoder') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    // Decode another block reusing the already-adapted CDFs and the continuing
    // stream window (no CDF reload), for tile/frame decode where the entropy
    // contexts persist across blocks. Mutually exclusive with `start`.
    createPort('next_blk', PortDirection.input);
    createPort('stall', PortDirection.input); // freeze while a beat is refilled
    createPort('num_coeffs', PortDirection.input, width: posWidth);
    if (!useOdEc) createPort('stream', PortDirection.input, width: 64);
    createPort('bytes_in', PortDirection.input, width: useOdEc ? 24 : 16);
    createPort('coeff_addr', PortDirection.input, width: posWidth);
    addOutput('byte_pop', width: 2);
    addOutput('done');
    addOutput('coeff_out', width: 16);

    final clk = input('clk');
    final reset = input('reset');

    // coefficient syntax contexts and their default CDFs
    // Cumulative (simplified) or AV1 inverse-CDF (od_ec): icdf[i] = 32768 -
    // cumulative[i], decreasing with icdf[nsyms-1] = 0.
    BigInt packCdf(List<int> c) {
      var v = BigInt.zero;
      for (var s = 0; s < 16; s++) {
        v |=
            BigInt.from(
              (s < c.length ? c[s] : (useOdEc ? 0 : 0x8000)) & 0xFFFF,
            ) <<
            (s * 16);
      }
      return v;
    }

    const ctxEob = 0;
    const ctxBase = 1;
    const ctxBr = 2;
    const ctxSign = 3;
    const maxBr = 4; // range-extension steps before stopping
    final cdfs = useOdEc
        ? [
            packCdf([for (var i = 0; i < 16; i++) (15 - i) * 2048]), // EOB icdf
            packCdf([16384, 8192, 2048, 0]), // base level
            packCdf([24576, 16384, 8192, 0]), // range
            packCdf([16384, 0]), // sign
          ]
        : [
            packCdf([for (var i = 0; i < 16; i++) (i + 1) * 2048]), // EOB (16)
            packCdf([16384, 24576, 30720, 32768]), // base level (4)
            packCdf([8192, 16384, 24576, 32768]), // range (4)
            packCdf([16384, 32768]), // sign (2)
          ];
    const numSymsArr = [16, 4, 4, 2];

    // FSM
    const sIdle = 0;
    const sLoad = 1; // load the four CDF contexts
    const sEob = 2;
    const sBase = 3;
    const sBr = 4;
    const sSign = 5;
    const sDone = 6;

    final state = Logic(name: 'state', width: 3);
    final phase = Logic(name: 'phase'); // 0 = issue decode, 1 = capture
    final loadIdx = Logic(name: 'load_idx', width: 2);
    final eob = Logic(name: 'eob', width: posWidth);
    final pos = Logic(name: 'pos', width: posWidth);
    final level = Logic(name: 'level', width: 16);
    final brCnt = Logic(name: 'br_cnt', width: 3);
    final doneReg = Logic(name: 'done_reg');
    final coeffBuf = [
      for (var i = 0; i < maxCoeffs; i++) Logic(name: 'coeff_$i', width: 16),
    ];

    final entDec = useOdEc
        ? HarborOdEcDecoder(maxSyms: 16, numCtx: 4, name: 'ent')
        : HarborEntropyDecoder(maxSyms: 16, numCtx: 4, name: 'ent');
    addSubModule(entDec);
    const entCtxWidth = 2; // numCtx = 4

    Logic mux4(Logic sel, List<Logic> v) => mux(
      sel.eq(Const(0, width: 2)),
      v[0],
      mux(
        sel.eq(Const(1, width: 2)),
        v[1],
        mux(sel.eq(Const(2, width: 2)), v[2], v[3]),
      ),
    );

    // Context for the current decode: the loading index, or the syntax element.
    final inLoad = state.eq(Const(sLoad, width: 3)).named('in_load');
    final decCtx = mux(
      inLoad,
      loadIdx,
      mux(
        state.eq(Const(sEob, width: 3)),
        Const(ctxEob, width: 2),
        mux(
          state.eq(Const(sBase, width: 3)),
          Const(ctxBase, width: 2),
          mux<Logic>(
            state.eq(Const(sBr, width: 3)),
            Const(ctxBr, width: 2),
            Const(ctxSign, width: 2),
          ),
        ),
      ),
    ).named('dec_ctx');
    final isDecodeState =
        (state.eq(Const(sEob, width: 3)) |
                state.eq(Const(sBase, width: 3)) |
                state.eq(Const(sBr, width: 3)) |
                state.eq(Const(sSign, width: 3)))
            .named('is_decode');

    entDec.input('clk').srcConnection! <= clk;
    entDec.input('reset').srcConnection! <= reset;
    entDec.input('init').srcConnection! <=
        (inLoad & loadIdx.eq(Const(0, width: 2)));
    entDec.input('load').srcConnection! <= inLoad;
    entDec.input('decode').srcConnection! <=
        (isDecodeState & ~phase & ~input('stall'));
    // od_ec initializes the window from the byte feed, the simplified decoder
    // loads a 64-bit stream window.
    if (!useOdEc) entDec.input('stream').srcConnection! <= input('stream');
    entDec.input('ctx').srcConnection! <= decCtx.getRange(0, entCtxWidth);
    entDec.input('cdf').srcConnection! <=
        mux4(loadIdx, [for (final c in cdfs) Const(c, width: 256)]);
    entDec.input('num_syms').srcConnection! <=
        mux4(loadIdx, [for (final n in numSymsArr) Const(n, width: 5)]);
    entDec.input('bytes_in').srcConnection! <= input('bytes_in');
    output('byte_pop') <= entDec.output('byte_pop');
    output('done') <= doneReg;

    final sym = entDec.output('symbol'); // 4-bit decoded symbol
    // End-of-block clamped to the block's coefficient count.
    final eobClamped = mux(
      sym.zeroExtend(posWidth).lt(input('num_coeffs')),
      sym.zeroExtend(posWidth),
      input('num_coeffs'),
    ).named('eob_clamped');
    // Read port for the coefficient buffer.
    Logic rd = Const(0, width: 16);
    for (var i = maxCoeffs - 1; i >= 0; i--) {
      rd = mux(
        input('coeff_addr').eq(Const(i, width: posWidth)),
        coeffBuf[i],
        rd,
      );
    }
    output('coeff_out') <= rd;

    // Writes the coefficient at `pos`, then either decodes the next position or
    // finishes the block.
    List<Conditional> placeAndAdvance(Logic value) => [
      for (var i = 0; i < maxCoeffs; i++)
        If(pos.eq(Const(i, width: posWidth)), then: [coeffBuf[i] < value]),
      phase < Const(0),
      If(
        (pos + Const(1, width: posWidth)).eq(eob),
        then: [state < Const(sDone, width: 3)],
        orElse: [
          pos < (pos + Const(1, width: posWidth)),
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
          loadIdx < Const(0, width: 2),
          eob < Const(0, width: posWidth),
          pos < Const(0, width: posWidth),
          level < Const(0, width: 16),
          brCnt < Const(0, width: 3),
          doneReg < Const(0),
          for (var i = 0; i < maxCoeffs; i++) coeffBuf[i] < Const(0, width: 16),
        ],
        orElse: [
          // Frozen while the environment refills a stream beat.
          If(
            ~input('stall'),
            then: [
              Case(state, [
                CaseItem(Const(sIdle, width: 3), [
                  If(
                    input('start'),
                    then: [
                      doneReg < Const(0),
                      loadIdx < Const(0, width: 2),
                      phase < Const(0),
                      pos < Const(0, width: posWidth),
                      for (var i = 0; i < maxCoeffs; i++)
                        coeffBuf[i] < Const(0, width: 16),
                      state < Const(sLoad, width: 3),
                    ],
                    orElse: [
                      // Continue: skip the CDF load, decode straight from EOB,
                      // reusing the adapted contexts and the live stream window.
                      If(
                        input('next_blk'),
                        then: [
                          doneReg < Const(0),
                          phase < Const(0),
                          pos < Const(0, width: posWidth),
                          for (var i = 0; i < maxCoeffs; i++)
                            coeffBuf[i] < Const(0, width: 16),
                          state < Const(sEob, width: 3),
                        ],
                      ),
                    ],
                  ),
                ]),
                // Load the four CDF contexts (and init the window on the first).
                CaseItem(Const(sLoad, width: 3), [
                  If(
                    loadIdx.eq(Const(3, width: 2)),
                    then: [state < Const(sEob, width: 3)],
                    orElse: [loadIdx < (loadIdx + Const(1, width: 2))],
                  ),
                ]),
                // End-of-block: how many coefficients are coded.
                CaseItem(Const(sEob, width: 3), [
                  If(
                    phase,
                    then: [
                      phase < Const(0),
                      eob < eobClamped,
                      If(
                        eobClamped.eq(Const(0, width: posWidth)),
                        then: [state < Const(sDone, width: 3)],
                        orElse: [state < Const(sBase, width: 3)],
                      ),
                    ],
                    orElse: [phase < Const(1)],
                  ),
                ]),
                // Base level for the current position.
                CaseItem(Const(sBase, width: 3), [
                  If(
                    phase,
                    then: [
                      level < sym.zeroExtend(16),
                      If(
                        sym.eq(Const(0, width: 4)),
                        then: placeAndAdvance(Const(0, width: 16)),
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
                // Range extension: keep adding while the symbol saturates.
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
                // Sign for a non-zero coefficient.
                CaseItem(Const(sSign, width: 3), [
                  If(
                    phase,
                    then: placeAndAdvance(
                      mux(sym[0], (Const(0, width: 16) - level), level),
                    ),
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

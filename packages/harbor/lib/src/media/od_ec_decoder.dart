import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor AV1 od_ec multi-symbol entropy decoder (the real libaom range coder),
/// with per-context adaptive CDFs.
///
/// The range coder implements libaom's `od_ec_decode_cdf_q15` exactly
/// (aom/aom_dsp/entdec.c, entcommon.h): a 32-bit "difference" window [dif], a
/// 16-bit range [rng] in [0x8000, 0xFFFF], and a bit counter. Probabilities are
/// the AV1 *inverse* CDF (ICDF, Q15, monotonically decreasing, icdf[nsyms-1]=0).
/// For each symbol boundary,
///   v = ((rng >> 8) * (icdf[ret] >> EC_PROB_SHIFT)) >> (7 - EC_PROB_SHIFT)
///       + EC_MIN_PROB * (nsyms - 1 - ret)
/// (EC_PROB_SHIFT = 6, EC_MIN_PROB = 4). The symbol is the first whose boundary
/// the top 16 bits of the window meet, then the window renormalizes with the
/// inverted update `dif = ((dif + 1) << d) - 1` and refills bytes by XOR.
///
/// The decoder OWNS its CDFs in a per-context memory ([numCtx] contexts, each
/// [maxSyms] ICDF entries + an adaptation count). After every decode it adapts
/// the context with libaom's `update_cdf`: entries below the decoded symbol move
/// toward 32768, the rest toward 0, by `>> rate`, where
///   rate = 3 + (count > 15) + (count > 31) + speed(nsyms)
/// (speed: 0 for n<2, 1 for n<4, else 2), the count saturating at 32. This is
/// the genuine AV1 entropy path (vs the simplified [HarborEntropyDecoder]).
///
/// Ports: `init` loads the window from the first stream bytes. `load` stores the
/// `cdf`/`num_syms` input into context `ctx` and resets its count. `decode`
/// decodes one symbol from context `ctx`, adapting it. Up to three stream bytes
/// are consumed per op (`byte_pop`). The environment feeds the next three on
/// `bytes_in` (MSB byte first) and advances by `byte_pop`.
class HarborOdEcDecoder extends BridgeModule {
  /// Maximum alphabet size.
  final int maxSyms;

  /// Number of adaptive CDF contexts.
  final int numCtx;

  int get symWidth => (maxSyms - 1).bitLength;
  int get ctxWidth => numCtx <= 1 ? 1 : (numCtx - 1).bitLength;

  /// Decoded symbol.
  Logic get symbol => output('symbol');

  HarborOdEcDecoder({this.maxSyms = 16, this.numCtx = 8, String? name})
    : super(
        'HarborOdEcDecoder_S${maxSyms}_C$numCtx',
        name: name ?? 'od_ec',
      ) {
    const w = 32; // OD_EC_WINDOW_SIZE
    const probShift = 6; // EC_PROB_SHIFT
    const minProb = 4; // EC_MIN_PROB

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('init', PortDirection.input); // load initial window + refill
    createPort('load', PortDirection.input); // store cdf/num_syms into ctx
    createPort('decode', PortDirection.input); // decode one symbol from ctx
    createPort('ctx', PortDirection.input, width: ctxWidth);
    createPort(
      'cdf',
      PortDirection.input,
      width: maxSyms * 16,
    ); // ICDF for load
    createPort('num_syms', PortDirection.input, width: 5);
    createPort('bytes_in', PortDirection.input, width: 24); // next 3 bytes
    addOutput('symbol', width: symWidth);
    addOutput('byte_pop', width: 2);
    addOutput('rng', width: 16);

    final clk = input('clk');
    final reset = input('reset');
    final ctxIn = input('ctx');

    // window state (shared across contexts: it tracks the bitstream)
    final difReg = Logic(name: 'dif', width: w);
    final rngReg = Logic(name: 'rng_r', width: 16);
    final winCnt = Logic(name: 'win_cnt', width: 8); // signed bit-count
    // The decoded symbol is registered (1-cycle latency), so a consumer can
    // capture it the cycle after issuing `decode` (matching the simplified
    // HarborEntropyDecoder). The combinational symFinal feeds adaptation/window.
    final symReg = Logic(name: 'sym_reg', width: symWidth);

    // per-context CDF memory
    final cdfMem = [
      for (var c = 0; c < numCtx; c++)
        [
          for (var s = 0; s < maxSyms; s++)
            Logic(name: 'cdf_${c}_$s', width: 16),
        ],
    ];
    final nsymsMem = [
      for (var c = 0; c < numCtx; c++) Logic(name: 'nsyms_$c', width: 5),
    ];
    final adaptCnt = [
      for (var c = 0; c < numCtx; c++) Logic(name: 'acnt_$c', width: 6),
    ];

    final cdfIn = [
      for (var s = 0; s < maxSyms; s++)
        input('cdf').getRange(s * 16, s * 16 + 16),
    ];
    final b0 = input('bytes_in').getRange(16, 24);
    final b1 = input('bytes_in').getRange(8, 16);
    final b2 = input('bytes_in').getRange(0, 8);

    // Select context `ctx`'s entries.
    Logic selCtx(List<Logic> perCtx) {
      Logic v = perCtx.last;
      for (var c = numCtx - 2; c >= 0; c--) {
        v = mux(ctxIn.eq(Const(c, width: ctxWidth)), perCtx[c], v);
      }
      return v;
    }

    final curCdf = [
      for (var s = 0; s < maxSyms; s++)
        selCtx([for (var c = 0; c < numCtx; c++) cdfMem[c][s]]),
    ];
    final curNsyms = selCtx(nsymsMem);
    final curCnt = selCtx(adaptCnt);

    // combinational refill: XOR up to three bytes at s = 8 - cnt, -8, -16.
    ({Logic dif, Logic cnt, Logic pop}) refill(Logic dif, Logic cnt) {
      final s0 = (Const(8, width: 9) - [cnt[7], cnt].swizzle()).getRange(0, 9);
      final s1 = (s0 - Const(8, width: 9)).getRange(0, 9);
      final s2 = (s0 - Const(16, width: 9)).getRange(0, 9);
      final l0 = ~s0[8];
      final l1 = ~s1[8];
      final l2 = ~s2[8];
      Logic sh(Logic b, Logic s, Logic en) => mux(
        en,
        (b.zeroExtend(w) << s.getRange(0, 6)).getRange(0, w),
        Const(0, width: w),
      );
      final newDif = (dif ^ sh(b0, s0, l0) ^ sh(b1, s1, l1) ^ sh(b2, s2, l2));
      final pop = (l0.zeroExtend(2) + l1.zeroExtend(2) + l2.zeroExtend(2))
          .getRange(0, 2);
      final newCnt = (cnt + [pop, Const(0, width: 3)].swizzle().zeroExtend(8))
          .getRange(0, 8);
      return (dif: newDif, cnt: newCnt, pop: pop);
    }

    // decode one symbol from (difReg, rngReg) using the context's CDF.
    final c16 = difReg.getRange(w - 16, w);
    final vArr = <Logic>[];
    for (var ret = 0; ret < maxSyms; ret++) {
      final prob = curCdf[ret].getRange(probShift, 16); // icdf[ret] >> 6
      final prod =
          ((rngReg.getRange(8, 16).zeroExtend(24) * prob.zeroExtend(24))
              .getRange(0, 24) >>>
          (7 - probShift)); // >> 1
      final tail =
          ((curNsyms.zeroExtend(16) - Const(1 + ret, width: 16)).getRange(
                    0,
                    16,
                  ) *
                  Const(minProb, width: 16))
              .getRange(0, 16);
      vArr.add((prod.getRange(0, 16) + tail).getRange(0, 16).named('v_$ret'));
    }
    Logic symFinal = Const(0, width: symWidth);
    for (var ret = maxSyms - 1; ret >= 0; ret--) {
      final inRange = Const(ret, width: 5).lt(curNsyms);
      final cond = inRange & c16.gte(vArr[ret]);
      symFinal = mux(cond, Const(ret, width: symWidth), symFinal);
    }

    Logic selV(Logic idx) {
      Logic v = vArr.last;
      for (var i = maxSyms - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: symWidth)), vArr[i], v);
      }
      return v;
    }

    final vSym = selV(symFinal);
    final uSym = mux(
      symFinal.eq(Const(0, width: symWidth)),
      rngReg,
      selV((symFinal - Const(1, width: symWidth)).getRange(0, symWidth)),
    );
    final rNew = (uSym - vSym).getRange(0, 16);
    final difDec = (difReg - [vSym, Const(0, width: w - 16)].swizzle())
        .getRange(0, w);

    Logic ilog(Logic x) {
      Logic n = Const(0, width: 5);
      for (var i = 0; i < 16; i++) {
        n = mux(x[i], Const(i + 1, width: 5), n);
      }
      return n;
    }

    final d = (Const(16, width: 5) - ilog(rNew)).getRange(0, 5);
    final difShift =
        (((difDec + Const(1, width: w)).getRange(0, w) << d) -
                Const(1, width: w))
            .getRange(0, w);
    final rngShift = (rNew.zeroExtend(16) << d).getRange(0, 16);
    final cntAfter = (winCnt - [d[4], d].swizzle().zeroExtend(8)).getRange(
      0,
      8,
    );
    final needRefill = cntAfter[7];
    final decRefill = refill(difShift, cntAfter);

    // update_cdf: adapt the context's CDF toward the decoded symbol.
    final speed = mux(
      curNsyms.lt(Const(2, width: 5)),
      Const(0, width: 2),
      mux(
        curNsyms.lt(Const(4, width: 5)),
        Const(1, width: 2),
        Const(2, width: 2),
      ),
    );
    final rate =
        (Const(3, width: 4) +
                curCnt.gt(Const(15, width: 6)).zeroExtend(4) +
                curCnt.gt(Const(31, width: 6)).zeroExtend(4) +
                speed.zeroExtend(4))
            .getRange(0, 4);
    final adaptedCdf = <Logic>[];
    for (var s = 0; s < maxSyms; s++) {
      final toward = mux(
        Const(s, width: symWidth).lt(symFinal),
        Const(32768, width: 16),
        Const(0, width: 16),
      );
      final up = curCdf[s].lte(toward); // move up toward `toward`
      final mag = mux(
        up,
        (toward - curCdf[s]).getRange(0, 16),
        (curCdf[s] - toward).getRange(0, 16),
      );
      final delta = (mag >>> rate).getRange(0, 16);
      final moved = mux(
        up,
        (curCdf[s] + delta).getRange(0, 16),
        (curCdf[s] - delta).getRange(0, 16),
      );
      // Only entries 0..nsyms-2 are updated. The rest (incl. icdf[nsyms-1]=0)
      // are untouched.
      final inUpd = Const(s, width: 5).lt((curNsyms - Const(1, width: 5)));
      adaptedCdf.add(mux(inUpd, moved, curCdf[s]));
    }
    final newAdaptCnt = mux(
      curCnt.lt(Const(32, width: 6)),
      (curCnt + Const(1, width: 6)).getRange(0, 6),
      Const(32, width: 6),
    );

    // init
    final initDif = Const((1 << (w - 1)) - 1, width: w);
    const initCntVal = -15 & 0xFF;
    final initRefill = refill(initDif, Const(initCntVal, width: 8));

    output('symbol') <= symReg;
    output('rng') <= rngReg;
    output('byte_pop') <=
        mux(
          input('init'),
          initRefill.pop,
          mux(input('decode') & needRefill, decRefill.pop, Const(0, width: 2)),
        );

    Sequential(clk, [
      If(
        reset,
        then: [
          difReg < Const(0, width: w),
          rngReg < Const(0x8000, width: 16),
          winCnt < Const(0, width: 8),
          symReg < Const(0, width: symWidth),
          for (var c = 0; c < numCtx; c++) ...[
            nsymsMem[c] < Const(0, width: 5),
            adaptCnt[c] < Const(0, width: 6),
            for (var s = 0; s < maxSyms; s++)
              cdfMem[c][s] < Const(0, width: 16),
          ],
        ],
        orElse: [
          If(
            input('init'),
            then: [
              difReg < initRefill.dif,
              rngReg < Const(0x8000, width: 16),
              winCnt < initRefill.cnt,
            ],
          ),
          If(
            input('load'),
            then: [
              for (var c = 0; c < numCtx; c++)
                If(
                  ctxIn.eq(Const(c, width: ctxWidth)),
                  then: [
                    for (var s = 0; s < maxSyms; s++) cdfMem[c][s] < cdfIn[s],
                    nsymsMem[c] < input('num_syms'),
                    adaptCnt[c] < Const(0, width: 6),
                  ],
                ),
            ],
          ),
          If(
            input('decode'),
            then: [
              difReg < mux(needRefill, decRefill.dif, difShift),
              rngReg < rngShift,
              winCnt < mux(needRefill, decRefill.cnt, cntAfter),
              symReg < symFinal,
              for (var c = 0; c < numCtx; c++)
                If(
                  ctxIn.eq(Const(c, width: ctxWidth)),
                  then: [
                    for (var s = 0; s < maxSyms; s++)
                      cdfMem[c][s] < adaptedCdf[s],
                    adaptCnt[c] < newAdaptCnt,
                  ],
                ),
            ],
          ),
        ],
      ),
    ]);
  }
}

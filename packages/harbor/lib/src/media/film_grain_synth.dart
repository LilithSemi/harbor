import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'film_grain_gaussian.dart';

/// AV1 film-grain template synthesis engine (the autoregressive noise
/// generation).
///
/// Clocked, single-pass-per-plane sequential datapath: an LFSR draws Gaussian
/// samples into each template position (fill), and the same raster pass folds in
/// the AR filter using the already-finalized neighbours (held in a shift
/// register, so the taps are free fixed slices). The chroma passes additionally
/// fold in the luma-average cross term. Produces the luma, Cb and Cr grain
/// templates.
///
/// Structural parameters baked at elaboration (profile/header constants):
/// `ssx`/`ssy` (subsampling), `bd` (bit depth), `arCoeffLag`, and whether Cb/Cr
/// are generated / chroma-from-luma / luma cross-term present. The seed, AR
/// coefficient values, `arCoeffShift` and `grainScaleShift` are runtime ports.
///
/// Grain template entries are signed [grainW]-bit values, packed LSB-first into
/// the output buses (position `c` at bits `[c*grainW, c*grainW+grainW)`), row
/// major with the plane's block stride.
class HarborFilmGrainSynth extends BridgeModule {
  final int ssx;
  final int ssy;
  final int bd;
  final int arCoeffLag;
  final bool genCb;
  final bool genCr;
  final bool chromaFromLuma;

  /// Whether the luma->chroma cross term is present (num_y_points > 0).
  final bool lumaCross;

  /// Signed width of a stored grain sample (covers bd 8/10/12 clamp ranges).
  static const int grainW = 16;

  // Geometry (mirrors addFilmGrain / synthesizeGrainTemplates).
  late final int lumaBlockY, lumaBlockX, lumaStride, nLuma;
  late final int chromaBlockY, chromaBlockX, chromaStride, nChroma;
  late final int numPosLuma;

  HarborFilmGrainSynth({
    this.ssx = 1,
    this.ssy = 1,
    this.bd = 8,
    this.arCoeffLag = 3,
    this.genCb = true,
    this.genCr = true,
    this.chromaFromLuma = false,
    this.lumaCross = true,
    String? name,
  }) : super(
         'HarborFilmGrainSynth_SX${ssx}_SY${ssy}_B${bd}_AR${arCoeffLag}_'
         'CB${genCb ? 1 : 0}_CR${genCr ? 1 : 0}_CFL${chromaFromLuma ? 1 : 0}_'
         'LX${lumaCross ? 1 : 0}',
         name: name ?? 'film_grain_synth',
       ) {
    const leftPad = 3, rightPad = 3, topPad = 3, bottomPad = 0, arPadding = 3;
    const lumaSubY = 32, lumaSubX = 32;
    final chromaSubY = lumaSubY >> ssy, chromaSubX = lumaSubX >> ssx;

    lumaBlockY = topPad + 2 * arPadding + lumaSubY * 2 + bottomPad;
    lumaBlockX =
        leftPad + 2 * arPadding + lumaSubX * 2 + 2 * arPadding + rightPad;
    chromaBlockY = topPad + (2 >> ssy) * arPadding + chromaSubY * 2 + bottomPad;
    chromaBlockX =
        leftPad +
        (2 >> ssx) * arPadding +
        chromaSubX * 2 +
        (2 >> ssx) * arPadding +
        rightPad;
    lumaStride = lumaBlockX;
    chromaStride = chromaBlockX;
    nLuma = lumaBlockY * lumaStride;
    nChroma = chromaBlockY * chromaStride;
    numPosLuma = 2 * arCoeffLag * (arCoeffLag + 1);

    // AR tap (dr,dc) list, exact SW pred_pos order.
    final taps = <List<int>>[];
    for (var row = -arCoeffLag; row < 0; row++) {
      for (var col = -arCoeffLag; col < arCoeffLag + 1; col++) {
        taps.add([row, col]);
      }
    }
    for (var col = -arCoeffLag; col < 0; col++) {
      taps.add([0, col]);
    }
    assert(taps.length == numPosLuma);

    const grainCenter8 = 128;
    final grainCenter = grainCenter8 << (bd - 8);
    final grainMin = 0 - grainCenter, grainMax = grainCenter - 1;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('seed', PortDirection.input, width: 16);
    createPort('ar_coeff_shift', PortDirection.input, width: 4);
    createPort('grain_scale_shift', PortDirection.input, width: 4);
    // AR coefficient buses, signed 8b per position, LSB-first.
    createPort('ar_coeffs_y', PortDirection.input, width: 24 * 8);
    createPort('ar_coeffs_cb', PortDirection.input, width: 25 * 8);
    createPort('ar_coeffs_cr', PortDirection.input, width: 25 * 8);

    addOutput('luma', width: nLuma * grainW);
    addOutput('cb', width: nChroma * grainW);
    addOutput('cr', width: nChroma * grainW);
    addOutput('done');

    final clk = input('clk');
    final reset = input('reset');
    final start = input('start');
    final seed = input('seed');
    final arShift = input('ar_coeff_shift');
    final gss = input('grain_scale_shift');
    final arY = input('ar_coeffs_y');
    final arCb = input('ar_coeffs_cb');
    final arCr = input('ar_coeffs_cr');
    final outLuma = output('luma');
    final outCb = output('cb');
    final outCr = output('cr');
    final done = output('done');

    // Balanced tree multiplexer: returns vals[sel] for sel < vals.length. Built
    // as a log-depth binary reduction so signal propagation does not recurse
    // linearly (a long linear mux chain overflows the ROHD propagation stack).
    // The list is padded to a power of two so every level is even and the pure
    // binary tree selects exactly (padding entries are never addressed).
    Logic treeMux(Logic sel, List<Logic> vals) {
      final w = vals.first.width;
      var level = List<Logic>.from(vals);
      var pow2 = 1;
      while (pow2 < level.length) {
        pow2 <<= 1;
      }
      while (level.length < pow2) {
        level.add(Const(0, width: w));
      }
      var bit = 0;
      while (level.length > 1) {
        final next = <Logic>[];
        for (var i = 0; i < level.length; i += 2) {
          next.add(mux(sel[bit], level[i + 1], level[i]));
        }
        level = next;
        bit++;
      }
      return level[0];
    }

    // Gaussian ROM (2048 x 12b signed), read by an 11-bit index.
    Logic gaussRom(Logic idx11) => treeMux(idx11, [
      for (var i = 0; i < 2048; i++)
        Const(kGaussianSequence[i] & 0xFFF, width: 12),
    ]);

    // Arithmetic right shift of signed [x] (width w) by runtime [sh] (0..15).
    Logic asr(Logic x, int w, Logic sh) {
      Logic build(int k) {
        if (k == 0) return x;
        if (k >= w) return x[w - 1].replicate(w);
        return [x[w - 1].replicate(k), x.getRange(k, w)].swizzle();
      }

      Logic v = build(0);
      for (var k = 1; k <= 15; k++) {
        v = mux(sh.eq(Const(k, width: 4)), build(k), v);
      }
      return v;
    }

    // gauss_sec_shift = 12 - bd + grain_scale_shift (runtime via gss).
    final gaussSecShift = (Const(12 - bd, width: 4) + gss).getRange(0, 4);

    // fill value from a gauss sample: (gauss + (1<<gss2>>1)) >> gss2, signed.
    Logic fillFrom(Logic idx11) {
      final g = gaussRom(idx11).signExtend(20);
      // rounding = (1<<gaussSecShift)>>1. Add then arithmetic shift.
      Logic rnd = Const(0, width: 20);
      for (var k = 1; k <= 15; k++) {
        rnd = mux(
          gaussSecShift.eq(Const(k, width: 4)),
          Const(1 << (k - 1), width: 20),
          rnd,
        );
      }
      final biased = (g + rnd).getRange(0, 20);
      return asr(biased, 20, gaussSecShift).getRange(0, grainW);
    }

    // Clamp a signed [x] (width 32) to [grainMin, grainMax], return grainW.
    // Signed comparison via the sign bit of a two's-complement subtraction
    // (operands are small, no 32-bit overflow).
    Logic clampGrain(Logic x) {
      final lo = Const(grainMin & 0xFFFFFFFF, width: 32);
      final hi = Const(grainMax & 0xFFFFFFFF, width: 32);
      final xLtLo = (x - lo).getRange(31, 32); // (x-lo)<0  => x<lo
      final c1 = mux(xLtLo, lo, x);
      final c1GtHi = (hi - c1).getRange(31, 32); // (hi-c1)<0 => c1>hi
      final c2 = mux(c1GtHi, hi, c1);
      return c2.getRange(0, grainW);
    }

    // LFSR one step: returns (nextReg16, gaussIdx11 = next>>5).
    List<Logic> lfsrStep(Logic r) {
      final b = (r[0] ^ r[1] ^ r[3] ^ r[12]);
      final next = [b, r.getRange(1, 16)].swizzle(); // {b, r[15:1]}
      final idx = next.getRange(5, 16); // next >> 5, 11 bits
      return [next, idx];
    }

    // Chroma LFSR init constants (initRandom(7<<5) and (11<<5)).
    int initConst(int lumaLine) {
      final lumaNum = lumaLine >> 5;
      final hi = ((lumaNum * 37 + 178) & 255) << 8;
      final lo = (lumaNum * 173 + 105) & 255;
      return (hi ^ lo) & 0xffff;
    }

    final cbInitC = initConst(7 << 5);
    final crInitC = initConst(11 << 5);

    // Storage: one packed register per plane holding finalized values as slots
    // (slot 0 = most recently finalized). Shifting is a single wide assignment,
    // AR taps are fixed slices, and the whole plane is the output.
    final lumaBus = Logic(name: 'luma_bus', width: nLuma * grainW);
    final cbBus = Logic(name: 'cb_bus', width: nChroma * grainW);
    final crBus = Logic(name: 'cr_bus', width: nChroma * grainW);
    // Frozen copy of the finalized luma template, latched when the luma pass
    // ends. The chroma cross term reads this (never the live [lumaBus]) so its
    // large read multiplexer only re-evaluates during the chroma passes.
    final lumaSnap = Logic(name: 'luma_snap', width: nLuma * grainW);

    // slot s of a packed bus (s counts back from the most recent).
    Logic slot(Logic bus, int s, int n) =>
        bus.getRange(s * grainW, s * grainW + grainW);
    // shift newVal into slot 0, dropping the oldest slot.
    Logic shiftIn(Logic bus, Logic newVal, int n) =>
        [bus.getRange(0, (n - 1) * grainW), newVal].swizzle();

    // FSM
    const sIdle = 0,
        sYLoad = 1,
        sYRun = 2,
        sCbLoad = 3,
        sCbRun = 4,
        sCrLoad = 5,
        sCrRun = 6,
        sDone = 7;
    final st = Logic(name: 'st', width: 3);
    final lr = Logic(name: 'lfsr', width: 16);
    final iR = Logic(name: 'iR', width: 8);
    final jR = Logic(name: 'jR', width: 8);

    done <= st.eq(Const(sDone, width: 3));
    final inChroma =
        st.eq(Const(sCbRun, width: 3)) | st.eq(Const(sCrRun, width: 3));

    // Dynamic read of luma[pos] from the frozen snapshot. After the luma pass,
    // position p lives in slot (nLuma-1-p). Balanced tree select over the pos
    // bits.
    Logic lumaAt(Logic pos) => treeMux(pos, [
      for (var p = 0; p < nLuma; p++) slot(lumaSnap, nLuma - 1 - p, nLuma),
    ]);

    // Coefficient slice (signed 8b) from a packed bus.
    Logic coeff(Logic bus, int pos) =>
        bus.getRange(pos * 8, pos * 8 + 8).signExtend(32);

    // Build the AR weighted sum for a plane given its packed bus + coeffs.
    // [srcBus] holds this plane's finalized values (slot 0 = most recent).
    // [stride] is the plane stride. Returns signed 32b wsum.
    Logic wsum(Logic srcBus, int n, Logic coeffBus, int stride) {
      Logic acc = Const(0, width: 32);
      for (var t = 0; t < taps.length; t++) {
        final dr = taps[t][0], dc = taps[t][1];
        final depth = -(dr * stride + dc);
        final nb = slot(srcBus, depth - 1, n).signExtend(32);
        acc = (acc + coeff(coeffBus, t) * nb).getRange(0, 32);
      }
      return acc;
    }

    // Average of the luma window for the current chroma position (shared by the
    // Cb and Cr cross terms). ly = ((i-tp)<<ssy)+tp, lx = ((j-lp)<<ssx)+lp,
    // window (ssy+1)x(ssx+1). The read address is frozen to a constant outside
    // the chroma passes so the wide luma read multiplexer does not re-evaluate
    // during the (much longer) luma pass.
    Logic avgLuma() {
      const tp = 3, lp = 3;
      final iC = mux(inChroma, iR, Const(tp, width: 8));
      final jC = mux(inChroma, jR, Const(lp, width: 8));
      final iMinusTp = (iC - Const(tp, width: 8)).getRange(0, 8);
      final jMinusLp = (jC - Const(lp, width: 8)).getRange(0, 8);
      final ly = ((iMinusTp.zeroExtend(16) << ssy) + Const(tp, width: 16))
          .getRange(0, 16);
      final lx = ((jMinusLp.zeroExtend(16) << ssx) + Const(lp, width: 16))
          .getRange(0, 16);
      Logic sum = Const(0, width: 32);
      for (var k = 0; k <= ssy; k++) {
        for (var l = 0; l <= ssx; l++) {
          final pos =
              ((ly + Const(k, width: 16)) * Const(lumaStride, width: 16) +
                      (lx + Const(l, width: 16)))
                  .getRange(0, 16);
          sum = (sum + lumaAt(pos).signExtend(32)).getRange(0, 32);
        }
      }
      final shift = ssy + ssx;
      final rnd = Const((1 << shift) >> 1, width: 32);
      // Arithmetic right shift of (sum + rnd) by [shift]. The sign fill must
      // come from (sum + rnd), not sum: adding the rounding bias can lift a
      // small negative sum into the non-negative range.
      final sr = (sum + rnd).getRange(0, 32);
      return shift == 0
          ? sr
          : [sr[31].replicate(shift), sr.getRange(shift, 32)].swizzle();
    }

    // Cross term = cross_coeff * avgLuma, for a given chroma coeff bus.
    Logic crossTerm(Logic coeffBus, Logic av) =>
        (coeff(coeffBus, numPosLuma) * av.getRange(0, 32)).getRange(0, 32);

    // Interior predicate for a plane of given block dims.
    Logic interior(int by, int bx) {
      const tp = 3, lp = 3, bp = 0, rp = 3;
      return iR.gte(Const(tp, width: 8)) &
          iR.lt(Const(by - bp, width: 8)) &
          jR.gte(Const(lp, width: 8)) &
          jR.lt(Const(bx - rp, width: 8));
    }

    // AR rounding for a runtime arShift: (wsum + (1<<(arShift-1))) >> arShift.
    Logic arFold(Logic fill, Logic wsumV) {
      Logic rnd = Const(0, width: 32);
      for (var k = 1; k <= 15; k++) {
        rnd = mux(
          arShift.eq(Const(k, width: 4)),
          Const(1 << (k - 1), width: 32),
          rnd,
        );
      }
      final biased = (wsumV + rnd).getRange(0, 32);
      final shifted = asr(biased, 32, arShift);
      final res = (fill.signExtend(32) + shifted).getRange(0, 32);
      return clampGrain(res);
    }

    // Per-cycle datapath: compute the finalized value for the current position
    // of the active plane. gaussIdx uses the stepped LFSR.
    final gaussIdx = Logic(name: 'gauss_idx', width: 11);
    final lrNext = Logic(name: 'lfsr_next', width: 16);
    final stepRes = lfsrStep(lr);
    lrNext <= stepRes[0];
    gaussIdx <= stepRes[1];
    final fillVal = fillFrom(gaussIdx);

    final newLuma = mux(
      interior(lumaBlockY, lumaBlockX),
      arFold(fillVal, wsum(lumaBus, nLuma, arY, lumaStride)),
      fillVal,
    );
    Logic newCb = Const(0, width: grainW);
    Logic newCr = Const(0, width: grainW);
    // Shared luma-window average (built once, reused by Cb and Cr) when either
    // chroma plane needs the cross term.
    final av = (lumaCross && (genCb || genCr))
        ? avgLuma()
        : Const(0, width: 32);
    if (genCb) {
      final base = wsum(cbBus, nChroma, arCb, chromaStride);
      final cbWsum = lumaCross
          ? (base + crossTerm(arCb, av)).getRange(0, 32)
          : base;
      newCb = mux(
        interior(chromaBlockY, chromaBlockX),
        arFold(fillVal, cbWsum),
        fillVal,
      );
    }
    if (genCr) {
      final base = wsum(crBus, nChroma, arCr, chromaStride);
      final crWsum = lumaCross
          ? (base + crossTerm(arCr, av)).getRange(0, 32)
          : base;
      newCr = mux(
        interior(chromaBlockY, chromaBlockX),
        arFold(fillVal, crWsum),
        fillVal,
      );
    }

    // Position advance helpers.
    List<Conditional> advance(int bx, int by, int nextLoadState) {
      final lastCol = jR.eq(Const(bx - 1, width: 8));
      final lastRow = iR.eq(Const(by - 1, width: 8));
      return [
        lr < lrNext,
        If(
          lastCol & lastRow,
          then: [st < Const(nextLoadState, width: 3)],
          orElse: [
            If(
              lastCol,
              then: [
                jR < Const(0, width: 8),
                iR < (iR + Const(1, width: 8)).getRange(0, 8),
              ],
              orElse: [jR < (jR + Const(1, width: 8)).getRange(0, 8)],
            ),
          ],
        ),
      ];
    }

    final cbNext = genCb ? sCbLoad : (genCr ? sCrLoad : sDone);
    final crNext = genCr ? sCrLoad : sDone;

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 3),
          lr < Const(0, width: 16),
          iR < Const(0, width: 8),
          jR < Const(0, width: 8),
          lumaBus < Const(0, width: nLuma * grainW),
          cbBus < Const(0, width: nChroma * grainW),
          crBus < Const(0, width: nChroma * grainW),
          lumaSnap < Const(0, width: nLuma * grainW),
        ],
        orElse: [
          Case(st, [
            CaseItem(Const(sIdle, width: 3), [
              If(start, then: [st < Const(sYLoad, width: 3)]),
            ]),
            CaseItem(Const(sYLoad, width: 3), [
              lr < seed,
              iR < Const(0, width: 8),
              jR < Const(0, width: 8),
              st < Const(sYRun, width: 3),
            ]),
            CaseItem(Const(sYRun, width: 3), [
              lumaBus < shiftIn(lumaBus, newLuma, nLuma),
              ...advance(lumaBlockX, lumaBlockY, cbNext),
            ]),
            CaseItem(Const(sCbLoad, width: 3), [
              lr < (seed ^ Const(cbInitC, width: 16)),
              iR < Const(0, width: 8),
              jR < Const(0, width: 8),
              lumaSnap < lumaBus,
              st < Const(sCbRun, width: 3),
            ]),
            CaseItem(Const(sCbRun, width: 3), [
              cbBus < shiftIn(cbBus, newCb, nChroma),
              ...advance(chromaBlockX, chromaBlockY, crNext),
            ]),
            CaseItem(Const(sCrLoad, width: 3), [
              lr < (seed ^ Const(crInitC, width: 16)),
              iR < Const(0, width: 8),
              jR < Const(0, width: 8),
              lumaSnap < lumaBus,
              st < Const(sCrRun, width: 3),
            ]),
            CaseItem(Const(sCrRun, width: 3), [
              crBus < shiftIn(crBus, newCr, nChroma),
              ...advance(chromaBlockX, chromaBlockY, sDone),
            ]),
            CaseItem(Const(sDone, width: 3), [
              If(~start, then: [st < Const(sIdle, width: 3)]),
            ]),
          ]),
        ],
      ),
    ]);

    // Outputs: raw slot order (slot s = the s-th most recent finalized value).
    // Position c of a plane of size n lives in slot (n-1-c). Callers reverse.
    outLuma <= lumaBus;
    outCb <= cbBus;
    outCr <= crBus;
  }
}

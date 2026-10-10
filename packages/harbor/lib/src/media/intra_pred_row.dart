import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor ROW-SEQUENTIAL intra predictor: produces ONE row (`bs` pixels) of a
/// `bs` x `bs` intra-predicted block for a RUNTIME row index `row`, with
/// neighbour availability. This is the build-scalable counterpart of the flat
/// combinational [HarborIntraPredAvail]: instead of unrolling `bs*bs` pixels
/// (which explodes ROHD build time at bs >= 32 because each SMOOTH/PAETH/
/// directional pixel carries a multiply), it builds ONE row's worth of logic
/// (O(bs)) with `row` as a runtime input, and a sequential recon FSM sweeps
/// `row` 0..bs-1 to reconstruct the whole block over `bs` cycles.
///
/// This module covers the NON-DIRECTIONAL modes (DC / V / H / SMOOTH / SMOOTH_V
/// / SMOOTH_H / PAETH) and the availability construction (matching
/// [HarborIntraPredAvail]). The directional modes (D45..D67) are added by
/// [HarborIntraDirRow] and muxed in the recon core. For a directional `mode`
/// this module outputs the DC row (a safe placeholder never selected once the
/// directional row is wired in).
///
/// Ports: `mode` (4b), `have_above` / `have_left` (1b), `above` / `left`
/// (`bs` neighbour pixels, 8b), `above_left` (corner), `row` (log2(bs) bits) ->
/// `pred_row` (`bs` pixels, 8b, pixel c at `[c*8 +: 8]`). Combinational.
class HarborIntraPredRow extends BridgeModule {
  /// Square block size (4, 8, 16, 32).
  final int bs;

  /// Sample bit depth (8/10/12). Sets the pixel width (`pw = bitDepth`), the
  /// no-neighbour fill base (`1 << (bd-1)`) and the DC/PAETH/SMOOTH accumulator
  /// widths. Defaults to 8 (byte-identical to the historic module).
  final int bitDepth;

  static const _smoothWeights = {
    4: [255, 149, 85, 64],
    8: [255, 197, 146, 105, 73, 50, 37, 32],
    16: [255, 225, 196, 170, 145, 123, 102, 84, 68, 54, 43, 33, 26, 20, 17, 16],
    32: [
      255,
      240,
      225,
      210,
      196,
      182,
      169,
      157,
      145,
      133,
      122,
      111,
      101,
      92,
      83, //
      74, 66, 59, 52, 45, 39, 34, 29, 25, 21, 17, 14, 12, 10, 9, 8, 8,
    ],
    64: [
      255,
      248,
      240,
      233,
      225,
      218,
      210,
      203,
      196,
      189,
      182,
      176,
      169,
      163,
      156, //
      150,
      144,
      138,
      133,
      127,
      121,
      116,
      111,
      106,
      101,
      96,
      91,
      86,
      82,
      77,
      73,
      69,
      65,
      61,
      57,
      54,
      50,
      47,
      44,
      41,
      38,
      35,
      32,
      29,
      27,
      25,
      22,
      20,
      18,
      16,
      15,
      13, 12, 10, 9, 8, 7, 6, 6, 5, 5, 4, 4, 4,
    ],
  };
  static const _dc = 0, _v = 1, _h = 2, _smooth = 9, _smoothV = 10;
  static const _smoothH = 11, _paeth = 12;

  HarborIntraPredRow({required this.bs, this.bitDepth = 8, String? name})
    : assert(
        bs == 4 || bs == 8 || bs == 16 || bs == 32 || bs == 64,
        'bs in {4,8,16,32,64}',
      ),
      assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
      super(
        'HarborIntraPredRow_S${bs}_B$bitDepth',
        name: name ?? 'intra_pred_row_$bs',
      ) {
    final pw = bitDepth; // pixel width
    final rowBits = (bs - 1).bitLength;
    createPort('mode', PortDirection.input, width: 4);
    createPort('have_above', PortDirection.input);
    createPort('have_left', PortDirection.input);
    createPort('above', PortDirection.input, width: bs * pw);
    createPort('left', PortDirection.input, width: bs * pw);
    createPort('above_left', PortDirection.input, width: pw);
    createPort('row', PortDirection.input, width: rowBits);
    addOutput('pred_row', width: bs * pw);

    final mode = input('mode');
    final haveA = input('have_above');
    final haveL = input('have_left');
    final aboveLeft = input('above_left');
    final row = input('row');
    Logic aPix(int i) => input('above').getRange(i * pw, i * pw + pw);
    Logic lPix(int i) => input('left').getRange(i * pw, i * pw + pw);

    final base = 1 << (bitDepth - 1); // 128 at bd 8
    final defAbove = Const(base - 1, width: pw); // 127 at bd 8
    final defLeft = Const(base + 1, width: pw); // 129 at bd 8

    // Availability-constructed neighbour arrays (same as HarborIntraPredAvail).
    final aboveC = [
      for (var i = 0; i < bs; i++)
        mux(haveA, aPix(i), mux(haveL, lPix(0), defAbove)),
    ];
    final leftC = [
      for (var i = 0; i < bs; i++)
        mux(haveL, lPix(i), mux(haveA, aPix(0), defLeft)),
    ];
    final cornerC = mux(
      haveA & haveL,
      aboveLeft,
      mux(haveA, aPix(0), mux(haveL, lPix(0), Const(base, width: pw))),
    );

    // Runtime row-select of the (constructed) left column and the smooth weight.
    Logic selRow(List<Logic> arr) {
      Logic v = arr.last;
      for (var i = bs - 2; i >= 0; i--) {
        v = mux(row.eq(Const(i, width: rowBits)), arr[i], v);
      }
      return v;
    }

    final smW = _smoothWeights[bs]!;
    final leftAtRow = selRow(leftC); // leftC[row]
    // smooth weight at the runtime row (mux over the constant weights).
    Logic smWvAtRow() {
      Logic v = Const(smW[bs - 1], width: 9);
      for (var i = bs - 2; i >= 0; i--) {
        v = mux(row.eq(Const(i, width: rowBits)), Const(smW[i], width: 9), v);
      }
      return v;
    }

    final wvRow = smWvAtRow(); // smW[row], 9-bit
    const scale = 256;

    // DC value (availability variant), broadcast (row-independent). The sum
    // width must hold 2*bs*maxval + bs (maxval = (1<<bd)-1). At bd 8 this yields
    // 14 for bs <= 32 / 15 for bs = 64 - >= the historic 14/16, and since the DC
    // extract slices only high bits (the low ones are byte-identical), a wider
    // dcW is result-identical at bd 8.
    final dcW = (2 * bs * ((1 << bitDepth) - 1) + bs).bitLength + 1;
    Logic sumOf(List<Logic> a) {
      Logic s = a[0].zeroExtend(dcW);
      for (var i = 1; i < bs; i++) {
        s = (s + a[i].zeroExtend(dcW)).getRange(0, dcW);
      }
      return s;
    }

    final bsLog2 = bs.bitLength - 1;
    final sumA = sumOf([for (var i = 0; i < bs; i++) aPix(i)]);
    final sumL = sumOf([for (var i = 0; i < bs; i++) lPix(i)]);
    final dcBoth = ((sumA + sumL).getRange(0, dcW) + Const(bs, width: dcW))
        .getRange(bsLog2 + 1, dcW);
    final dcLeftV = (sumL + Const(bs >> 1, width: dcW)).getRange(bsLog2, dcW);
    final dcTopV = (sumA + Const(bs >> 1, width: dcW)).getRange(bsLog2, dcW);
    final dcVal = mux(
      haveL & haveA,
      dcBoth.getRange(0, pw),
      mux(
        haveL,
        dcLeftV.getRange(0, pw),
        mux(haveA, dcTopV.getRange(0, pw), Const(base, width: pw)),
      ),
    );

    Logic divRound(Logic value, int bits, int w) =>
        ((value + Const(1 << (bits - 1), width: w)).getRange(0, w) >>> bits)
            .getRange(0, pw);

    // PAETH: base = t + l - tl (signed), pick ref with the smallest abs diff.
    Logic paeth(Logic l, Logic t, Logic tl) {
      final w = bitDepth + 4; // 12 at bd 8; holds +-(t+l-tl) and the abs diffs
      Logic sx(Logic v) => v.zeroExtend(w);
      final b = (sx(t) + sx(l) - sx(tl)).getRange(0, w);
      Logic absd(Logic x) {
        final d = (b - sx(x)).getRange(0, w);
        return mux(d[w - 1], (Const(0, width: w) - d).getRange(0, w), d);
      }

      final pL = absd(l), pT = absd(t), pTL = absd(tl);
      return mux(pL.lte(pT) & pL.lte(pTL), l, mux(pT.lte(pTL), t, tl));
    }

    final belowLeft = leftC[bs - 1];
    final rightPred = aboveC[bs - 1];

    // directional modes (D45..D67), row-sequential port of HarborIntraDir.
    // Angles/derivatives are build-time. The RUNTIME `row` drives the base/shift
    // arithmetic so one row's worth of logic (O(bs)) serves all rows.
    const modeAngle = {3: 45, 4: 135, 5: 113, 6: 157, 7: 203, 8: 67};
    const drv = [
      0, 0, 0, 1023, 0, 0, 547, 0, 0, 372, 0, 0, 0, 0, 273, 0, 0, 215, 0, 0, //
      178, 0, 0, 151, 0, 0, 132, 0, 0, 116, 0, 0, 102, 0, 0, 0, 90, 0, 0, 80, //
      0,
      0,
      71,
      0,
      0,
      64,
      0,
      0,
      57,
      0,
      0,
      51,
      0,
      0,
      45,
      0,
      0,
      0,
      40,
      0,
      0,
      35, //
      0, 0, 31, 0, 0, 27, 0, 0, 23, 0, 0, 19, 0, 0, 15, 0, 0, 0, 0, 11, 0, 0, //
      7, 0, 0, 3, 0, 0,
    ];
    int getDx(int a) =>
        (a > 0 && a < 90) ? drv[a] : (a > 90 && a < 180 ? drv[180 - a] : 1);
    int getDy(int a) => (a > 90 && a < 180)
        ? drv[a - 90]
        : (a > 180 && a < 270 ? drv[270 - a] : 1);
    const dw = 20; // projection working width (two's complement)
    final rowE = row.zeroExtend(dw);
    // arithmetic shift right by 6 of a dw-bit two's complement value.
    Logic ashr6(Logic v) =>
        [v[dw - 1].replicate(6), v.getRange(6, dw)].swizzle();
    // (v & 0x3F) >> 1 -> bits [1..5], 5-bit shift for the 2-tap blend.
    Logic shiftOf(Logic v) => v.getRange(1, 6);
    // 2-tap blend with a RUNTIME shift (0..31): round((32-s)*a + s*b, 5).
    // Blend accumulator holds 32*maxV -> bd+8 (16 at bd8, wider for bd 10/12).
    final bw = bitDepth + 8;
    Logic blendRT(Logic a, Logic b, Logic s) {
      final sX = s.zeroExtend(bw);
      final v =
          ((a.zeroExtend(bw) * (Const(32, width: bw) - sX)).getRange(0, bw) +
                  (b.zeroExtend(bw) * sX).getRange(0, bw))
              .getRange(0, bw);
      return ((v + Const(16, width: bw)).getRange(0, bw) >>> 5).getRange(0, pw);
    }

    // aboveC[idx] clamped to [0, bs-1] (idx an unsigned dw value >= 0).
    Logic aboveClamp(Logic idx) {
      Logic v = aboveC[bs - 1];
      for (var i = bs - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: dw)), aboveC[i], v);
      }
      return v;
    }

    Logic leftClamp(Logic idx) {
      Logic v = leftC[bs - 1];
      for (var i = bs - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: dw)), leftC[i], v);
      }
      return v;
    }

    // signed ref: idx == -1 -> corner, else clamp. idx a dw two's complement.
    final neg1 = Const((BigInt.one << dw) - BigInt.one, width: dw); // -1
    Logic aboveRefS(Logic idx) => mux(idx.eq(neg1), cornerC, aboveClamp(idx));
    Logic leftRefS(Logic idx) => mux(idx.eq(neg1), cornerC, leftClamp(idx));

    // Build the directional row for a given (build-time) mode.
    List<Logic> dirRowFor(int m) {
      final angle = modeAngle[m]!;
      final out = List<Logic>.filled(bs, Const(0, width: pw));
      if (angle < 90) {
        // z1: from above. x = (row+1)*dx.
        final dx = getDx(angle);
        final x = ((rowE + Const(1, width: dw)) * Const(dx, width: dw))
            .getRange(0, dw);
        final baseV = (x >>> 6).getRange(0, dw);
        final sh = shiftOf(x);
        for (var c = 0; c < bs; c++) {
          final idx = (baseV + Const(c, width: dw)).getRange(0, dw);
          final idx1 = (baseV + Const(c + 1, width: dw)).getRange(0, dw);
          out[c] = blendRT(aboveClamp(idx), aboveClamp(idx1), sh);
        }
      } else if (angle > 180) {
        // z3: from left. y = (c+1)*dy is build-time, ref index = base_c + row.
        final dy = getDy(angle);
        for (var c = 0; c < bs; c++) {
          final y = (c + 1) * dy;
          final baseC = y >> 6;
          final sh = (y & 0x3F) >> 1; // build-time shift
          final idx = (Const(baseC, width: dw) + rowE).getRange(0, dw);
          final idx1 = (Const(baseC + 1, width: dw) + rowE).getRange(0, dw);
          // const-shift blend.
          Logic blendC(Logic a, Logic b) {
            if (sh == 0) return a;
            final v =
                (a.zeroExtend(bw) * Const(32 - sh, width: bw) +
                        b.zeroExtend(bw) * Const(sh, width: bw))
                    .getRange(0, bw);
            return ((v + Const(16, width: bw)).getRange(0, bw) >>> 5).getRange(
              0,
              pw,
            );
          }

          out[c] = blendC(leftClamp(idx), leftClamp(idx1));
        }
      } else {
        // z2: above when baseX >= -1, else left. Both indices/shifts runtime.
        final dx = getDx(angle), dy = getDy(angle);
        for (var c = 0; c < bs; c++) {
          // xv = (c<<6) - (row+1)*dx
          final yv = (rowE + Const(1, width: dw)).getRange(0, dw);
          final prod = (yv * Const(dx, width: dw)).getRange(0, dw);
          final xv = (Const(c << 6, width: dw) - prod).getRange(0, dw);
          final baseX = ashr6(xv);
          final baseXp1 = (baseX + Const(1, width: dw)).getRange(0, dw);
          // baseX >= -1  <=>  (baseX + 1) >= 0  <=>  sign bit of (baseX+1) == 0.
          final useAbove = ~baseXp1[dw - 1];
          final shA = shiftOf(xv);
          final aPixSel = blendRT(aboveRefS(baseX), aboveRefS(baseXp1), shA);
          // else: yv2 = (row<<6) - (c+1)*dy
          final rowSh = (rowE << 6).getRange(0, dw);
          final yv2 = (rowSh - Const((c + 1) * dy, width: dw)).getRange(0, dw);
          final baseY = ashr6(yv2);
          final baseYp1 = (baseY + Const(1, width: dw)).getRange(0, dw);
          final shL = shiftOf(yv2);
          final lPixSel = blendRT(leftRefS(baseY), leftRefS(baseYp1), shL);
          out[c] = mux(useAbove, aPixSel, lPixSel);
        }
      }
      return out;
    }

    // Directional pixel per column, muxed over the six directional modes.
    final dirBlocks = {for (final m in modeAngle.keys) m: dirRowFor(m)};
    final dirPx = <Logic>[];
    for (var c = 0; c < bs; c++) {
      Logic px = dirBlocks[8]![c]; // default D67
      for (final m in [3, 4, 5, 6, 7]) {
        px = mux(mode.eq(Const(m, width: 4)), dirBlocks[m]![c], px);
      }
      dirPx.add(px);
    }
    final isDir = mode.gte(Const(3, width: 4)) & mode.lte(Const(8, width: 4));

    // Build one row (c = 0..bs-1), using leftAtRow / wvRow for the row terms.
    final outs = <Logic>[];
    for (var c = 0; c < bs; c++) {
      final vP = aboveC[c];
      final hP = leftAtRow;
      final pP = paeth(leftAtRow, aboveC[c], cornerC);
      final wh = smW[c]; // build-time column weight
      // SMOOTH accumulator widths: 4-term <= 2*256*maxV -> bd+12 (20 at bd8).
      // 2-term <= 256*maxV -> bd+10 (18 at bd8). Widen for bd 10/12 so the
      // weighted sums don't overflow (byte-identical at bd8).
      final smW4 = bitDepth + 12;
      final smW2 = bitDepth + 10;
      // SMOOTH: 4-term weighted blend >> 9. wv is runtime (wvRow), wh const.
      final sm = divRound(
        ((wvRow.zeroExtend(smW4) * aboveC[c].zeroExtend(smW4)).getRange(
                  0,
                  smW4,
                ) +
                (Const(scale, width: smW4) - wvRow.zeroExtend(smW4)).getRange(
                      0,
                      smW4,
                    ) *
                    belowLeft.zeroExtend(smW4) +
                Const(wh, width: smW4) * leftAtRow.zeroExtend(smW4) +
                Const(scale - wh, width: smW4) * rightPred.zeroExtend(smW4))
            .getRange(0, smW4),
        9,
        smW4,
      );
      final smv = divRound(
        ((wvRow.zeroExtend(smW2) * aboveC[c].zeroExtend(smW2)).getRange(
                  0,
                  smW2,
                ) +
                (Const(scale, width: smW2) - wvRow.zeroExtend(smW2)).getRange(
                      0,
                      smW2,
                    ) *
                    belowLeft.zeroExtend(smW2))
            .getRange(0, smW2),
        8,
        smW2,
      );
      final smh = divRound(
        (Const(wh, width: smW2) * leftAtRow.zeroExtend(smW2) +
                Const(scale - wh, width: smW2) * rightPred.zeroExtend(smW2))
            .getRange(0, smW2),
        8,
        smW2,
      );

      final ndPx = mux(
        mode.eq(Const(_v, width: 4)),
        vP,
        mux(
          mode.eq(Const(_h, width: 4)),
          hP,
          mux(
            mode.eq(Const(_paeth, width: 4)),
            pP,
            mux(
              mode.eq(Const(_smooth, width: 4)),
              sm,
              mux(
                mode.eq(Const(_smoothV, width: 4)),
                smv,
                mux(mode.eq(Const(_smoothH, width: 4)), smh, dcVal),
              ),
            ),
          ),
        ),
      ); // default: DC
      // directional modes select the projected pixel, else the ND result.
      outs.add(mux(isDir, dirPx[c], ndPx));
    }
    assert(_dc == 0);
    output('pred_row') <= [for (var c = bs - 1; c >= 0; c--) outs[c]].swizzle();
  }
}

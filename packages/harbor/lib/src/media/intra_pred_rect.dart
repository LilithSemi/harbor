import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Harbor bit-exact AV1 RECTANGULAR intra predictor WITH neighbour availability
/// (bd 8, angle_delta = 0, no edge filter, above-right / below-left treated as
/// repeat). The rectangular analogue of [HarborIntraPredAvail]: prediction and
/// transform blocks in AV1 are not only square (4x4, 8x8, 16x16) but also
/// rectangular (8x4, 4x8, 16x8, 8x16, ...), which the HORZ / VERT partition leaf
/// shapes require. Reduces exactly to the square case when `bw == bh`.
///
/// Mirrors [HarborIntraPredAvail]'s edge construction with separate width
/// (`bw`) and height (`bh`):
///   - when `have_above` / `have_left` is low the above / left arrays are filled
///     with defaults (127 / 129) or cross-filled from the other side, and the
///     corner resolves to the available source or 128.
///   - DC uses its availability variant (both / left / top / 128). The both
///     variant divides the `bw + bh` neighbour sum by `bw + bh`, which is NOT a
///     power of two for rectangular blocks (e.g. 8x4 -> 12): it is done with an
///     exact constant reciprocal multiply `(sum * recip) >> shift` matching the
///     software `(sum + ((bw + bh) >> 1)) ~/ (bw + bh)` truncating divide. The
///     left-only / top-only variants divide by `bh` / `bw` (powers of two -> a
///     clean shift).
///
/// SMOOTH weights are indexed per dimension: the height ramp uses the `bh` table
/// (by row), the width ramp uses the `bw` table (by column).
///
/// Modes covered match [HarborIntraPredAvail]: 0 DC, 1 V, 2 H, the directional
/// modes 3..8 (D45/D135/D113/D157/D203/D67 at angle_delta 0, no edge filter, no
/// upsample), 9 SMOOTH, 10 SMOOTH_V, 11 SMOOTH_H, 12 PAETH.
///
/// Ports: `mode` (4b, y_mode 0..12), `have_above` / `have_left` (1b), `above`
/// (`bw` neighbour pixels, 8b each), `left` (`bh` neighbour pixels, 8b each),
/// `above_left` (corner, 8b) -> `pred` (`bw*bh` predicted pixels, row-major:
/// pixel (r, c) at `[(r*bw + c)*8 +: 8]`, 8b each). Combinational.
class HarborIntraPredRect extends BridgeModule {
  /// Block width (columns): 4, 8 or 16.
  final int bw;

  /// Block height (rows): 4, 8 or 16.
  final int bh;

  static const _smoothWeights = {
    4: [255, 149, 85, 64],
    8: [255, 197, 146, 105, 73, 50, 37, 32],
    16: [255, 225, 196, 170, 145, 123, 102, 84, 68, 54, 43, 33, 26, 20, 17, 16],
  };

  // dr_intra_derivative[90] (reconintra.h).
  static const _drv = [
    0, 0, 0, 1023, 0, 0, 547, 0, 0, 372, 0, 0, 0, 0, 273, 0, 0, 215, 0, 0, //
    178, 0, 0, 151, 0, 0, 132, 0, 0, 116, 0, 0, 102, 0, 0, 0, 90, 0, 0, 80, //
    0, 0, 71, 0, 0, 64, 0, 0, 57, 0, 0, 51, 0, 0, 45, 0, 0, 0, 40, 0, 0, 35, //
    0, 0, 31, 0, 0, 27, 0, 0, 23, 0, 0, 19, 0, 0, 15, 0, 0, 0, 0, 11, 0, 0, //
    7, 0, 0, 3, 0, 0,
  ];
  static const _modeAngle = {3: 45, 4: 135, 5: 113, 6: 157, 7: 203, 8: 67};

  static int _getDx(int a) =>
      (a > 0 && a < 90) ? _drv[a] : (a > 90 && a < 180 ? _drv[180 - a] : 1);
  static int _getDy(int a) => (a > 90 && a < 180)
      ? _drv[a - 90]
      : (a > 180 && a < 270 ? _drv[270 - a] : 1);

  HarborIntraPredRect({required this.bw, required this.bh, String? name})
    : assert(bw == 4 || bw == 8 || bw == 16, 'bw in {4,8,16}'),
      assert(bh == 4 || bh == 8 || bh == 16, 'bh in {4,8,16}'),
      super(
        'HarborIntraPredRect_${bw}x$bh',
        name: name ?? 'intra_pred_rect_${bw}x$bh',
      ) {
    createPort('mode', PortDirection.input, width: 4);
    createPort('have_above', PortDirection.input);
    createPort('have_left', PortDirection.input);
    createPort('above', PortDirection.input, width: bw * 8);
    createPort('left', PortDirection.input, width: bh * 8);
    createPort('above_left', PortDirection.input, width: 8);
    addOutput('pred', width: bw * bh * 8);

    final mode = input('mode');
    final haveA = input('have_above');
    final haveL = input('have_left');
    final aboveLeft = input('above_left');
    Logic aPix(int i) => input('above').getRange(i * 8, i * 8 + 8);
    Logic lPix(int i) => input('left').getRange(i * 8, i * 8 + 8);

    const base = 128; // 1 << (bd-1)
    final defAbove = Const(base - 1, width: 8); // 127
    final defLeft = Const(base + 1, width: 8); // 129

    // Constructed (availability-resolved) neighbour arrays (libaom _build):
    // aboveC[i] = haveA ? above[i] : (haveL ? left[0] : 127)   (bw entries)
    // leftC[i]  = haveL ? left[i]  : (haveA ? above[0] : 129)   (bh entries)
    final aboveC = [
      for (var i = 0; i < bw; i++)
        mux(haveA, aPix(i), mux(haveL, lPix(0), defAbove)),
    ];
    final leftC = [
      for (var i = 0; i < bh; i++)
        mux(haveL, lPix(i), mux(haveA, aPix(0), defLeft)),
    ];
    final cornerC = mux(
      haveA & haveL,
      aboveLeft,
      mux(haveA, aPix(0), mux(haveL, lPix(0), Const(base, width: 8))),
    );

    // Extended reference access over the constructed arrays (repeat past the
    // block edge, corner at index -1). z1/z2/z3 read up to bw+bh-1.
    Logic aboveRef(int i) =>
        i < 0 ? cornerC : (i < bw ? aboveC[i] : aboveC[bw - 1]);
    Logic leftRef(int i) =>
        i < 0 ? cornerC : (i < bh ? leftC[i] : leftC[bh - 1]);

    // 2-tap blend round((32-shift)*a + shift*b, 5), shift 0..31, build-time.
    Logic blend(Logic a, Logic b, int shift) {
      if (shift == 0) return a;
      final v =
          (a.zeroExtend(16) * Const(32 - shift, width: 16) +
                  b.zeroExtend(16) * Const(shift, width: 16))
              .getRange(0, 16);
      return ((v + Const(16, width: 16)).getRange(0, 16) >>> 5).getRange(0, 8);
    }

    // directional prediction block for one mode (all build-time idx)
    List<Logic> predDir(int m) {
      final angle = _modeAngle[m]!;
      final dst = List<Logic>.filled(bw * bh, Const(0, width: 8));
      if (angle < 90) {
        // z1: from above. maxBaseX = bw + bh - 1.
        final dx = _getDx(angle);
        final maxBaseX = bw + bh - 1;
        var x = dx;
        for (var r = 0; r < bh; r++, x += dx) {
          var b = x >> 6;
          final shift = (x & 0x3F) >> 1;
          if (b >= maxBaseX) {
            for (var i = r; i < bh; i++) {
              for (var c = 0; c < bw; c++) {
                dst[i * bw + c] = aboveRef(maxBaseX);
              }
            }
            break;
          }
          for (var c = 0; c < bw; c++, b++) {
            dst[r * bw + c] = b < maxBaseX
                ? blend(aboveRef(b), aboveRef(b + 1), shift)
                : aboveRef(maxBaseX);
          }
        }
      } else if (angle > 180) {
        // z3: from left. maxBaseY = bw + bh - 1.
        final dy = _getDy(angle);
        final maxBaseY = bw + bh - 1;
        var y = dy;
        for (var c = 0; c < bw; c++, y += dy) {
          var b = y >> 6;
          final shift = (y & 0x3F) >> 1;
          var r = 0;
          for (; r < bh; r++, b++) {
            if (b < maxBaseY) {
              dst[r * bw + c] = blend(leftRef(b), leftRef(b + 1), shift);
            } else {
              for (; r < bh; r++) {
                dst[r * bw + c] = leftRef(maxBaseY);
              }
              break;
            }
          }
        }
      } else {
        // z2: from above (baseX >= -1) else left.
        final dx = _getDx(angle), dy = _getDy(angle);
        for (var r = 0; r < bh; r++) {
          for (var c = 0; c < bw; c++) {
            final yv = r + 1;
            final xv = (c << 6) - yv * dx;
            final baseX = xv >> 6;
            if (baseX >= -1) {
              final shift = (xv & 0x3F) >> 1;
              dst[r * bw + c] = blend(
                aboveRef(baseX),
                aboveRef(baseX + 1),
                shift,
              );
            } else {
              final xv2 = c + 1;
              final yv2 = (r << 6) - xv2 * dy;
              final baseY = yv2 >> 6;
              final shift = (yv2 & 0x3F) >> 1;
              dst[r * bw + c] = blend(
                leftRef(baseY),
                leftRef(baseY + 1),
                shift,
              );
            }
          }
        }
      }
      return dst;
    }

    // non-directional + directional per-pixel build over constructed arrays
    final smW = _smoothWeights[bw]!; // width ramp, indexed by column
    final smH = _smoothWeights[bh]!; // height ramp, indexed by row
    const scale = 256; // 1 << 8

    // divide_round(value, bits) = (value + (1<<(bits-1))) >> bits.
    Logic divRound(Logic value, int bits, int w) =>
        ((value + Const(1 << (bits - 1), width: w)).getRange(0, w) >>> bits)
            .getRange(0, 8);

    // PAETH single (signed base + abs-diff).
    Logic paeth(Logic l, Logic t, Logic tl) {
      const w = 12;
      Logic sx(Logic v) => v.zeroExtend(w);
      final base0 = (sx(t) + sx(l) - sx(tl)).getRange(0, w);
      Logic absd(Logic x) {
        final d = (base0 - sx(x)).getRange(0, w);
        return mux(d[w - 1], (Const(0, width: w) - d).getRange(0, w), d);
      }

      final pL = absd(l), pT = absd(t), pTL = absd(tl);
      return mux(pL.lte(pT) & pL.lte(pTL), l, mux(pT.lte(pTL), t, tl));
    }

    final belowLeft = leftC[bh - 1];
    final rightPred = aboveC[bw - 1];

    final dirBlocks = {for (final m in _modeAngle.keys) m: predDir(m)};

    // DC availability variant -> single broadcast value.
    // Sum widths: bw/bh <= 16, pixel <= 255 -> bw*255 fits well within 14 bits.
    const sumW = 14;
    Logic sumOf(List<Logic> a) {
      Logic s = a[0].zeroExtend(sumW);
      for (var i = 1; i < a.length; i++) {
        s = (s + a[i].zeroExtend(sumW)).getRange(0, sumW);
      }
      return s;
    }

    final sumA = sumOf([for (var i = 0; i < bw; i++) aPix(i)]);
    final sumL = sumOf([for (var i = 0; i < bh; i++) lPix(i)]);

    // both: (sumA + sumL + ((bw+bh)>>1)) / (bw+bh). For square (bw+bh power of
    // two) this is a shift. For rectangular it is an exact constant reciprocal
    // multiply. We use the reciprocal form uniformly (it is exact for both).
    final count = bw + bh;
    final sumBothRaw =
        ((sumA + sumL).getRange(0, sumW) + Const(count >> 1, width: sumW))
            .getRange(0, sumW); // numerator = sum + count/2
    final Logic dcBoth;
    if ((count & (count - 1)) == 0) {
      // power of two -> clean shift by log2(count). numerator already has the
      // +count/2 bias, but for a power of two the canonical libaom form is
      // (sumA+sumL+(count>>1)) >> log2(count). Equivalently here.
      final lg = count.bitLength - 1;
      dcBoth = (sumBothRaw >>> lg).getRange(0, 8);
    } else {
      // exact division by `count` via reciprocal multiply: q = (n * recip) >> s.
      // n max = count*255 + count/2 < 2^14. Choose s=24, recip=ceil(2^s/count).
      const s = 24;
      final recip =
          ((BigInt.one << s) + BigInt.from(count) - BigInt.one) ~/
          BigInt.from(count);
      const prodW = sumW + 25; // 14 + 25 = 39 > 14 + 24
      final prod = (sumBothRaw.zeroExtend(prodW) * Const(recip, width: prodW))
          .getRange(0, prodW);
      dcBoth = (prod >>> s).getRange(0, 8);
    }

    // left-only: (sumL + (bh>>1)) / bh. bh power of two -> shift by log2(bh).
    final dcLeftV =
        ((sumL + Const(bh >> 1, width: sumW)).getRange(0, sumW) >>>
                (bh.bitLength - 1))
            .getRange(0, 8);
    // top-only: (sumA + (bw>>1)) / bw. bw power of two -> shift by log2(bw).
    final dcTopV =
        ((sumA + Const(bw >> 1, width: sumW)).getRange(0, sumW) >>>
                (bw.bitLength - 1))
            .getRange(0, 8);

    final dcVal = mux(
      haveL & haveA,
      dcBoth,
      mux(haveL, dcLeftV, mux(haveA, dcTopV, Const(base, width: 8))),
    );

    // assemble per-pixel mux across all modes
    const dc = 0, v = 1, h = 2, smooth = 9, smoothV = 10, smoothH = 11;
    const paethM = 12;

    final outs = <Logic>[];
    for (var r = 0; r < bh; r++) {
      for (var c = 0; c < bw; c++) {
        final vP = aboveC[c];
        final hP = leftC[r];
        final pP = paeth(leftC[r], aboveC[c], cornerC);
        final wv = smH[r], wh = smW[c];
        // SMOOTH: 4-term >> 9.
        final sm = divRound(
          (Const(wv, width: 20) * aboveC[c].zeroExtend(20) +
                  Const(scale - wv, width: 20) * belowLeft.zeroExtend(20) +
                  Const(wh, width: 20) * leftC[r].zeroExtend(20) +
                  Const(scale - wh, width: 20) * rightPred.zeroExtend(20))
              .getRange(0, 20),
          9,
          20,
        );
        // SMOOTH_V / SMOOTH_H: 2-term >> 8.
        final smv = divRound(
          (Const(wv, width: 18) * aboveC[c].zeroExtend(18) +
                  Const(scale - wv, width: 18) * belowLeft.zeroExtend(18))
              .getRange(0, 18),
          8,
          18,
        );
        final smh = divRound(
          (Const(wh, width: 18) * leftC[r].zeroExtend(18) +
                  Const(scale - wh, width: 18) * rightPred.zeroExtend(18))
              .getRange(0, 18),
          8,
          18,
        );

        // directional (modes 3..8) for this pixel.
        Logic dirPx = dirBlocks[8]![r * bw + c]; // default D67
        for (final m in [3, 4, 5, 6, 7]) {
          dirPx = mux(
            mode.eq(Const(m, width: 4)),
            dirBlocks[m]![r * bw + c],
            dirPx,
          );
        }
        final isDir =
            mode.gte(Const(3, width: 4)) & mode.lte(Const(8, width: 4));

        // non-directional select (DC handled by dcVal broadcast).
        final nd = mux(
          mode.eq(Const(v, width: 4)),
          vP,
          mux(
            mode.eq(Const(h, width: 4)),
            hP,
            mux(
              mode.eq(Const(paethM, width: 4)),
              pP,
              mux(
                mode.eq(Const(smooth, width: 4)),
                sm,
                mux(
                  mode.eq(Const(smoothV, width: 4)),
                  smv,
                  mux(mode.eq(Const(smoothH, width: 4)), smh, dcVal),
                ),
              ),
            ),
          ),
        ); // default DC
        assert(dc == 0);

        outs.add(mux(isDir, dirPx, nd));
      }
    }

    output('pred') <= outs.reversed.toList().swizzle();
  }
}

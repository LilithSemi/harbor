import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart';

import 'fp_lzc.dart';
import 'fp_round_pack.dart';
import 'fp_unpack.dart';
import 'fpu_config.dart';

/// The ops that [HarborFpFmaPath] computes.
const harborFpFmaOps = {
  HarborFpOp.add,
  HarborFpOp.sub,
  HarborFpOp.mul,
  HarborFpOp.madd,
  HarborFpOp.msub,
  HarborFpOp.nmsub,
  HarborFpOp.nmadd,
};

/// Width of an op port that holds a [HarborFpOp] index.
final int harborFpOpWidth = (HarborFpOp.values.length - 1).bitLength;

/// Width of the `fmt_narrow` port for [config].
int harborFpNarrowWidth(HarborFpuConfig config) =>
    max(1, config.widening.length.bitLength);

const _mulOps = {
  HarborFpOp.mul,
  HarborFpOp.madd,
  HarborFpOp.msub,
  HarborFpOp.nmsub,
  HarborFpOp.nmadd,
};

/// Width of the significands that [HarborFpFmaPath] multiplies.
///
/// This is the largest mantissa plus one over [HarborFpuConfig.mulFormats]
/// and the narrow side of each widening pair. It is 0 when `mul` and the
/// madd ops are not built.
int harborFpProductWidth(HarborFpuConfig config) {
  if (config.ops.intersection(_mulOps).isEmpty) {
    return 0;
  }
  final used = {
    ...config.mulFormats ?? config.formats,
    for (final (narrow, _) in config.widening) narrow,
  };
  return used.map((f) => f.mantissaWidth + 1).reduce(max);
}

/// Splits [n] bits into the fewest slices of at most [s] bits, with sizes
/// that differ by at most one. Returns `(low bit, width)` for each slice.
List<(int, int)> _slices(int n, int s) {
  final k = (n + s - 1) ~/ s;
  final out = <(int, int)>[];
  var lo = 0;
  for (var i = 0; i < k; i++) {
    final w = n ~/ k + (i < n % k ? 1 : 0);
    out.add((lo, w));
    lo += w;
  }
  return out;
}

int _signedBits(int lo, int hi) {
  var w = 1;
  while (lo < -(1 << (w - 1)) || hi >= (1 << (w - 1))) {
    w++;
  }
  return w;
}

/// The add, multiply and fused multiply add datapath of the shared FPU.
///
/// All ops are `a * b + c` with one rounding. `add` and `sub` compute
/// `a * 1 + b` and `a * 1 - b`. `mul` computes `a * b + z`, where `z` is
/// -0, or +0 when [rm] is RDN, so an exact zero product keeps its own sign.
/// `msub` is `a * b - c`, `nmsub` is `-(a * b) + c`, `nmadd` is
/// `-(a * b) - c`.
///
/// [op] holds a [HarborFpOp] index. [fmt] selects the format. A nonzero
/// [fmtNarrow] selects the pair `config.widening[fmtNarrow - 1]` for a madd
/// family op or `mul`: `a` and `b` use the narrow format, `c` and the result
/// the wide format, and [fmt] is ignored. `add` and `sub` ignore [fmtNarrow].
///
/// Let `M` be the largest mantissa field, `p = M + 1`, and `W = 3p + 6`.
/// The stages are:
///
///   1. Unpack, special cases, exponent difference and result exponent.
///   2. The partial products. See below.
///   3. The partial products go to two rows. A 3:2 row adds the addend,
///      which a right shift aligns in parallel.
///   4. Two adders give the sum and the sum plus one, then the magnitude.
///   5. Leading zero count and one left shift. The shift stops at the
///      minimum normal exponent.
///   6. [HarborFpRound]: the alignment at the format LSB and the round bits.
///   7. [HarborFpPack]: the round increment and the packed word.
///
/// The product sits at bits 3 up to `2p + 3` of a `W` bit window. The addend
/// shifts right from the top of the window, and the bits it loses go into a
/// sticky bit. When the addend is far above the product, it stays at the
/// top. The product is then smaller than a quarter of an addend ULP, so its
/// effect on the rounding is the same.
///
/// The multiplier operands are the top `pm` bits of each significand, with
/// `pm` from [harborFpProductWidth]. A narrower format has zeros in the low
/// bits, so the product moves up by `2(p - pm)` bits. When `pm < p`, `add`
/// and `sub` do not use the multiplier: `a * 1` is `a` moved up by `M` bits.
///
/// With [HarborFpMultiplier.dsp], each operand splits into slices of at
/// most [HarborFpuConfig.mulSlice] bits, and each pair of slices is one
/// plain `*` that synthesis maps to one DSP block. Cut C2 holds these slice
/// products. In stage 3, products that do not overlap share a row, and 3:2
/// rows take the rows to two. With [HarborFpMultiplier.compressionTree],
/// stage 2 is radix 4 Booth rows in two halves, and a rohd_hcl column
/// compressor takes each half to two rows. C2 holds these four rows, and a
/// third compressor takes them to two in stage 3.
///
/// [cuts] lists the signals that cross each cut point. When [clk] is given,
/// each cut in [HarborFpuConfig.cuts] puts a register on these signals. The
/// register loads when the enable for that cut in `enables` is high, or on
/// each clock when the cut has no enable.
class HarborFpFmaPath extends Module {
  final HarborFpuConfig config;

  /// The signals that cross each cut point, before any register.
  late final Map<HarborFpCut, List<Logic>> cuts;

  /// Significand width `p`, the largest mantissa field plus one.
  late final int significandWidth;

  /// Width of the addition window.
  late final int windowWidth;

  /// Guard bits below the product in the window.
  late final int guardWidth;

  /// Width of each multiplier operand, from [harborFpProductWidth].
  late final int productWidth;

  /// Width of the internal exponent.
  late final int exponentWidth;

  Logic get op => input('op');
  Logic get fmt => input('fmt');
  Logic get fmtNarrow => input('fmt_narrow');

  /// Rounding mode: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM.
  Logic get rm => input('rm');
  Logic get a => input('a');
  Logic get b => input('b');
  Logic get c => input('c');

  /// The packed result, right aligned.
  Logic get result => output('result');

  /// `{NV, DZ, OF, UF, NX}`, NX at bit 0. DZ is always 0.
  Logic get flags => output('flags');

  HarborFpFmaPath(
    this.config, {
    required Logic op,
    required Logic fmt,
    required Logic fmtNarrow,
    required Logic rm,
    required Logic a,
    required Logic b,
    required Logic c,
    Logic? clk,
    Map<HarborFpCut, Logic> enables = const {},
    super.name = 'fp_fma_path',
  }) : super(definitionName: _definitionName(config)) {
    final ops = config.ops.intersection(harborFpFmaOps);
    if (ops.isEmpty) {
      throw ArgumentError.value(config.ops, 'config.ops', 'has no FMA op');
    }
    final formats = config.formats;
    final fmtW = config.fmtWidth;
    final opW = config.widest.width;
    final m = harborFpMaxMantissaWidth(config);
    final ue = harborFpMaxExponentWidth(config) + 2;
    final p = m + 1;
    final maddOps = {
      HarborFpOp.madd,
      HarborFpOp.msub,
      HarborFpOp.nmsub,
      HarborFpOp.nmadd,
    };
    final maddWidens =
        config.widening.isNotEmpty && ops.intersection(maddOps).isNotEmpty;
    // Guard bits below the product. When addend bits fall below the window,
    // the product top bit must stay at window bit p + 2 or higher. A subnormal
    // times a normal has its top bit at p - 1 or higher in the product.
    var lead = p - 1;
    if (maddWidens) {
      for (final (narrow, _) in config.widening) {
        lead = min(lead, 2 * (p - narrow.mantissaWidth - 1));
      }
    }
    final g = max(3, p + 2 - lead);
    final qmax = g + 2 * p + 2;
    final w = qmax + p + 1;
    final dMax = w - 1;
    final dw = dMax.bitLength;
    final pm = harborFpProductWidth(config);
    significandWidth = p;
    guardWidth = g;
    productWidth = pm;
    windowWidth = w;

    final maxBias = formats.map((f) => f.bias).reduce(max);
    final minBias = formats.map((f) => f.bias).reduce(min);
    final eLo = 1 - maxBias;
    final eHi = maxBias + 1;
    final topLo = min(2 * eLo + m + 5, eLo + 1);
    final topHi = max(2 * eHi + m + 5, eHi + 1);
    final xw = [
      ue,
      _signedBits(2 * eLo - eHi + m + 4, 2 * eHi - eLo + m + 4),
      _signedBits(topLo - w, topHi),
      _signedBits(topLo - (1 - minBias), topHi - (1 - maxBias)),
      dw + 1,
    ].reduce(max);
    exponentWidth = xw;

    op = addInput('op', op, width: harborFpOpWidth);
    fmt = addInput('fmt', fmt, width: fmtW);
    fmtNarrow = addInput(
      'fmt_narrow',
      fmtNarrow,
      width: harborFpNarrowWidth(config),
    );
    rm = addInput('rm', rm, width: 3);
    a = addInput('a', a, width: opW);
    b = addInput('b', b, width: opW);
    c = addInput('c', c, width: opW);
    if (clk != null) {
      clk = addInput('clk', clk);
    }
    final en = {
      for (final e in enables.entries)
        e.key: addInput('en_${e.key.name}', e.value),
    };
    addOutput('result', width: opW);
    addOutput('flags', width: 5);

    final groups = {for (final k in HarborFpCut.values) k: <Logic>[]};
    Logic cut(HarborFpCut k, String name, Logic s) {
      final src = s.named('${k.name}_$name');
      groups[k]!.add(src);
      if (clk == null || !config.cuts.contains(k)) {
        return src;
      }
      return flop(clk, src, en: en[k]).named('${k.name}_${name}_q');
    }

    Logic isOp(HarborFpOp o) => ops.contains(o)
        ? op.eq(Const(o.index, width: harborFpOpWidth))
        : Const(0);
    final hasAddSub =
        ops.contains(HarborFpOp.add) || ops.contains(HarborFpOp.sub);
    final hasMul = ops.contains(HarborFpOp.mul);
    final addSub = isOp(HarborFpOp.add) | isOp(HarborFpOp.sub);
    final isMul = isOp(HarborFpOp.mul);
    final negP = isOp(HarborFpOp.nmsub) | isOp(HarborFpOp.nmadd);
    final negC =
        isOp(HarborFpOp.sub) | isOp(HarborFpOp.msub) | isOp(HarborFpOp.nmadd);
    final rdn = rm.eq(Const(2, width: 3));

    // Stage 1: unpack and the decisions that need only exponents and classes.
    var fmtAb = fmt;
    var fmtC = fmt;
    final widenOps = ops.intersection({...maddOps, HarborFpOp.mul});
    Logic widened = Const(0);
    if (config.widening.isNotEmpty && widenOps.isNotEmpty) {
      final widenOp = widenOps.map(isOp).reduce((x, y) => x | y);
      for (var i = 0; i < config.widening.length; i++) {
        final (narrow, wide) = config.widening[i];
        final sel =
            widenOp & fmtNarrow.eq(Const(i + 1, width: fmtNarrow.width));
        fmtAb = mux(sel, Const(formats.indexOf(narrow), width: fmtW), fmtAb);
        fmtC = mux(sel, Const(formats.indexOf(wide), width: fmtW), fmtC);
        widened |= sel;
      }
    }
    // A format is computed exactly when its mantissa plus hidden bit fits
    // the product width pm. Otherwise it gives the canonical NaN with NV.
    Logic noProduct = Const(0);
    if (widenOps.isNotEmpty && formats.any((f) => f.mantissaWidth + 1 > pm)) {
      final built = harborFpSelect(fmt, [
        for (final f in formats) Const(f.mantissaWidth + 1 <= pm ? 1 : 0),
      ]);
      noProduct =
          widenOps.map(isOp).reduce((x, y) => x | y) & ~widened & ~built;
    }

    final ua = HarborFpUnpack(config, fmt: fmtAb, operand: a, name: 'unpack_a');
    final ub = HarborFpUnpack(config, fmt: fmtAb, operand: b, name: 'unpack_b');
    final uc = HarborFpUnpack(
      config,
      fmt: fmtC,
      operand: hasAddSub ? mux(addSub, b, c) : c,
      name: 'unpack_c',
    );

    // add and sub multiply by one. mul adds a zero.
    Logic one(Logic oneValue, Logic v) =>
        hasAddSub ? mux(addSub, oneValue, v) : v;
    Logic zero(Logic zeroValue, Logic v) =>
        hasMul ? mux(isMul, zeroValue, v) : v;
    final bSign = one(Const(0), ub.sign);
    final bExp = one(Const(0, width: ue), ub.exponent);
    final bSig = one(Const(BigInt.one << m, width: p), ub.significand);
    final bZero = one(Const(0), ub.isZero);
    final bInf = one(Const(0), ub.isInf);
    final bNan = one(Const(0), ub.isNan);
    final bSnan = one(Const(0), ub.isSnan);
    final cSig = zero(Const(0, width: p), uc.significand);
    final cZero = zero(Const(1), uc.isZero);
    final cInf = zero(Const(0), uc.isInf);
    final cNan = zero(Const(0), uc.isNan);
    final cSnan = zero(Const(0), uc.isSnan);

    final signP = (ua.sign ^ bSign ^ negP).named('sign_p');
    final signC = (zero(~rdn, uc.sign) ^ negC).named('sign_c');
    final prodZero = ua.isZero | bZero;
    final prodInf = ua.isInf | bInf;
    final invMul = (ua.isInf & bZero) | (ua.isZero & bInf);
    final invAdd = prodInf & ~ua.isNan & ~bNan & cInf & (signP ^ signC);
    final nv = ua.isSnan | bSnan | cSnan | invMul | invAdd | noProduct;
    final forceNan = ua.isNan | bNan | cNan | invMul | invAdd | noProduct;
    final forceInf = ~forceNan & (prodInf | cInf);
    final forceZero = ~forceNan & ~forceInf & prodZero & cZero;
    final special = forceNan | forceInf | forceZero;
    // Inf and zero results carry their sign on the sign_p path.
    final specSign = mux(
      forceInf,
      mux(prodInf, signP, signC),
      (signP & signC) | ((signP ^ signC) & rdn),
    );
    final effSub = (signP ^ signC) & ~cZero & ~special;

    // The addend LSB sits at window bit `qmax - d`. A negative d means the
    // addend is far above the product, so it stays at the top. Each sum of
    // exponents is one carry save row and one adder, run in parallel.
    final xw1 = xw + 1;
    Logic sx(Logic v) => v.signExtend(xw1);
    Logic expSum3(Logic x, Logic y, Logic z) {
      final carry = (x & y) | (x & z) | (y & z);
      return (x ^ y ^ z) + [carry.getRange(0, xw1 - 1), Const(0)].swizzle();
    }

    Logic k(int v) => Const(v & ((1 << xw1) - 1), width: xw1);
    final ea = sx(ua.exponent);
    final eb = sx(bExp);
    final ecN = ~sx(uc.exponent);
    // ea + eb - ec = ea + eb + ~ec + 1.
    final abc0 = ea ^ eb ^ ecN;
    final abc1 = [
      ((ea & eb) | (ea & ecN) | (eb & ecN)).getRange(0, xw1 - 1),
      Const(0),
    ].swizzle();
    final d = expSum3(abc0, abc1, k(m + 5)).getRange(0, xw).named('align_diff');
    final dNeg = d[xw - 1];
    final cDom = ((dNeg | prodZero) & ~cZero).named('c_dom');
    final expTop = mux(
      cDom,
      uc.exponent.signExtend(xw) + Const(1, width: xw),
      expSum3(ea, eb, k(m + 5)).getRange(0, xw),
    ).named('exp_top');
    final dBig = dNeg | ~expSum3(abc0, abc1, k(m + 5 - dMax - 1))[xw1 - 1];
    final dShift = mux(
      cDom,
      Const(0, width: dw),
      mux(dBig, Const(dMax, width: dw), d.getRange(0, dw)),
    );

    // Signals that ride along to later stages. The special kind is 0 for
    // none, 1 for NaN, 2 for Inf and 3 for zero.
    final ride = <String, Logic>{
      'sign_p': mux(forceInf | forceZero, specSign, signP),
      'eff_sub': effSub,
      'exp_top': expTop,
      'special': [forceInf | forceZero, forceNan | forceZero].swizzle(),
      'nv': nv,
      'rm': rm,
      if (formats.length > 1) 'fmt': fmtC,
    };
    void pass(HarborFpCut k) {
      for (final e in ride.entries.toList()) {
        ride[e.key] = cut(k, e.key, e.value);
      }
    }

    // add and sub skip the multiplier when it is narrower than p, so they
    // keep all of a.
    final bypass = hasAddSub && pm < p;
    final sigA1 = cut(
      HarborFpCut.c1,
      'sig_a',
      ua.significand.getRange(bypass ? 0 : p - pm),
    );
    final sigB1 = pm > 0
        ? cut(
            HarborFpCut.c1,
            'sig_b',
            (bypass ? ub.significand : bSig).getRange(p - pm),
          )
        : null;
    var addSub1 = bypass && pm > 0
        ? cut(HarborFpCut.c1, 'add_sub', addSub)
        : null;
    var sigC = cut(HarborFpCut.c1, 'sig_c', cSig);
    var dSh = cut(HarborFpCut.c1, 'align_shift', dShift);
    pass(HarborFpCut.c1);

    // Stage 2 and 3: the top pm bits of each significand give two rows of
    // 2pm bits. With a carry, the rows sum to the product plus 2^(2pm).
    final pa = pm > 0 ? sigA1.getRange(sigA1.width - pm) : null;
    final pb = sigB1;
    Logic? lo0;
    Logic? lo1;
    Logic? wrap;
    if (pa != null &&
        pb != null &&
        config.multiplier == HarborFpMultiplier.compressionTree) {
      // Booth rows, cut to the low 2pm + 1 columns. The rows sum to the
      // product modulo 2^(2pm + 1).
      final rowW = 2 * pm + 1;
      final pp = PartialProduct(pa, pb, RadixEncoder(4), name: 'booth_pp');
      CompactRectSignExtension(pp.array).signExtend();
      pp.generateOutputs();
      final rows = <Logic>[];
      final shifts = <int>[];
      for (var r = 0; r < pp.rows.length; r++) {
        final s = pp.rowShift[r];
        final keep = min(pp.rows[r].width, rowW - s);
        if (keep > 0) {
          rows.add(pp.rows[r].getRange(0, keep));
          shifts.add(s);
        }
      }

      // A half that does not reach the top column is summed exactly, so its
      // compressor drops no carry.
      List<(Logic, int)> compress(
        List<Logic> rs,
        List<int> sh,
        int width,
        String nm,
      ) {
        var top = 0;
        for (var i = 0; i < rs.length; i++) {
          if (sh[i] + rs[i].width > sh[top] + rs[top].width) {
            top = i;
          }
        }
        final padded = [...rs];
        padded[top] = rs[top].zeroExtend(width - sh[top]);
        final cc = ColumnCompressor(padded, sh, name: nm);
        // The compressor fills the low sh[0] and sh[1] bits of its rows
        // with 0.
        return [(cc.add0, sh[0]), (cc.add1, sh[1])];
      }

      final List<(Logic, int)> half;
      if (rows.length >= 4) {
        final k = rows.length ~/ 2;
        var topA = 0;
        for (var i = 0; i < k; i++) {
          topA = max(topA, shifts[i] + rows[i].width);
        }
        final wA = min(rowW, topA + log2Ceil(k));
        half = [
          ...compress(
            rows.sublist(0, k),
            shifts.sublist(0, k),
            wA,
            'compress_lo',
          ),
          ...compress(rows.sublist(k), shifts.sublist(k), rowW, 'compress_hi'),
        ];
      } else {
        half = [
          for (var i = 0; i < rows.length; i++)
            (
              [
                rows[i],
                if (shifts[i] > 0) Const(0, width: shifts[i]),
              ].swizzle(),
              shifts[i],
            ),
        ];
      }
      final halfRows = <Logic>[];
      for (var i = 0; i < half.length; i++) {
        final (row, zeros) = half[i];
        final kept = cut(HarborFpCut.c2, 'pp_row$i', row.getRange(zeros));
        halfRows.add(
          (zeros > 0 ? [kept, Const(0, width: zeros)].swizzle() : kept).named(
            'pp_full_row$i',
          ),
        );
      }
      final fin = ColumnCompressor(
        halfRows,
        List.filled(halfRows.length, 0),
        name: 'compress_final',
      );
      final r0 = fin.add0.getRange(0, rowW);
      final r1 = fin.add1.getRange(0, rowW);
      lo0 = r0.getRange(0, 2 * pm);
      lo1 = r1.getRange(0, 2 * pm);
      // Bit 2pm of the product is 0, so the carry into it is r0 ^ r1 there.
      wrap = r0[2 * pm] ^ r1[2 * pm];
    } else if (pa != null && pb != null) {
      // One DSP multiply for each pair of slices. C2 holds these products.
      final (sliceA, sliceB) = config.mulSlice;
      final pieces = <(Logic, int)>[];
      for (final (i, (aLo, aW)) in _slices(pm, sliceA).indexed) {
        for (final (j, (bLo, bW)) in _slices(pm, sliceB).indexed) {
          final pw = aW + bW;
          final prod =
              pa.getRange(aLo, aLo + aW).zeroExtend(pw) *
              pb.getRange(bLo, bLo + bW).zeroExtend(pw);
          pieces.add((cut(HarborFpCut.c2, 'pp_${i}_$j', prod), aLo + bLo));
        }
      }
      // Products that do not overlap share a row. 3:2 rows then take the
      // rows to two. The sum is below 2^(2pm), so no carry is lost.
      pieces.sort((x, y) => x.$2.compareTo(y.$2));
      final packed = <List<(Logic, int)>>[];
      for (final piece in pieces) {
        final row = packed.where((r) {
          final (last, at) = r.last;
          return at + last.width <= piece.$2;
        }).firstOrNull;
        row == null ? packed.add([piece]) : row.add(piece);
      }
      var rows = <Logic>[
        for (final (n, r) in packed.indexed)
          () {
            final parts = <Logic>[];
            var at = 0;
            for (final (v, lo) in r) {
              if (lo > at) {
                parts.add(Const(0, width: lo - at));
              }
              parts.add(v);
              at = lo + v.width;
            }
            if (at < 2 * pm) {
              parts.add(Const(0, width: 2 * pm - at));
            }
            return parts.reversed.toList().swizzle().named('dsp_row$n');
          }(),
      ];
      while (rows.length > 2) {
        final next = <Logic>[];
        var i = 0;
        for (; i + 3 <= rows.length; i += 3) {
          final (x, y, z) = (rows[i], rows[i + 1], rows[i + 2]);
          next
            ..add(x ^ y ^ z)
            ..add(
              [
                ((x & y) | (z & (x ^ y))).getRange(0, 2 * pm - 1),
                Const(0),
              ].swizzle(),
            );
        }
        rows = [...next, ...rows.sublist(i)];
      }
      lo0 = rows[0];
      lo1 = rows.length > 1 ? rows[1] : Const(0, width: 2 * pm);
    }
    final sigA2 = bypass ? cut(HarborFpCut.c2, 'sig_a', sigA1) : null;
    if (addSub1 != null) {
      addSub1 = cut(HarborFpCut.c2, 'add_sub', addSub1);
    }
    sigC = cut(HarborFpCut.c2, 'sig_c', sigC);
    dSh = cut(HarborFpCut.c2, 'align_shift', dSh);
    pass(HarborFpCut.c2);

    // The normalize shift stops at the minimum normal exponent:
    // at most cap places, none when cap is negative. The compares flip the
    // top bit, so an unsigned compare gives the signed order.
    final lzw = w.bitLength;
    final eTop3 = ride['exp_top']!;
    final eOff = [~eTop3[xw - 1], eTop3.getRange(0, xw - 1)].swizzle();
    Logic geTop(int c) => eOff.gte(Const(c + (1 << (xw - 1)), width: xw));
    ride['cap'] = harborFpSelect(ride['fmt'] ?? fmtC, [
      for (final f in formats)
        mux(
          ~geTop(1 - f.bias),
          Const(0, width: lzw),
          mux(
            geTop(1 - f.bias + w + 1),
            Const(w, width: lzw),
            eTop3.getRange(0, lzw) -
                Const((1 - f.bias) & ((1 << lzw) - 1), width: lzw),
          ),
        ),
    ]);
    // A negative cap keeps the exponent at eTop, else the exponent after
    // normalize is normal. So the round shift is known from eTop.
    ride['align'] = harborFpAlignShift(config, ride['fmt'] ?? fmtC, eTop3);

    // Stage 3: place the product rows at bit 2(p - pm) of a 2p bit field,
    // then add the aligned addend.
    Logic field(Logic? v) => v == null
        ? Const(0, width: 2 * p)
        : (pm < p ? [v, Const(0, width: 2 * (p - pm))].swizzle() : v);
    var r0 = field(lo0);
    var r1 = field(lo1);
    if (sigA2 != null) {
      // a * 1.0 for add and sub.
      final aOne = [Const(0), sigA2, Const(0, width: m)].swizzle();
      if (addSub1 == null) {
        r0 = aOne;
      } else {
        r0 = mux(addSub1, aOne, r0);
        r1 = mux(addSub1, Const(0, width: 2 * p), r1);
        wrap = wrap == null ? null : wrap & ~addSub1;
      }
    }
    final hiW = w - g - 2 * p;
    final x0 = [Const(0, width: hiW), r0, Const(0, width: g)].swizzle();
    // Take the carry back out above the product.
    final x1 = [
      if (wrap != null)
        mux(wrap, Const(1, width: hiW, fill: true), Const(0, width: hiW))
      else
        Const(0, width: hiW),
      r1,
      Const(0, width: g),
    ].swizzle();

    final cField = [sigC, Const(0, width: qmax)].swizzle();
    final cWin = (cField >>> dSh).zeroExtend(w).named('c_aligned');
    // Addend bit j drops below the window when dSh > j + qmax.
    final stickyC = [
      for (var j = 0; j < p; j++) sigC[j] & dSh.gt(Const(j + qmax, width: dw)),
    ].swizzle().or().named('sticky_c');
    final x2 = mux(ride['eff_sub']!, ~cWin, cWin);

    final csaSum = x0 ^ x1 ^ x2;
    final csaCarry = (x0 & x1) | (x2 & (x0 ^ x1));
    final sum3 = cut(HarborFpCut.c3, 'sum', csaSum);
    // Carry bits below g are always 0.
    final carry3 = cut(HarborFpCut.c3, 'carry', csaCarry.getRange(g, w - 1));
    ride['sticky'] = stickyC;
    pass(HarborFpCut.c3);

    // Stage 4: the sum and the sum plus one. A subtract adds ~c, so a
    // nonnegative result needs the plus one, unless addend bits were lost.
    // A negative result is ~sum.
    final sum0 = (sum3 + [carry3, Const(0, width: g + 1)].swizzle()).named(
      'sum0',
    );
    final sum1 = (sum3 + [carry3, Const(0, width: g), Const(1)].swizzle())
        .named('sum1');
    final sub = ride.remove('eff_sub')!;
    final neg = sub & sum0[w - 1];
    final mag = mux(neg, ~sum0, mux(sub & ~ride['sticky']!, sum1, sum0));
    final mag4 = cut(HarborFpCut.c4, 'mag', mag);
    ride['sign'] = ride.remove('sign_p')! ^ neg;
    pass(HarborFpCut.c4);

    // Stage 5: normalize, but not below the minimum normal exponent. A one
    // at bit w - 1 - cap stops the count at cap.
    final cap5 = ride.remove('cap')!;
    final stop = [
      for (var j = 0; j < w; j++) cap5.eq(Const(w - 1 - j, width: lzw)),
    ].rswizzle();
    final shAmt = harborFpLeadingZeros(mag4 | stop).named('norm_shift');
    final eTop = ride.remove('exp_top')!;
    final shifted = (mag4 << shAmt).named('normalized');
    final sigOut = shifted.getRange(w - p - 2, w);
    final sticky = ride.remove('sticky')!;
    // The bits below the significand go out ORed in groups of four. The
    // round ORs the groups in parallel with its alignment shift.
    final below = shifted.getRange(0, w - p - 2);
    final stickyOut = [
      sticky,
      for (var i = 0; i < below.width; i += 4)
        below.getRange(i, min(i + 4, below.width)).or(),
    ].swizzle();
    final expOut = eTop - shAmt.zeroExtend(xw);
    // An exact zero sum is +0, or -0 in RDN. Inf and zero specials keep the
    // sign they have.
    final exactZero = ~mag4.or() & ~sticky & ~ride['special']![1];
    final rdn5 = ride['rm']!.eq(Const(2, width: 3));
    ride['sign'] = mux(exactZero, rdn5, ride['sign']!);

    final sig5 = cut(HarborFpCut.c5, 'sig', sigOut);
    final sticky5 = cut(HarborFpCut.c5, 'sticky', stickyOut);
    final exp5 = cut(HarborFpCut.c5, 'exp', expOut);
    pass(HarborFpCut.c5);

    // Stage 6: round. Stage 7: pack.
    final kind = ride['special']!;
    final round = HarborFpRound(
      config,
      fmt: ride['fmt'] ?? fmtC,
      rm: ride['rm']!,
      sign: ride['sign']!,
      exponent: exp5,
      significand: sig5,
      sticky: sticky5.or(),
      alignShift: ride.remove('align'),
      forceNan: kind[0] & ~kind[1],
      forceInf: ~kind[0] & kind[1],
      forceZero: kind[0] & kind[1],
      exponentWidth: xw,
    );
    final nv6 = cut(HarborFpCut.c6, 'nv', ride['nv']!);
    final pack = HarborFpPack(config, {
      for (final e in round.mid.entries)
        e.key: cut(HarborFpCut.c6, e.key, e.value),
    });
    result <= cut(HarborFpCut.c7, 'result', pack.result);
    flags <=
        cut(
          HarborFpCut.c7,
          'flags',
          pack.flags | [nv6, Const(0, width: 4)].swizzle(),
        );

    cuts = {
      for (final k in HarborFpCut.values) k: List.unmodifiable(groups[k]!),
    };
  }

  static String _definitionName(HarborFpuConfig config) {
    final ops = config.ops.intersection(harborFpFmaOps);
    final mf = config.mulFormats;
    final parts = [
      for (final f in config.formats) f.tag,
      for (final (n, w) in config.widening) 'W${n.tag}to${w.tag}',
      for (final o in HarborFpOp.values)
        if (ops.contains(o)) o.name,
      'S${config.stages}',
      if (config.ftz) 'Ftz',
      config.multiplier == HarborFpMultiplier.compressionTree
          ? 'Ct'
          : 'Dsp${config.mulSlice.$1}x${config.mulSlice.$2}',
      if (mf != null)
        'Mf${(mf.toList()..sort(harborFpFormatCompare)).map((f) => f.tag).join()}',
    ];
    return harborStableDefinitionName('HarborFpFmaPath', parts);
  }
}

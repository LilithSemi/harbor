import 'dart:math';

import 'package:rohd/rohd.dart';

import 'fp_cuts.dart';
import 'fp_fma_path.dart' show harborFpOpWidth;
import 'fp_format.dart';
import 'fp_lzc.dart';
import 'fp_round_pack.dart';
import 'fp_unpack.dart';
import 'fpu_config.dart';

/// The ops that [HarborFpConvertPath] computes.
const harborFpConvertOps = {
  HarborFpOp.fpToFp,
  HarborFpOp.fpToInt,
  HarborFpOp.intToFp,
  HarborFpOp.cvtModWD,
  HarborFpOp.li,
  HarborFpOp.round,
  HarborFpOp.roundNx,
};

/// `fli.*`, RISC-V Zfa, table `flis` (src/unpriv/zfa.adoc). Entries are
/// `(mantissa, exp2)`: value = mantissa * 2^exp2. Index 1, 30 and 31 are
/// format dependent and built directly instead.
const _fliTable = <int, (int, int)>{
  0: (1, 0),
  2: (1, -16),
  3: (1, -15),
  4: (1, -8),
  5: (1, -7),
  6: (1, -4),
  7: (1, -3),
  8: (1, -2),
  9: (5, -4),
  10: (3, -3),
  11: (7, -4),
  12: (1, -1),
  13: (5, -3),
  14: (3, -2),
  15: (7, -3),
  16: (1, 0),
  17: (5, -2),
  18: (3, -1),
  19: (7, -2),
  20: (1, 1),
  21: (5, -1),
  22: (3, 0),
  23: (1, 2),
  24: (1, 3),
  25: (1, 4),
  26: (1, 7),
  27: (1, 8),
  28: (1, 15),
  29: (1, 16),
};

/// `fli.*`'s 32-entry ROM value for format [f], as a raw bit pattern. Index
/// 1 is the minimum positive normal, 30 is +infinity and 31 is the
/// canonical NaN. An entry that overflows the format (index 29 in half
/// precision) loads +infinity instead.
BigInt _fliValue(HarborFpFormat f, int index) {
  BigInt assemble(int sign, int expBits, BigInt mantField) =>
      (BigInt.from(sign) << (f.exponentWidth + f.mantissaWidth)) |
      (BigInt.from(expBits) << f.mantissaWidth) |
      mantField;
  BigInt inf(int sign) =>
      assemble(sign, (1 << f.exponentWidth) - 1, BigInt.zero);
  BigInt nan() => assemble(
    0,
    (1 << f.exponentWidth) - 1,
    BigInt.one << (f.mantissaWidth - 1),
  );

  if (index == 1) return assemble(0, 1, BigInt.zero);
  if (index == 30) return inf(0);
  if (index == 31) return nan();

  final (m, e) = _fliTable[index]!;
  final mantissa = BigInt.from(m);
  final te = e + mantissa.bitLength - 1;
  final maxNormalTe = (1 << f.exponentWidth) - 2 - f.bias;
  if (te > maxNormalTe) return inf(0);
  final sign = index == 0 ? 1 : 0;
  final minNormalTe = 1 - f.bias;
  if (te >= minNormalTe) {
    final shift = f.mantissaWidth - (mantissa.bitLength - 1);
    final mantField =
        (mantissa << shift) & ((BigInt.one << f.mantissaWidth) - BigInt.one);
    return assemble(sign, te + f.bias, mantField);
  }
  // Below the minimum normal: every table entry fits exactly at this width,
  // so this never rounds.
  final shift = f.mantissaWidth - (mantissa.bitLength - 1) - (minNormalTe - te);
  final mantField = mantissa << shift;
  return assemble(sign, 0, mantField);
}

int _signedBits(int lo, int hi) {
  var w = 1;
  while (lo < -(1 << (w - 1)) || hi >= (1 << (w - 1))) {
    w++;
  }
  return w;
}

/// Format and integer conversions on the shared FPU path: `fpToFp`,
/// `fpToInt`, `intToFp`, `fcvtmod.w.d`, `fround`, `froundnx` and `fli`.
///
/// [fmt] is the operand format, and the result format of `intToFp` and `li`.
/// [fmtDst] is the result format of `fpToFp`. [intWidth] selects one of
/// [HarborFpuConfig.intWidths] for `fpToInt` and `intToFp`. `cvtModWD`
/// always gives 32 bits and rounds toward zero. [liIndex] is the `fli` table
/// index. The result is right aligned with zeros above.
///
/// Let `p` be the largest significand, `A` the larger of `p` and the widest
/// integer, and `K` the integer bits the alignment keeps. The stages are:
///
///   1. Unpack, the integer operand, and the alignment shift amount.
///   2. One right shift puts the binary point of an operand that rounds to
///      an integer at a fixed place: `K` integer bits, a round bit and a
///      sticky bit.
///   3. Rounding decision and the integer range checks.
///   4. One `A` bit adder: the rounding increment, the two's complement of a
///      negative integer, or a pass of the operand. `fpToInt` and `cvtModWD`
///      finish here.
///   5. One leading zero count and left shift for every op that rounds.
///   6. [HarborFpRound].
///   7. [HarborFpPack], the `fli` table and the result select.
///
/// [cuts] lists the signals that cross each cut point. When [clk] is given,
/// each cut in [HarborFpuConfig.cuts] puts a register on these signals, with
/// the enable for that cut in `enables`.
class HarborFpConvertPath extends Module {
  final HarborFpuConfig config;

  /// The signals that cross each cut point, before any register.
  late final Map<HarborFpCut, List<Logic>> cuts;

  Logic get op => input('op');
  Logic get fmt => input('fmt');
  Logic get fmtDst => input('fmt_dst');
  Logic get rm => input('rm');
  Logic get a => input('a');
  Logic get intIn => input('int_in');
  Logic get intWidth => input('int_width');
  Logic get signed => input('is_signed');
  Logic get liIndex => input('li_index');

  /// The result, right aligned: a value of the result format, or an integer
  /// for `fpToInt` and `cvtModWD`.
  Logic get result => output('result');

  /// `{NV, DZ, OF, UF, NX}`, NX at bit 0. DZ is always 0.
  Logic get flags => output('flags');

  HarborFpConvertPath(
    this.config, {
    required Logic op,
    required Logic fmt,
    required Logic fmtDst,
    required Logic rm,
    required Logic a,
    required Logic intIn,
    required Logic intWidth,
    required Logic signed,
    required Logic liIndex,
    Logic? clk,
    Map<HarborFpCut, Logic> enables = const {},
    super.name = 'fp_convert_path',
  }) : super(definitionName: _definitionName(config)) {
    final ops = config.ops.intersection(harborFpConvertOps);
    if (ops.isEmpty) {
      throw ArgumentError.value(config.ops, 'config.ops', 'has no convert op');
    }
    bool has(Iterable<HarborFpOp> os) => os.any(ops.contains);
    const intOutOps = [HarborFpOp.fpToInt, HarborFpOp.cvtModWD];
    const roundOps = [HarborFpOp.round, HarborFpOp.roundNx];
    const packOps = [
      HarborFpOp.fpToFp,
      HarborFpOp.intToFp,
      HarborFpOp.round,
      HarborFpOp.roundNx,
    ];
    final intWidths = config.intWidths;
    if (has([...intOutOps, HarborFpOp.intToFp]) && intWidths.isEmpty) {
      throw ArgumentError.value(intWidths, 'config.intWidths', 'is empty');
    }
    final hasShift = has([...intOutOps, ...roundOps]);
    final hasPack = has(packOps);
    final hasIntOut = has(intOutOps);

    final formats = config.formats;
    final fmtW = config.fmtWidth;
    final opW = config.widest.width;
    final m = harborFpMaxMantissaWidth(config);
    final p = m + 1;
    final ewu = harborFpMaxExponentWidth(config) + 2;
    final maxIntW = intWidths.isEmpty ? 1 : intWidths.reduce(max);
    final resultW = max(opW, maxIntW);
    final aw = max(p, intWidths.isEmpty ? 0 : maxIntW);
    // cvtModWD needs the exact low 32 bits of integers up to 2^(m + 31).
    final kw = [
      m,
      if (has(intOutOps)) maxIntW,
      if (ops.contains(HarborFpOp.cvtModWD)) m + 32,
    ].reduce(max);
    final gw = p + 1;
    final tw = kw + gw;
    final shW = (kw + 1).bitLength;
    final maxBias = formats.map((f) => f.bias).reduce(max);
    final xw = max(
      ewu,
      _signedBits(1 - maxBias - m - aw - 1, aw + maxBias + 1),
    );

    op = addInput('op', op, width: harborFpOpWidth);
    fmt = addInput('fmt', fmt, width: fmtW);
    fmtDst = addInput('fmt_dst', fmtDst, width: fmtW);
    rm = addInput('rm', rm, width: 3);
    a = addInput('a', a, width: opW);
    intIn = addInput('int_in', intIn, width: maxIntW);
    intWidth = addInput(
      'int_width',
      intWidth,
      width: max(1, (intWidths.length - 1).bitLength),
    );
    signed = addInput('is_signed', signed);
    liIndex = addInput('li_index', liIndex, width: 5);
    if (clk != null) {
      clk = addInput('clk', clk);
    }
    final st = HarborFpCuts(
      config,
      clk: clk,
      enables: {
        for (final e in enables.entries)
          e.key: addInput('en_${e.key.name}', e.value),
      },
    );
    addOutput('result', width: resultW);
    addOutput('flags', width: 5);

    // Reads the op that rides with the value at the current stage.
    Logic isOp(HarborFpOp o) => ops.contains(o)
        ? st['op'].eq(Const(o.index, width: harborFpOpWidth))
        : Const(0);
    Logic anyOf(Iterable<HarborFpOp> os) =>
        os.map(isOp).reduce((x, y) => x | y);
    // The special kind is 0 for none, 1 for NaN, 2 for Inf and 3 for zero.
    Logic kindIs(int k) => st['kind'].eq(Const(k, width: 2));

    // Stage 1: unpack, the integer operand and the shift amount.
    st['op'] = op;
    final ua = HarborFpUnpack(config, fmt: fmt, operand: a, name: 'unpack_a');
    final fromInt = isOp(HarborFpOp.intToFp);
    var field = ua.significand.zeroExtend(aw);
    var sign = ua.sign;
    if (ops.contains(HarborFpOp.intToFp)) {
      final ext = harborFpSelect(intWidth, [
        for (final w in intWidths)
          mux(
            signed,
            intIn.getRange(0, w).signExtend(aw),
            intIn.getRange(0, w).zeroExtend(aw),
          ),
      ]);
      field = mux(fromInt, ext, field);
      sign = mux(fromInt, signed & ext[aw - 1], sign);
    }
    final kind = mux(
      fromInt,
      Const(0, width: 2),
      [ua.isInf | ua.isZero, ua.isNan | ua.isZero].swizzle(),
    );
    st
      ..['rm'] = ops.contains(HarborFpOp.cvtModWD)
          ? mux(isOp(HarborFpOp.cvtModWD), Const(1, width: 3), rm)
          : rm
      ..['sign'] = sign
      ..['kind'] = kind
      ..['nv'] = ua.isSnan & anyOf([HarborFpOp.fpToFp, ...roundOps])
      ..['field'] = field;
    if (formats.length > 1 && (hasPack || ops.contains(HarborFpOp.li))) {
      st['fmt'] = ops.contains(HarborFpOp.fpToFp)
          ? mux(isOp(HarborFpOp.fpToFp), fmtDst, fmt)
          : fmt;
    }
    if (hasIntOut) {
      st['signed'] = signed;
      if (intWidths.length > 1) {
        st['int_width'] = intWidth;
      }
    }
    if (ops.contains(HarborFpOp.li)) {
      st['li_index'] = liIndex;
    }

    final sw = max(ewu, shW + 1) + 1;
    final expS = ua.exponent.signExtend(sw);
    // Signed compares with constants. With the top bit flipped, an unsigned
    // compare gives the signed order.
    final expOff = [~expS[sw - 1], expS.getRange(0, sw - 1)].swizzle();
    Logic expGe(int c) => expOff.gte(Const(c + (1 << (sw - 1)), width: sw));
    // The value is significand * 2^(exponent - m), so it is an integer when
    // the exponent is at least m.
    final integral = expGe(m);
    if (hasShift) {
      // The shift is kw - 1 - exponent, 0 when that is negative, and at
      // most kw + 1.
      final tooBig = expGe(kw);
      st
        ..['shift'] = mux(
          tooBig,
          Const(0, width: shW),
          mux(
            ~expGe(-2),
            Const(kw + 1, width: shW),
            Const((kw - 1) & ((1 << shW) - 1), width: shW) -
                expS.getRange(0, shW),
          ),
        )
        ..['too_big'] = tooBig
        ..['use_kept'] = anyOf(intOutOps) | (anyOf(roundOps) & ~integral);
    }
    if (hasPack) {
      // The weight of field bit aw - 1: 2^(exponent - m + aw - 1) for a
      // significand, 2^(aw - 1) for an integer.
      final fpScaled = isOp(HarborFpOp.fpToFp) | (anyOf(roundOps) & integral);
      st['e_top'] = mux(
        fpScaled,
        ua.exponent.signExtend(xw) + Const(aw - 1 - m, width: xw),
        Const(aw - 1, width: xw),
      );
    }
    st.pass(HarborFpCut.c1);

    // Stage 2: align the binary point. The significand starts at the top of
    // a kw + gw bit field and shifts right until its hidden bit has weight
    // 2^exponent. Bits gw and up are the integer, bit gw - 1 the round bit.
    if (hasShift) {
      final f = st.ride.remove('field')!;
      final tooBig = st.ride.remove('too_big')!;
      final useKept = st.ride.remove('use_kept')!;
      final placed = [f.getRange(0, p), Const(0, width: tw - p)].swizzle();
      final shift = st.ride.remove('shift')!;
      final shifted = (placed >>> shift).named('aligned');
      final kept = shifted.getRange(gw, tw);
      // Field bit i goes below the round bit when the shift is at least
      // i + kw + 2 - p. This mask does not wait for the shift.
      final lost = [
        for (var i = 0; i < p; i++)
          f[i] & shift.gte(Const(i + kw + 2 - p, width: shift.width)),
      ].swizzle().or();
      final keptLow = kept.getRange(0, min(kw, aw)).zeroExtend(aw);
      final keptHigh = kw > aw ? kept.getRange(aw, kw).or() : Const(0);
      st
        ..['val'] = mux(useKept, mux(tooBig, Const(0, width: aw), keptLow), f)
        ..['hi'] = useKept & (tooBig | keptHigh)
        ..['round_bit'] = useKept & ~tooBig & shifted[gw - 1]
        ..['sticky'] = useKept & ~tooBig & lost;
    } else {
      st['val'] = st.ride.remove('field')!;
    }
    st.pass(HarborFpCut.c2);

    // Stage 3: rounding decision, range checks and the adder operand.
    {
      final val = st.ride.remove('val')!;
      Logic cin = Const(0);
      Logic inexact = Const(0);
      Logic hi = Const(0);
      if (hasShift) {
        final rb = st.ride.remove('round_bit')!;
        final sticky = st.ride.remove('sticky')!;
        hi = st.ride.remove('hi')!;
        cin = harborFpRoundUp(st['rm'], st['sign'], rb, sticky, val[0]);
        inexact = rb | sticky;
      }
      final rUp = cin;
      final negOps = [...intOutOps, HarborFpOp.intToFp].where(ops.contains);
      final neg = negOps.isEmpty ? Const(0) : st['sign'] & anyOf(negOps);
      st
        ..['x'] = mux(neg, ~val, val)
        ..['cin'] = neg ^ rUp;

      // A magnitude kept + rUp is above limit when kept is above it, or
      // equal with a round up.
      Logic above(BigInt Function(bool neg) limit) {
        final l = mux(
          st['sign'],
          Const(limit(true), width: aw),
          Const(limit(false), width: aw),
        );
        return hi | val.gt(l) | (val.eq(l) & rUp);
      }

      final nan = kindIs(1);
      final inf = kindIs(2);
      final sign = st['sign'];
      var nv = st['nv'];
      Logic nx = Const(0);
      if (roundOps.any(ops.contains)) {
        nx = mux(isOp(HarborFpOp.roundNx), inexact & kindIs(0), nx);
      }
      // Int kind: 0 the adder result, 1 zero, 2 the largest, 3 the smallest.
      Logic intKind = Const(0, width: 2);
      if (ops.contains(HarborFpOp.fpToInt)) {
        final signedL = st['signed'];
        final oor = harborFpSelect(st.ride['int_width'] ?? Const(0), [
          for (final w in intWidths)
            mux(
              signedL,
              above(
                (n) => n
                    ? BigInt.one << (w - 1)
                    : (BigInt.one << (w - 1)) - BigInt.one,
              ),
              above((_) => (BigInt.one << w) - BigInt.one) |
                  (sign & (hi | val.or() | rUp)),
            ),
        ]);
        final bad = nan | inf | oor;
        final sel = isOp(HarborFpOp.fpToInt);
        nv = nv | (sel & bad);
        nx = mux(sel, ~bad & inexact, nx);
        intKind = mux(sel & bad, [Const(1), sign & ~nan].swizzle(), intKind);
      }
      if (ops.contains(HarborFpOp.cvtModWD)) {
        final oor = above(
          (n) => n ? BigInt.one << 31 : (BigInt.one << 31) - BigInt.one,
        );
        final bad = nan | inf | oor;
        final sel = isOp(HarborFpOp.cvtModWD);
        nv = nv | (sel & bad);
        nx = mux(sel, ~bad & inexact, nx);
        intKind = mux(sel & (nan | inf), Const(1, width: 2), intKind);
      }
      st
        ..['nv'] = nv
        ..['nx'] = nx;
      if (hasIntOut) {
        st['int_kind'] = intKind;
      }
    }
    st.pass(HarborFpCut.c3);

    // Stage 4: the adder. fpToInt and cvtModWD finish here.
    {
      final sum = (st.ride.remove('x')! + st.ride.remove('cin')!.zeroExtend(aw))
          .named('sum');
      var val = sum;
      if (hasIntOut) {
        final intKind = st.ride.remove('int_kind')!;
        Logic pick(int w, BigInt largest, BigInt smallest) =>
            harborFpSelect(intKind, [
              sum.getRange(0, w),
              Const(0, width: w),
              Const(largest, width: w),
              Const(smallest, width: w),
            ]).zeroExtend(aw);
        if (ops.contains(HarborFpOp.fpToInt)) {
          final signedL = st.ride.remove('signed')!;
          final r = harborFpSelect(st.ride.remove('int_width') ?? Const(0), [
            for (final w in intWidths)
              mux(
                signedL,
                pick(
                  w,
                  (BigInt.one << (w - 1)) - BigInt.one,
                  BigInt.one << (w - 1),
                ),
                pick(w, (BigInt.one << w) - BigInt.one, BigInt.zero),
              ),
          ]);
          val = mux(isOp(HarborFpOp.fpToInt), r, val);
        } else {
          st.ride
            ..remove('signed')
            ..remove('int_width');
        }
        if (ops.contains(HarborFpOp.cvtModWD)) {
          val = mux(
            isOp(HarborFpOp.cvtModWD),
            pick(32, BigInt.zero, BigInt.zero),
            val,
          );
        }
      }
      st['val'] = val;
    }
    st.pass(HarborFpCut.c4);

    // Stage 5: normalize for round and pack.
    if (hasPack) {
      final val = st['val'];
      final lz = harborFpLeadingZeros(val).named('lead_zeros');
      final isPack = anyOf(packOps);
      st
        ..['val'] = (val << mux(isPack, lz, Const(0, width: lz.width))).named(
          'normalized',
        )
        ..['exp'] = st.ride.remove('e_top')! - lz.zeroExtend(xw);
    }
    st.pass(HarborFpCut.c5);

    // Stage 6: round. Stage 7: pack, the fli table and the result select.
    final fmtR = st.ride['fmt'] ?? Const(0, width: fmtW);
    Map<String, Logic>? mid;
    if (hasPack) {
      final sigW = p + 2;
      final val = st['val'];
      final round = HarborFpRound(
        config,
        fmt: fmtR,
        rm: st['rm'],
        sign: st['sign'],
        exponent: st.ride.remove('exp')!,
        significand: aw >= sigW
            ? val.getRange(aw - sigW)
            : [val, Const(0, width: sigW - aw)].swizzle(),
        sticky: aw > sigW ? val.getRange(0, aw - sigW).or() : Const(0),
        forceNan: kindIs(1),
        forceInf: kindIs(2),
        forceZero: kindIs(3),
        exponentWidth: xw,
      );
      mid = {
        for (final e in round.mid.entries)
          e.key: st.cut(HarborFpCut.c6, e.key, e.value),
      };
    }
    st.ride
      ..remove('rm')
      ..remove('sign')
      ..remove('kind');
    if (!hasIntOut) {
      st.ride.remove('val');
    }
    if (!ops.contains(HarborFpOp.li)) {
      st.ride.remove('fmt');
    }
    st.pass(HarborFpCut.c6);

    final opFlags = [st['nv'], Const(0, width: 3), st['nx']].swizzle();
    Logic resultOut = hasIntOut
        ? st['val'].zeroExtend(resultW)
        : Const(0, width: resultW);
    Logic flagsOut = opFlags;
    if (mid != null) {
      final pack = HarborFpPack(config, mid);
      final sel = anyOf(packOps);
      resultOut = mux(sel, pack.result.zeroExtend(resultW), resultOut);
      flagsOut = mux(sel, pack.flags | opFlags, flagsOut);
    }
    if (ops.contains(HarborFpOp.li)) {
      final rom = harborFpSelect(st.ride['fmt'] ?? Const(0, width: fmtW), [
        for (final f in formats)
          harborFpSelect(st['li_index'], [
            for (var i = 0; i < 32; i++)
              Const(_fliValue(f, i), width: f.width).zeroExtend(resultW),
          ]),
      ]);
      final sel = isOp(HarborFpOp.li);
      resultOut = mux(sel, rom, resultOut);
      flagsOut = mux(sel, Const(0, width: 5), flagsOut);
    }
    result <= st.cut(HarborFpCut.c7, 'result', resultOut);
    flags <= st.cut(HarborFpCut.c7, 'flags', flagsOut);
    cuts = st.groups;
  }

  static String _definitionName(HarborFpuConfig config) {
    final ops = config.ops.intersection(harborFpConvertOps);
    final parts = [
      for (final f in config.formats) f.tag,
      for (final o in HarborFpOp.values)
        if (ops.contains(o)) o.name,
      'S${config.stages}',
      for (final w in config.intWidths) 'I$w',
    ];
    return harborStableDefinitionName('HarborFpConvertPath', parts);
  }
}

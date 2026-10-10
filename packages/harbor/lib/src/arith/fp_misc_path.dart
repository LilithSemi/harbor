import 'package:rohd/rohd.dart';

import 'fp_cuts.dart';
import 'fp_fma_path.dart' show harborFpOpWidth;
import 'fp_format.dart';
import 'fp_unpack.dart';
import 'fpu_config.dart';

/// The ops that [HarborFpMiscPath] computes.
const harborFpMiscOps = {
  HarborFpOp.eq,
  HarborFpOp.lt,
  HarborFpOp.le,
  HarborFpOp.ltq,
  HarborFpOp.leq,
  HarborFpOp.min,
  HarborFpOp.max,
  HarborFpOp.minm,
  HarborFpOp.maxm,
  HarborFpOp.classify,
  HarborFpOp.sgnj,
  HarborFpOp.sgnjn,
  HarborFpOp.sgnjx,
};

/// Compare, min/max, classify and sign injection on the shared FPU path.
///
/// None of these ops round, so the result comes from [HarborFpUnpack] and a
/// final select, with no [HarborFpRoundPack]. `eq`, `ltq` and `leq` are the
/// quiet compares and raise NV only on a signaling NaN. `lt` and `le` are the
/// signaling compares and raise NV on any NaN. `minm` and `maxm` propagate
/// NaN (the 754-2019 `minimum` and `maximum`). `min` and `max` return the
/// operand that is not NaN.
///
/// Compare, min, max, minm and maxm flush a subnormal operand when
/// [HarborFpuConfig.ftz] is set. Classify and sign injection never flush.
///
/// [op] holds a [HarborFpOp] index. [fmt] selects the format of [a] and [b].
/// The result is right aligned with zeros above the format: a 1 bit compare,
/// a 10 bit classify mask, or a value of the format.
///
/// All ops finish before cut C1. The result and flags then go through every
/// cut. When [clk] is given, each cut in [HarborFpuConfig.cuts] puts a
/// register on them, with the enable for that cut in `enables`.
class HarborFpMiscPath extends Module {
  final HarborFpuConfig config;

  /// The signals that cross each cut point, before any register.
  late final Map<HarborFpCut, List<Logic>> cuts;

  Logic get op => input('op');
  Logic get fmt => input('fmt');
  Logic get a => input('a');
  Logic get b => input('b');

  /// The result, right aligned.
  Logic get result => output('result');

  /// `{NV, DZ, OF, UF, NX}`, NX at bit 0. Only NV is ever set.
  Logic get flags => output('flags');

  HarborFpMiscPath(
    this.config, {
    required Logic op,
    required Logic fmt,
    required Logic a,
    required Logic b,
    Logic? clk,
    Map<HarborFpCut, Logic> enables = const {},
    super.name = 'fp_misc_path',
  }) : super(definitionName: _definitionName(config)) {
    final ops = config.ops.intersection(harborFpMiscOps);
    if (ops.isEmpty) {
      throw ArgumentError.value(config.ops, 'config.ops', 'has no misc op');
    }
    final formats = config.formats;
    final fmtW = config.fmtWidth;
    final opW = config.widest.width;
    final opIdxW = harborFpOpWidth;

    op = addInput('op', op, width: opIdxW);
    fmt = addInput('fmt', fmt, width: fmtW);
    a = addInput('a', a, width: opW);
    b = addInput('b', b, width: opW);
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
    addOutput('result', width: opW);
    addOutput('flags', width: 5);

    Logic isOp(HarborFpOp o) =>
        ops.contains(o) ? op.eq(Const(o.index, width: opIdxW)) : Const(0);
    Logic anyOf(List<HarborFpOp> os) => os.map(isOp).reduce((x, y) => x | y);

    final cmpOps = [
      HarborFpOp.eq,
      HarborFpOp.lt,
      HarborFpOp.le,
      HarborFpOp.ltq,
      HarborFpOp.leq,
    ].where(ops.contains).toList();
    final minMaxOps = [
      HarborFpOp.min,
      HarborFpOp.max,
      HarborFpOp.minm,
      HarborFpOp.maxm,
    ].where(ops.contains).toList();
    final sgnjOps = [
      HarborFpOp.sgnj,
      HarborFpOp.sgnjn,
      HarborFpOp.sgnjx,
    ].where(ops.contains).toList();
    final needsValueUnpack = cmpOps.isNotEmpty || minMaxOps.isNotEmpty;

    Logic resultOut = Const(0, width: opW);
    Logic flagsOut = Const(0, width: 5);

    HarborFpUnpack? valueA;
    if (needsValueUnpack) {
      final ua = HarborFpUnpack(config, fmt: fmt, operand: a, name: 'unpack_a');
      valueA = ua;
      final ub = HarborFpUnpack(config, fmt: fmt, operand: b, name: 'unpack_b');
      final ew = ua.exponentWidth;

      Logic flipMsb(Logic x) => [~x[ew - 1], x.getRange(0, ew - 1)].swizzle();
      final keyA = [flipMsb(ua.exponent), ua.significand].swizzle();
      final keyB = [flipMsb(ub.exponent), ub.significand].swizzle();
      final magLt = keyA.lt(keyB);
      final magEq = keyA.eq(keyB);
      final magGt = ~magLt & ~magEq;

      final diffSign = ua.sign ^ ub.sign;
      final bothZero = ua.isZero & ub.isZero;
      final signedLess = mux(diffSign, ua.sign, mux(ua.sign, magGt, magLt));
      final signedEq = ~diffSign & magEq;
      final eqFinal = (bothZero | signedEq).named('cmp_eq');
      final ltFinal = (~bothZero & signedLess).named('cmp_lt');
      final leFinal = (eqFinal | ltFinal).named('cmp_le');

      final anyNan = ua.isNan | ub.isNan;
      final anySignaling = ua.isSnan | ub.isSnan;

      // Zero-safe bits: a flushed subnormal has no raw pattern for its
      // winning side, so a zero result is rebuilt as a signed zero instead.
      Logic zeroVariant(Logic sign) => harborFpSelect(fmt, [
        for (final f in formats)
          mux(
            sign,
            Const(BigInt.one << (f.width - 1), width: opW),
            Const(0, width: opW),
          ),
      ]);
      // The operand bits with zeros above the format.
      Logic clean(Logic x) => harborFpSelect(fmt, [
        for (final f in formats) x.getRange(0, f.width).zeroExtend(opW),
      ]);
      final aSafe = mux(ua.isZero, zeroVariant(ua.sign), clean(a));
      final bSafe = mux(ub.isZero, zeroVariant(ub.sign), clean(b));

      if (cmpOps.isNotEmpty) {
        final quiet = anyOf([HarborFpOp.eq, HarborFpOp.ltq, HarborFpOp.leq]);
        final cmpNv = mux(quiet, anySignaling, anyNan);
        Logic cmpBit = Const(0);
        if (ops.contains(HarborFpOp.eq)) {
          cmpBit = mux(isOp(HarborFpOp.eq), eqFinal, cmpBit);
        }
        if (ops.contains(HarborFpOp.lt) || ops.contains(HarborFpOp.ltq)) {
          cmpBit = mux(
            isOp(HarborFpOp.lt) | isOp(HarborFpOp.ltq),
            ltFinal,
            cmpBit,
          );
        }
        if (ops.contains(HarborFpOp.le) || ops.contains(HarborFpOp.leq)) {
          cmpBit = mux(
            isOp(HarborFpOp.le) | isOp(HarborFpOp.leq),
            leFinal,
            cmpBit,
          );
        }
        cmpBit = mux(anyNan, Const(0), cmpBit);
        final anyCmp = anyOf(cmpOps);
        resultOut = mux(anyCmp, cmpBit.zeroExtend(opW), resultOut);
        flagsOut = mux(anyCmp, [cmpNv, Const(0, width: 4)].swizzle(), flagsOut);
      }

      if (minMaxOps.isNotEmpty) {
        final nvMinMax = anySignaling;
        final bothNan = ua.isNan & ub.isNan;
        final aNanOnly = ua.isNan & ~ub.isNan;
        final bNanOnly = ub.isNan & ~ua.isNan;
        final canonicalizeSingle = anyOf([HarborFpOp.minm, HarborFpOp.maxm]);
        final resultIsNan = mux(
          canonicalizeSingle,
          ua.isNan | ub.isNan,
          bothNan,
        );

        final aNegZero = ua.isZero & ua.sign;
        final bNegZero = ub.isZero & ub.sign;
        final aPosZero = ua.isZero & ~ua.sign;
        final bPosZero = ub.isZero & ~ub.sign;
        final mixedZero = (aNegZero & bPosZero) | (aPosZero & bNegZero);
        final isMax = anyOf([HarborFpOp.max, HarborFpOp.maxm]);
        final mixedAWins = mux(~isMax, aNegZero, aPosZero);
        final generalAWins = mux(isMax, ~ltFinal, leFinal);
        final aWins = mux(mixedZero, mixedAWins, generalAWins);

        final numberResult = mux(aWins, aSafe, bSafe);
        final propagated = mux(
          aNanOnly,
          bSafe,
          mux(bNanOnly, aSafe, numberResult),
        );
        final canonicalNan = harborFpSelect(fmt, [
          for (final f in formats)
            [
              Const(0),
              Const(1, width: f.exponentWidth, fill: true),
              Const(
                BigInt.one << (f.mantissaWidth - 1),
                width: f.mantissaWidth,
              ),
            ].swizzle().zeroExtend(opW),
        ]);
        final minMaxResult = mux(resultIsNan, canonicalNan, propagated);

        final anyMinMax = anyOf(minMaxOps);
        resultOut = mux(anyMinMax, minMaxResult, resultOut);
        flagsOut = mux(
          anyMinMax,
          [nvMinMax, Const(0, width: 4)].swizzle(),
          flagsOut,
        );
      }
    }

    if (ops.contains(HarborFpOp.classify)) {
      // Classify sees subnormals, so it needs an unpack that does not flush.
      final uaRaw = valueA != null && !config.ftz
          ? valueA
          : HarborFpUnpack(
              config,
              fmt: fmt,
              operand: a,
              ftz: false,
              name: 'unpack_a_raw',
            );
      final signA = uaRaw.sign;
      final finiteNz = ~uaRaw.isZero & ~uaRaw.isInf & ~uaRaw.isNan;
      final b0 = uaRaw.isInf & signA;
      final b1 = finiteNz & signA & ~uaRaw.isSub;
      final b2 = finiteNz & signA & uaRaw.isSub;
      final b3 = uaRaw.isZero & signA;
      final b4 = uaRaw.isZero & ~signA;
      final b5 = finiteNz & ~signA & uaRaw.isSub;
      final b6 = finiteNz & ~signA & ~uaRaw.isSub;
      final b7 = uaRaw.isInf & ~signA;
      final b8 = uaRaw.isSnan;
      final b9 = uaRaw.isNan & ~uaRaw.isSnan;
      final classMask = [b9, b8, b7, b6, b5, b4, b3, b2, b1, b0].swizzle();
      resultOut = mux(
        isOp(HarborFpOp.classify),
        classMask.zeroExtend(opW),
        resultOut,
      );
    }

    if (sgnjOps.isNotEmpty) {
      Logic sgnjWord(HarborFpFormat f) {
        final sA = a[f.width - 1];
        final sB = b[f.width - 1];
        final rest = a.getRange(0, f.width - 1);
        var sign = sA ^ sB;
        if (ops.contains(HarborFpOp.sgnjn)) {
          sign = mux(isOp(HarborFpOp.sgnjn), ~sB, sign);
        }
        if (ops.contains(HarborFpOp.sgnj)) {
          sign = mux(isOp(HarborFpOp.sgnj), sB, sign);
        }
        return [sign, rest].swizzle().zeroExtend(opW);
      }

      final sgnjResult = harborFpSelect(fmt, [
        for (final f in formats) sgnjWord(f),
      ]);
      resultOut = mux(anyOf(sgnjOps), sgnjResult, resultOut);
    }

    st
      ..['result'] = resultOut
      ..['flags'] = flagsOut
      ..passRange(HarborFpCut.c1, HarborFpCut.c7);
    result <= st['result'];
    flags <= st['flags'];
    cuts = st.groups;
  }

  static String _definitionName(HarborFpuConfig config) {
    final ops = config.ops.intersection(harborFpMiscOps);
    final parts = [
      for (final f in config.formats) f.tag,
      for (final o in HarborFpOp.values)
        if (ops.contains(o)) o.name,
      'S${config.stages}',
      if (config.ftz) 'Ftz',
    ];
    return harborStableDefinitionName('HarborFpMiscPath', parts);
  }
}

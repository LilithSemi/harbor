import 'package:rohd/rohd.dart';

import 'fp_cuts.dart';
import 'fp_fma_path.dart' show harborFpOpWidth;
import 'fp_format.dart';
import 'fp_lzc.dart';
import 'fp_unpack.dart';
import 'fpu_config.dart';

/// The ops that [HarborFpEstimate] computes.
const harborFpEstimateOps = {HarborFpOp.rec7, HarborFpOp.rsqrt7};

/// `vfrec7.v` table, RISC-V "V" vector extension 1.0, "Vector
/// Floating-Point Reciprocal Estimate Instruction" (vfrec7.adoc).
const _rec7Table = [
  127,
  125,
  123,
  121,
  119,
  117,
  116,
  114,
  112,
  110,
  109,
  107,
  105,
  104,
  102,
  100,
  99,
  97,
  96,
  94,
  93,
  91,
  90,
  88,
  87,
  85,
  84,
  83,
  81,
  80,
  79,
  77,
  76,
  75,
  74,
  72,
  71,
  70,
  69,
  68,
  66,
  65,
  64,
  63,
  62,
  61,
  60,
  59,
  58,
  57,
  56,
  55,
  54,
  53,
  52,
  51,
  50,
  49,
  48,
  47,
  46,
  45,
  44,
  43,
  42,
  41,
  40,
  40,
  39,
  38,
  37,
  36,
  35,
  35,
  34,
  33,
  32,
  31,
  31,
  30,
  29,
  28,
  28,
  27,
  26,
  25,
  25,
  24,
  23,
  23,
  22,
  21,
  21,
  20,
  19,
  19,
  18,
  17,
  17,
  16,
  15,
  15,
  14,
  14,
  13,
  12,
  12,
  11,
  11,
  10,
  9,
  9,
  8,
  8,
  7,
  7,
  6,
  5,
  5,
  4,
  4,
  3,
  3,
  2,
  2,
  1,
  1,
  0,
];

/// `vfrsqrt7.v` table, "... Reciprocal Square-Root Estimate Instruction"
/// (vfrsqrt7.adoc), indexed `[exponent parity][top 6 fraction bits]`.
const _rsqrt7Table = [
  [
    52,
    51,
    50,
    48,
    47,
    46,
    44,
    43,
    42,
    41,
    40,
    39,
    38,
    36,
    35,
    34,
    33,
    32,
    31,
    30,
    30,
    29,
    28,
    27,
    26,
    25,
    24,
    23,
    23,
    22,
    21,
    20,
    19,
    19,
    18,
    17,
    16,
    16,
    15,
    14,
    14,
    13,
    12,
    12,
    11,
    10,
    10,
    9,
    9,
    8,
    7,
    7,
    6,
    6,
    5,
    4,
    4,
    3,
    3,
    2,
    2,
    1,
    1,
    0,
  ],
  [
    127,
    125,
    123,
    121,
    119,
    118,
    116,
    114,
    113,
    111,
    109,
    108,
    106,
    105,
    103,
    102,
    100,
    99,
    97,
    96,
    95,
    93,
    92,
    91,
    90,
    88,
    87,
    86,
    85,
    84,
    83,
    82,
    80,
    79,
    78,
    77,
    76,
    75,
    74,
    73,
    72,
    71,
    70,
    70,
    69,
    68,
    67,
    66,
    65,
    64,
    63,
    63,
    62,
    61,
    60,
    59,
    59,
    58,
    57,
    56,
    56,
    55,
    54,
    53,
  ],
];

/// `vfrec7.v` and `vfrsqrt7.v`, RISC-V V extension: 7 bit estimates of
/// 1/x and 1/sqrt(x) from the fixed tables above.
///
/// The operand goes through [HarborFpUnpack], which flushes it when
/// [HarborFpuConfig.ftz] is set. The result is a table entry put in place,
/// with no rounding. `rec7` reads [rm] only when the result overflows.
///
/// The stages are:
///
///   1. Unpack.
///   2. Leading zero count and shift: the true exponent and the top bits
///      below the leading one.
///   3. Table lookup.
///   6. Result exponent and pack, after cut C5. The result then goes
///      through C6 and C7.
///
/// [cuts] lists the signals that cross each cut point. When [clk] is given,
/// each cut in [HarborFpuConfig.cuts] puts a register on these signals, with
/// the enable for that cut in `enables`.
class HarborFpEstimate extends Module {
  final HarborFpuConfig config;

  /// The signals that cross each cut point, before any register.
  late final Map<HarborFpCut, List<Logic>> cuts;

  Logic get op => input('op');
  Logic get fmt => input('fmt');
  Logic get rm => input('rm');
  Logic get a => input('a');

  Logic get result => output('result');

  /// `{NV, DZ, OF, UF, NX}`, NX at bit 0. UF is set only when ftz flushes a
  /// subnormal `rec7` result.
  Logic get flags => output('flags');

  HarborFpEstimate(
    this.config, {
    required Logic op,
    required Logic fmt,
    required Logic rm,
    required Logic a,
    Logic? clk,
    Map<HarborFpCut, Logic> enables = const {},
    super.name = 'fp_estimate',
  }) : super(definitionName: _definitionName(config)) {
    final ops = config.ops.intersection(harborFpEstimateOps);
    if (ops.isEmpty) {
      throw ArgumentError.value(config.ops, 'config.ops', 'has no estimate op');
    }
    final formats = config.formats;
    final fmtW = config.fmtWidth;
    final opW = config.widest.width;
    final p = harborFpMaxMantissaWidth(config) + 1;
    final ewu = harborFpMaxExponentWidth(config) + 2;
    // Stage 6 math on te needs about two more bits than an exponent.
    final cw = ewu + 2;

    op = addInput('op', op, width: harborFpOpWidth);
    fmt = addInput('fmt', fmt, width: fmtW);
    rm = addInput('rm', rm, width: 3);
    a = addInput('a', a, width: opW);
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

    // Reads the op that rides with the value at the current stage.
    Logic isOp(HarborFpOp o) => ops.contains(o)
        ? st['op'].eq(Const(o.index, width: harborFpOpWidth))
        : Const(0);

    // Stage 1: unpack.
    final ua = HarborFpUnpack(config, fmt: fmt, operand: a, name: 'unpack_a');
    st
      ..['op'] = op
      ..['fmt'] = fmt
      ..['rm'] = rm
      ..['sign'] = ua.sign
      ..['is_nan'] = ua.isNan
      ..['is_zero'] = ua.isZero
      ..['is_inf'] = ua.isInf;
    // rsqrt7 of a negative nonzero value is invalid too.
    var nv = ua.isSnan;
    if (ops.contains(HarborFpOp.rsqrt7)) {
      nv = nv | (isOp(HarborFpOp.rsqrt7) & ua.sign & ~ua.isZero & ~ua.isNan);
    }
    st['nv'] = nv;
    final sig = st.cut(HarborFpCut.c1, 'sig', ua.significand);
    final exp = st.cut(HarborFpCut.c1, 'exp', ua.exponent);
    st.pass(HarborFpCut.c1);

    // Stage 2: the true exponent and the top bits below the leading one.
    final lz = harborFpLeadingZeros(sig).named('lead_zeros');
    final normSig = (sig << lz).named('norm_sig');
    final te = (exp - lz.zeroExtend(ewu)).named('te');
    final top7 = st.cut(HarborFpCut.c2, 'top7', normSig.getRange(p - 8, p - 1));
    st
      ..['te'] = te
      ..pass(HarborFpCut.c2);

    // Stage 3: table lookup. Every bias is odd, so the rsqrt7 row is the
    // inverse of the te LSB.
    Logic est = Const(0, width: 7);
    if (ops.contains(HarborFpOp.rec7)) {
      est = harborFpSelect(top7, [
        for (final v in _rec7Table) Const(v, width: 7),
      ]);
    }
    if (ops.contains(HarborFpOp.rsqrt7)) {
      final top6 = top7.getRange(1, 7);
      final rows = [
        for (final row in _rsqrt7Table)
          harborFpSelect(top6, [for (final v in row) Const(v, width: 7)]),
      ];
      est = mux(
        isOp(HarborFpOp.rsqrt7),
        mux(st['te'][0], rows[0], rows[1]),
        est,
      );
    }
    st
      ..['est'] = est
      ..passRange(HarborFpCut.c3, HarborFpCut.c5);

    // Stage 6: the result exponent and the packed word.
    final sign = st['sign'];
    final te6 = st['te'].signExtend(cw);
    final frac7 = st['est'];
    final fmt6 = st['fmt'];
    final isNan = st['is_nan'];
    final isZero = st['is_zero'];
    final isInf = st['is_inf'];

    Logic word(Logic sign, Logic expBits, Logic mantField) =>
        [sign, expBits, mantField].swizzle().zeroExtend(opW);
    Logic infWord(HarborFpFormat f, Logic sign) => word(
      sign,
      Const(1, width: f.exponentWidth, fill: true),
      Const(0, width: f.mantissaWidth),
    );
    Logic zeroWord(HarborFpFormat f, Logic sign) => word(
      sign,
      Const(0, width: f.exponentWidth),
      Const(0, width: f.mantissaWidth),
    );
    Logic fracOf(HarborFpFormat f) =>
        frac7.zeroExtend(f.mantissaWidth) << (f.mantissaWidth - 7);
    Logic perFormat(Logic Function(HarborFpFormat f) build) =>
        harborFpSelect(fmt6, [for (final f in formats) build(f)]);
    final nanWord = perFormat(
      (f) => word(
        Const(0),
        Const(1, width: f.exponentWidth, fill: true),
        Const(1 << (f.mantissaWidth - 1), width: f.mantissaWidth),
      ),
    );
    Logic flagWord({bool nv = false, bool dz = false, Logic? of, Logic? uf}) =>
        [
          Const(nv ? 1 : 0),
          Const(dz ? 1 : 0),
          of ?? Const(0),
          uf ?? Const(0),
          (of ?? Const(0)) | (uf ?? Const(0)),
        ].swizzle();

    Logic resultOut = Const(0, width: opW);
    Logic flagsOut = Const(0, width: 5);

    if (ops.contains(HarborFpOp.rec7)) {
      final toInf =
          st['rm'].eq(Const(0, width: 3)) |
          st['rm'].eq(Const(4, width: 3)) |
          (st['rm'].eq(Const(3, width: 3)) & ~sign) |
          (st['rm'].eq(Const(2, width: 3)) & sign);
      final words = <Logic>[];
      final overflows = <Logic>[];
      final flushes = <Logic>[];
      // Signed `te < c`. With the top bit flipped, an unsigned compare
      // gives the signed order.
      final teOff = [~te6[cw - 1], te6.getRange(0, cw - 1)].swizzle();
      Logic teLt(int c) => ~teOff.gte(Const(c + (1 << (cw - 1)), width: cw));
      for (final f in formats) {
        final m = f.mantissaWidth;
        final e = f.exponentWidth;
        // The result exponent is bias - 1 - te. Each test on it is a test on
        // te against a constant, so only the low bits need an adder.
        final overflow = teLt(-f.bias - 1);
        final subOut = ~teLt(f.bias - 1);
        // A subnormal result shifts right by te - bias + 2. Past the field
        // width it is exactly 0.
        final shiftW = (m + 2).bitLength;
        final rawShift =
            te6.getRange(0, shiftW) +
            Const((2 - f.bias) & ((1 << shiftW) - 1), width: shiftW);
        final subShift = mux(
          ~teLt(m + f.bias),
          Const(m + 1, width: shiftW),
          rawShift,
        );
        final subMant = ([Const(1), fracOf(f)].swizzle() >>> subShift).getRange(
          0,
          m,
        );
        final overflowWord = mux(
          toInf,
          infWord(f, sign),
          word(
            sign,
            Const((1 << f.exponentWidth) - 2, width: f.exponentWidth),
            Const(1, width: m, fill: true),
          ),
        );
        // Under ftz a nonzero subnormal result flushes, with UF and NX.
        final flush = config.ftz ? subOut & ~overflow & subMant.or() : Const(0);
        final subWord = mux(
          flush,
          zeroWord(f, sign),
          word(sign, Const(0, width: f.exponentWidth), subMant),
        );
        final normalWord = word(
          sign,
          Const(f.bias - 1, width: e) - te6.getRange(0, e),
          fracOf(f),
        );
        words.add(
          mux(overflow, overflowWord, mux(subOut, subWord, normalWord)),
        );
        overflows.add(overflow);
        flushes.add(flush);
      }
      final overflow = harborFpSelect(fmt6, overflows);
      final flush = harborFpSelect(fmt6, flushes);
      final recResult = mux(
        isNan,
        nanWord,
        mux(
          isZero,
          perFormat((f) => infWord(f, sign)),
          mux(
            isInf,
            perFormat((f) => zeroWord(f, sign)),
            harborFpSelect(fmt6, words),
          ),
        ),
      );
      final recFlags = mux(
        isNan | isInf,
        Const(0, width: 5),
        mux(
          isZero,
          flagWord(dz: true),
          flagWord(of: overflow, uf: ~overflow & flush),
        ),
      );
      final sel = isOp(HarborFpOp.rec7);
      resultOut = mux(sel, recResult, resultOut);
      flagsOut = mux(sel, recFlags, flagsOut);
    }

    if (ops.contains(HarborFpOp.rsqrt7)) {
      final nanOut = isNan | (sign & ~isZero);
      // The result exponent field is (2 * bias - 1 - te) / 2. It is always
      // normal, since te is at most bias + 1.
      final rsqrtResult = mux(
        nanOut,
        nanWord,
        mux(
          isZero,
          perFormat((f) => infWord(f, sign)),
          mux(
            isInf,
            perFormat((f) => zeroWord(f, Const(0))),
            perFormat((f) {
              final expField = (Const(2 * f.bias - 1, width: cw) - te6) >> 1;
              return word(
                Const(0),
                expField.getRange(0, f.exponentWidth),
                fracOf(f),
              );
            }),
          ),
        ),
      );
      final rsqrtFlags = mux(
        nanOut,
        Const(0, width: 5),
        mux(isZero, flagWord(dz: true), Const(0, width: 5)),
      );
      final sel = isOp(HarborFpOp.rsqrt7);
      resultOut = mux(sel, rsqrtResult, resultOut);
      flagsOut = mux(sel, rsqrtFlags, flagsOut);
    }

    // NV comes from stage 1.
    flagsOut = flagsOut | [st['nv'], Const(0, width: 4)].swizzle();
    st.ride.clear();
    st
      ..['result'] = resultOut
      ..['flags'] = flagsOut
      ..passRange(HarborFpCut.c6, HarborFpCut.c7);
    result <= st['result'];
    flags <= st['flags'];
    cuts = st.groups;
  }

  static String _definitionName(HarborFpuConfig config) {
    final ops = config.ops.intersection(harborFpEstimateOps);
    final parts = [
      for (final f in config.formats) f.tag,
      for (final o in HarborFpOp.values)
        if (ops.contains(o)) o.name,
      'S${config.stages}',
      if (config.ftz) 'Ftz',
    ];
    return harborStableDefinitionName('HarborFpEstimate', parts);
  }
}

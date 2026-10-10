import 'package:rohd/rohd.dart';

import 'fp_format.dart';
import 'fp_unpack.dart';
import 'fpu_config.dart';

/// True when a value with [sign] rounds away from zero in mode [rm]. [odd]
/// is the LSB that stays, [roundBit] the bit below it and [sticky] the OR of
/// all lower bits.
Logic harborFpRoundUp(
  Logic rm,
  Logic sign,
  Logic roundBit,
  Logic sticky,
  Logic odd,
) {
  final away = roundBit | sticky;
  return (rm.eq(Const(0, width: 3)) & roundBit & (sticky | odd)) |
      (rm.eq(Const(2, width: 3)) & sign & away) |
      (rm.eq(Const(3, width: 3)) & ~sign & away) |
      (rm.eq(Const(4, width: 3)) & roundBit);
}

/// Compares of a two's complement exponent with constants, and constant
/// minus exponent, with no carry chain longer than the exponent. A high
/// [dec] subtracts one from the exponent. It changes only constants.
class _ExpConst {
  final Logic? dec;
  final int bw;
  late final Logic ex;
  late final Logic _off;

  _ExpConst(Logic exponent, this.dec) : bw = exponent.width + 1 {
    ex = exponent.signExtend(bw);
    // With the top bit flipped, an unsigned compare gives the signed order.
    _off = [~ex[bw - 1], ex.getRange(0, bw - 1)].swizzle();
  }

  int get _mask => (1 << bw) - 1;

  Logic byDec(Logic Function(int d) f) =>
      dec == null ? f(0) : mux(dec!, f(1), f(0));

  Logic ge(int c) =>
      byDec((d) => _off.gte(Const(c + d + (1 << (bw - 1)), width: bw)));
  Logic lt(int c) => ~ge(c);
  Logic eq(int c) => byDec((d) => ex.eq(Const((c + d) & _mask, width: bw)));

  /// The low [width] bits of `c` minus the exponent.
  Logic minus(int c, int width) =>
      (byDec((d) => Const((c + d) & _mask, width: bw)) - ex).getRange(0, width);
}

/// The right shift that [HarborFpRound] gives a significand with unbiased
/// [exponent] in format [fmt]: the distance from the LSB of the widest
/// format to the LSB of [fmt], plus the subnormal shift. It stops at the
/// significand width, since every bit past it is sticky. A high [dec]
/// subtracts one from [exponent].
Logic harborFpAlignShift(
  HarborFpuConfig config,
  Logic fmt,
  Logic exponent, {
  Logic? dec,
}) => _alignShift(config, fmt, _ExpConst(exponent, dec));

Logic _alignShift(HarborFpuConfig config, Logic fmt, _ExpConst x) {
  final formats = config.formats;
  final maxMant = harborFpMaxMantissaWidth(config);
  final s = maxMant + 3;
  final shW = s.bitLength;
  Logic one(HarborFpFormat f) {
    final b = f.bias;
    final off = maxMant - f.mantissaWidth;
    return mux(
      x.lt(1 - b),
      mux(
        x.lt(1 - b + off - s),
        Const(s, width: shW),
        x.minus(1 - b + off, shW),
      ),
      Const(off, width: shW),
    );
  }

  return harborFpSelect(fmt, [for (final f in formats) one(f)]);
}

/// The first half of round and pack: the alignment at the LSB of the
/// selected format, the round and sticky bits, and the exponent and range
/// decisions. [HarborFpPack] reads [mid] and does the rest.
///
/// The ports are the inputs of [HarborFpRoundPack]. A path can put a
/// register on each signal of [mid] to cut round and pack in two stages.
/// No signal of [mid] comes from a carry chain longer than the exponent.
///
/// A high `exponent_dec` input subtracts one from the exponent. It changes
/// only constants, so it adds no adder. The port is there only when
/// `exponentDec` is given.
///
/// When a path knows the shift early, it can give [alignShift], which must
/// equal [harborFpAlignShift] of the exponent. The shift is then not on the
/// path from `exponent`.
class HarborFpRound extends Module {
  final HarborFpuConfig config;

  /// Width of the `exponent` input.
  final int exponentWidth;

  /// Width of the `significand` input.
  int get significandWidth => harborFpMaxMantissaWidth(config) + 3;

  /// The signals that [HarborFpPack] reads, by name.
  late final Map<String, Logic> mid;

  HarborFpRound(
    this.config, {
    required Logic fmt,
    required Logic rm,
    required Logic sign,
    required Logic exponent,
    required Logic significand,
    required Logic sticky,
    required Logic forceNan,
    required Logic forceInf,
    required Logic forceZero,
    Logic? exponentDec,
    Logic? alignShift,
    int? exponentWidth,
    super.name = 'fp_round',
  }) : exponentWidth = exponentWidth ?? harborFpMaxExponentWidth(config) + 2,
       super(
         definitionName: _definitionName(
           config,
           exponentWidth ?? harborFpMaxExponentWidth(config) + 2,
           exponentDec != null,
           alignShift != null,
         ),
       ) {
    final formats = config.formats;
    final maxExp = harborFpMaxExponentWidth(config);
    final s = significandWidth;
    final shW = s.bitLength;

    fmt = addInput('fmt', fmt, width: config.fmtWidth);
    rm = addInput('rm', rm, width: 3);
    sign = addInput('sign', sign);
    exponent = addInput('exponent', exponent, width: this.exponentWidth);
    significand = addInput('significand', significand, width: s);
    sticky = addInput('sticky', sticky);
    forceNan = addInput('force_nan', forceNan);
    forceInf = addInput('force_inf', forceInf);
    forceZero = addInput('force_zero', forceZero);
    final x = _ExpConst(
      exponent,
      exponentDec == null ? null : addInput('exponent_dec', exponentDec),
    );
    final byDec = x.byDec;
    final ge = x.ge;
    final lt = x.lt;
    final eq = x.eq;

    Logic sel(Logic Function(int i) build) => harborFpSelect(fmt, [
      for (var i = 0; i < formats.length; i++) build(i),
    ]);

    // A biased exponent of zero or less is subnormal.
    final subPath = sel((i) => lt(1 - formats[i].bias)).named('sub_path');
    final shift =
        (alignShift == null
                ? _alignShift(config, fmt, x)
                : addInput('align_shift_in', alignShift, width: shW))
            .named('align_shift');

    final shifted = (significand >>> shift).named('aligned');
    final kept = shifted.getRange(2).named('kept');
    final roundBit = shifted[1];
    final lowMask = ~(Const(1, width: s, fill: true) << shift);
    final stickyBit = (shifted[0] | (significand & lowMask).or() | sticky)
        .named('sticky');

    // The biased exponent field with no carry out of the round, and with
    // one. Only the low bits go in the word.
    final eLow = exponent.getRange(0, maxExp);
    final e0 = sel(
      (i) => mux(
        subPath,
        Const(1, width: maxExp),
        eLow + byDec((d) => Const(formats[i].bias - d, width: maxExp)),
      ),
    );
    final e1 = sel(
      (i) => eLow + byDec((d) => Const(formats[i].bias + 1 - d, width: maxExp)),
    );
    int maxField(int i) => (1 << formats[i].exponentWidth) - 1;
    final ovf0 = sel((i) => ge(maxField(i) - formats[i].bias));
    final ovf1 = sel((i) => ge(maxField(i) - 1 - formats[i].bias));

    // Tininess after rounding: round at full precision, unbounded exponent,
    // and check if the value still stays below the minimum normal.
    Logic carriesToNext(int t, int i) {
      final m = formats[i].mantissaWidth;
      final ones = significand.getRange(t - m, t + 1).and();
      final rb = significand[t - m - 1];
      final below = t - m - 1;
      final st = below > 0
          ? significand.getRange(0, below).or() | sticky
          : sticky;
      return ones & harborFpRoundUp(rm, sign, rb, st, Const(1));
    }

    final msb = significand[s - 1];
    final tiny = sel((i) {
      final b = formats[i].bias;
      return lt(-b) |
          (eq(-b) & ~carriesToNext(s - 1, i)) |
          (eq(1 - b) & ~msb & ~(significand[s - 2] & carriesToNext(s - 2, i)));
    });

    final exactZero = ~significand.or() & ~sticky;
    final rdn = rm.eq(Const(2, width: 3));
    final rup = rm.eq(Const(3, width: 3));

    mid = {};
    void put(String name, Logic v) {
      mid[name] = addOutput('mid_$name', width: v.width)..gets(v);
    }

    if (formats.length > 1) {
      put('fmt', fmt);
    }
    put('sign', sign);
    put('kept', kept);
    put('round_bit', roundBit);
    put('sticky', stickyBit);
    put('rne', rm.eq(Const(0, width: 3)));
    put('rmm', rm.eq(Const(4, width: 3)));
    put('dir_up', (rdn & sign) | (rup & ~sign));
    put('e0', e0);
    put('e1', e1);
    put('ovf0', ovf0);
    put('ovf1', ovf1);
    put('tiny', tiny);
    put('nan', forceNan);
    put('inf', forceInf);
    put('zero', forceZero | exactZero);
    if (config.ftz) {
      put('kept_nz', kept.or());
    }
  }

  static String _definitionName(
    HarborFpuConfig config,
    int exponentWidth,
    bool hasExponentDec,
    bool hasAlignShift,
  ) {
    final parts = [
      for (final f in config.formats) f.tag,
      'Ew$exponentWidth',
      if (config.ftz) 'Ftz',
      if (hasExponentDec) 'Dec',
      if (hasAlignShift) 'Algn',
    ];
    return harborStableDefinitionName('HarborFpRound', parts);
  }
}

/// The second half of round and pack: the round increment, the overflow
/// select and the packed word with its flags. [mid] is [HarborFpRound.mid],
/// directly or through registers.
class HarborFpPack extends Module {
  final HarborFpuConfig config;

  /// The packed result.
  Logic get result => output('result');

  /// `{NV, DZ, OF, UF, NX}`, NX at bit 0.
  Logic get flags => output('flags');

  HarborFpPack(this.config, Map<String, Logic> mid, {super.name = 'fp_pack'})
    : super(definitionName: _definitionName(config)) {
    final formats = config.formats;
    final maxMant = harborFpMaxMantissaWidth(config);
    final outW = config.widest.width;
    final m = {
      for (final e in mid.entries)
        e.key: addInput(e.key, e.value, width: e.value.width),
    };
    addOutput('result', width: outW);
    addOutput('flags', width: 5);

    final fmt = m['fmt'] ?? Const(0);
    Logic sel(Logic Function(int i) build) => harborFpSelect(fmt, [
      for (var i = 0; i < formats.length; i++) build(i),
    ]);

    final sign = m['sign']!;
    final kept = m['kept']!;
    final rb = m['round_bit']!;
    final st = m['sticky']!;
    final dirUp = m['dir_up']!;
    final up =
        (m['rne']! & rb & (st | kept[0])) |
        (dirUp & (rb | st)) |
        (m['rmm']! & rb);
    final inexact = rb | st;
    final rounded = (kept.zeroExtend(maxMant + 2) + up.zeroExtend(maxMant + 2))
        .named('rounded');

    final hidden = sel((i) => rounded[formats[i].mantissaWidth]);
    final carry = sel((i) => rounded[formats[i].mantissaWidth + 1]);
    final hasLead = (hidden | carry).named('has_lead');
    final overflow = (hasLead & mux(carry, m['ovf1']!, m['ovf0']!)).named(
      'overflow',
    );
    final expField = mux(
      carry,
      m['e1']!,
      mux(hidden, m['e0']!, Const(0, width: m['e0']!.width)),
    );
    final flush = config.ftz
        ? (~hasLead & (m['kept_nz']! | up)).named('flush')
        : Const(0);
    final toInf = m['rne']! | m['rmm']! | dirUp;
    final nan = m['nan']!;
    final inf = m['inf']!;
    final zero = m['zero']!;

    Logic word(List<Logic> fields) => fields.swizzle().zeroExtend(outW);

    final words = <Logic>[];
    for (final f in formats) {
      final e = f.exponentWidth;
      final mw = f.mantissaWidth;
      final nanWord = word([
        Const(0),
        Const(1, width: e, fill: true),
        Const(1 << (mw - 1), width: mw),
      ]);
      final infWord = word([
        sign,
        Const(1, width: e, fill: true),
        Const(0, width: mw),
      ]);
      final zeroWord = word([sign, Const(0, width: e + mw)]);
      final maxWord = word([
        sign,
        Const((1 << e) - 2, width: e),
        Const(1, width: mw, fill: true),
      ]);
      final normWord = word([
        sign,
        expField.getRange(0, e),
        rounded.getRange(0, mw),
      ]);
      words.add(
        mux(
          nan,
          nanWord,
          mux(
            inf,
            infWord,
            mux(
              zero | flush,
              zeroWord,
              mux(overflow, mux(toInf, infWord, maxWord), normWord),
            ),
          ),
        ),
      );
    }
    result <= harborFpSelect(fmt, words);

    final special = nan | inf | zero;
    final of = ~special & overflow;
    final uf = ~special & ~overflow & ((m['tiny']! & inexact) | flush);
    final nx = ~special & (inexact | overflow | flush);
    flags <= [Const(0, width: 2), of, uf, nx].swizzle();
  }

  static String _definitionName(HarborFpuConfig config) {
    final parts = [
      for (final f in config.formats) f.tag,
      if (config.ftz) 'Ftz',
    ];
    return harborStableDefinitionName('HarborFpPack', parts);
  }
}

/// Rounds a value to the selected format and packs it, with the IEEE 754
/// flags. It is [HarborFpRound] and [HarborFpPack] with no register between
/// them.
///
/// Let `E` be the largest exponent field and `M` the largest mantissa field of
/// all configured formats. The input value is
/// `significand * 2^(exponent - M - 2)`, plus a nonzero amount below the
/// significand LSB when [sticky] is set.
///
///   - [exponent] is unbiased and two's complement, [exponentWidth] bits
///     (`E + 2` by default). It is the weight of the significand MSB.
///   - [significand] is `M + 3` bits: the hidden bit at the top, `M` mantissa
///     bits, then a guard bit and a round bit. A narrower format uses the top
///     bits and rounds at its own LSB. All lower bits go into its sticky.
///   - [sticky] is the OR of every bit below the significand.
///
/// The significand MSB must be set, or the exponent must be at or below the
/// minimum normal exponent `1 - bias` of the selected format. An unpacked
/// subnormal satisfies this as it is. Zero significand with clear [sticky] is
/// an exact zero and gives a signed zero with no flags.
///
/// The result is right aligned in a [HarborFpuConfig.widest] wide port, with
/// zeros above. [flags] is `{NV, DZ, OF, UF, NX}`. This block never sets NV
/// or DZ. Overflow gives Inf or the largest finite value as [rm] selects, and
/// sets OF and NX. Tininess is detected after rounding, and UF needs NX too.
///
/// With [HarborFpuConfig.ftz], a nonzero subnormal result becomes a zero of
/// the same sign and sets UF and NX.
///
/// [forceNan], [forceInf] and [forceZero] override the value in that priority
/// order with no flags. The NaN is canonical, the others take [sign].
class HarborFpRoundPack extends Module {
  final HarborFpuConfig config;

  /// Width of [exponent].
  final int exponentWidth;

  /// Runtime format index into [HarborFpuConfig.formats].
  Logic get fmt => input('fmt');

  /// Rounding mode: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM.
  Logic get rm => input('rm');

  Logic get sign => input('sign');
  Logic get exponent => input('exponent');
  Logic get significand => input('significand');
  Logic get sticky => input('sticky');
  Logic get forceNan => input('force_nan');
  Logic get forceInf => input('force_inf');
  Logic get forceZero => input('force_zero');

  /// The packed result.
  Logic get result => output('result');

  /// `{NV, DZ, OF, UF, NX}`, NX at bit 0.
  Logic get flags => output('flags');

  /// Width of [significand].
  int get significandWidth => harborFpMaxMantissaWidth(config) + 3;

  HarborFpRoundPack(
    this.config, {
    required Logic fmt,
    required Logic rm,
    required Logic sign,
    required Logic exponent,
    required Logic significand,
    required Logic sticky,
    required Logic forceNan,
    required Logic forceInf,
    required Logic forceZero,
    int? exponentWidth,
    super.name = 'fp_round_pack',
  }) : exponentWidth = exponentWidth ?? harborFpMaxExponentWidth(config) + 2,
       super(
         definitionName: _definitionName(
           config,
           exponentWidth ?? harborFpMaxExponentWidth(config) + 2,
         ),
       ) {
    fmt = addInput('fmt', fmt, width: config.fmtWidth);
    rm = addInput('rm', rm, width: 3);
    sign = addInput('sign', sign);
    exponent = addInput('exponent', exponent, width: this.exponentWidth);
    significand = addInput('significand', significand, width: significandWidth);
    sticky = addInput('sticky', sticky);
    forceNan = addInput('force_nan', forceNan);
    forceInf = addInput('force_inf', forceInf);
    forceZero = addInput('force_zero', forceZero);
    addOutput('result', width: config.widest.width);
    addOutput('flags', width: 5);

    final round = HarborFpRound(
      config,
      fmt: fmt,
      rm: rm,
      sign: sign,
      exponent: exponent,
      significand: significand,
      sticky: sticky,
      forceNan: forceNan,
      forceInf: forceInf,
      forceZero: forceZero,
      exponentWidth: this.exponentWidth,
    );
    final pack = HarborFpPack(config, round.mid);
    result <= pack.result;
    flags <= pack.flags;
  }

  static String _definitionName(HarborFpuConfig config, int exponentWidth) {
    final parts = [
      for (final f in config.formats) f.tag,
      'Ew$exponentWidth',
      if (config.ftz) 'Ftz',
    ];
    return harborStableDefinitionName('HarborFpRoundPack', parts);
  }
}

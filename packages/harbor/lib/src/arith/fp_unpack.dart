import 'package:rohd/rohd.dart';

import 'fpu_config.dart';

/// Largest exponent field width in [config].
int harborFpMaxExponentWidth(HarborFpuConfig config) =>
    config.formats.map((f) => f.exponentWidth).reduce((a, b) => a > b ? a : b);

/// Largest mantissa field width in [config].
int harborFpMaxMantissaWidth(HarborFpuConfig config) =>
    config.formats.map((f) => f.mantissaWidth).reduce((a, b) => a > b ? a : b);

/// Selects `values[fmt]`. An index past the end selects the last entry.
Logic harborFpSelect(Logic fmt, List<Logic> values) {
  var out = values.last;
  for (var i = values.length - 2; i >= 0; i--) {
    out = mux(fmt.eq(Const(i, width: fmt.width)), values[i], out);
  }
  return out;
}

/// Splits an operand of the selected format into sign, exponent and
/// significand, and classifies it.
///
/// The operand is right aligned in a [HarborFpuConfig.widest] wide port. Bits
/// above the selected format are ignored.
///
/// Let `E` be the largest exponent field and `M` the largest mantissa field of
/// all configured formats. The outputs are the same for every format:
///
///   - [exponent] is the unbiased exponent, `E + 2` bits, two's complement.
///     A subnormal or zero gives `1 - bias`, so a subnormal is not normalized.
///   - [significand] is `M + 1` bits with the hidden bit explicit at the top.
///     A narrower mantissa is left aligned under the hidden bit.
///
/// A finite value is `significand * 2^(exponent - M)`. For Inf and NaN the
/// exponent is `bias + 1` and the hidden bit is 1.
///
/// With [HarborFpuConfig.ftz], a subnormal reads as a zero of the same sign.
/// [ftz] overrides [HarborFpuConfig.ftz] for this instance, for ops such as
/// classify that must see subnormals when the config flushes. An instance
/// that overrides it has its own definition name.
class HarborFpUnpack extends Module {
  final HarborFpuConfig config;

  /// Flush subnormals for this instance. Defaults to [HarborFpuConfig.ftz].
  final bool ftz;

  /// Runtime format index into [HarborFpuConfig.formats].
  Logic get fmt => input('fmt');

  /// The raw operand.
  Logic get operand => input('operand');

  Logic get sign => output('sign');

  /// Unbiased exponent, signed.
  Logic get exponent => output('exponent');

  /// Significand with the hidden bit at the top.
  Logic get significand => output('significand');

  /// Zero, including a subnormal flushed by ftz.
  Logic get isZero => output('is_zero');

  /// Subnormal. Never set with ftz.
  Logic get isSub => output('is_sub');

  Logic get isInf => output('is_inf');

  /// Any NaN, quiet or signaling.
  Logic get isNan => output('is_nan');

  /// Signaling NaN.
  Logic get isSnan => output('is_snan');

  /// Width of [exponent].
  int get exponentWidth => harborFpMaxExponentWidth(config) + 2;

  /// Width of [significand].
  int get significandWidth => harborFpMaxMantissaWidth(config) + 1;

  HarborFpUnpack(
    this.config, {
    required Logic fmt,
    required Logic operand,
    bool? ftz,
    super.name = 'fp_unpack',
  }) : ftz = ftz ?? config.ftz,
       super(definitionName: _definitionName(config, ftz ?? config.ftz)) {
    final maxMant = harborFpMaxMantissaWidth(config);
    final ew = exponentWidth;

    fmt = addInput('fmt', fmt, width: config.fmtWidth);
    operand = addInput('operand', operand, width: config.widest.width);
    addOutput('sign');
    addOutput('exponent', width: ew);
    addOutput('significand', width: significandWidth);
    addOutput('is_zero');
    addOutput('is_sub');
    addOutput('is_inf');
    addOutput('is_nan');
    addOutput('is_snan');

    final signs = <Logic>[];
    final exps = <Logic>[];
    final sigs = <Logic>[];
    final zeros = <Logic>[];
    final subs = <Logic>[];
    final infs = <Logic>[];
    final nans = <Logic>[];
    final snans = <Logic>[];

    for (final f in config.formats) {
      final m = f.mantissaWidth;
      final expField = operand.getRange(m, m + f.exponentWidth);
      final mantField = operand.getRange(0, m);
      final expZero = ~expField.or();
      final expOnes = expField.and();
      final mantZero = ~mantField.or();
      final sub = expZero & ~mantZero;
      final flush = this.ftz ? sub : Const(0);

      signs.add(operand[f.width - 1]);
      exps.add(
        mux(
          expZero,
          Const(1 - f.bias, width: ew),
          expField.zeroExtend(ew) - Const(f.bias, width: ew),
        ),
      );
      sigs.add(
        mux(
          flush,
          Const(0, width: maxMant + 1),
          [
            ~expZero,
            mantField,
            if (maxMant > m) Const(0, width: maxMant - m),
          ].swizzle(),
        ),
      );
      zeros.add((expZero & mantZero) | flush);
      subs.add(this.ftz ? Const(0) : sub);
      infs.add(expOnes & mantZero);
      nans.add(expOnes & ~mantZero);
      snans.add(expOnes & ~mantZero & ~mantField[m - 1]);
    }

    sign <= harborFpSelect(fmt, signs);
    exponent <= harborFpSelect(fmt, exps);
    significand <= harborFpSelect(fmt, sigs);
    isZero <= harborFpSelect(fmt, zeros);
    isSub <= harborFpSelect(fmt, subs);
    isInf <= harborFpSelect(fmt, infs);
    isNan <= harborFpSelect(fmt, nans);
    isSnan <= harborFpSelect(fmt, snans);
  }

  static String _definitionName(HarborFpuConfig config, bool effectiveFtz) {
    final parts = [
      for (final f in config.formats) f.tag,
      if (effectiveFtz != config.ftz) (effectiveFtz ? 'Ftz' : 'NoFtz'),
    ];
    return harborStableDefinitionName('HarborFpUnpack', parts);
  }
}

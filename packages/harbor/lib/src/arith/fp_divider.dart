import 'package:rohd/rohd.dart';

/// A multi cycle FP32 divide.
///
/// `rohd_hcl` 0.2.1 has a floating point square root but no divide, so this
/// fills that gap.
///
/// The significand divide is restoring shift and subtract, the same method as
/// [HarborScalarDivider] but not the same module. That one is 32 bits wide
/// over 32 steps. This needs a 24 bit divisor, a 26 bit partial remainder and
/// 24 steps.
///
/// With both significands in the range 2^23 up to 2^24, the quotient is 25
/// bits. One compare of the significands gives its top bit and the walk gives
/// the 24 under it, so the result needs at most one normalising shift.
///
/// A consumer handles the latency the way it handles a slow memory. The
/// thread that issued the divide waits and other threads keep issuing.
///
/// What this does not do:
///
/// Rounding is toward zero, to match a truncating FP multiply rather than the
/// IEEE round to nearest even. A subnormal input reads as zero and a
/// subnormal result flushes to zero, so there is no gradual underflow. Both
/// are deliberate and both cost area to fix.
///
/// The special cases do follow IEEE 754, because they are cheap and a wrong
/// answer there is a wrong value rather than a last bit difference:
///
///   - a NaN operand, zero over zero, or infinity over infinity gives a
///     canonical quiet NaN
///   - a non zero finite over zero gives a signed infinity
///   - infinity over a finite gives a signed infinity, and a finite over
///     infinity gives a signed zero
///   - the result sign is always the exclusive or of the operand signs
class HarborFpDivider extends Module {
  /// Accepts the operands this cycle. Only valid while [ready] is high.
  Logic get start => input('start');

  /// High when a new divide can be started.
  Logic get ready => output('ready');

  /// High while [result] holds a finished divide. It stays high until [take]
  /// is asserted, so a core can leave a result parked while its register
  /// write port is busy.
  Logic get resultValid => output('result_valid');

  /// The quotient, as an FP32 bit pattern.
  Logic get result => output('result');

  /// High while a divide is in flight.
  Logic get busy => output('busy');

  /// Cycles the mantissa walk takes, one per quotient bit.
  static const int mantissaSteps = 24;

  /// The canonical quiet NaN this unit produces.
  static const int canonicalNan = 0x7FC00000;

  HarborFpDivider({
    required Logic clk,
    required Logic reset,
    required Logic start,
    required Logic a,
    required Logic b,
    required Logic take,
    super.name = 'fp_divider',
  }) : super(definitionName: 'HarborFpDivider') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    a = addInput('a', a, width: 32);
    b = addInput('b', b, width: 32);
    take = addInput('take', take);

    addOutput('ready');
    addOutput('result_valid');
    addOutput('result', width: 32);
    addOutput('busy');

    // A zero exponent means zero or subnormal. Both read as zero here, which
    // is what it means to flush a subnormal input.
    ({Logic sign, Logic exp, Logic frac, Logic zeroish, Logic inf, Logic nan})
    parts(Logic x) {
      final exp = x.getRange(23, 31);
      final frac = x.getRange(0, 23);
      return (
        sign: x[31],
        exp: exp,
        frac: frac,
        zeroish: exp.eq(0),
        inf: exp.eq(255) & frac.eq(0),
        nan: exp.eq(255) & ~frac.eq(0),
      );
    }

    final pa = parts(a);
    final pb = parts(b);
    final signOut = pa.sign ^ pb.sign;

    final wantNan =
        pa.nan | pb.nan | (pa.zeroish & pb.zeroish) | (pa.inf & pb.inf);
    final wantInf = ~wantNan & (pa.inf | pb.zeroish);
    final wantZero = ~wantNan & ~wantInf & (pa.zeroish | pb.inf);
    final isSpecial = wantNan | wantInf | wantZero;
    final specialResult = mux(
      wantNan,
      Const(canonicalNan, width: 32),
      mux(
        wantInf,
        [signOut, Const(255, width: 8), Const(0, width: 23)].swizzle(),
        [signOut, Const(0, width: 31)].swizzle(),
      ),
    );

    // The significands, with their implicit leading one restored.
    final ma = [Const(1), pa.frac].swizzle(); // 24 bits
    final mb = [Const(1), pb.frac].swizzle();
    // expA - expB + 127, in 12-bit two's complement so the intermediate
    // cannot wrap: the true range is -128 to 382.
    final expBiased =
        (pa.exp.zeroExtend(12) + Const(127, width: 12)) - pb.exp.zeroExtend(12);

    // State.
    final stepW = (mantissaSteps + 1).bitLength;
    final rem = Logic(name: 'rem', width: 26);
    // One compare of the significands resolves the quotient's top bit before
    // the walk. It stays out of the shift register, because the walk shifts
    // left and would push it straight out. The walk builds the 24 bits under
    // it.
    final topBit = Logic(name: 'top_bit');
    final quot = Logic(name: 'quot', width: 24);
    final divisor = Logic(name: 'divisor', width: 24);
    final expReg = Logic(name: 'exp_reg', width: 12);
    final signReg = Logic(name: 'sign_reg');
    final stepIdx = Logic(name: 'step_idx', width: stepW);
    final running = Logic(name: 'running');
    final validReg = Logic(name: 'valid_reg');
    final resultReg = Logic(name: 'result_reg', width: 32);

    // One restoring step. Shift the remainder up, subtract the divisor if it
    // fits, and record the quotient bit.
    final shifted = [rem.getRange(0, 25), Const(0)].swizzle();
    final trial = shifted - divisor.zeroExtend(26);
    final fits = shifted.gte(divisor.zeroExtend(26));
    final nextRem = mux(fits, trial, shifted);
    final nextQuot = [quot.getRange(0, 23), fits].swizzle();

    // Assemble the result once the walk is done.
    // The full quotient is topBit above quot, 25 bits. With topBit set the
    // value is at least one and under two, so it needs no shift. If not, the
    // leading one is quot's top bit and one shift normalises it.
    final noShift = topBit;
    final fracOut = mux(noShift, quot.getRange(1, 24), quot.getRange(0, 23));
    final expFinal = mux(noShift, expReg, expReg - Const(1, width: 12));
    // A negative or zero exponent underflows. There are no subnormal
    // results, so it flushes to a signed zero. An exponent of 255 or more
    // overflows to a signed infinity.
    final underflow = expFinal[11] | expFinal.eq(0);
    final overflow = ~expFinal[11] & expFinal.gte(Const(255, width: 12));
    final assembled = mux(
      underflow,
      [signReg, Const(0, width: 31)].swizzle(),
      mux(
        overflow,
        [signReg, Const(255, width: 8), Const(0, width: 23)].swizzle(),
        [signReg, expFinal.getRange(0, 8), fracOut].swizzle(),
      ),
    );

    final atEnd = stepIdx.eq(mantissaSteps);

    Sequential(clk, reset: reset, [
      If(
        ~running,
        then: [
          If(
            start,
            then: [
              validReg < Const(0),
              signReg < signOut,
              If(
                isSpecial,
                then: [
                  // No walk. The answer does not need the significands.
                  resultReg < specialResult,
                  validReg < Const(1),
                ],
                orElse: [
                  // Both significands are in the range 2^23 up to 2^24, so
                  // the quotient is under 2^25. One compare decides where its
                  // leading one sits.
                  topBit < ma.gte(mb),
                  rem <
                      mux(
                        ma.gte(mb),
                        (ma - mb).zeroExtend(26),
                        ma.zeroExtend(26),
                      ),
                  quot < Const(0, width: 24),
                  divisor < mb,
                  expReg < expBiased,
                  stepIdx < Const(0, width: stepW),
                  running < Const(1),
                ],
              ),
            ],
            orElse: [
              If(take, then: [validReg < Const(0)]),
            ],
          ),
        ],
        orElse: [
          If(
            atEnd,
            then: [
              resultReg < assembled,
              validReg < Const(1),
              running < Const(0),
            ],
            orElse: [rem < nextRem, quot < nextQuot, stepIdx < stepIdx + 1],
          ),
        ],
      ),
    ]);

    ready <= ~running & ~validReg;
    resultValid <= validReg;
    result <= resultReg;
    busy <= running;
  }
}

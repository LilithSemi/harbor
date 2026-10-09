import 'package:rohd/rohd.dart';

/// Integer divide operations.
///
/// The enum index is the op select encoding. It matches the low two bits of
/// RV32M funct3, so a decoder can pass funct3[1:0] straight through.
enum HarborDivOp {
  /// Quotient, signed. RV32M DIV.
  quotientSigned,

  /// Quotient, unsigned. RV32M DIVU.
  quotientUnsigned,

  /// Remainder, signed. RV32M REM.
  remainderSigned,

  /// Remainder, unsigned. RV32M REMU.
  remainderUnsigned,
}

/// A multi cycle integer divider with the RISC-V answers for the two cases
/// that have no mathematical result.
///
/// Restoring shift and subtract. Each cycle shifts the next dividend bit into
/// a partial remainder, subtracts the divisor if it fits, and records one
/// quotient bit. A divide takes [width] cycles.
///
/// Signed operands divide by magnitude and the signs apply afterwards. That
/// gives the truncate toward zero quotient RISC-V asks for, and a remainder
/// that takes the sign of the dividend.
///
/// This does not use `rohd_hcl`'s `MultiCycleDivider`. That one is reachable
/// only through a `PairInterface` which the package never instantiates below
/// its own top level, so reading its results from inside a core inside an SoC
/// breaks the ROHD port rules.
///
/// Division does not fold into one stage at a sensible area, so a consumer
/// handles the latency the way it handles a slow memory. The thread that
/// issued the divide waits, and other threads keep issuing. One divider is
/// shared, single outstanding, so an issue gate holds back a thread whose
/// next instruction is a divide while the unit is busy.
///
/// Both special cases are applied here rather than in the consumer, so one
/// place knows them and a test can reach them directly:
///
///   - divide by zero gives an all ones quotient, which reads as minus one
///     signed, and the dividend as the remainder
///   - signed overflow, the single case of the most negative value over minus
///     one, gives the dividend as the quotient and zero as the remainder
class HarborScalarDivider extends Module {
  /// Accepts the operands this cycle. Only valid while [ready] is high.
  Logic get start => input('start');

  /// The operation, as a [HarborDivOp] index.
  Logic get op => input('op');

  /// High when a new divide can be started.
  Logic get ready => output('ready');

  /// High while [result] holds a finished divide. It stays high until [take]
  /// is asserted, so a core can leave a result parked while its register
  /// write port is busy.
  Logic get resultValid => output('result_valid');

  /// The quotient or remainder, with the special answers applied.
  Logic get result => output('result');

  /// High while a divide is in flight.
  Logic get busy => output('busy');

  final int width;

  HarborScalarDivider({
    required Logic clk,
    required Logic reset,
    required Logic start,
    required Logic dividend,
    required Logic divisor,
    required Logic op,
    required Logic take,
    this.width = 32,
    super.name = 'scalar_divider',
  }) : super(definitionName: 'HarborScalarDivider_W$width') {
    final opW = (HarborDivOp.values.length - 1).bitLength;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    dividend = addInput('dividend', dividend, width: width);
    divisor = addInput('divisor', divisor, width: width);
    op = addInput('op', op, width: opW);
    // Assert this on the cycle the result is written. The divider holds until
    // then, so a write port can give priority to something else.
    take = addInput('take', take);
    addOutput('ready');
    addOutput('result_valid');
    addOutput('result', width: width);
    addOutput('busy');

    final isSignedOp =
        op.eq(Const(HarborDivOp.quotientSigned.index, width: opW)) |
        op.eq(Const(HarborDivOp.remainderSigned.index, width: opW));

    // Magnitudes, so one unsigned engine serves both signednesses.
    final negDividend = (isSignedOp & dividend[width - 1]).named('neg_a');
    final negDivisor = (isSignedOp & divisor[width - 1]).named('neg_b');
    final absDividend = mux(negDividend, ~dividend + 1, dividend);
    final absDivisor = mux(negDivisor, ~divisor + 1, divisor);

    // State. `quot` doubles as the shifting dividend: the dividend shifts out
    // of the top as quotient bits shift in at the bottom, so one register
    // serves both and the pair {rem, quot} is the classic shift-subtract
    // accumulator.
    final counterW = (width + 1).bitLength;
    final counter = Logic(name: 'counter', width: counterW);
    final rem = Logic(name: 'rem', width: width);
    final quot = Logic(name: 'quot', width: width);
    final held = Logic(name: 'held');
    final opHeld = Logic(name: 'op_held', width: opW);
    final dividendHeld = Logic(name: 'dividend_held', width: width);
    final divisorHeld = Logic(name: 'divisor_held', width: width);
    final negQuotHeld = Logic(name: 'neg_quot_held');
    final negRemHeld = Logic(name: 'neg_rem_held');
    final negDivisorHeld = Logic(name: 'neg_divisor_held');

    final running = counter.neq(Const(0, width: counterW)).named('running');
    final lastStep = counter.eq(Const(1, width: counterW)).named('last_step');

    // One step: bring down the dividend's top bit, subtract if it fits.
    final shifted = [
      rem.getRange(0, width - 1),
      quot[width - 1],
    ].swizzle().named('shifted_rem');
    final fits = shifted.gte(divisorHeld).named('divisor_fits');
    final nextRem = mux(fits, shifted - divisorHeld, shifted);
    final nextQuot = [quot.getRange(0, width - 1), fits].swizzle();

    Sequential(clk, reset: reset, [
      If(
        start & ~running & ~held,
        then: [
          counter < Const(width, width: counterW),
          rem < Const(0, width: width),
          quot < absDividend,
          opHeld < op,
          dividendHeld < dividend,
          divisorHeld < absDivisor,
          // The quotient is negative when the signs differ; the remainder
          // always takes the dividend's sign.
          negQuotHeld < (negDividend ^ negDivisor),
          negRemHeld < negDividend,
          negDivisorHeld < negDivisor,
          held < Const(0),
        ],
        orElse: [
          If(
            running,
            then: [
              rem < nextRem,
              quot < nextQuot,
              counter < counter - Const(1, width: counterW),
              If(lastStep, then: [held < Const(1)]),
            ],
          ),
          If(held & take, then: [held < Const(0)]),
        ],
      ),
    ]);

    final heldWantsRemainder =
        opHeld.eq(Const(HarborDivOp.remainderSigned.index, width: opW)) |
        opHeld.eq(Const(HarborDivOp.remainderUnsigned.index, width: opW));

    final allOnes = Const(1, width: width, fill: true);
    final minSigned = [
      Const(1),
      Const(0, width: width - 1),
    ].swizzle().named('min_signed');

    // Apply the signs back to the magnitude results.
    final signedQuot = mux(negQuotHeld, ~quot + 1, quot);
    final signedRem = mux(negRemHeld, ~rem + 1, rem);
    final naturalResult = mux(heldWantsRemainder, signedRem, signedQuot);

    // Divide by zero gives an all ones quotient and the dividend as the
    // remainder. Signed overflow is one pair of operands only, the most
    // negative value over minus one.
    final byZero = divisorHeld.eq(Const(0, width: width)).named('div_by_zero');
    final heldSigned =
        opHeld.eq(Const(HarborDivOp.quotientSigned.index, width: opW)) |
        opHeld.eq(Const(HarborDivOp.remainderSigned.index, width: opW));
    final overflow =
        (heldSigned &
                dividendHeld.eq(minSigned) &
                divisorHeld.eq(Const(1, width: width)) &
                negDivisorHeld)
            .named('div_overflow');

    result <=
        mux(
          byZero,
          mux(heldWantsRemainder, dividendHeld, allOnes),
          mux(
            overflow,
            mux(heldWantsRemainder, Const(0, width: width), minSigned),
            naturalResult,
          ),
        );
    resultValid <= held;
    busy <= running | held;
    ready <= ~(running | held);
  }
}

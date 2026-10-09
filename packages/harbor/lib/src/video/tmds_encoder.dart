import 'package:rohd/rohd.dart';

/// DVI 1.0 TMDS channel encoder.
///
/// Encodes one 8-bit pixel channel into a 10-bit TMDS symbol. During the data
/// period ([de] high) it runs the two-stage DVI algorithm: stage one minimizes
/// transitions (XOR vs XNOR), stage two DC-balances the stream using a running
/// disparity counter. During the control period ([de] low) it emits one of the
/// four fixed control symbols selected by [ctrl] (`{c1, c0}`) and resets the
/// disparity.
///
/// The encoder is a two-register pipeline. The first register holds `q_m` and
/// its ones count, the second holds [q]. So [q] is the symbol for the inputs
/// of [latency] [clk] cycles before, and it comes straight from a register.
class TmdsEncoder extends Module {
  /// Clock cycles from an input to its symbol on [q].
  static const latency = 2;

  /// The 10-bit TMDS symbol (q[0] serialized first).
  Logic get q => output('q');

  TmdsEncoder({
    required Logic clk,
    required Logic reset,
    required Logic de,
    required Logic data,
    required Logic ctrl,
    super.name = 'tmds_encoder',
  }) : super(definitionName: 'TmdsEncoder') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    de = addInput('de', de);
    data = addInput('data', data, width: 8);
    ctrl = addInput('ctrl', ctrl, width: 2);
    addOutput('q', width: 10);

    // --- Stage 1: transition minimization ---
    final ones = _popcount(data);
    final useXnor = ones.gt(4) | (ones.eq(4) & ~data[0]);

    final qm = <Logic>[data[0]];
    for (var i = 1; i < 8; i++) {
      qm.add(mux(useXnor, ~(qm[i - 1] ^ data[i]), qm[i - 1] ^ data[i]));
    }
    final qmLowNext = [for (var i = 7; i >= 0; i--) qm[i]].swizzle();

    final deS1 = Logic(name: 'de_s1');
    final ctrlS1 = Logic(name: 'ctrl_s1', width: 2);
    final qmLow = Logic(name: 'qm_low', width: 8);
    final qm8 = Logic(name: 'qm8'); // 1 on the XOR path
    final n1 = Logic(name: 'qm_ones', width: 4);
    Sequential(clk, reset: reset, [
      deS1 < de,
      ctrlS1 < ctrl,
      qmLow < qmLowNext,
      qm8 < ~useXnor,
      n1 < _popcount(qmLowNext),
    ]);

    // --- Stage 2: DC balancing ---
    final cnt = Logic(name: 'disparity', width: 8);
    final n0 = Const(8, width: 4) - n1;
    final n1e = n1.zeroExtend(8);
    final n0e = n0.zeroExtend(8);
    final qm8e = qm8.zeroExtend(8);
    final notQm8e = (~qm8).zeroExtend(8);

    final isZero = cnt.eq(0);
    final isNeg = cnt[7];
    final isPos = ~isNeg & ~isZero;

    final balanced = isZero | n1.eq(n0);
    final invert = (isPos & n1.gt(n0)) | (isNeg & n0.gt(n1));

    final dataLow = mux(
      balanced,
      mux(qm8, qmLow, ~qmLow),
      mux(invert, ~qmLow, qmLow),
    );
    final dataQ9 = mux(balanced, ~qm8, invert);
    final dataSymbol = [dataQ9, qm8, dataLow].swizzle();

    // Disparity updates (two's complement, modular add is fine here).
    final balCnt = mux(qm8, cnt + (n1e - n0e), cnt + (n0e - n1e));
    final invCnt = cnt + (qm8e << 1) + (n0e - n1e);
    final nonInvCnt = cnt - (notQm8e << 1) + (n1e - n0e);
    final dataCnt = mux(balanced, balCnt, mux(invert, invCnt, nonInvCnt));

    // Control symbols, selected by {c1, c0}.
    final ctrlSymbol = mux(
      ctrlS1.eq(0),
      Const(0x354, width: 10),
      mux(
        ctrlS1.eq(1),
        Const(0x0AB, width: 10),
        mux(ctrlS1.eq(2), Const(0x154, width: 10), Const(0x2AB, width: 10)),
      ),
    );

    final qReg = Logic(name: 'q_reg', width: 10);
    Sequential(clk, reset: reset, [
      cnt < mux(deS1, dataCnt, Const(0, width: 8)),
      qReg < mux(deS1, dataSymbol, ctrlSymbol),
    ]);
    q <= qReg;
  }

  /// Counts the set bits of [v] as a 4-bit value (v is at most 8 bits wide).
  static Logic _popcount(Logic v) {
    Logic sum = Const(0, width: 4);
    for (var i = 0; i < v.width; i++) {
      sum = sum + v[i].zeroExtend(4);
    }
    return sum;
  }
}

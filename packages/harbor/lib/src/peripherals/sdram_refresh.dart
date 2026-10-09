/// Sdr sdram refresh credit counter.
library;

import 'package:rohd/rohd.dart';

/// Tracks how many scheduled refreshes the controller owes sdram, so the
/// scheduler can postpone a refresh behind live traffic or pull one in
/// early. `owed` moves by +1 every [refi] cycles while [enable] is high,
/// and by -1 for every pulse on [issued]. It saturates at
/// `[-maxPulledIn, maxPostponed]`. as4c16m16sb datasheet rev 2.0, features
/// p2, command 12 p17.
class SdramRefreshCredit extends Module {
  /// Scheduled refresh interval, in controller cycles.
  final int refi;

  /// Refreshes the scheduler may postpone (owed's positive bound, `k`).
  final int maxPostponed;

  /// Refreshes the scheduler may pull in ahead of schedule (owed's
  /// negative bound, `p`).
  final int maxPulledIn;

  /// Signed refresh credit, in `[-maxPulledIn, maxPostponed]`.
  Logic get owed => output('owed');

  /// High while a refresh is owed (`owed > 0`).
  Logic get need => output('need');

  /// High while a refresh may be pulled in early (`owed > -maxPulledIn`).
  Logic get mayPullIn => output('may_pull_in');

  /// High once owed has reached the postponement limit.
  Logic get force => output('force_refresh');

  /// Two's complement width that holds every value in
  /// `[-maxPulledIn, maxPostponed]`.
  int get owedWidth => _signedWidth(-maxPulledIn, maxPostponed);

  SdramRefreshCredit({
    required this.refi,
    required this.maxPostponed,
    required this.maxPulledIn,
    required Logic clk,
    required Logic reset,
    required Logic enable,
    required Logic issued,
    super.name = 'sdram_refresh',
  }) {
    if (refi < 1) {
      throw ArgumentError('refi must be >= 1');
    }
    if (maxPostponed < 1) {
      throw ArgumentError('maxPostponed must be >= 1');
    }
    if (maxPulledIn < 0) {
      throw ArgumentError('maxPulledIn must be >= 0');
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    enable = addInput('enable', enable);
    issued = addInput('issued', issued);

    addOutput('owed', width: owedWidth);
    addOutput('need');
    addOutput('may_pull_in');
    addOutput('force_refresh');

    // owedOffset holds owed + maxPulledIn, so it stays unsigned in
    // [0, maxPostponed + maxPulledIn] and every comparison below is a
    // plain unsigned one.
    final span = maxPostponed + maxPulledIn;
    final spanWidth = span.bitLength;
    final tickWidth = refi.bitLength;

    final owedOffset = Logic(name: 'owed_offset', width: spanWidth);
    final tickCounter = Logic(name: 'tick_counter', width: tickWidth);
    final tick = tickCounter.eq(Const(refi - 1, width: tickWidth));

    output('owed') <=
        (owedOffset.zeroExtend(owedWidth) -
            Const(maxPulledIn, width: owedWidth));
    output('need') <= owedOffset.gt(maxPulledIn);
    output('may_pull_in') <= owedOffset.gt(0);
    output('force_refresh') <= owedOffset.gte(span);

    final tick1 = tick & enable;
    // A tick only moves owedOffset up if it is not already at the ceiling,
    // and an issue only moves it down if it is not already at the floor.
    // On a cycle where both land, whichever side is still unsaturated
    // wins. If both are unsaturated they cancel, and owedOffset holds.
    final tickReal = tick1 & owedOffset.lt(span);
    final issueReal = issued & owedOffset.gt(0);
    Sequential(clk, [
      If(
        reset,
        then: [
          owedOffset < Const(maxPulledIn, width: spanWidth),
          tickCounter < Const(0, width: tickWidth),
        ],
        orElse: [
          tickCounter < mux(tick, Const(0, width: tickWidth), tickCounter + 1),
          If(
            tickReal & issueReal,
            then: [],
            orElse: [
              If(tickReal, then: [owedOffset < owedOffset + 1]),
              If(issueReal, then: [owedOffset < owedOffset - 1]),
            ],
          ),
        ],
      ),
    ]);
  }

  static int _signedWidth(int min, int max) {
    var w = 2;
    while (!(-(1 << (w - 1)) <= min && (1 << (w - 1)) - 1 >= max)) {
      w++;
    }
    return w;
  }
}

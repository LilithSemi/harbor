import 'package:rohd/rohd.dart';

/// A clock that rises at [firstRise] and toggles every [halfPeriod], driven
/// by scheduled actions.
///
/// A divider built from a `Sequential` makes each flop on the divided clock
/// sample the outputs of the fast clock flops after their update, because
/// ROHD 0.7 runs it later in the same tick. A scheduled clock edge samples
/// the values from before the edge, as hardware does.
///
/// Throws when [halfPeriod] is not positive or [firstRise] is before the
/// current simulator time.
Logic scheduledClock({required int firstRise, required int halfPeriod}) {
  if (halfPeriod <= 0) {
    throw ArgumentError.value(halfPeriod, 'halfPeriod', 'must be positive');
  }
  if (firstRise < Simulator.time) {
    throw ArgumentError.value(firstRise, 'firstRise', 'is in the past');
  }
  final clk = Logic(name: 'scheduled_clk')..put(0);
  void toggle(int time, int value) {
    Simulator.registerAction(time, () {
      clk.put(value);
      toggle(time + halfPeriod, 1 - value);
    });
  }

  toggle(firstRise, 1);
  return clk;
}

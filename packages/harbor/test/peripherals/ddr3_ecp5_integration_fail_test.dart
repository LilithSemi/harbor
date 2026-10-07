import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'ddr3_ecp5_integration_stack.dart';

/// No window exists (skew beyond anything bitslip + READCLKSEL can
/// compensate for), so calibration gives up with CAL_FAILED and cal_failed
/// high, and never hangs. One calibration run is enough to show it (each run
/// is a full 128-point sweep, several minutes of simulation).
void main() {
  tearDown(() async => Simulator.reset());

  test('no window: calibration gives up with CAL_FAILED and cal_failed high, '
      'and never hangs', () async {
    // Skew beyond anything bitslip (max 15 edges) + READCLKSEL (max 7
    // groups) can compensate for: no (bitslip, READCLKSEL) setting passes.
    final s = Ddr3Ecp5IntegrationStack(
      ddr3Ecp5TestParams(),
      readSkewBeats: 40,
      maxCalAttempts: 1,
    );
    await s.build();
    await s.run();
    final end = await s.waitDone(maxTicks: 45000);
    expect(end, 26, reason: 'did not reach CAL_FAILED');
    expect(s.ctrl.calFailed!.value.toInt(), 1);

    await Simulator.endSimulation();
  });
}

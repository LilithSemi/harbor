import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'ddr3_ecp5_integration_stack.dart';

// The leveler follows a round-trip skew. Separate file: the
// leveler's 128-point sweep makes this slow.

void main() {
  tearDown(() async => Simulator.reset());

  test('one beat of read skew moves the pick to the next bitslip and two '
      'READCLKSEL steps later', () async {
    // One half-CK beat of round trip delays the DQS preamble by two quarter-T
    // READCLKSEL steps, and the data by one beat of bitslip.
    final s = Ddr3Ecp5IntegrationStack(ddr3Ecp5TestParams(), readSkewBeats: 1);
    await s.build();
    await s.run();
    final end = await s.waitDone();
    expect(end, 23, reason: 'never reached DONE_CALIBRATE');
    expect(s.dram.errors, isEmpty);
    for (var l = 0; l < 2; l++) {
      final slip = s.slipOf(l);
      expect(slip, isNot(ddr3Ecp5BaseSlip));
      expect((slip - ddr3Ecp5BaseSlip).abs(), 1);
      expect(s.readClkSelOf(l), ddr3Ecp5BaseReadClkSel + 2);
      // The neighbouring bitslips fail at every READCLKSEL.
      expect(s.passRow(l, slip - 1), 0);
      expect(s.passRow(l, slip + 1), 0);
    }

    await Simulator.endSimulation();
  });
}

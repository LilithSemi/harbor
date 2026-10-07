import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'ddr3_ecp5_integration_stack.dart';

/// Full-stack ECP5 simulation reaches DONE_CALIBRATE through the
/// real PHY datapath, against a DRAM model that sees only the DDR3 pins.
void main() {
  tearDown(() async => Simulator.reset());

  test(
    'Ddr3Controller + Ddr3PhyEcp5 + Ddr3Ecp5PadDramModel reach DONE_CALIBRATE '
    'through the real pad-level PHY datapath',
    () async {
      final s = Ddr3Ecp5IntegrationStack(ddr3Ecp5TestParams());
      await s.build();
      await s.run();
      final end = await s.waitDone();
      expect(end, 23, reason: 'never reached DONE_CALIBRATE');
      expect(s.dram.errors, isEmpty);
      expect(s.dram.writes, 2);
      for (var l = 0; l < 2; l++) {
        expect(s.slipOf(l), ddr3Ecp5BaseSlip);
        expect(s.readClkSelOf(l), ddr3Ecp5BaseReadClkSel);
        // Several READCLKSEL values pass at the right bitslip, so the centre
        // rule picks the middle one.
        expect(s.passRow(l, ddr3Ecp5BaseSlip), 0x0E);
        // Every other bitslip fails the controller's read check.
        for (var slip = 0; slip < 16; slip++) {
          if (slip != ddr3Ecp5BaseSlip) {
            expect(s.passRow(l, slip), 0, reason: 'lane $l slip $slip');
          }
        }
      }

      await Simulator.endSimulation();
    },
  );
}

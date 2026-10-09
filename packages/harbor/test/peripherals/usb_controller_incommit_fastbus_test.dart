import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('IN_COMMIT with a bus clock faster than usb_clk sends whole packets '
      'for every size and phase', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness(
      busPeriod: 3,
      usbPeriod: 10,
      maxSimTime: 40000000,
    );
    await inCommitSweep(dut, host, clk);
    await Simulator.endSimulation();
  });
}

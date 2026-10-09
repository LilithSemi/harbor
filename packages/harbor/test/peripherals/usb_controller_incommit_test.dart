import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('IN_COMMIT at the normal clock ratio sends whole packets for every '
      'size and phase', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness(
      maxSimTime: 40000000,
    );
    await inCommitSweep(dut, host, clk);
    await Simulator.endSimulation();
  });
}

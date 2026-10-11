import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_harness.dart';

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('125 MHz: a fabric reset during a line fetch keeps every display '
      'line and the fabric works after it', () async {
    await runFabricResetDuringScanout(memPeriodPs: 8000);
  }, timeout: const Timeout(Duration(minutes: 90)));
}

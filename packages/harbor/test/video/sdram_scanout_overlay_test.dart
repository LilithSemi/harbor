@Tags(['slow'])
library;

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_overlay_harness.dart';

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test(
    '125 MHz: half line 1080p60 nv12 with a 320 pixel xrgb8888 overlay on the sdram '
    'scanout port',
    () => scanOverlay(320, 320),
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

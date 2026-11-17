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
    '125 MHz: 1080p60 nv12, 1920 pixel lines, with a full width xrgb8888 '
    'overlay on the sdram '
    'scanout port',
    () => scanOverlay(1920, 0, hActive: 1920),
    timeout: const Timeout(Duration(minutes: 90)),
  );
}

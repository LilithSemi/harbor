@Tags(['slow'])
library;

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_planes_harness.dart';

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test(
    '125 MHz: half line 1080p60 (960 pixel) nv12 lines from the sdram scanout port meet every line',
    () => scanNv12(960, 6734),
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

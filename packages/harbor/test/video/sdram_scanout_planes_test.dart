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
    '125 MHz: 720p60 nv12 lines from the sdram scanout port meet every line',
    () => scanNv12(1280, 13468),
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'ddr3_memory_port_bench.dart';

// Separate file per kind: calibration makes each run slow, so the kinds run
// in parallel.
void main() {
  tearDown(Simulator.reset);

  test(
    'wishbone: random bursts through the crossing match a reference memory',
    () async {
      await ddr3RandomBursts(
        HarborFabricKind.wishbone,
        fabricPeriod: 14,
        seed: 3,
      );
    },
    timeout: const Timeout(Duration(hours: 6)),
  );
}

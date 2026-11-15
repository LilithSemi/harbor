import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'ddr3_memory_port_bench.dart';

// The 256 beat bursts of the wishbone kind: a slow fabric clock needs them in
// their own file to finish in time.
void main() {
  tearDown(Simulator.reset);

  test(
    'wishbone: 256 beat bursts through the crossing match a reference memory',
    () async {
      await ddr3RandomBursts(
        HarborFabricKind.wishbone,
        fabricPeriod: 14,
        seed: 3,
        count: 12,
        longPart: 1,
        span: 0x800,
      );
    },
    timeout: const Timeout(Duration(hours: 6)),
  );
}

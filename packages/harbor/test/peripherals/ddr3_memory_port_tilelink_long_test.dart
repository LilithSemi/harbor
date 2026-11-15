import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'ddr3_memory_port_bench.dart';

// The 256 beat bursts of the tilelink kind: a slow fabric clock needs them in
// their own file to finish in time.
void main() {
  tearDown(Simulator.reset);

  test(
    'tilelink: 256 beat bursts through the crossing match a reference memory',
    () async {
      await ddr3RandomBursts(
        HarborFabricKind.tilelink,
        fabricPeriod: 18,
        seed: 2,
        count: 6,
        longPart: 1,
        span: 0x800,
      );
    },
    timeout: const Timeout(Duration(hours: 6)),
  );
}

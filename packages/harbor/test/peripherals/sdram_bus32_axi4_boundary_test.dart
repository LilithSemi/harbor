import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_bus_width_bench.dart';

// One file per group, so the groups run in parallel.
void main() {
  tearDown(Simulator.reset);

  for (final map in HarborSdramAddressMap.values) {
    test(
      'axi4 32-bit: bursts across a bank and a row boundary, ${map.name}',
      () async {
        expect(
          await sdramBoundaryBursts(HarborFabricKind.axi4, 32, addressMap: map),
          isEmpty,
        );
      },
      timeout: const Timeout(Duration(minutes: 30)),
    );
  }
}

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_bus_width_bench.dart';

// One file per group, so the groups run in parallel.
void main() {
  tearDown(Simulator.reset);

  test(
    'wishbone 64-bit: bursts across a row boundary, bankRowCol',
    () async {
      expect(
        await sdramBoundaryBursts(
          HarborFabricKind.wishbone,
          64,
          addressMap: HarborSdramAddressMap.bankRowCol,
        ),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

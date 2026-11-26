import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'sdram_bus_width_bench.dart';

// One file per group, so the groups run in parallel.
void main() {
  tearDown(Simulator.reset);

  test(
    'tilelink 64-bit: every strobe pattern reads back merged',
    () async {
      expect(await sdramStrobePatterns(HarborFabricKind.tilelink, 64), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );

  test(
    'tilelink 64-bit: bursts across a bank and a row boundary',
    () async {
      expect(
        await sdramBoundaryBursts(
          HarborFabricKind.tilelink,
          64,
          addressMap: HarborSdramAddressMap.bankRowCol,
        ),
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

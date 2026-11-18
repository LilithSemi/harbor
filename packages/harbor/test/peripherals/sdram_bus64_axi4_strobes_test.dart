import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_bus_width_bench.dart';

// One file per group, so the groups run in parallel.
void main() {
  tearDown(Simulator.reset);

  for (final width in [32, 64]) {
    test(
      'axi4 $width-bit: every strobe pattern reads back merged',
      () async {
        expect(
          await sdramStrobePatterns(HarborFabricKind.axi4, width),
          isEmpty,
        );
      },
      timeout: const Timeout(Duration(minutes: 30)),
    );
  }
}

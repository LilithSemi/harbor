import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_bus_width_bench.dart';

// One file per kind, so the kinds run in parallel.
void main() {
  tearDown(Simulator.reset);

  test('tilelink 64-bit, bus clock is mem_clk: every strobe pattern reads back '
      'merged', () async {
    expect(
      await sdramStrobePatterns(HarborFabricKind.tilelink, 64, sync: true),
      isEmpty,
    );
  }, timeout: const Timeout(Duration(minutes: 30)));
}

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_bus_width_bench.dart';
import 'sdram_memory_port_bench.dart';

// One file per kind, so the kinds run in parallel.
void main() {
  tearDown(Simulator.reset);

  for (final width in [32, 64]) {
    test('wishbone $width-bit, bus clock is mem_clk: random bursts match a '
        'reference memory', () async {
      final bad = await sdramRandomBursts(
        HarborFabricKind.wishbone,
        fabricPeriodPs: 8000,
        seed: 21 + width,
        outstanding: 1,
        dataWidth: width,
        sync: true,
        pastTheEnd: false,
      );
      expect(bad, isEmpty);
    }, timeout: const Timeout(Duration(hours: 2)));
  }

  test('wishbone 64-bit, bus clock is mem_clk: every strobe pattern reads back '
      'merged', () async {
    expect(
      await sdramStrobePatterns(HarborFabricKind.wishbone, 64, sync: true),
      isEmpty,
    );
  }, timeout: const Timeout(Duration(minutes: 30)));
}

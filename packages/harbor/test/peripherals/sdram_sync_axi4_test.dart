import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_bus_width_bench.dart';
import 'sdram_memory_port_bench.dart';

// One file per kind, so the kinds run in parallel.
void main() {
  tearDown(Simulator.reset);

  for (final width in [32, 64]) {
    test('axi4 $width-bit, bus clock is mem_clk: random bursts match a '
        'reference memory', () async {
      final bad = await sdramRandomBursts(
        HarborFabricKind.axi4,
        fabricPeriodPs: 8000,
        seed: 21 + width,
        outstanding: 8,
        dataWidth: width,
        sync: true,
        pastTheEnd: true,
      );
      expect(bad, isEmpty);
    }, timeout: const Timeout(Duration(hours: 2)));
  }

  test('axi4 64-bit, bus clock is mem_clk: every strobe pattern reads back '
      'merged', () async {
    expect(
      await sdramStrobePatterns(HarborFabricKind.axi4, 64, sync: true),
      isEmpty,
    );
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('axi4 64-bit, bus clock is mem_clk at 25 MHz: random bursts match a '
      'reference memory', () async {
    final bad = await sdramRandomBursts(
      HarborFabricKind.axi4,
      fabricPeriodPs: 40000,
      seed: 25,
      outstanding: 8,
      dataWidth: 64,
      sync: true,
    );
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(hours: 2)));
}

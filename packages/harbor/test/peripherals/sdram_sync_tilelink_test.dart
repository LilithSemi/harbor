import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_memory_port_bench.dart';

// One file per kind, so the kinds run in parallel.
void main() {
  tearDown(Simulator.reset);

  for (final width in [64]) {
    test('tilelink $width-bit, bus clock is mem_clk: random bursts match a '
        'reference memory', () async {
      final bad = await sdramRandomBursts(
        HarborFabricKind.tilelink,
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
}

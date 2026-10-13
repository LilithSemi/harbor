import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_memory_port_bench.dart';

// One file per kind, so the kinds run in parallel.
void main() {
  tearDown(Simulator.reset);

  test('tilelink: random bursts and IDs through the crossing match a reference '
      'memory', () async {
    final bad = await sdramRandomBursts(
      HarborFabricKind.tilelink,
      fabricPeriodPs: 6000,
      seed: 2,
      outstanding: 8,
    );
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(hours: 2)));
}

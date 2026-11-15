import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_memory_port_bench.dart';

// One file per group, so the groups run in parallel.
void main() {
  tearDown(Simulator.reset);

  test('tilelink 64-bit: random bursts and IDs through the crossing match a '
      'reference memory', () async {
    final bad = await sdramRandomBursts(
      HarborFabricKind.tilelink,
      fabricPeriodPs: 6000,
      seed: 12,
      outstanding: 8,
      dataWidth: 64,
    );
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(hours: 2)));
}

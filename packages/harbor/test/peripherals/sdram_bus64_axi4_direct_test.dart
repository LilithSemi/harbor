import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_memory_port_bench.dart';

// One file per group, so the groups run in parallel.
void main() {
  tearDown(Simulator.reset);

  test('axi4 64-bit, one request in flight: random bursts match a reference '
      'memory', () async {
    final bad = await sdramRandomBursts(
      HarborFabricKind.axi4,
      fabricPeriodPs: 20000,
      seed: 14,
      outstanding: 1,
      count: 24,
      dataWidth: 64,
    );
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(hours: 2)));
}

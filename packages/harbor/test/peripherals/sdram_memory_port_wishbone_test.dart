import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_memory_port_bench.dart';

// One file per kind, so the kinds run in parallel.
void main() {
  tearDown(Simulator.reset);

  test('wishbone: random bursts through the classic port match a reference '
      'memory', () async {
    final bad = await sdramRandomBursts(
      HarborFabricKind.wishbone,
      fabricPeriodPs: 14000,
      seed: 3,
      outstanding: 1,
      // The classic Wishbone port wraps an address past the sdram size.
      pastTheEnd: false,
    );
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(hours: 2)));
}

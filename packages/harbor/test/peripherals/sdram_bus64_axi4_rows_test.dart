import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart' show Burst;
import 'sdram_bus_width_bench.dart';
import 'sdram_memory_port_bench.dart';

// One file per group, so the groups run in parallel.
void main() {
  tearDown(Simulator.reset);

  for (final width in [32, 64]) {
    test('axi4 $width-bit: a burst in one open row takes no extra row '
        'cycles', () async {
      expect(await sdramRowCycles(HarborFabricKind.axi4, width), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 30)));
  }

  test('axi4 64-bit: a FIXED or narrow burst takes one sdram request per '
      'beat, a full size burst one per 2-beat block', () async {
    Burst b(int addr, int burst, int size, {bool write = false}) => Burst(
      id: 0,
      write: write,
      addr: addr,
      len: 15,
      size: size,
      burst: burst,
      data: write ? List.filled(16, 0x5a5a5a5a5a5a5a5a) : const [],
      strb: write ? List.filled(16, 255) : const [],
    );
    final got = await sdramRequestCounts([
      b(0x100, 0, 3),
      b(0x100, 0, 3, write: true),
      b(0x200, 1, 2),
      b(0x300, 1, 3),
      b(0x308, 1, 3),
      b(0x508, 2, 3),
    ], dataWidth: 64);
    final counts = [for (final (_, n, _) in got) n];
    expect(counts, [16, 16, 16, 8, 9, 9]);
    for (final (burst, n, bound) in got) {
      expect(n, lessThanOrEqualTo(bound), reason: '$burst');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}

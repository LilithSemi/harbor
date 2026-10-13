import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart' show Burst;
import 'sdram_memory_port_bench.dart';

// One file per kind, so the kinds run in parallel.
void main() {
  tearDown(Simulator.reset);

  test('axi4: random bursts and IDs through the crossing match a reference '
      'memory', () async {
    final bad = await sdramRandomBursts(
      HarborFabricKind.axi4,
      fabricPeriodPs: 20000,
      seed: 1,
      outstanding: 8,
    );
    expect(bad, isEmpty);
  }, timeout: const Timeout(Duration(hours: 2)));

  test(
    'axi4: a write acked before a fabric reset reads back after it',
    () async {
      expect(await sdramAckedWriteSurvivesReset(), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );

  test('axi4: a FIXED or narrow burst takes one sdram request per beat, a full '
      'size burst one per 4-beat block', () async {
    Burst b(int addr, int burst, int size, {bool write = false}) => Burst(
      id: 0,
      write: write,
      addr: addr,
      len: 15,
      size: size,
      burst: burst,
      data: write ? List.filled(16, 0x5a5a5a5a) : const [],
      strb: write ? List.filled(16, 15) : const [],
    );
    final got = await sdramRequestCounts([
      b(0x100, 0, 2),
      b(0x100, 0, 2, write: true),
      b(0x200, 1, 1),
      b(0x300, 1, 2),
      b(0x404, 1, 2),
      b(0x504, 2, 2),
    ]);
    final counts = [for (final (_, n, _) in got) n];
    expect(counts, [16, 16, 16, 4, 5, 5]);
    for (final (burst, n, bound) in got) {
      expect(n, lessThanOrEqualTo(bound), reason: '$burst');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));

  for (final n in [1, 8]) {
    test(
      'axi4 $n in flight: WRESP only after the arbiter takes the last request '
      'of its write',
      () async {
        expect(await sdramWrespAfterTake(n), isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 30)),
    );
  }
}

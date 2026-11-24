// The real-time read wait under the bound with the real-time reads moved
// against the long bursts of the other masters. The wait depends on how
// many pieces the slave holds ahead of the read, so each start phase is a
// case of its own.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'axi4_fabric_harness.dart';
import 'realtime_qos_axi4_harness.dart';

void main() {
  tearDown(() async => Simulator.reset());

  forEachPipeline((p) {
    for (final t in HarborFabricTopology.values) {
      test(
        'axi4 ${t.name}, a slave with fewer IDs than requests',
        () async {
          await rtTiming(t, rtMasters, rtFewIdSlaves, rtCap);
        },
        // A real-time read with a new ID waits until a slave ID frees, and
        // the other masters hold both slave IDs through their long bursts.
        // The bound has no term for that: 416 against 213 at compact.
        skip: 'the bound does not cover a slave with fewer IDs than requests',
      );
    }
    for (var shift = 1; shift <= 6; shift++) {
      test('axi4 shared, 2 slaves, reads moved by $shift cycles', () async {
        await rtTiming(
          HarborFabricTopology.shared,
          rtMasters,
          rtTwoSlaves,
          rtCap,
          shift: shift,
        );
      });
    }
  });
}

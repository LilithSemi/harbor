import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// A 2 us tRAS max in both the engine and the model, with back-to-back
/// traffic, so the row-age force has to close rows between refreshes.
void main() {
  tearDown(() async => Simulator.reset());

  test('125 MHz: row-age force closes rows before tRAS max', () async {
    final s = await sdramRandomRun(
      125000000,
      seed: 145,
      requests: 150,
      gaps: false,
      tRasMaxNs: 2000,
    );
    // The model checks the 2 us tRAS max on every row.
    expect(s.errors, isEmpty);
    expect(s.rowAgeEdges, greaterThanOrEqualTo(3));
  });
}

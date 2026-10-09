import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';
import 'sdram_row_age_test.dart' show sdramPullInToFloor, sdramRowHitTraffic;

/// The negative half of sdram_row_age_test.dart: without the row-age
/// guard, a row held open by row hits overruns tRAS max.
void main() {
  tearDown(() async => Simulator.reset());

  test('125 MHz: with the row age guard off, continuous row-hit traffic '
      'overruns tRAS max', () async {
    final s = SdramEngineStack(
      clockHz: 125000000,
      maxGrantWords: 16,
      rowAgeGuard: false,
    );
    await s.start();
    await sdramPullInToFloor(s);
    // Past tRAS max (15000 cycles) and before the forced refresh that a
    // pulled-in credit allows (about 16 periods).
    await sdramRowHitTraffic(s, 15500);
    await s.stop();

    expect(s.errors.any((e) => e.contains('tRAS-max')), isTrue);
  });
}

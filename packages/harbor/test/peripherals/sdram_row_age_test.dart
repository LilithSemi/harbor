import 'package:harbor/src/peripherals/sdram_bank_timers.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// Design fix 1 from the review: a global row-age guard, not the refresh
/// credit, is what keeps a row under tRAS max when pulled-in credit would
/// otherwise let the next refresh land too late. Both the positive check
/// (the guard closes the row in time) and the negative one (turning the
/// guard off lets tRAS max fail) use the real part's tRAS max, not a
/// shortened one, so the timing matches [HarborSdramCycles.rowAgeLimit].
int sdramOwed(SdramEngineStack s) {
  final o = s.top.engine.refreshOwed;
  return o.value.toInt().toSigned(o.width);
}

Future<void> sdramPullInToFloor(SdramEngineStack s) async {
  final p = s.cycles.maxPulledIn;
  var waited = 0;
  while (sdramOwed(s) > -p && waited < 20000) {
    await s.clk.nextPosedge;
    waited++;
  }
  expect(sdramOwed(s), equals(-p), reason: 'pull-in did not settle at -p');
}

Future<void> sdramRowHitTraffic(SdramEngineStack s, int cycles) async {
  const addr = 0; // bank 0, row 0, col 0: one row, held open throughout.
  final c0 = s.cycle;
  // Keep a backlog of row hits so the bank never goes idle, without
  // queueing more than the engine can work through by the end.
  while (s.cycle - c0 < cycles) {
    while (s.pending < 60) {
      s.read(addr, 1);
    }
    await s.idle(10);
  }
  await s.drain();
  await s.idle(20);
}

void main() {
  tearDown(() async => Simulator.reset());

  test('125 MHz: row age force closes a row before tRAS max', () async {
    final s = SdramEngineStack(clockHz: 125000000, maxGrantWords: 16);
    await s.start();
    await sdramPullInToFloor(s);

    // The engine's own row_age_force edge is the guard acting, whether
    // or not a refresh also happens to land around the same time.
    var firstRowAgeCycle = -1;
    final timers = s.top.engine.subModules.whereType<SdramBankTimers>().single;
    var lastAge = false;
    s.clk.posedge.listen((_) {
      final a = timers.rowAgeForce.value == LogicValue.one;
      if (a && !lastAge && firstRowAgeCycle < 0) {
        firstRowAgeCycle = s.cycle;
      }
      lastAge = a;
    });

    final c0 = s.cycle;
    await sdramRowHitTraffic(s, 14500);
    await s.stop();

    expect(s.errors, isEmpty);
    expect(s.rowAgeEdges, greaterThanOrEqualTo(1));
    expect(firstRowAgeCycle, greaterThan(0));
    expect(
      firstRowAgeCycle - c0,
      lessThan(s.cycles.rowAgeLimit + 50),
      reason: 'row age force came later than the configured limit',
    );
  });
}

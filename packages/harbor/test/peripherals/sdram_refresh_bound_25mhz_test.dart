import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';
import 'sdram_refresh_bound_test.dart'
    show sdramRefreshOwed, sdramSaturateRefresh;

void main() {
  tearDown(() async => Simulator.reset());

  // At 25 MHz a refresh is shorter than the credit feedback, so the engine
  // must not issue a second refresh before the first one is counted.
  test('25 MHz: idle pull-in settles at -p, then one refresh a refi', () async {
    final s = SdramEngineStack(clockHz: 25000000);
    await s.start();
    var minOwed = 0;
    s.clk.posedge.listen((_) {
      final o = sdramRefreshOwed(s);
      if (o < minOwed) minOwed = o;
    });

    final refi = s.cycles.refi;
    await s.idle(20 * refi);
    expect(minOwed, equals(-s.cycles.maxPulledIn));

    final before = s.model.refreshTimesPs.length;
    await s.idle(15 * refi);
    final after = s.model.refreshTimesPs.length;
    await s.stop();

    expect(after - before, inInclusiveRange(12, 18));
    expect(s.errors, isEmpty);
  });

  test(
    '25 MHz: saturating traffic keeps refresh_owed <= k and the window',
    () async {
      await sdramSaturateRefresh(25000000, 8000, seed: 25);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

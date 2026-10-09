// Drives SdramRefreshCredit with random enable/issue patterns and checks
// owed never leaves [-maxPulledIn, maxPostponed], force only asserts at
// the top of that range, and every issued refresh lands inside the
// window t0 + (n-p)*refi <= t_n implied by the refresh budget.

import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/sdram_refresh.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

Future<void> _runRandom({
  required int refi,
  required int maxPostponed,
  required int maxPulledIn,
  required int cycles,
  required int seed,
}) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset')..inject(1);
  final enable = Logic(name: 'enable')..inject(0);
  final issued = Logic(name: 'issued')..inject(0);
  final dut = SdramRefreshCredit(
    refi: refi,
    maxPostponed: maxPostponed,
    maxPulledIn: maxPulledIn,
    clk: clk,
    reset: reset,
    enable: enable,
    issued: issued,
  );
  await dut.build();

  Simulator.setMaxSimTime((cycles + 10) * 10 * 2);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  await clk.nextPosedge;
  reset.inject(0);

  final rand = Random(seed);
  final issueCycles = <int>[];

  // An independent owed trajectory: tracked in Dart from the same
  // enable/issued history the device sees, by the credit rule itself (+1
  // per tick, -1 per issue, clamped), not by reading the device's own
  // owed. This is what actually catches a same-cycle tick+issue bug at a
  // saturation bound, which comparing need/mayPullIn/force to the
  // device's own owed cannot.
  var expectedOwed = 0;
  var tickCounter = 0;

  for (var t = 0; t < cycles; t++) {
    enable.inject(1);
    // A realistic scheduler: always clear a forced refresh, usually clear
    // a needed one, and only occasionally pull one in early. Random in
    // when a refresh lands, not in whether the credit backs it.
    final force = dut.force.value.toInt() == 1;
    final need = dut.need.value.toInt() == 1;
    final mayPullIn = dut.mayPullIn.value.toInt() == 1;
    final issueNow =
        force ||
        (need && rand.nextDouble() < 0.5) ||
        (mayPullIn && rand.nextDouble() < 0.1);
    issued.inject(issueNow ? 1 : 0);

    final tick = tickCounter == refi - 1;
    tickCounter = tick ? 0 : tickCounter + 1;
    final tickReal = tick && expectedOwed < maxPostponed;
    final issueReal = issueNow && expectedOwed > -maxPulledIn;
    if (tickReal && issueReal) {
      // cancel: a newly-due refresh and a performed one land together.
    } else if (tickReal) {
      expectedOwed += 1;
    } else if (issueReal) {
      expectedOwed -= 1;
    }

    await clk.nextPosedge;

    final owed = dut.owed.value.toInt().toSigned(dut.owedWidth);
    expect(owed, equals(expectedOwed), reason: 'owed trajectory at t=$t');
    expect(owed, greaterThanOrEqualTo(-maxPulledIn), reason: 'at t=$t');
    expect(owed, lessThanOrEqualTo(maxPostponed), reason: 'at t=$t');
    expect(dut.need.value.toInt(), owed > 0 ? 1 : 0, reason: 'need at t=$t');
    expect(
      dut.mayPullIn.value.toInt(),
      owed > -maxPulledIn ? 1 : 0,
      reason: 'mayPullIn at t=$t',
    );
    expect(
      dut.force.value.toInt(),
      owed >= maxPostponed ? 1 : 0,
      reason: 'force at t=$t',
    );
    if (owed >= maxPostponed) {
      expect(dut.force.value.toInt(), 1, reason: 'force must assert at k');
    }
    if (issueNow) {
      issueCycles.add(t);
    }
  }

  // Window property (design fix 2): the n-th issued refresh (1-based)
  // cannot land before (n - maxPulledIn) * refi cycles from t0, since
  // owed can pull in at most maxPulledIn refreshes ahead of schedule.
  for (var n = 1; n <= issueCycles.length; n++) {
    final tN = issueCycles[n - 1];
    final bound = (n - maxPulledIn) * refi;
    expect(
      tN,
      greaterThanOrEqualTo(bound),
      reason: 'refresh $n at cycle $tN violates the pull-in window',
    );
  }

  await Simulator.endSimulation();
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'owed stays in [-8, 8] and force asserts at k over 50000 cycles',
    () async {
      await _runRandom(
        refi: 4,
        maxPostponed: 8,
        maxPulledIn: 8,
        cycles: 50000,
        seed: 1,
      );
    },
  );

  test('k=2, p=0 also holds', () async {
    await _runRandom(
      refi: 4,
      maxPostponed: 2,
      maxPulledIn: 0,
      cycles: 50000,
      seed: 2,
    );
  });

  test('a same-cycle tick and issue at the lower bound still applies the '
      'unsaturated tick', () async {
    const maxPostponed = 4;
    const maxPulledIn = 4;
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final enable = Logic(name: 'enable')..inject(0);
    final issued = Logic(name: 'issued')..inject(0);
    final dut = SdramRefreshCredit(
      refi: 1, // a tick every enabled cycle, for exact control.
      maxPostponed: maxPostponed,
      maxPulledIn: maxPulledIn,
      clk: clk,
      reset: reset,
      enable: enable,
      issued: issued,
    );
    await dut.build();

    Simulator.setMaxSimTime(1000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);

    // Pull owed down to -maxPulledIn with enable held low, so no tick
    // competes with these issues.
    for (var i = 0; i < maxPulledIn; i++) {
      enable.inject(0);
      issued.inject(1);
      await clk.nextPosedge;
    }
    expect(
      dut.owed.value.toInt().toSigned(dut.owedWidth),
      -maxPulledIn,
      reason: 'owed at the floor',
    );

    // A tick and an issue land on the same cycle at the floor: the
    // issue is saturated (owed can't go lower), the tick is not, so
    // owed must still move up by one.
    enable.inject(1);
    issued.inject(1);
    await clk.nextPosedge;
    expect(
      dut.owed.value.toInt().toSigned(dut.owedWidth),
      -maxPulledIn + 1,
      reason: 'owed after the same-cycle tick+issue at the floor',
    );

    await Simulator.endSimulation();
  });

  test('a same-cycle tick and issue at the upper bound still applies the '
      'unsaturated issue', () async {
    const maxPostponed = 4;
    const maxPulledIn = 4;
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final enable = Logic(name: 'enable')..inject(0);
    final issued = Logic(name: 'issued')..inject(0);
    final dut = SdramRefreshCredit(
      refi: 1,
      maxPostponed: maxPostponed,
      maxPulledIn: maxPulledIn,
      clk: clk,
      reset: reset,
      enable: enable,
      issued: issued,
    );
    await dut.build();

    Simulator.setMaxSimTime(1000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);

    // Push owed up to maxPostponed with issued held low.
    for (var i = 0; i < maxPostponed; i++) {
      enable.inject(1);
      issued.inject(0);
      await clk.nextPosedge;
    }
    expect(
      dut.owed.value.toInt().toSigned(dut.owedWidth),
      maxPostponed,
      reason: 'owed at the ceiling',
    );

    // A tick and an issue land on the same cycle at the ceiling: the
    // tick is saturated (owed can't go higher), the issue is not, so
    // owed must still move down by one.
    enable.inject(1);
    issued.inject(1);
    await clk.nextPosedge;
    expect(
      dut.owed.value.toInt().toSigned(dut.owedWidth),
      maxPostponed - 1,
      reason: 'owed after the same-cycle tick+issue at the ceiling',
    );

    await Simulator.endSimulation();
  });

  test('owedWidth fits the signed range', () async {
    final clk = SimpleClockGenerator(10).clk;
    final dut = SdramRefreshCredit(
      refi: 4,
      maxPostponed: 8,
      maxPulledIn: 8,
      clk: clk,
      reset: Logic()..inject(0),
      enable: Logic()..inject(0),
      issued: Logic()..inject(0),
    );
    expect(dut.owedWidth, equals(5));
  });
}

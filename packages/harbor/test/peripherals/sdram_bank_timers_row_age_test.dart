// Split out from sdram_bank_timers_test.dart: row_age_force needs a run of
// rowAgeLimit cycles (thousands at 125 MHz) to reach its threshold, which
// pushes the file over the one-sim-file time budget if kept alongside the
// other bank-timer checks.

import 'dart:async';

import 'package:harbor/src/peripherals/sdram_bank_timers.dart';
import 'package:harbor/src/peripherals/sdram_command.dart';
import 'package:harbor/src/peripherals/sdram_config.dart';
import 'package:harbor/src/peripherals/sdram_cycles.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('row_age_force rises two cycles after rowAgeLimit', () async {
    final cycles = HarborSdramCycles(
      const HarborSdramConfig.as4c16m16sb6(),
      clockHz: 125000000,
    );
    final clk = SimpleClockGenerator(cycles.tCkPs).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final cmd = Logic(name: 'cmd', width: 3)..inject(0);
    final cmdBank = Logic(name: 'cmd_bank', width: cycles.config.bankBits)
      ..inject(0);
    final cmdBeats = Logic(name: 'cmd_beats', width: 4)..inject(0);
    final dut = SdramBankTimers(
      cycles,
      clk: clk,
      reset: reset,
      cmd: cmd,
      cmdBank: cmdBank,
      cmdBeats: cmdBeats,
    );
    await dut.build();

    final maxCycles = cycles.rowAgeLimit + 10;
    Simulator.setMaxSimTime(maxCycles * cycles.tCkPs * 2);
    unawaited(Simulator.run());

    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);

    cmd.inject(SdramCommand.act.index);
    await clk.nextPosedge;
    cmd.inject(SdramCommand.nop.index);

    // The age counts from the registered open flag and the force flag
    // reads the registered age, so it rises two edges after the limit.
    for (var i = 0; i < cycles.rowAgeLimit; i++) {
      await clk.nextPosedge;
    }
    expect(dut.rowAgeForce.value.toInt(), 0, reason: 'just before the limit');
    await clk.nextPosedge;
    expect(dut.rowAgeForce.value.toInt(), 1, reason: 'at the limit');

    await Simulator.endSimulation();
  });
}

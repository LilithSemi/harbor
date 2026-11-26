import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'plane_memory.dart';

const _timing = HarborDisplayTiming(
  hActive: 16,
  hFrontPorch: 2,
  hSyncWidth: 2,
  hBackPorch: 2,
  vActive: 8,
  vFrontPorch: 2,
  vSyncWidth: 1,
  vBackPorch: 2,
  pixelClock: 1000000,
);

void main() {
  tearDown(() async => Simulator.reset());

  test('an errored read beat of the memory waist pulses bus_error', () async {
    final pixelClk = SimpleClockGenerator(20).clk;
    final sysClk = SimpleClockGenerator(4).clk;
    final pixelReset = Logic(name: 'pixel_reset')..inject(1);
    final sysReset = Logic(name: 'sys_reset')..inject(1);
    final memory = HarborMemoryWaist(
      const HarborMemoryWaistConfig(
        addressWidth: 32,
        dataWidth: 32,
        outstanding: 4,
      ),
    );
    final display = HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: _timing,
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
      enable: Const(1),
      update: Const(1),
      fbBase: Const(0x1000, width: 32),
      memory: memory,
      outputType: HarborDisplayInterface.parallelRgb,
    );
    await display.build();
    WaistMemory(memory, sysClk);
    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    await pixelClk.nextPosedge;
    pixelReset.inject(0);
    sysReset.inject(0);

    var pulses = 0;
    sysClk.posedge.listen((_) {
      if (display.busError.value == LogicValue.one) pulses++;
    });
    for (var i = 0; i < 1200; i++) {
      await sysClk.nextPosedge;
    }
    expect(pulses, 0, reason: 'no error yet');

    // One errored beat.
    var errors = 0;
    memory.rdataErr.inject(1);
    while (errors < 1) {
      await sysClk.nextPosedge;
      if (memory.rdataValid.value == LogicValue.one &&
          memory.rdataReady.value == LogicValue.one) {
        errors++;
      }
    }
    await sysClk.nextPosedge;
    memory.rdataErr.inject(0);
    for (var i = 0; i < 20; i++) {
      await sysClk.nextPosedge;
    }
    expect(pulses, greaterThanOrEqualTo(1));
    final seen = pulses;
    for (var i = 0; i < 600; i++) {
      await sysClk.nextPosedge;
    }
    expect(pulses, seen, reason: 'no more pulses after the error');
    await Simulator.endSimulation();
  });
}

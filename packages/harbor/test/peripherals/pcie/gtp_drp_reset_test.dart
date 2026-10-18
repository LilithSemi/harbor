import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(Simulator.reset);

  test('masks DRP 0x011 before releasing GTRXRESET and restores it', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    final start = Logic()..inject(0);
    final pmaDone = Logic()..inject(1);
    final ready = Logic()..inject(0);
    final dataOut = Logic(width: 16)..inject(0xaffe);
    final dut = HarborGtpDrpReset(
      clk: clk,
      reset: reset,
      start: start,
      rxPmaResetDone: pmaDone,
      drpReady: ready,
      drpDataOut: dataOut,
      timeoutCycles: 16,
    );
    await dut.build();
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    start.inject(1);

    final operations = <(bool, int)>[];
    var sawRelease = false;
    var sawDone = false;
    var readyNext = false;
    for (var cycle = 0; cycle < 40; cycle++) {
      await clk.nextNegedge;
      final enable = dut.drpEnable.value.toBool();
      if (enable) {
        operations.add((
          dut.drpWrite.value.toBool(),
          dut.drpDataIn.value.toInt(),
        ));
      }
      ready.inject(readyNext ? 1 : 0);
      readyNext = enable;
      if (!dut.gtReset.value.toBool() && operations.length >= 2) {
        sawRelease = true;
        pmaDone.inject(0);
      }
      if (dut.done.value.toBool()) {
        sawDone = true;
        break;
      }
    }
    expect(operations, [(false, 0), (true, 0xa7fe), (true, 0xaffe)]);
    expect(dut.drpAddr.value.toInt(), 0x011);
    expect(sawRelease, isTrue);
    expect(sawDone, isTrue);
    expect(dut.failed.value.toBool(), isFalse);
    await Simulator.endSimulation();
  });

  test('reports a timed out DRP transaction', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic()..inject(1);
    final start = Logic()..inject(0);
    final dut = HarborGtpDrpReset(
      clk: clk,
      reset: reset,
      start: start,
      rxPmaResetDone: Logic()..inject(0),
      drpReady: Logic()..inject(0),
      drpDataOut: Logic(width: 16)..inject(0),
      timeoutCycles: 4,
    );
    await dut.build();
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);
    start.inject(1);
    for (var i = 0; i < 10; i++) {
      await clk.nextPosedge;
    }
    expect(dut.failed.value.toBool(), isTrue);
    await Simulator.endSimulation();
  });
}

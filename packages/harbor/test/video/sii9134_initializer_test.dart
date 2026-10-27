import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  Future<HarborSii9134Initializer> build({required int sda}) async {
    final dut = HarborSii9134Initializer(
      clk: SimpleClockGenerator(10).clk,
      reset: Logic(name: 'reset'),
      sclIn: Const(1),
      sdaIn: Const(sda),
      clockFrequency: 1000000,
      i2cFrequency: 10000,
      resetHoldUs: 50,
    );
    await dut.build();
    return dut;
  }

  tearDown(() async => Simulator.reset());

  test('holds reset and writes the AX7203 transmitter setup', () async {
    final dut = await build(sda: 0);
    final clk = dut.input('clk');
    final reset = dut.input('reset');
    reset.inject(1);
    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);

    var resetLowCycles = 0;
    var previousSclOe = dut.sclOe.value.toInt();
    final risingBits = <int>[];
    for (var i = 0; dut.done.value.toInt() == 0; i++) {
      if (i > 19000) fail('no done in $i clocks');
      await clk.nextPosedge;
      if (dut.resetN.value.toInt() == 0) resetLowCycles++;
      final sclOe = dut.sclOe.value.toInt();
      if (previousSclOe == 1 && sclOe == 0) {
        risingBits.add(dut.sdaOe.value.toInt() == 0 ? 1 : 0);
      }
      previousSclOe = sclOe;
      expect(dut.error.value.toInt(), equals(0));
    }

    expect(resetLowCycles, greaterThanOrEqualTo(50));
    expect(risingBits.length, equals(56));

    int byteAt(int transaction, int byteIndex) {
      final base = transaction * 28 + byteIndex * 9;
      var value = 0;
      for (var bit = 0; bit < 8; bit++) {
        value = (value << 1) | risingBits[base + bit];
      }
      return value;
    }

    expect([
      for (var transaction = 0; transaction < 2; transaction++)
        for (var byteIndex = 0; byteIndex < 3; byteIndex++)
          byteAt(transaction, byteIndex),
    ], equals([0x72, 0x08, 0x35, 0x7a, 0x2f, 0x00]));
    await Simulator.endSimulation();
  });

  test('reports a missing transmitter ACK', () async {
    final dut = await build(sda: 1);
    final clk = dut.input('clk');
    final reset = dut.input('reset');
    reset.inject(1);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    reset.inject(0);

    for (var i = 0; dut.error.value.toInt() == 0; i++) {
      if (i > 9000) fail('no error in $i clocks');
      await clk.nextPosedge;
    }
    expect(dut.done.value.toInt(), equals(0));
    await Simulator.endSimulation();
  });

  test('rejects timings outside the data sheet limits', () {
    expect(
      () => HarborSii9134Initializer(
        clk: Logic(),
        reset: Logic(),
        sclIn: Logic(),
        sdaIn: Logic(),
        clockFrequency: 1000000,
        resetHoldUs: 49,
      ),
      throwsArgumentError,
    );
    expect(
      () => HarborSii9134Initializer(
        clk: Logic(),
        reset: Logic(),
        sclIn: Logic(),
        sdaIn: Logic(),
        clockFrequency: 1000000,
        i2cFrequency: 400001,
      ),
      throwsArgumentError,
    );
  });
}

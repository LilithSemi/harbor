import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests the TMDS serializer's gearbox: a 10-bit symbol is shifted out LSB
/// first as DDR bit pairs (d0 on the rising edge, d1 on the falling edge) over
/// five shift-clock cycles. The ODDRX1F output itself is a vendor blackbox, so
/// these tests target the fabric gearing that feeds it.
void main() {
  late Logic shiftClk, reset, symbol, align;
  late TmdsSerializer ser;

  Future<void> setup() async {
    shiftClk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    symbol = Logic(name: 'symbol', width: 10);
    align = Logic(name: 'align');
    ser = TmdsSerializer(
      shiftClk: shiftClk,
      reset: reset,
      symbol: symbol,
      align: align,
      target: const HarborSimTarget(),
    );
    await ser.build();
    reset.inject(1);
    symbol.inject(0);
    align.inject(0);
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());
    await shiftClk.nextPosedge;
    await shiftClk.nextPosedge;
    reset.inject(0);
    await shiftClk.nextNegedge;
  }

  Future<void> tick(int n) async {
    for (var i = 0; i < n; i++) {
      await shiftClk.nextPosedge;
    }
    await shiftClk.nextNegedge;
  }

  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  test('shifts a symbol out LSB first as DDR bit pairs', () async {
    await setup();
    symbol.inject(0x101); // bits: bit0=1, bit8=1, rest 0
    // The load takes five cycles, and d0/d1 follow the shift register by one.
    await tick(6);

    final d0s = <int>[];
    final d1s = <int>[];
    for (var i = 0; i < 5; i++) {
      d0s.add(ser.d0.value.toInt());
      d1s.add(ser.d1.value.toInt());
      await tick(1);
    }
    // pairs (bit0,bit1)..(bit8,bit9): d0 over the word, then d1.
    expect(d0s, equals([1, 0, 0, 0, 1]));
    expect(d1s, equals([0, 0, 0, 0, 0]));
  });

  test('an all-ones symbol drives both DDR phases high', () async {
    await setup();
    symbol.inject(0x3FF);
    await tick(6);
    expect(ser.d0.value.toInt(), equals(1));
    expect(ser.d1.value.toInt(), equals(1));
  });

  test('an align pulse moves the word border to the next edge', () async {
    await setup();
    symbol.inject(0x003);
    await tick(7);
    // Each pass starts the pulse at a different phase of the gearbox.
    for (var shift = 0; shift < 5; shift++) {
      align.inject(1);
      await tick(1);
      align.inject(0);
      // The next edge loads, and the output pair follows one edge later.
      await tick(2);
      final d0s = <int>[];
      for (var i = 0; i < 10; i++) {
        d0s.add(ser.d0.value.toInt());
        await tick(1);
      }
      expect(d0s, equals([1, 0, 0, 0, 0, 1, 0, 0, 0, 0]));
      await tick(shift);
    }
  });
}

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('matches the BT.709 model, chroma order and sync delay', () async {
    final dut = HarborYcbcr422Converter(
      clk: SimpleClockGenerator(10).clk,
      reset: Logic(),
      red: Logic(width: 8),
      green: Logic(width: 8),
      blue: Logic(width: 8),
      de: Logic(),
      hsync: Logic(),
      vsync: Logic(),
    );
    await dut.build();
    final clk = dut.input('clk');
    final rnd = Random(7);

    // Runs of DE of odd and even length, with gaps.
    final de = <bool>[];
    for (final (gap, run) in [(3, 8), (5, 7), (2, 1), (4, 6), (3, 9), (6, 4)]) {
      de
        ..addAll(List.filled(gap, false))
        ..addAll(List.filled(run, true));
    }
    de.addAll(List.filled(8, false));
    final n = de.length;
    final px = [for (var i = 0; i < n; i++) [for (var c = 0; c < 3; c++) rnd.nextInt(256)]];
    // Corner values on the first run.
    px[3] = [0, 0, 0];
    px[4] = [255, 255, 255];
    px[5] = [255, 0, 0];
    px[6] = [0, 255, 0];
    px[7] = [0, 0, 255];
    final hs = [for (var i = 0; i < n; i++) i % 11 < 4 ? 0 : 1];
    final vs = [for (var i = 0; i < n; i++) i % 17 < 6 ? 0 : 1];

    dut.input('reset').inject(1);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextNegedge;
    await clk.nextNegedge;
    dut.input('reset').inject(0);

    final seenD = <int>[], seenDe = <int>[], seenHs = <int>[], seenVs = <int>[];
    for (var k = 0; k < n + HarborYcbcr422Converter.latency; k++) {
      await clk.nextNegedge;
      if (k >= HarborYcbcr422Converter.latency) {
        seenD.add(dut.d.value.toInt());
        seenDe.add(dut.de.value.toInt());
        seenHs.add(dut.hsync.value.toInt());
        seenVs.add(dut.vsync.value.toInt());
      }
      if (k < n) {
        dut.input('red').inject(px[k][0]);
        dut.input('green').inject(px[k][1]);
        dut.input('blue').inject(px[k][2]);
        dut.input('de').inject(de[k] ? 1 : 0);
        dut.input('hsync').inject(hs[k]);
        dut.input('vsync').inject(vs[k]);
      }
    }

    var pos = 0;
    var evenPx = [0, 0, 0];
    for (var i = 0; i < n; i++) {
      pos = de[i] ? pos + 1 : 0;
      final p = px[i];
      final y = HarborBt709.y(p[0], p[1], p[2]);
      int expected;
      if (!de[i]) {
        expected = 0x8010;
      } else if (pos.isOdd) {
        evenPx = p;
        expected = (HarborBt709.cb(p[0], p[1], p[2]) << 8) | y;
      } else {
        expected =
            (HarborBt709.cr(evenPx[0], evenPx[1], evenPx[2]) << 8) | y;
      }
      expect(seenD[i], expected, reason: 'pixel $i');
      expect(seenDe[i], de[i] ? 1 : 0, reason: 'de $i');
      expect(seenHs[i], hs[i], reason: 'hsync $i');
      expect(seenVs[i], vs[i], reason: 'vsync $i');
    }
    await Simulator.endSimulation();
  });

  test('the model matches known values', () {
    expect(HarborBt709.y(0, 0, 0), 16);
    expect(HarborBt709.cb(0, 0, 0), 128);
    expect(HarborBt709.y(255, 255, 255), 235);
    expect(HarborBt709.cb(255, 255, 255), 127);
    expect(HarborBt709.cr(255, 255, 255), 128);
  });
}

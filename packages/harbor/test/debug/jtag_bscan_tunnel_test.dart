import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('a DR frame with the widest scan walks the inner TAP', () async {
    final tunnel = JtagBscanTunnel();
    final clk = SimpleClockGenerator(10).clk;
    tunnel.input('clk').srcConnection! <= clk;
    Logic src(String name) => tunnel.input(name).srcConnection!;
    for (final name in ['reset', 'jtck', 'jtdi', 'jupdate', 'inner_tdo']) {
      src(name).inject(0);
    }
    for (final name in ['jshift', 'jce1', 'jrstn']) {
      src(name).inject(1);
    }
    await tunnel.build();

    // Frame bits: sel, 7 width bits LSB first, N + 1 payload, 3 idle.
    const n = 127;
    final bits = [
      1,
      for (var i = 0; i < 7; i++) (n >> i) & 1,
      for (var i = 0; i < n + 1; i++) i & 1,
      0,
      0,
      0,
    ];

    final tmsHigh = <int>[];
    var tckCount = 0;
    tunnel.output('inner_tck').posedge.listen((_) {
      if (tunnel.output('inner_tms').value.toBool()) tmsHigh.add(tckCount);
      tckCount++;
    });

    Simulator.setMaxSimTime(100000);
    src('reset').inject(1);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    src('reset').inject(0);
    await clk.nextPosedge;
    for (final b in bits) {
      src('jtdi').inject(b);
      src('jtck').inject(0);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      src('jtck').inject(1);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
    }
    await Simulator.endSimulation();

    expect(tckCount, bits.length);
    expect(tmsHigh, [5, 8 + n - 1, 8 + n]);
  });
}

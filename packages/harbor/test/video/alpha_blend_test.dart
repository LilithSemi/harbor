import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'overlay_reference.dart';

const _ecp5 = HarborFpgaTarget.ecp5(device: 'LFE5U-85F', package: 'CABGA381');

/// Sends each (overlay, primary, alpha) case through the blend, one each
/// clock, and checks every output against [blend255].
Future<void> _run(HarborDeviceTarget? target, List<List<int>> cases) async {
  final clk = SimpleClockGenerator(10).clk;
  final ov = [for (var i = 0; i < 3; i++) Logic(width: 8)];
  final pri = [for (var i = 0; i < 3; i++) Logic(width: 8)];
  final alpha = Logic(width: 8);
  final b = HarborAlphaBlend(
    clk: clk,
    overlay: ov,
    primary: pri,
    alpha: alpha,
    target: target,
  );
  await b.build();
  addTearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });
  unawaited(Simulator.run());
  final sent = <List<int>>[];
  for (var i = 0; i < cases.length + HarborAlphaBlend.latency; i++) {
    await clk.nextNegedge;
    final k = i - HarborAlphaBlend.latency;
    if (k >= 0) {
      final c = sent[k];
      expect(
        [b.red.value.toInt(), b.green.value.toInt(), b.blue.value.toInt()],
        [
          for (var ch = 0; ch < 3; ch++) blend255(c[ch], c[3 + ch], c[6]),
        ],
        reason: '$c',
      );
    }
    if (i < cases.length) {
      final c = cases[i];
      for (var ch = 0; ch < 3; ch++) {
        ov[ch].inject(c[ch]);
        pri[ch].inject(c[3 + ch]);
      }
      alpha.inject(c[6]);
      sent.add(c);
    }
  }
  await Simulator.endSimulation();
}

void main() {
  test('div255 is the rounded quotient over its whole range', () {
    for (var v = 0; v <= 255 * 255; v++) {
      expect(div255(v), (v / 255).round(), reason: '$v');
    }
  });

  test('alpha 0 gives the primary and alpha 255 the overlay', () {
    for (var o = 0; o < 256; o++) {
      for (var p = 0; p < 256; p++) {
        expect(blend255(o, p, 0), p);
        expect(blend255(o, p, 255), o);
      }
    }
  });

  for (final (name, target) in [('inferred', null), ('ecp5', _ecp5)]) {
    test('the $name blend matches the formula', () async {
      final rng = Random(7);
      final cases = <List<int>>[
        for (final a in [0, 1, 127, 128, 254, 255])
          for (final (o, p) in [(0, 0), (255, 0), (0, 255), (255, 255)])
            [o, 255 - o, o, p, p, 255 - p, a],
        for (var i = 0; i < 2000; i++)
          [for (var k = 0; k < 7; k++) rng.nextInt(256)],
      ];
      await _run(target, cases);
    });
  }

  test('the ecp5 blend has 3 MULT18X18D with their registers', () async {
    final b = HarborAlphaBlend(
      clk: Logic(),
      overlay: [for (var i = 0; i < 3; i++) Logic(width: 8)],
      primary: [for (var i = 0; i < 3; i++) Logic(width: 8)],
      alpha: Logic(width: 8),
      target: _ecp5,
    );
    await b.build();
    expect(b.definitionName, 'HarborAlphaBlend_ecp5');
    expect(b.subModules.whereType<Ecp5Mult18x18d>(), hasLength(3));
    final sv = b.generateSynth();
    expect('REG_OUTPUT_CLK'.allMatches(sv), hasLength(3));
  });
}

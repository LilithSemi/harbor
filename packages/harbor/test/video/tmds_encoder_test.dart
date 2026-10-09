import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'tmds_reference.dart';

typedef _In = ({bool de, int data, int ctrl});

/// Tests the DVI 1.0 TMDS encoder against spec-derived vectors.
///
/// Control codes (DE low) are the four fixed 10-bit symbols. Data vectors and
/// the running-disparity behavior are derived by hand from the DVI 1.0
/// encoding algorithm (Figure 3-5):
///   - D=0x00 with disparity 0 encodes to 0x100, leaving disparity -8.
///   - feeding D=0x00 again (disparity -8) balances to 0x3FF.
///
/// The encoder is pipelined, so each symbol is read [TmdsEncoder.latency]
/// cycles after its input.
void main() {
  late Logic clk, reset, de, data, ctrl;
  late TmdsEncoder enc;

  Future<void> setup() async {
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    de = Logic(name: 'de');
    data = Logic(name: 'data', width: 8);
    ctrl = Logic(name: 'ctrl', width: 2);
    enc = TmdsEncoder(clk: clk, reset: reset, de: de, data: data, ctrl: ctrl);
    await enc.build();

    reset.inject(1);
    de.inject(0);
    data.inject(0);
    ctrl.inject(0);
    Simulator.setMaxSimTime(10000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextNegedge;
  }

  /// Drives one input for each cycle and returns the symbol for each one.
  Future<List<int>> run(List<_In> stream) async {
    final out = <int>[];
    for (var i = 0; i < stream.length + TmdsEncoder.latency; i++) {
      final v = i < stream.length ? stream[i] : (de: false, data: 0, ctrl: 0);
      de.inject(v.de ? 1 : 0);
      data.inject(v.data);
      ctrl.inject(v.ctrl);
      await clk.nextPosedge;
      await clk.nextNegedge;
      if (i + 1 >= TmdsEncoder.latency) out.add(enc.q.value.toInt());
    }
    return out;
  }

  tearDown(() async {
    await Simulator.endSimulation();
    Simulator.reset();
  });

  group('control period (DE low)', () {
    test('emits the four fixed control symbols', () async {
      await setup();
      final q = await run([
        for (var c = 0; c < 4; c++) (de: false, data: 0, ctrl: c),
      ]);
      expect(q.take(4), equals([0x354, 0x0AB, 0x154, 0x2AB]));
    });
  });

  group('data period (DE high)', () {
    test('D=0 then D=0 balances disparity (0x100 then 0x3FF)', () async {
      await setup();
      final q = await run([
        (de: true, data: 0, ctrl: 0),
        (de: true, data: 0, ctrl: 0),
      ]);
      expect(q.take(2), equals([0x100, 0x3FF]));
    });

    test('D=0xFF at disparity 0 encodes to 0x200 (XNOR path)', () async {
      await setup();
      final q = await run([(de: true, data: 0xFF, ctrl: 0)]);
      expect(q.first, equals(0x200));
    });
  });

  test('a long stream matches the DVI reference symbol for symbol', () async {
    await setup();
    final rng = Random(7);
    final stream = <_In>[];
    // Lines of random data with blanking between them, so the disparity
    // resets and every control code appears.
    for (var line = 0; line < 12; line++) {
      for (var i = 0; i < 40; i++) {
        stream.add((de: true, data: rng.nextInt(256), ctrl: 0));
      }
      for (var i = 0; i < 6; i++) {
        stream.add((de: false, data: rng.nextInt(256), ctrl: (line + i) & 3));
      }
    }
    final ref = TmdsReference();
    final expected = [
      for (final v in stream) ref.encode(de: v.de, data: v.data, ctrl: v.ctrl),
    ];
    final q = await run(stream);
    expect(q.take(stream.length).toList(), equals(expected));
  });
}

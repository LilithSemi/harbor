import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'tmds_reference.dart';

/// DviTransmitter is the reusable TMDS backend: it takes parallel RGB plus
/// HSYNC/VSYNC/DE (from any source) and serializes them onto the four GPDI
/// lanes.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('elaborates with three encoders and four serializers', () async {
    final tx = DviTransmitter(
      target: const HarborSimTarget(),
      pixelClk: Logic(name: 'pixel_clk'),
      shiftClk: Logic(name: 'shift_clk'),
      pixelReset: Logic(name: 'pixel_reset'),
      shiftReset: Logic(name: 'shift_reset'),
      de: Logic(name: 'de'),
      hsync: Logic(name: 'hsync'),
      vsync: Logic(name: 'vsync'),
      red: Logic(name: 'red', width: 8),
      green: Logic(name: 'green', width: 8),
      blue: Logic(name: 'blue', width: 8),
    );
    await tx.build();
    final sv = tx.generateSynth();

    expect(tx.gpdi.width, equals(4));
    expect('TmdsEncoder'.allMatches(sv).length, greaterThanOrEqualTo(3));
    expect('TmdsSerializer'.allMatches(sv).length, greaterThanOrEqualTo(4));
  });

  // Serializes [lines] lines of random video, shift reset released
  // [shiftDelay] shift cycles after the pixel reset, and checks all lanes.
  // Returns the bit index where the first stream word starts.
  Future<int> serializeStream(int shiftDelay, {int lines = 8}) async {
    const pixelPeriod = 100;
    const shiftPeriod = pixelPeriod ~/ 5;
    const halfBit = shiftPeriod ~/ 2;
    // The pixel reset goes low on this falling edge of both clocks.
    const pixelRelease = 3 * pixelPeriod;
    final pixelClk = SimpleClockGenerator(pixelPeriod).clk;
    final shiftClk = SimpleClockGenerator(shiftPeriod).clk;
    final pixelReset = Logic(name: 'pixel_reset');
    final shiftReset = Logic(name: 'shift_reset');
    final de = Logic(name: 'de');
    final hsync = Logic(name: 'hsync');
    final vsync = Logic(name: 'vsync');
    final red = Logic(name: 'red', width: 8);
    final green = Logic(name: 'green', width: 8);
    final blue = Logic(name: 'blue', width: 8);
    final tx = DviTransmitter(
      target: const HarborSimTarget(),
      pixelClk: pixelClk,
      shiftClk: shiftClk,
      pixelReset: pixelReset,
      shiftReset: shiftReset,
      de: de,
      hsync: hsync,
      vsync: vsync,
      red: red,
      green: green,
      blue: blue,
    );
    await tx.build();

    // Lines of random pixels with blanking that walks through the sync codes.
    final rng = Random(11);
    final stream = <({bool de, bool hs, bool vs, int r, int g, int b})>[];
    for (var line = 0; line < lines; line++) {
      for (var i = 0; i < 24; i++) {
        stream.add((
          de: true,
          hs: false,
          vs: false,
          r: rng.nextInt(256),
          g: rng.nextInt(256),
          b: rng.nextInt(256),
        ));
      }
      for (var i = 0; i < 8; i++) {
        stream.add((de: false, hs: i.isOdd, vs: line.isOdd, r: 0, g: 0, b: 0));
      }
    }
    final refs = [TmdsReference(), TmdsReference(), TmdsReference()];
    final expected = [
      for (final v in stream)
        [
          refs[0].encode(
            de: v.de,
            data: v.b,
            ctrl: (v.vs ? 2 : 0) | (v.hs ? 1 : 0),
          ),
          refs[1].encode(de: v.de, data: v.g, ctrl: 0),
          refs[2].encode(de: v.de, data: v.r, ctrl: 0),
        ],
    ];

    const lead = 8;
    const tail = 16;
    final cycles = lead + stream.length + tail;
    // One sample in the middle of each half shift period, one bit each.
    final bits = <List<int>>[];
    for (var t = halfBit ~/ 2; t < cycles * pixelPeriod; t += halfBit) {
      Simulator.registerAction(t, () {
        final v = tx.gpdi.value;
        bits.add([for (var l = 0; l < 4; l++) v[l].isValid ? v[l].toInt() : 9]);
      });
    }
    Simulator.registerAction(pixelRelease, () => pixelReset.inject(0));
    Simulator.registerAction(
      pixelRelease + shiftDelay * shiftPeriod,
      () => shiftReset.inject(0),
    );

    pixelReset.inject(1);
    shiftReset.inject(1);
    de.inject(0);
    hsync.inject(0);
    vsync.inject(0);
    red.inject(0);
    green.inject(0);
    blue.inject(0);
    Simulator.setMaxSimTime(cycles * pixelPeriod + pixelPeriod);
    unawaited(Simulator.run());

    for (var i = 0; i < cycles; i++) {
      await pixelClk.nextNegedge;
      final k = i - lead;
      if (k >= 0 && k < stream.length) {
        final v = stream[k];
        de.inject(v.de ? 1 : 0);
        hsync.inject(v.hs ? 1 : 0);
        vsync.inject(v.vs ? 1 : 0);
        red.inject(v.r);
        green.inject(v.g);
        blue.inject(v.b);
      } else {
        de.inject(0);
        hsync.inject(0);
        vsync.inject(0);
      }
    }
    await Simulator.simulationEnded;

    // The clock lane marks each word: five zeros then five ones.
    int word(int lane, int at) {
      var w = 0;
      for (var j = 0; j < 10; j++) {
        w |= bits[at + j][lane] << j;
      }
      return w;
    }

    final start = Iterable<int>.generate(
      bits.length - 10,
    ).firstWhere((s) => s >= 60 && word(3, s) == 0x3E0);
    final words = [
      for (var s = start; s + 10 <= bits.length; s += 10)
        [word(0, s), word(1, s), word(2, s), word(3, s)],
    ];
    for (final w in words) {
      expect(w[3], equals(0x3E0), reason: 'clock lane keeps its pattern');
    }

    // Find the one offset that lines the whole stream up on all lanes.
    final offsets = <int>[];
    for (var off = 0; off + stream.length <= words.length; off++) {
      var ok = true;
      for (var k = 0; k < stream.length && ok; k++) {
        for (var l = 0; l < 3; l++) {
          if (words[off + k][l] != expected[k][l]) {
            ok = false;
            break;
          }
        }
      }
      if (ok) offsets.add(off);
    }
    expect(offsets, hasLength(1), reason: 'one alignment for every lane');
    return start + 10 * offsets.single;
  }

  test('the serialized lanes carry the whole stream in order', () async {
    await serializeStream(0);
  });

  test('shift reset release sweeps all five gearbox phases', () async {
    // The shift reset release sweeps all five gearbox phases, before and after
    // the pixel reset. The words must start on the same bit every time, so the
    // load phase follows the pixel clock and not the reset order.
    final starts = <int, int>{};
    for (var delay = -2; delay <= 2; delay++) {
      starts[delay] = await serializeStream(delay, lines: 2);
      await Simulator.reset();
    }
    expect(
      starts.values.toSet(),
      hasLength(1),
      reason: 'all delays give same word start: $starts',
    );
  });
}

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The real reset logic of [HarborAdv7511Clocks] with the MMCM outputs
/// replaced by two clocks that a test schedules, then the converter and the
/// pin stage.
class _Top extends Module {
  _Top(Logic src) : super(name: 'adv_clock_path') {
    final source = addInput('source', src);
    final reset = addInput('reset', Logic());
    final clk2x = addInput('clk2x', Logic());
    final pixel = addInput('pixel', Logic());
    final clocks = HarborAdv7511Clocks(
      source: source,
      reset: reset,
      sourceHz: 200000000,
      clk2xHz: 130000000,
      sourceBuffered: true,
      lockBits: 5,
      simClk2x: clk2x,
      simPixelClk: pixel,
    );
    final cnt = Logic(name: 'cnt', width: 8);
    cnt <= flop(clocks.pixelClk, cnt + 1, reset: clocks.pixelReset);
    final conv = HarborYcbcr422Converter(
      clk: clocks.pixelClk,
      reset: clocks.pixelReset,
      red: cnt,
      green: ~cnt,
      blue: cnt << 1,
      de: ~cnt[3],
      hsync: ~(cnt[5] & cnt[4]),
      vsync: ~(cnt[7] & cnt[6]),
    );
    final pins = HarborAdv7511PinStage(
      clk2x: clocks.clk2x,
      reset: clocks.reset2x,
      tog: conv.tog,
      d: conv.d,
      de: conv.de,
      hsync: conv.hsync,
      vsync: conv.vsync,
    );
    addOutput('reset2x') <= clocks.reset2x;
    addOutput('pixel_reset') <= clocks.pixelReset;
    addOutput('pin_clk') <= pins.clkOut;
    addOutput('pin_d', width: 19) <=
        [pins.vsync, pins.hsync, pins.de, pins.d].concat();
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'resets release, the pin clock has a 50% duty, data changes at its rise',
    () async {
      final top = _Top(SimpleClockGenerator(4).clk);
      await top.build();
      const cycles = 600;
      // The 2x clock rises at 5, 15, ... and the pixel clock rises on every
      // second one, as the two outputs of one MMCM do.
      for (var k = 0; k < cycles; k++) {
        final t = 5 + 10 * k;
        Simulator.registerAction(t, () {
          top.input('clk2x').put(1);
          if (k.isEven) top.input('pixel').put(1);
        });
        Simulator.registerAction(t + 5, () {
          top.input('clk2x').put(0);
          if (k.isOdd) top.input('pixel').put(0);
        });
      }
      Simulator.registerAction(0, () {
        top.input('clk2x').put(0);
        top.input('pixel').put(0);
        top.input('reset').put(1);
      });
      Simulator.registerAction(60, () => top.input('reset').put(0));
      Simulator.setMaxSimTime(10 * cycles + 20);

      final rst2x = <int>[], rstPix = <int>[], clk = <int>[], bus = <int>[];
      top.input('clk2x').negedge.listen((_) {
        rst2x.add(top.output('reset2x').value.toInt());
        rstPix.add(top.output('pixel_reset').value.toInt());
        clk.add(top.output('pin_clk').value.toInt());
        final v = top.output('pin_d').value;
        bus.add(v.isValid ? v.toInt() : -1);
      });
      unawaited(Simulator.run());
      await Simulator.simulationEnded;

      // Both resets hold during the count, then release.
      final rel2x = rst2x.indexOf(0);
      final relPix = rstPix.indexOf(0);
      expect(rel2x, greaterThan(5));
      expect(relPix, greaterThan(5));
      expect((relPix - rel2x).abs(), lessThanOrEqualTo(8));
      expect(rst2x.sublist(rel2x).every((v) => v == 0), isTrue);
      expect(rstPix.sublist(relPix).every((v) => v == 0), isTrue);

      // After the release the pin clock toggles on every 2x clock.
      final start = clk.indexOf(1, relPix);
      expect(start, isNot(-1));
      for (var i = start; i < clk.length - 1; i++) {
        expect(clk[i + 1], 1 - clk[i], reason: 'pin_clk at $i');
      }

      // The bus changes only in a 2x cycle where the pin clock rose, and each
      // rise has at most one change, because a change needs a new pixel.
      var changes = 0;
      for (var i = start + 1; i < clk.length; i++) {
        expect(bus[i], isNot(-1), reason: 'bus at $i');
        if (bus[i] != bus[i - 1]) {
          changes++;
          expect(clk[i], 1, reason: 'change at $i');
          expect(clk[i - 1], 0, reason: 'change at $i');
        }
      }
      expect(changes, greaterThan(50));

      // One rise for each pixel clock.
      final rises = [
        for (var i = start + 1; i < clk.length; i++)
          if (clk[i] == 1 && clk[i - 1] == 0) i,
      ];
      expect(rises.length, greaterThan(100));
      for (var i = 1; i < rises.length; i++) {
        expect(rises[i] - rises[i - 1], 2);
      }
    },
  );
}

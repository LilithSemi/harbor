import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// End-to-end parallel RGB display test at full 640x480 VGA timing. The
/// framebuffer display's parallelRgb backend packs rgb, forwards hsync/vsync/
/// de, and forwards the pixel clock, with no TMDS encoder or serializer and no
/// shift clock. Fake memory returns address-as-data, so the pixel word (and
/// from it rgb) is a fully known function of the scan position, checked here
/// against the real timing's active region, sync widths and positions for one
/// whole frame.
void main() {
  const timing = HarborDisplayTiming.vga640x480();
  const hTotal = 800;
  const vTotal = 525;
  const fbBase = 0x1000;

  // HarborFramebufferDisplay's parallelRgb backend registers every parallel
  // output (rgb/hsync/vsync/de and x/y/pixelWord) in one stage, so they all
  // describe the same pixel.
  const prgbDelay = 0;

  test('a full 640x480 frame matches the timing on rgb/hsync/vsync/de', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final enable = Logic(name: 'enable');
    final base = Logic(name: 'fb_base', width: 32);
    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');

    final disp = HarborFramebufferDisplay(
      target: const HarborSimTarget(),
      timing: timing,
      pixelClk: clk,
      pixelReset: reset,
      shiftClk: clk,
      shiftReset: reset,
      enable: enable,
      fbBase: base,
      mDataIn: mDataIn,
      mAck: mAck,
      outputType: HarborDisplayInterface.parallelRgb,
    );
    // Fake memory: 0-latency ack, data = requested address. Deterministic and
    // fully known for every (x, y), without a 300k-entry lookup.
    mAck <= disp.mStb;
    mDataIn <= disp.mAddr;
    await disp.build();

    expect(disp.rgb.width, equals(24));
    expect(disp.pclk.width, equals(1));
    // parallelRgb has no TMDS lanes.
    expect(() => disp.gpdi, throwsA(anything));

    reset.inject(1);
    enable.inject(1);
    base.inject(fbBase);
    Simulator.setMaxSimTime(1 << 30);
    unawaited(Simulator.run());
    addTearDown(() async {
      if (!Simulator.simulationHasEnded) {
        await Simulator.endSimulation();
      }
      Simulator.reset();
    });
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextNegedge;

    // One frame primes the double buffer.
    for (var i = 0; i < hTotal * vTotal; i++) {
      await clk.nextPosedge;
    }

    final hSyncStart = timing.hActive + timing.hFrontPorch;
    final hSyncEnd = hSyncStart + timing.hSyncWidth;
    final vSyncStart = timing.vActive + timing.vFrontPorch;
    final vSyncEnd = vSyncStart + timing.vSyncWidth;

    final history = <List<int>>[]; // [x, y, pixelWord]
    var active = 0;
    var hsyncAssertedCycles = 0;
    var vsyncAssertedCycles = 0;

    for (var i = 0; i < hTotal * vTotal; i++) {
      await clk.nextNegedge;
      // pclk is forwarded in phase in sim (the default latchEdge == falling,
      // non-inverted), so it reads 0 here, same as the pixel clock itself.
      expect(disp.pclk.value.toInt(), equals(0), reason: 'cycle $i: pclk');

      history.add([
        disp.x.value.toInt(),
        disp.y.value.toInt(),
        disp.pixelWord.value.toInt(),
      ]);

      if (history.length > prgbDelay) {
        final want = history[history.length - 1 - prgbDelay];
        final wx = want[0];
        final wy = want[1];
        final wWord = want[2];

        final expectedDe = wx < timing.hActive && wy < timing.vActive;
        expect(
          disp.de.value.toInt(),
          equals(expectedDe ? 1 : 0),
          reason: 'cycle $i: de at ($wx,$wy)',
        );

        if (expectedDe) {
          final r = (wWord >> 16) & 0xFF;
          final g = (wWord >> 8) & 0xFF;
          final b = wWord & 0xFF;
          final expectedRgb = (r << 16) | (g << 8) | b;
          expect(
            disp.rgb.value.toInt(),
            equals(expectedRgb),
            reason: 'cycle $i: rgb at ($wx,$wy)',
          );
          active++;
        } else {
          expect(
            disp.rgb.value.toInt(),
            equals(0),
            reason: 'cycle $i: rgb blanked at ($wx,$wy)',
          );
        }

        final hsyncRaw = wx >= hSyncStart && wx < hSyncEnd;
        final expectedHsync = timing.hSyncPositive ? hsyncRaw : !hsyncRaw;
        expect(
          disp.hsync.value.toInt(),
          equals(expectedHsync ? 1 : 0),
          reason: 'cycle $i: hsync at x=$wx',
        );
        if (hsyncRaw) hsyncAssertedCycles++;

        final vsyncRaw = wy >= vSyncStart && wy < vSyncEnd;
        final expectedVsync = timing.vSyncPositive ? vsyncRaw : !vsyncRaw;
        expect(
          disp.vsync.value.toInt(),
          equals(expectedVsync ? 1 : 0),
          reason: 'cycle $i: vsync at y=$wy',
        );
        if (vsyncRaw) vsyncAssertedCycles++;
      }
      await clk.nextPosedge;
    }

    expect(
      active,
      equals(timing.hActive * timing.vActive),
      reason: 'every active pixel of a 640x480 frame must have been checked',
    );
    expect(
      hsyncAssertedCycles,
      equals(timing.hSyncWidth * vTotal),
      reason: 'hsync pulse width x one pulse per line',
    );
    expect(
      vsyncAssertedCycles,
      equals(timing.vSyncWidth * hTotal),
      reason: 'vsync pulse width x one pulse per frame, in pixel-clock units',
    );
  });
}

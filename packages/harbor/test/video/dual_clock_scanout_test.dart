import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Tests the dual-clock scanout: the pixel domain drives frameStart/lineStart/
/// col. The system domain bursts lines from a fake memory into the double line
/// buffer. A req/done toggle handshake crosses the two clocks. Fake memory
/// returns address-as-data, so row r column c reads back as fbBase+r*stride+c*4.
void main() {
  test('streams rows across two clocks via the handshake', () async {
    final pixelClk = SimpleClockGenerator(14).clk; // slower pixel clock
    final sysClk = SimpleClockGenerator(6).clk; // faster system/bus clock
    final pixelReset = Logic(name: 'pixel_reset');
    final sysReset = Logic(name: 'sys_reset');
    final frameStart = Logic(name: 'frame_start');
    final lineStart = Logic(name: 'line_start');
    final col = Logic(name: 'col', width: 2);
    final fbBase = Logic(name: 'fb_base', width: 32);
    final stride = Logic(name: 'stride', width: 32);
    final words = Logic(name: 'words', width: 16);

    final mDataIn = Logic(name: 'm_dat_i', width: 32);
    final mAck = Logic(name: 'm_ack');

    final so = HarborDualClockScanout(
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
      frameStart: frameStart,
      lineStart: lineStart,
      col: col,
      fbBase: fbBase,
      stride: stride,
      wordsPerLine: words,
      mDataIn: mDataIn,
      mAck: mAck,
      maxWords: 4,
    );
    // Fake memory on the system side: 0-latency ack, data = address.
    mAck <= so.mStb;
    mDataIn <= so.mAddr;
    await so.build();

    pixelReset.inject(1);
    sysReset.inject(1);
    frameStart.inject(0);
    lineStart.inject(0);
    col.inject(0);
    fbBase.inject(0x100);
    stride.inject(16);
    words.inject(4);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    // Ending and resetting the simulator in a tearDown, rather than inline at
    // the end of the test, avoids leaving stale simulator state for the next
    // test in this file.
    addTearDown(() async {
      if (!Simulator.simulationHasEnded) {
        await Simulator.endSimulation();
      }
      Simulator.reset();
    });
    await pixelClk.nextPosedge;
    await pixelClk.nextPosedge;
    pixelReset.inject(0);
    sysReset.inject(0);
    await pixelClk.nextNegedge;

    Future<void> pix(int n) async {
      for (var i = 0; i < n; i++) {
        await pixelClk.nextPosedge;
      }
      await pixelClk.nextNegedge;
    }

    Future<void> pulse(Logic s) async {
      s.inject(1);
      await pixelClk.nextPosedge;
      s.inject(0);
      await pixelClk.nextNegedge;
    }

    Future<void> expectRow(int row) async {
      for (var c = 0; c < 4; c++) {
        col.inject(c);
        await pixelClk.nextNegedge;
        expect(
          so.pixel.value.toInt(),
          equals(0x100 + row * 16 + c * 4),
          reason: 'row $row col $c',
        );
      }
    }

    await pulse(frameStart);
    await pix(40); // let the system domain prime both line buffers
    await expectRow(0);

    await pulse(lineStart);
    await pix(40);
    await expectRow(1);

    await pulse(lineStart);
    await pix(40);
    await expectRow(2);
  });

  test(
    'svga800x600 rgb565: hActive/2 words per line, stride hActive*2',
    () async {
      const timing = HarborDisplayTiming.svga800x600();
      final wordsPerLine = timing.hActive ~/ 2;
      final stride = timing.hActive * 2;
      expect(wordsPerLine, equals(400));
      expect(stride, equals(1600));

      final pixelClk = SimpleClockGenerator(14).clk;
      final sysClk = SimpleClockGenerator(6).clk;
      final pixelReset = Logic(name: 'pixel_reset');
      final sysReset = Logic(name: 'sys_reset');
      final frameStart = Logic(name: 'frame_start');
      final lineStart = Logic(name: 'line_start');
      final col = Logic(name: 'col', width: 9);
      final fbBase = Logic(name: 'fb_base', width: 32);
      final strideIn = Logic(name: 'stride', width: 32);
      final words = Logic(name: 'words', width: 16);
      final mDataIn = Logic(name: 'm_dat_i', width: 32);
      final mAck = Logic(name: 'm_ack');

      final so = HarborDualClockScanout(
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        sysClk: sysClk,
        sysReset: sysReset,
        frameStart: frameStart,
        lineStart: lineStart,
        col: col,
        fbBase: fbBase,
        stride: strideIn,
        wordsPerLine: words,
        mDataIn: mDataIn,
        mAck: mAck,
        // The burst length (what this test checks) comes from wordsPerLine,
        // not from the buffer's storage size, so a small buffer keeps
        // elaboration cheap here.
        maxWords: 4,
      );
      // Fake memory: 0-latency ack, data unused (only the burst length matters).
      mAck <= so.mStb;
      mDataIn <= so.mAddr;
      await so.build();

      pixelReset.inject(1);
      sysReset.inject(1);
      frameStart.inject(0);
      lineStart.inject(0);
      col.inject(0);
      fbBase.inject(0x1000);
      strideIn.inject(stride);
      words.inject(wordsPerLine);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      addTearDown(() async {
        if (!Simulator.simulationHasEnded) {
          await Simulator.endSimulation();
        }
        Simulator.reset();
      });
      await pixelClk.nextPosedge;
      await pixelClk.nextPosedge;
      pixelReset.inject(0);
      sysReset.inject(0);
      await pixelClk.nextNegedge;

      // Counts the length of the next contiguous m_stb burst on the system
      // clock: one word is transferred per cycle it is high. Bounded so a
      // real regression fails fast instead of hanging.
      Future<int> burstLength() async {
        await sysClk.nextNegedge;
        var waited = 0;
        while (so.mStb.value.toInt() == 0) {
          await sysClk.nextPosedge;
          await sysClk.nextNegedge;
          waited++;
          if (waited > 2 * wordsPerLine) {
            fail('m_stb never went high waiting for the next burst');
          }
        }
        var n = 0;
        while (so.mStb.value.toInt() == 1) {
          n++;
          await sysClk.nextPosedge;
          await sysClk.nextNegedge;
          if (n > 2 * wordsPerLine) {
            fail('m_stb never dropped, burst ran past $n words');
          }
        }
        return n;
      }

      // Lets the done handshake cross back into the pixel domain. A
      // lineStart sent before that is ignored by the scanout.
      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await pixelClk.nextPosedge;
        }
      }

      frameStart.inject(1);
      await pixelClk.nextPosedge;
      frameStart.inject(0);

      // Priming fetches row 0 then row 1 back-to-back.
      expect(await burstLength(), equals(wordsPerLine), reason: 'line 0');
      expect(await burstLength(), equals(wordsPerLine), reason: 'line 1');
      await settle();

      lineStart.inject(1);
      await pixelClk.nextPosedge;
      lineStart.inject(0);
      expect(await burstLength(), equals(wordsPerLine), reason: 'line 2');
    },
  );
}

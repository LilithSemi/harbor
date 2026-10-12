import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../peripherals/sim_dram_ref_model.dart';

/// [HarborSimDram]'s scanout port, through [HarborDualClockDisplay], the
/// same way a [HarborSdram] scanout port is tested in
/// test/video/sdram_scanout_harness.dart. [HarborSimDram] has no ROHD body
/// of its own (only a SystemVerilog string for a Verilator build), so this
/// drives [SimDramRefModel], the plain-Dart twin of that body, instead.
void main() {
  tearDown(() async => Simulator.reset());

  // This caught a HarborScanoutFetcher gap (lib/src/video/line_fetcher.dart):
  // its next_len register lagged req_left by a cycle, so a take right after
  // one that just changed req_left could read a stale next_len and repeat
  // the previous request instead of advancing. The real HarborSdram engine
  // never pulses ready fast enough to hit it; this leaf's ready can. Fixed
  // by deriving next_len from req_left's next value instead.
  test(
    '640x480 32bpp scanout reads the frame the bus wrote, no underrun',
    () async {
      const lines = 3;
      const hActive = 640;
      const stride = 3072;
      const fbBase = 0x10000;
      const timing = HarborDisplayTiming(
        hActive: hActive,
        hFrontPorch: 16,
        hSyncWidth: 96,
        hBackPorch: 48,
        vActive: lines,
        vFrontPorch: 1,
        vSyncWidth: 1,
        vBackPorch: 1,
        pixelClock: 25175000,
      );

      // HarborSimDram's own clk is scan_clk too, and must run at the real
      // controller's mem clock rate (100-125 MHz), not the 25 MHz fabric
      // rate: a 16-bit port can move at most 1 word a cycle, and 640x480
      // 32bpp needs about 1.6 words a cycle at 25 MHz.
      final clk = SimpleClockGenerator(10000).clk; // 100 MHz
      final pixelClk = SimpleClockGenerator(39722).clk;
      final reset = Logic(name: 'reset');
      final pixelReset = Logic(name: 'pixel_reset');
      final enable = Logic(name: 'enable');

      final tCyc = Logic(name: 't_cyc');
      final tWe = Logic(name: 't_we');
      final tAdr = Logic(name: 't_adr', width: 32);
      final tDat = Logic(name: 't_dat', width: 32);

      final scanRqReady = Logic(name: 'scan_rq_ready');
      final scanRdValid = Logic(name: 'scan_rd_valid');
      final scanRdData = Logic(name: 'scan_rd_data', width: 16);

      final display = HarborDualClockDisplay(
        target: const HarborSimTarget(),
        timing: timing,
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        shiftClk: Const(0),
        shiftReset: Const(0),
        sysClk: clk,
        sysReset: reset,
        enable: enable,
        fbBase: Const(fbBase, width: 32),
        rqReady: scanRqReady,
        rdValid: scanRdValid,
        rdData: scanRdData,
        lineStride: stride,
      );

      // display.rqAddr is a byte address; the scanout port's rq_addr is a
      // 16-bit word address, the same shift HarborSdram._scanWordAddr does.
      final scanWordAddr = display.rqAddr.getRange(1, 17);

      final dram = SimDramRefModel(
        clk: clk,
        reset: reset,
        stb: tCyc,
        we: tWe,
        adr: tAdr,
        datW: tDat,
        sel: Const(0xf, width: 4),
        cti: Const(0, width: 3),
        scanRqValid: display.rqValid,
        scanRqAddr: scanWordAddr,
        scanRqWords: display.rqWords,
      );
      scanRqReady <= dram.scanRqReady;
      scanRdValid <= dram.scanRdValid;
      scanRdData <= dram.scanRdData;

      await display.build();

      reset.inject(1);
      pixelReset.inject(1);
      enable.inject(0);
      tCyc.inject(0);
      tWe.inject(0);
      tAdr.inject(0);
      tDat.inject(0);

      Simulator.setMaxSimTime(1 << 50);
      unawaited(Simulator.run());

      for (var i = 0; i < 8; i++) {
        await clk.nextPosedge;
      }
      reset.put(0);
      pixelReset.put(0);
      enable.put(1);

      // Pixels of the frame being scanned, keyed by y * hActive + x.
      final frame = <int, int>{};
      var frames = 0;
      var underrunFrames = 0;
      var underrunCycles = 0;
      var sawUnder = false;
      var prevY = -1;
      final de = display.de;
      final x = display.x;
      final y = display.y;
      final word = display.pixelWord;
      final under = display.underrun;
      pixelClk.posedge.listen((_) {
        if (enable.value != LogicValue.one || !y.value.isValid) return;
        final yv = y.value.toInt();
        if (de.value == LogicValue.one) {
          frame[yv * hActive + x.value.toInt()] = word.value.isValid
              ? word.value.toInt()
              : -1;
        }
        if (under.value == LogicValue.one) {
          sawUnder = true;
          underrunCycles++;
        }
        if (prevY == lines - 1 && yv == lines) {
          frames++;
          if (sawUnder && frames > 1) underrunFrames++;
          sawUnder = false;
        }
        prevY = yv;
      });

      // Cycles the line fetcher stays busy on each line, on the mem clock,
      // to turn into a worst-line MB/s number the same way
      // test/video/sdram_scanout_harness.dart does.
      Iterable<Module> all(Module m) sync* {
        yield m;
        for (final s in m.subModules) {
          yield* all(s);
        }
      }

      final fetchBusy = all(
        display,
      ).whereType<HarborScanoutFetcher>().single.output('busy');
      final lineCycles = <int>[];
      var busyFor = 0;
      clk.posedge.listen((_) {
        if (fetchBusy.value == LogicValue.one) {
          busyFor++;
        } else if (busyFor > 0) {
          lineCycles.add(busyFor);
          busyFor = 0;
        }
      });

      Future<void> waitFrames(int n) async {
        final target = frames + n;
        while (frames < target) {
          await pixelClk.nextPosedge;
        }
      }

      int pixelAddr(int px, int py) => fbBase + py * stride + px * 4;

      // Fill the frame over the bus while the display is already scanning.
      await waitFrames(1);
      var accesses = 0;
      for (var py = 0; py < lines; py++) {
        for (var px = 0; px < hActive; px++) {
          final addr = pixelAddr(px, py);
          final data = (py << 16) | px | 0x5a000000;
          tAdr.inject(addr);
          tDat.inject(data);
          tWe.inject(1);
          tCyc.inject(1);
          var waited = 0;
          while (dram.ack.value != LogicValue.one) {
            await clk.nextPosedge;
            waited++;
            if (waited > 1000) {
              fail('no ack at 0x${addr.toRadixString(16)} after 1000 cycles');
            }
          }
          tCyc.inject(0);
          tWe.inject(0);
          accesses++;
          await clk.nextPosedge;
        }
      }

      List<String> frameErrors() {
        final bad = <String>[];
        for (var py = 0; py < lines; py++) {
          for (var px = 0; px < hActive; px++) {
            final want = (py << 16) | px | 0x5a000000;
            final got = frame[py * hActive + px];
            if (got != want && bad.length < 8) {
              bad.add(
                '($px,$py) got 0x${got?.toRadixString(16)} '
                'want 0x${want.toRadixString(16)}',
              );
            }
          }
        }
        return bad;
      }

      // At least 2 more full frames after the fill, matching every row.
      await waitFrames(2);
      final afterFillBad = frameErrors();
      await waitFrames(1);
      final laterBad = frameErrors();

      const memHz = 100000000; // matches the 10000 ps clk period above.
      final worst = lineCycles.isEmpty ? 0 : lineCycles.reduce(max);
      final mb = worst == 0 ? 0.0 : hActive * 4 * memHz / worst / 1e6;
      print(
        '${mb.toStringAsFixed(1)} MB/s worst line, '
        'underrun frames $underrunFrames, underrun cycles $underrunCycles',
      );

      expect(accesses, equals(lines * hActive));
      expect(afterFillBad, isEmpty, reason: 'frame 1 after fill: $afterFillBad');
      expect(laterBad, isEmpty, reason: 'frame 2 after fill: $laterBad');
      expect(underrunFrames, equals(0));
      expect(frames, greaterThanOrEqualTo(3));

      await Simulator.endSimulation();
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

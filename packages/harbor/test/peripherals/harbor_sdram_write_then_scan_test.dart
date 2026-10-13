import 'dart:collection';
import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_wb_stack.dart';

/// A bus write is done when it is acked. A scanout read of the same
/// address sent in the cycle after the ack must return the new data, even
/// while other scanout reads keep the arbiter busy.
void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test(
    '100 MHz: a scanout read right after a bus write ack sees the write',
    () async {
      final s = SdramWbStack(
        sysClockHz: 100000000,
        memClockHz: 100000000,
        busClockSync: true,
        scanoutPorts: 1,
      );
      await s.start();
      final clk = s.memClk;
      final rng = Random(11);

      // Scanout requests in send order, the probe first when there is one.
      final fill = Queue<(int, int)>();
      (int, int)? probe;
      final sent = Queue<(int, int, bool)>();
      final words = <int>[];
      final probeData = <int>[];
      var stop = false;

      // Everything on the negedge: the port outputs are registers, so they
      // hold their value for the whole cycle.
      clk.negedge.listen((_) {
        final sd = s.sdram;
        if (sd.output('scan0_rd_valid').value == LogicValue.one) {
          words.add(sd.output('scan0_rd_data').value.toInt());
          final (_, n, isProbe) = sent.first;
          if (words.length == n) {
            if (isProbe) probeData.add(words[0] | (words[1] << 16));
            sent.removeFirst();
            words.clear();
          }
        }
        if (!stop && fill.length < 4) {
          // Other rows of every bank, so the fill reads miss and run long.
          final row = 100 + rng.nextInt(50);
          final bank = rng.nextInt(4);
          final wordAddr = ((row << 2 | bank) << 9) | 8 * rng.nextInt(64);
          fill.add((2 * wordAddr, 8));
        }
        final p = probe;
        final head = p ?? (fill.isEmpty ? null : fill.first);
        s.scanRqValid.put(head == null ? 0 : 1);
        if (head == null) return;
        s.scanRqAddr.put(head.$1);
        s.scanRqWords.put(head.$2);
        // The take happens on the next posedge.
        if (sd.output('scan0_rq_ready').value != LogicValue.one) return;
        if (p != null) {
          sent.add((p.$1, p.$2, true));
          probe = null;
        } else {
          final f = fill.removeFirst();
          sent.add((f.$1, f.$2, false));
        }
      });

      final want = <int>[];
      for (var i = 0; i < 40; i++) {
        final addr = 0x400 * i + 4 * rng.nextInt(16);
        final data = rng.nextInt(1 << 32);
        // Write, and on the ack edge put the probe on the scanout port.
        s.drive(byteAddr: addr, write: true, data: data);
        await clk.nextPosedge;
        for (
          var n = 0;
          s.sdram.output('bus_ACK').value != LogicValue.one;
          n++
        ) {
          if (n > 20000) throw StateError('no ack at byte address $addr');
          await clk.nextPosedge;
        }
        probe = (addr, 2);
        s.cyc.inject(0);
        s.we.inject(0);
        want.add(data);
        for (var n = 0; probe != null || sent.any((e) => e.$3); n++) {
          if (n > 20000) throw StateError('no scan read at byte address $addr');
          await clk.nextPosedge;
        }
        for (var k = rng.nextInt(20); k > 0; k--) {
          await clk.nextPosedge;
        }
      }
      stop = true;
      expect(probeData, equals(want));
      expect(s.errors, isEmpty);
      await s.stop();
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_rw_test.dart' show sdramAddr;
import 'sdram_engine_stack.dart';
import 'sdram_pin_model.dart';

/// Measures command spacing on the sdram pins and checks that each rule
/// gives exactly its minimum cycle count. The pin model catches anything
/// shorter.
void main() {
  tearDown(() async => Simulator.reset());

  for (final clockHz in [100000000, 125000000]) {
    test('${clockHz ~/ 1000000} MHz: minimum command spacing', () async {
      final s = SdramEngineStack(clockHz: clockHz, maxGrantWords: 16);
      await s.start();
      await s.idle(200);
      final c = s.cycles;

      var start = s.model.log.length;
      Future<List<SdramModelCommand>> run(void Function() queue) async {
        start = s.model.log.length;
        queue();
        await s.drain();
        // The last command reaches the pins a few cycles after it is taken.
        await s.idle(4);
        return s.model.log.sublist(start);
      }

      int gap(SdramModelCommand a, SdramModelCommand b) =>
          ((b.timePs - a.timePs) / s.periodPs).round();
      List<SdramModelCommand> kind(List<SdramModelCommand> l, String k) => [
        for (final x in l)
          if (x.kind == k) x,
      ];

      // Two cold banks: rcd to the first read, then 8 cycles between the
      // two 8-beat reads. The second activate gets rrd when rcd is longer.
      // When they are equal, the first read takes that cycle.
      var log = await run(() {
        s.read(sdramAddr(s, 0, 100, 0), 16);
        s.read(sdramAddr(s, 1, 100, 0), 1);
      });
      var acts = kind(log, 'activate');
      var reads = kind(log, 'read');
      expect(
        gap(acts[0], acts[1]),
        c.rcd > c.rrd ? c.rrd : c.rrd + 1,
        reason: 'rrd',
      );
      expect(gap(acts[0], reads[0]), c.rcd, reason: 'rcd read');
      expect(gap(reads[0], reads[1]), 8, reason: '8-beat read spacing');

      // Two 1-beat reads from one request.
      log = await run(() => s.read(sdramAddr(s, 0, 100, 7), 2));
      reads = kind(log, 'read');
      expect(gap(reads[0], reads[1]), 1, reason: '1-beat read spacing');

      // Read to write turnaround, for 1 and 8 beats.
      for (final n in [1, 8]) {
        log = await run(() {
          s.read(sdramAddr(s, 0, 100, 16), n);
          s.write(sdramAddr(s, 0, 100, 40), [0x1234, 0x5678]);
        });
        final r = kind(log, 'read').last;
        final w = kind(log, 'write');
        expect(gap(r, w[0]), c.readToWrite(n), reason: 'read $n to write');
        expect(gap(w[0], w[1]), 1, reason: 'write to write');
      }

      // Write, then a row conflict on the same bank: wr, then rp.
      log = await run(() {
        s.write(sdramAddr(s, 0, 100, 48), [1]);
        s.read(sdramAddr(s, 0, 200, 0), 1);
      });
      final w = kind(log, 'write').last;
      final pre = kind(log, 'precharge').single;
      acts = kind(log, 'activate');
      expect(gap(w, pre), c.wr, reason: 'wr');
      expect(gap(pre, acts.single), c.rp, reason: 'rp');
      expect(gap(acts.single, kind(log, 'read').single), c.rcd, reason: 'rcd');

      // rcd for a write on a cold bank.
      log = await run(() => s.write(sdramAddr(s, 2, 5, 0), [7]));
      expect(
        gap(kind(log, 'activate').single, kind(log, 'write').single),
        c.rcd,
        reason: 'rcd write',
      );

      await s.idle(20);
      await s.stop();
      expect(s.errors, isEmpty);
    });
  }
}

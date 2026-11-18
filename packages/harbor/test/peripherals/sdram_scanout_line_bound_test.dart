import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// Streams [lines] lines of [lineWords] words on realtime port 1, as a
/// scanout port does with 3 in flight, and returns the cycles of each line
/// from its first request to its last word, and the refresh credit at each
/// line start. Port 0 is idle. With [gap] the engine idles between lines.
Future<({List<int> cycles, List<int> owed, SdramEngineStack stack})> _stream(
  int clockHz,
  int lines,
  int lineWords, {
  int gap = 0,
}) async {
  final s = SdramEngineStack(
    clockHz: clockHz,
    ports: 2,
    portRealtime: const [false, true],
  );
  await s.start();
  final c = s.config;
  int addrOf(int row, int bank, int col) =>
      (((row << c.bankBits) | bank) << c.colWidth) | col;
  final cycles = <int>[];
  final owed = <int>[];
  var row = 8;
  for (var line = 0; line < lines; line++) {
    // A line starts on a new row, as the stride of a scanout makes it.
    var next = addrOf(row, 0, 0);
    row += 2;
    final o = s.top.engine.refreshOwed;
    owed.add(o.value.toInt().toSigned(o.width));
    final start = s.cycle;
    for (var r = 0; r < lineWords ~/ 8; r++) {
      while (s.pendingReads(1) >= 3) {
        await s.clk.nextPosedge;
      }
      s.read(next, 8, port: 1);
      next += 8;
      await s.clk.nextPosedge;
    }
    while (s.pendingReads(1) > 0) {
      await s.clk.nextPosedge;
    }
    cycles.add(s.cycle - start);
    if (gap > 0) await s.idle(gap);
  }
  await s.stop();
  return (cycles: cycles, owed: owed, stack: s);
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final hz in [25000000, 100000000, 125000000]) {
    final mhz = hz ~/ 1000000;
    test('$mhz MHz: a line on the scanout port alone stays inside the stream '
        'bound', () async {
      final r = await _stream(hz, 6, 640, gap: 40);
      final s = r.stack;
      final stream = HarborSdram.scanoutStreamBound(s.cycles, s.config, 640);
      print('$mhz MHz: line ${r.cycles} cycles, stream bound $stream');
      for (final t in r.cycles.skip(1)) {
        expect(t, greaterThanOrEqualTo(640));
        expect(t, lessThanOrEqualTo(stream));
      }
      expect(s.errors, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }

  // Lines back to back keep the engine busy, so refreshes fall due in
  // bursts. The next line starts while the last requests of the line before
  // are still in flight, so nothing drains at a line start. Each line may
  // take longer than the stream alone by the refreshes inside its window,
  // each [HarborSdram.scanoutRefreshCost], and no more.
  test(
    '25 MHz CL2: a line is the stream plus the cost of its refreshes',
    () async {
      final s = SdramEngineStack(
        clockHz: 25000000,
        ports: 2,
        portRealtime: const [false, true],
      );
      await s.start();
      final c = s.config;
      int addrOf(int row, int bank, int col) =>
          (((row << c.bankBits) | bank) << c.colWidth) | col;
      const lines = 40;
      const perLine = 80;
      final starts = <int>[];
      final ends = <int>[];
      var submitted = 0;
      var row = 8;
      var next = addrOf(row, 0, 0);
      final o = s.top.engine.refreshOwed;
      var maxOwed = 0;
      while (ends.length < lines) {
        if (submitted < lines * perLine && s.pendingReads(1) < 3) {
          if (submitted % perLine == 0) {
            // A line starts on a new row, as the stride of a scanout makes it.
            row += 2;
            next = addrOf(row, 0, 0);
            starts.add(Simulator.time);
            final v = o.value.toInt().toSigned(o.width);
            if (v > maxOwed) maxOwed = v;
          }
          s.read(next, 8, port: 1);
          next += 8;
          submitted++;
        }
        await s.clk.nextPosedge;
        final done = submitted - s.pendingReads(1);
        while (ends.length < lines && done >= (ends.length + 1) * perLine) {
          ends.add(Simulator.time);
        }
      }
      await s.stop();

      final periodPs = 1000000000000 ~/ 25000000;
      final stream = HarborSdram.scanoutStreamBound(s.cycles, s.config, 640);
      final cost = HarborSdram.scanoutRefreshCost(s.cycles);
      final refreshes = s.model.refreshTimesPs;
      var most = 0;
      var worst = 0;
      for (var i = 0; i < lines; i++) {
        final n = refreshes.where((t) => t >= starts[i] && t < ends[i]).length;
        final cycles = (ends[i] - starts[i]) ~/ periodPs;
        if (n > most) most = n;
        if (cycles > worst) worst = cycles;
        expect(cycles - stream, lessThanOrEqualTo(n * cost), reason: 'line $i');
      }
      final bound = HarborSdram.scanoutLineBound(
        s.cycles,
        s.config,
        640,
        periodCycles: 800,
      );
      print(
        'owed at line start up to $maxOwed of ${s.cycles.maxPostponed}, most '
        'refreshes in a line $most, worst line $worst, stream $stream, '
        'bound $bound',
      );
      expect(most, greaterThanOrEqualTo(3));
      expect(worst, lessThanOrEqualTo(bound));
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

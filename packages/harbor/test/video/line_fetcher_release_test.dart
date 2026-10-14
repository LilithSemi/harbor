import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Runs one 40-word line over a Wishbone memory master port, from a slave
/// that acks [latency] cycles after the strobe. Returns the lengths of the
/// `cyc` low gaps inside the line and the words written to the line buffer,
/// keyed by index.
Future<(List<int>, Map<int, int>)> _line({
  required int burstWords,
  required int latency,
}) async {
  const words = 40;
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
  final start = Logic()..inject(0);
  const config = HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32);
  final waist = HarborMemoryWaist(config);
  final f = HarborLineFetcher(
    clk: clk,
    reset: reset,
    fetchStart: start,
    fetchAddr: Const(0x1000, width: 32),
    words: Const(words, width: 16),
    fillSel: Const(0),
    waist: waist,
    maxWords: 64,
    burstWords: burstWords,
  );
  // Flops hold what the write port showed at each edge.
  final wrEn = flop(clk, f.wrEn);
  final wrIdx = flop(clk, f.wrIdx);
  final wrData = flop(clk, f.wrData);
  await f.build();

  final wb = WishboneInterface(harborWishboneMemoryConfig(config));
  final master = HarborWishboneMemoryMaster(
    clk: clk,
    reset: reset,
    waist: waist,
    wb: wb,
  );
  await master.build();
  var waited = 0;
  // Slave: ack once the strobe has waited for the latency.
  clk.negedge.listen((_) {
    final stb = wb.stb.value == LogicValue.one;
    final ackNow = stb && wb.ack.value != LogicValue.one && ++waited >= latency;
    if (!stb || ackNow) waited = 0;
    wb.ack.inject(ackNow ? 1 : 0);
    wb.datMiso.inject(wb.adr.value);
  });
  wb.err!.inject(0);

  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());

  await clk.nextPosedge;
  reset.inject(0);
  await clk.nextNegedge;
  start.inject(1);
  await clk.nextNegedge;
  start.inject(0);

  final gaps = <int>[];
  final written = <int, int>{};
  var gap = 0;
  for (var n = 0; n < 4000 && f.done.value != LogicValue.one; n++) {
    await clk.nextPosedge;
    await clk.nextNegedge;
    if (wrEn.value == LogicValue.one) {
      written[wrIdx.value.toInt()] = wrData.value.toInt();
    }
    if (f.busy.value == LogicValue.one && wb.cyc.value != LogicValue.one) {
      gap++;
    } else if (gap > 0) {
      gaps.add(gap);
      gap = 0;
    }
  }
  expect(f.done.value, LogicValue.one, reason: 'the line did not finish');
  await Simulator.endSimulation();
  return (gaps, written);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final latency in [0, 1, 10]) {
    test('gives the bus back between every burstWords-chunk of words, '
        'latency $latency', () async {
      final (gaps, written) = await _line(burstWords: 16, latency: latency);
      // A 40-word line is bursts of 16, 16 and 8 words, with one `cyc` drop
      // between each pair.
      expect(gaps, equals([1, 1]));
      expect(written.length, equals(40));
      for (var i = 0; i < 40; i++) {
        expect(written[i], equals(0x1000 + i * 4), reason: 'word $i');
      }
    });
  }

  test('a burst as long as the line never drops cyc inside it', () async {
    final (gaps, written) = await _line(burstWords: 64, latency: 3);
    // One request, one burst, no inter-burst boundary: no gap at all.
    expect(gaps, equals(<int>[]));
    expect(written.length, equals(40));
  });

  test('burstWords below 1 throws', () {
    expect(
      () => HarborLineFetcher(
        clk: Logic(),
        reset: Logic(),
        fetchStart: Logic(),
        fetchAddr: Logic(width: 32),
        words: Logic(width: 16),
        fillSel: Logic(),
        waist: HarborMemoryWaist(
          const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
        ),
        burstWords: 0,
      ),
      throwsArgumentError,
    );
  });

  test('burstWords above 256 throws', () {
    expect(
      () => HarborLineFetcher(
        clk: Logic(),
        reset: Logic(),
        fetchStart: Logic(),
        fetchAddr: Logic(width: 32),
        words: Logic(width: 16),
        fillSel: Logic(),
        waist: HarborMemoryWaist(
          const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
        ),
        burstWords: 257,
      ),
      throwsArgumentError,
    );
  });

  test('a non-32-bit waist throws', () {
    expect(
      () => HarborLineFetcher(
        clk: Logic(),
        reset: Logic(),
        fetchStart: Logic(),
        fetchAddr: Logic(width: 32),
        words: Logic(width: 16),
        fillSel: Logic(),
        waist: HarborMemoryWaist(
          const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 16),
        ),
      ),
      throwsArgumentError,
    );
  });
}

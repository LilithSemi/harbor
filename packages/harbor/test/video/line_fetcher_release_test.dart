import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Runs one 40-word line from a slave that acks [latency] cycles after the
/// strobe. Returns the lengths of the `cyc` low gaps inside the line and the
/// words written to the line buffer, keyed by index.
Future<(List<int>, Map<int, int>)> _line({
  required int burstWords,
  required int latency,
}) async {
  const words = 40;
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic()..inject(1);
  final start = Logic()..inject(0);
  final ack = Logic()..inject(0);
  final data = Logic(width: 32)..inject(0);
  final f = HarborLineFetcher(
    clk: clk,
    reset: reset,
    fetchStart: start,
    fetchAddr: Const(0x1000, width: 32),
    words: Const(words, width: 16),
    fillSel: Const(0),
    mDataIn: data,
    mAck: ack,
    maxWords: 64,
    burstWords: burstWords,
  );
  // Flops hold what the write port showed at each edge.
  final wrEn = flop(clk, f.wrEn);
  final wrIdx = flop(clk, f.wrIdx);
  final wrData = flop(clk, f.wrData);
  await f.build();
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
  var waited = 0;
  for (var n = 0; n < 4000 && f.done.value != LogicValue.one; n++) {
    // Slave: ack once the strobe has waited for the latency.
    final stb = f.mStb.value == LogicValue.one;
    final ackNow = stb && ack.value != LogicValue.one && ++waited >= latency;
    if (!stb || ackNow) waited = 0;
    ack.inject(ackNow ? 1 : 0);
    data.inject(f.mAddr.value);
    await clk.nextPosedge;
    await clk.nextNegedge;
    if (wrEn.value == LogicValue.one) {
      written[wrIdx.value.toInt()] = wrData.value.toInt();
    }
    if (f.busy.value == LogicValue.one && f.mCyc.value != LogicValue.one) {
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

  for (final latency in [1, 10]) {
    test('gives the bus back for one cycle after every 16 words, '
        'latency $latency', () async {
      final (gaps, written) = await _line(burstWords: 16, latency: latency);
      // A 40-word line yields after words 16 and 32.
      expect(gaps, equals([1, 1]));
      expect(written.length, equals(40));
      for (var i = 0; i < 40; i++) {
        expect(written[i], equals(0x1000 + i * 4), reason: 'word $i');
      }
    });
  }

  test('a burst as long as the line never drops cyc inside it', () async {
    final (gaps, written) = await _line(burstWords: 64, latency: 3);
    expect(gaps, isEmpty);
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
        mDataIn: Logic(width: 32),
        mAck: Logic(),
        burstWords: 0,
      ),
      throwsArgumentError,
    );
  });
}

/// Random push and pop through [HarborCdcFifo] on two free-running clocks.
///
/// Each run checks the order and count of the words, and that the flags never
/// lie: a push the FIFO takes never overruns it, and a word the FIFO shows is
/// always a word the writer committed. Other runs gate the writer on
/// `wr_almost_full` only, or release the two resets at different times.
library;

import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _ecp5 = HarborFpgaTarget.ecp5(device: 'lfe5u-25f', package: 'CABGA381');

Future<void> _run({
  required int wrPeriod,
  required int rdPeriod,
  required int depth,
  required int items,
  required int seed,
  bool blockRam = false,
  bool almostFullGated = false,
  int wrResetDelay = 0,
  int rdResetDelay = 0,
}) async {
  const dw = 16;
  final fifo = HarborCdcFifo(
    dataWidth: dw,
    depth: depth,
    target: blockRam ? _ecp5 : null,
    blockRam: blockRam,
    name: 'fifo_rand',
  );
  final wrClk = SimpleClockGenerator(wrPeriod).clk;
  final rdClk = SimpleClockGenerator(rdPeriod).clk;
  final wrReset = Logic(name: 'wr_reset_in');
  final rdReset = Logic(name: 'rd_reset_in');
  final wrData = Logic(name: 'wr_data_in', width: dw);
  final wrEn = Logic(name: 'wr_en_in');
  final rdEn = Logic(name: 'rd_en_in');
  fifo.input('wr_clk').srcConnection! <= wrClk;
  fifo.input('wr_reset').srcConnection! <= wrReset;
  fifo.input('wr_data').srcConnection! <= wrData;
  fifo.input('wr_en').srcConnection! <= wrEn;
  fifo.input('rd_clk').srcConnection! <= rdClk;
  fifo.input('rd_reset').srcConnection! <= rdReset;
  fifo.input('rd_en').srcConnection! <= rdEn;
  await fifo.build();

  Simulator.setMaxSimTime(items * (wrPeriod + rdPeriod) * 40 + 100000);
  unawaited(Simulator.run());

  wrReset.inject(1);
  rdReset.inject(1);
  wrData.inject(0);
  wrEn.inject(0);
  rdEn.inject(0);
  for (var i = 0; i < 4; i++) {
    await wrClk.nextPosedge;
    await rdClk.nextPosedge;
  }

  // Each side releases its reset after its own delay, so one side can run
  // while the other is still in reset.
  Future<void> release(Logic reset, Logic clk, int delay) async {
    for (var i = 0; i < delay; i++) {
      await clk.nextPosedge;
    }
    await clk.nextNegedge;
    reset.inject(0);
  }

  final rng = Random(seed);
  // Words the writer committed, in order. The reader takes from the front.
  final model = <int>[];
  var pushed = 0;
  var popped = 0;
  final errors = <String>[];

  // Inputs change on the falling edge and the flops take them on the rising
  // edge. The flags are flops of their own domain, so they are stable there.
  Future<void> writer() async {
    await release(wrReset, wrClk, wrResetDelay);
    final pushRate = 0.5 + rng.nextDouble() * 0.5;
    while (pushed < items && errors.isEmpty) {
      await wrClk.nextNegedge;
      final full = fifo.output('wr_full').value.toInt() == 1;
      var want = rng.nextDouble() < pushRate;
      if (almostFullGated) {
        // A producer that trusts `wr_almost_full` alone must never meet full.
        want = want && fifo.output('wr_almost_full').value.toInt() == 0;
        if (want && full) {
          errors.add('push $pushed dropped: full but not almost full');
        }
      }
      final value = pushed & 0xffff;
      wrData.inject(value);
      wrEn.inject(want ? 1 : 0);
      final take = want && !full;
      // The FIFO can only see pops that are older than this edge, so the
      // count of pops here is a safe lower bound.
      if (take && pushed - popped >= depth) {
        errors.add('push $pushed taken while full (${pushed - popped} held)');
      }
      await wrClk.nextPosedge;
      if (take) {
        model.add(value);
        pushed++;
      }
    }
    await wrClk.nextNegedge;
    wrEn.inject(0);
  }

  Future<void> reader() async {
    await release(rdReset, rdClk, rdResetDelay);
    final popRate = 0.5 + rng.nextDouble() * 0.5;
    var idle = 0;
    while (popped < items && errors.isEmpty) {
      await rdClk.nextNegedge;
      final empty = fifo.output('rd_empty').value.toInt() == 1;
      final want = rng.nextDouble() < popRate;
      rdEn.inject(want ? 1 : 0);
      if (!empty) {
        idle = 0;
        if (model.isEmpty) {
          errors.add('rd_empty low with no word committed (pop $popped)');
          break;
        }
        final d = fifo.output('rd_data').value;
        if (!d.isValid || d.toInt() != model.first) {
          errors.add('pop $popped got $d, want ${model.first}');
          break;
        }
      } else if (model.isNotEmpty && ++idle > 64) {
        errors.add('rd_empty stuck high with ${model.length} words held');
        break;
      }
      await rdClk.nextPosedge;
      if (want && !empty) {
        model.removeAt(0);
        popped++;
      }
    }
    await rdClk.nextNegedge;
    rdEn.inject(0);
  }

  await Future.wait([writer(), reader()]);
  await Simulator.endSimulation();

  expect(errors, isEmpty);
  expect(pushed, items);
  expect(popped, items);
  expect(model, isEmpty);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const ratios = [(10, 10), (10, 14), (14, 10), (10, 26), (26, 10)];

  group('HarborCdcFifo async random traffic', () {
    for (final (wr, rd) in ratios) {
      for (final depth in [2, 8]) {
        test('flops wr $wr rd $rd depth $depth', () async {
          await _run(
            wrPeriod: wr,
            rdPeriod: rd,
            depth: depth,
            items: 2000,
            seed: wr * 1000 + rd * 10 + depth,
          );
        });
      }
      test('almost full gated wr $wr rd $rd depth 4', () async {
        await _run(
          wrPeriod: wr,
          rdPeriod: rd,
          depth: 4,
          items: 2000,
          seed: wr * 1000 + rd * 10 + 7,
          almostFullGated: true,
        );
      });
      test('block RAM wr $wr rd $rd depth 16', () async {
        await _run(
          wrPeriod: wr,
          rdPeriod: rd,
          depth: 16,
          items: 2000,
          seed: wr * 1000 + rd,
          blockRam: true,
        );
      });
    }
  });

  group('HarborCdcFifo staggered reset release', () {
    for (final (wrDelay, rdDelay) in [(0, 37), (37, 0)]) {
      test('wr after $wrDelay, rd after $rdDelay', () async {
        await _run(
          wrPeriod: 10,
          rdPeriod: 14,
          depth: 4,
          items: 1000,
          seed: wrDelay + rdDelay,
          wrResetDelay: wrDelay,
          rdResetDelay: rdDelay,
        );
      });
    }
  });

  test('gray pointers that cross domains are flops', () async {
    final fifo = HarborCdcFifo(dataWidth: 8, depth: 4, name: 'fifo_gray');
    await fifo.build();
    final sv = fifo.generateSynth();
    // A gray pointer made from logic can glitch through codes that are more
    // than one step away while the other domain samples it.
    for (final name in ['wr_ptr_gray', 'rd_ptr_gray']) {
      expect(
        RegExp('assign\\s+$name\\s*=').hasMatch(sv),
        isFalse,
        reason: '$name must come from a flop',
      );
    }
    // The flags come from flops, so no compare drives them.
    for (final name in ['wr_full', 'rd_empty']) {
      final line = RegExp('assign\\s+$name\\s*=[^;]*;').firstMatch(sv);
      expect(line?.group(0) ?? '', isNot(contains('==')), reason: name);
    }
  });

  test('wishbone CDC gray counters and head_we are flops', () async {
    final gray = HarborWishboneCdcBridge(addressWidth: 8, dataWidth: 32);
    await gray.build();
    final fifo = HarborWishboneCdcFifoBridge(
      addressWidth: 8,
      dataWidth: 32,
      postedWrites: true,
    );
    await fifo.build();
    final sv = gray.generateSynth() + fifo.generateSynth();
    for (final name in ['req_gray', 'done_gray', 'head_we']) {
      expect(sv, contains(name));
      expect(
        RegExp('assign\\s+$name\\s*=').hasMatch(sv),
        isFalse,
        reason: '$name must come from a flop',
      );
    }
  });
}

/// Tests of the BLOCK RAM storage path of [HarborCdcFifo] (`blockRam: true`).
///
/// The geometry is the one that motivated the path: 32 bits by 128 entries,
/// which is exactly one ECP5 DP16KD. The two clocks are asynchronous and not
/// harmonic (10 and 14 time units, a 5:7 ratio), so no edge of one domain has a
/// fixed relation to an edge of the other.
///
/// A block RAM read port is SYNCHRONOUS, so this path holds the head word in a
/// pre-fetch register. Every test here therefore also checks the EXTERNAL
/// contract of the flop path: `rd_data` holds the head word in the SAME cycle
/// that `rd_empty` is low.
library;

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// A built FIFO and everything needed to drive it.
class _Harness {
  final HarborCdcFifo fifo;
  final Logic wrClk;

  /// The free-running read clock, before the stop gate.
  final Logic rdClkFree;

  /// Read clock gate. Inject 0 to STOP the read clock, 1 to start it again.
  final Logic rdRun;
  final Logic reset;
  final Logic wrData;
  final Logic wrEn;
  final Logic rdEn;

  _Harness({
    required this.fifo,
    required this.wrClk,
    required this.rdClkFree,
    required this.rdRun,
    required this.reset,
    required this.wrData,
    required this.wrEn,
    required this.rdEn,
  });

  /// True while the FIFO holds a word for the consumer.
  bool get hasData => fifo.output('rd_empty').value.toInt() == 0;

  /// True when the write side refuses another push.
  bool get isFull => fifo.output('wr_full').value.toInt() == 1;

  /// The head word. Fails when any bit is X, so a torn or unwritten entry
  /// cannot pass as data.
  int readHead(String where) {
    final d = fifo.output('rd_data').value;
    expect(d.isValid, isTrue, reason: 'rd_data has no X at $where');
    return d.toInt();
  }
}

Future<_Harness> _build({
  int dataWidth = 32,
  int depth = 128,
  bool blockRam = true,
  int wrPeriod = 10,
  int rdPeriod = 14,
}) async {
  const target = HarborFpgaTarget.ecp5(
    device: 'lfe5u-25f',
    package: 'CABGA381',
  );
  final fifo = HarborCdcFifo(
    dataWidth: dataWidth,
    depth: depth,
    target: target,
    blockRam: blockRam,
    name: 'fifo_bram',
  );
  final wrClk = SimpleClockGenerator(wrPeriod).clk;
  final rdClkFree = SimpleClockGenerator(rdPeriod).clk;
  final rdRun = Logic(name: 'rd_run');
  // Gated read clock. The gate only ever changes while the free clock is low
  // (see [_stopReadClock]), so stopping or starting it makes no runt pulse.
  final rdClk = (rdClkFree & rdRun).named('rd_clk_gated');
  final reset = Logic(name: 'reset_bram');
  final wrData = Logic(name: 'wr_data_bram', width: dataWidth);
  final wrEn = Logic(name: 'wr_en_bram');
  final rdEn = Logic(name: 'rd_en_bram');

  fifo.input('wr_clk').srcConnection! <= wrClk;
  fifo.input('wr_reset').srcConnection! <= reset;
  fifo.input('wr_data').srcConnection! <= wrData;
  fifo.input('wr_en').srcConnection! <= wrEn;
  fifo.input('rd_clk').srcConnection! <= rdClk;
  fifo.input('rd_reset').srcConnection! <= reset;
  fifo.input('rd_en').srcConnection! <= rdEn;

  await fifo.build();

  return _Harness(
    fifo: fifo,
    wrClk: wrClk,
    rdClkFree: rdClkFree,
    rdRun: rdRun,
    reset: reset,
    wrData: wrData,
    wrEn: wrEn,
    rdEn: rdEn,
  );
}

/// Holds reset over several edges of BOTH clocks, then releases it.
Future<void> _resetSequence(_Harness h) async {
  h.reset.inject(1);
  h.rdRun.inject(1);
  h.wrData.inject(0);
  h.wrEn.inject(0);
  h.rdEn.inject(0);
  for (var i = 0; i < 4; i++) {
    await h.rdClkFree.nextPosedge;
  }
  h.reset.inject(0);
  for (var i = 0; i < 2; i++) {
    await h.wrClk.nextPosedge;
  }
}

/// Stops or starts the read clock. The gate changes while the free clock is
/// low, so the gated clock never makes a partial pulse.
Future<void> _setReadClock(_Harness h, {required bool running}) async {
  await h.rdClkFree.nextNegedge;
  h.rdRun.inject(running ? 1 : 0);
}

/// Pushes one word. Returns true when the FIFO took it.
Future<bool> _push(_Harness h, int value) async {
  final full = h.isFull;
  h.wrData.inject(value);
  h.wrEn.inject(full ? 0 : 1);
  await h.wrClk.nextPosedge;
  h.wrEn.inject(0);
  return !full;
}

/// Drains up to [count] words, and stops early after [maxCycles] read cycles.
/// Checks the same-cycle contract on every word: `rd_data` is read in the SAME
/// cycle that `rd_empty` is low, before `rd_en` goes high.
Future<List<int>> _drain(
  _Harness h,
  int count, {
  int maxCycles = 4000,
  String where = 'drain',
}) async {
  final got = <int>[];
  var cycles = 0;
  while (got.length < count && cycles < maxCycles) {
    cycles++;
    if (h.hasData) {
      got.add(h.readHead('$where word ${got.length}'));
      h.rdEn.inject(1);
      await h.rdClkFree.nextPosedge;
      h.rdEn.inject(0);
    } else {
      await h.rdClkFree.nextPosedge;
    }
  }
  return got;
}

/// Emits the SystemVerilog of a built FIFO. It runs the Simulator over a few
/// edges first, then ends it, so the clock streams of the built module close in
/// the order that ROHD expects.
Future<String> _emit(_Harness h) async {
  Simulator.setMaxSimTime(10000);
  unawaited(Simulator.run());
  h.reset.inject(1);
  h.rdRun.inject(1);
  h.wrData.inject(0);
  h.wrEn.inject(0);
  h.rdEn.inject(0);
  await h.wrClk.nextPosedge;
  final sv = h.fifo.generateSynth();
  await Simulator.endSimulation();
  return sv;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborCdcFifo block RAM selection', () {
    const ecp5 = HarborFpgaTarget.ecp5(
      device: 'lfe5u-25f',
      package: 'CABGA381',
    );

    test('ECP5 target with blockRam uses block RAM storage', () {
      final fifo = HarborCdcFifo(
        dataWidth: 32,
        depth: 128,
        target: ecp5,
        blockRam: true,
      );
      expect(fifo.usesBlockRam, isTrue);
      expect(fifo.definitionName, endsWith('_bram'));
    });

    test('blockRam false keeps the flop array', () {
      final fifo = HarborCdcFifo(dataWidth: 32, depth: 128, target: ecp5);
      expect(fifo.usesBlockRam, isFalse);
      expect(fifo.definitionName, equals('HarborCdcFifo_32w128d'));
    });

    test('no target falls back to the flop array', () {
      final fifo = HarborCdcFifo(dataWidth: 32, depth: 128, blockRam: true);
      expect(fifo.usesBlockRam, isFalse);
      expect(fifo.definitionName, equals('HarborCdcFifo_32w128d'));
    });

    test('a target with no block RAM falls back to the flop array', () {
      final fifo = HarborCdcFifo(
        dataWidth: 32,
        depth: 128,
        target: const HarborSimTarget(topCell: 'top'),
        blockRam: true,
      );
      expect(fifo.usesBlockRam, isFalse);
    });

    test('every FPGA vendor names a block RAM primitive', () {
      expect(
        const HarborFpgaTarget.ecp5(
          device: 'lfe5u-25f',
          package: 'CABGA381',
        ).blockRam,
        equals(HarborBlockRam.dp16kd),
      );
      expect(
        const HarborFpgaTarget.ice40(device: 'up5k', package: 'sg48').blockRam,
        equals(HarborBlockRam.sbRam40_4k),
      );
      expect(
        const HarborFpgaTarget.spartan7(
          device: 'xc7s50',
          package: 'ftgb196',
        ).blockRam,
        equals(HarborBlockRam.ramb),
      );
      expect(const HarborSimTarget(topCell: 'top').blockRam, isNull);
    });
  });

  group('HarborCdcFifo block RAM emission', () {
    test('emits the dual-clock inference template, not a flop array', () async {
      final h = await _build();
      final sv = await _emit(h);
      // The storage is a memory array with one clock for each port.
      expect(sv, contains('logic [31:0] mem [0:127];'));
      expect(sv, contains('always_ff @(posedge wr_clk)'));
      expect(sv, contains('always_ff @(posedge rd_clk)'));
      // The ECP5 cell that yosys maps this template onto.
      expect(sv, contains('DP16KD'));
      // No per-entry flop array, which is what the flop path emits.
      expect(sv, isNot(contains('mem_0')));
    });

    test('the flop path still emits the per-entry flop array', () async {
      final h = await _build(blockRam: false);
      final sv = await _emit(h);
      expect(sv, contains('mem_0'));
      expect(sv, isNot(contains('DP16KD')));
    });
  });

  group('HarborCdcFifo block RAM 32x128 async clocks', () {
    test('four 128-word blocks cross the 32x512 board geometry', () async {
      final h = await _build(depth: 512);
      Simulator.setMaxSimTime(9000000);
      unawaited(Simulator.run());
      await _resetSequence(h);

      const blocks = 4;
      const wordsPerBlock = 128;
      final written = <int>[];
      for (var block = 0; block < blocks; block++) {
        for (var word = 0; word < wordsPerBlock; word++) {
          final value = 0x40000000 | (block << 16) | word;
          expect(
            await _push(h, value),
            isTrue,
            reason: 'block $block word $word must fit',
          );
          written.add(value);
        }
      }

      final got = await _drain(
        h,
        blocks * wordsPerBlock,
        maxCycles: 12000,
        where: 'board geometry',
      );
      expect(got, equals(written), reason: 'no block boundary may tear');

      await Simulator.endSimulation();
    });

    test('fills, refuses a push when full, and drains in order', () async {
      final h = await _build();
      Simulator.setMaxSimTime(3000000);
      unawaited(Simulator.run());
      await _resetSequence(h);

      // Fill all 128 entries. The read clock runs, but nothing reads.
      const depth = 128;
      final written = <int>[];
      for (var i = 0; i < depth; i++) {
        final value = 0xA5000000 | i;
        expect(
          await _push(h, value),
          isTrue,
          reason: 'push $i must be taken before the FIFO is full',
        );
        written.add(value);
      }

      // wr_full must come up. It uses the synchronized read pointer, so give
      // the synchronizer a few write cycles.
      var full = false;
      for (var i = 0; i < 8 && !full; i++) {
        await h.wrClk.nextPosedge;
        full = h.isFull;
      }
      expect(full, isTrue, reason: 'wr_full after $depth pushes');

      // Pushes while full must be REFUSED, not wrap around. The sentinel value
      // must never come out of the FIFO.
      const sentinel = 0xDEADBEEF;
      for (var i = 0; i < 8; i++) {
        expect(
          await _push(h, sentinel),
          isFalse,
          reason: 'push $i while full must be refused',
        );
      }

      final got = await _drain(h, depth, where: 'full drain');
      expect(got.length, equals(depth), reason: 'every word comes back');
      expect(got, equals(written), reason: 'order is preserved, no tear');
      expect(got, isNot(contains(sentinel)), reason: 'no refused push landed');

      // Empty again, and it stays empty.
      for (var i = 0; i < 4; i++) {
        await h.rdClkFree.nextPosedge;
      }
      expect(h.hasData, isFalse, reason: 'rd_empty after the drain');

      await Simulator.endSimulation();
    });

    test('rd_data holds still while the consumer does not read', () async {
      final h = await _build();
      Simulator.setMaxSimTime(3000000);
      unawaited(Simulator.run());
      await _resetSequence(h);

      await _push(h, 0x11223344);
      await _push(h, 0x55667788);

      // Wait for the word to reach the read side.
      var guard = 0;
      while (!h.hasData && guard < 50) {
        guard++;
        await h.rdClkFree.nextPosedge;
      }
      expect(h.hasData, isTrue, reason: 'first word arrives');

      // The head word must not change over many read cycles with rd_en low.
      final head = h.readHead('hold');
      expect(head, equals(0x11223344));
      for (var i = 0; i < 20; i++) {
        await h.rdClkFree.nextPosedge;
        expect(
          h.readHead('hold cycle $i'),
          equals(0x11223344),
          reason: 'rd_data must hold while rd_en is low',
        );
        expect(h.hasData, isTrue, reason: 'rd_empty must stay low');
      }

      final got = await _drain(h, 2, where: 'hold drain');
      expect(got, equals([0x11223344, 0x55667788]));

      await Simulator.endSimulation();
    });

    test('a stopped read clock while filling loses nothing', () async {
      final h = await _build();
      Simulator.setMaxSimTime(3000000);
      unawaited(Simulator.run());
      await _resetSequence(h);

      // STOP the read clock, then fill the FIFO completely.
      await _setReadClock(h, running: false);
      for (var i = 0; i < 20; i++) {
        await h.wrClk.nextPosedge;
      }

      const depth = 128;
      final written = <int>[];
      for (var i = 0; i < depth; i++) {
        final value = 0x5A000000 | i;
        expect(
          await _push(h, value),
          isTrue,
          reason: 'push $i with the read clock stopped',
        );
        written.add(value);
      }

      // The write side must refuse more, with the read side frozen.
      var full = false;
      for (var i = 0; i < 8 && !full; i++) {
        await h.wrClk.nextPosedge;
        full = h.isFull;
      }
      expect(full, isTrue, reason: 'wr_full with the read clock stopped');
      expect(
        await _push(h, 0xFFFFFFFF),
        isFalse,
        reason: 'a push into a full FIFO is refused',
      );

      // Start the read clock again and drain.
      await _setReadClock(h, running: true);
      final got = await _drain(h, depth, where: 'restart drain');
      expect(
        got,
        equals(written),
        reason: 'nothing lost while the clock was off',
      );

      await Simulator.endSimulation();
    });

    test(
      'a stopped read clock in the middle of a drain loses nothing',
      () async {
        final h = await _build();
        Simulator.setMaxSimTime(3000000);
        unawaited(Simulator.run());
        await _resetSequence(h);

        const depth = 128;
        final written = <int>[];
        for (var i = 0; i < depth; i++) {
          final value = 0x7000_0000 | i;
          expect(await _push(h, value), isTrue, reason: 'push $i');
          written.add(value);
        }

        // Take half of the words.
        final got = await _drain(h, depth ~/ 2, where: 'first half');
        expect(got.length, equals(depth ~/ 2));

        // STOP the read clock in the middle of the drain, and let the write
        // domain run on. The FIFO is full, so every push is refused.
        await _setReadClock(h, running: false);
        for (var i = 0; i < 40; i++) {
          await _push(h, 0xBADF00D);
        }

        // Start it again and take the rest.
        await _setReadClock(h, running: true);
        got.addAll(await _drain(h, depth - got.length, where: 'second half'));

        expect(
          got,
          equals(written),
          reason: 'order held across the clock stop',
        );
        expect(
          got,
          isNot(contains(0xBADF00D)),
          reason: 'no refused push landed',
        );

        await Simulator.endSimulation();
      },
    );

    test('streams more than the depth with gaps on both sides', () async {
      final h = await _build();
      Simulator.setMaxSimTime(6000000);
      unawaited(Simulator.run());
      await _resetSequence(h);

      const total = 400;
      final written = <int>[];
      final got = <int>[];

      // Producer: pushes with an uneven gap, and retries what the FIFO
      // refuses, so nothing is dropped by the test itself.
      final producer = () async {
        var i = 0;
        var gap = 0;
        while (i < total) {
          if (gap > 0) {
            gap--;
            h.wrEn.inject(0);
            await h.wrClk.nextPosedge;
            continue;
          }
          final value = 0x0C000000 | i;
          if (await _push(h, value)) {
            written.add(value);
            i++;
            gap = i % 3;
          }
        }
        h.wrEn.inject(0);
      }();

      // Consumer: reads with its own uneven gap.
      final consumer = () async {
        var cycles = 0;
        var gap = 0;
        while (got.length < total && cycles < 20000) {
          cycles++;
          if (gap == 0 && h.hasData) {
            got.add(h.readHead('stream word ${got.length}'));
            h.rdEn.inject(1);
            await h.rdClkFree.nextPosedge;
            h.rdEn.inject(0);
            gap = got.length % 4;
          } else {
            if (gap > 0) gap--;
            await h.rdClkFree.nextPosedge;
          }
        }
      }();

      await Future.wait([producer, consumer]);

      expect(written.length, equals(total), reason: 'producer sent them all');
      expect(got.length, equals(total), reason: 'consumer got them all');
      expect(got, equals(written), reason: 'order preserved over 400 words');

      await Simulator.endSimulation();
    });
  });
}

import 'dart:async';
import 'dart:math' as math;

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// A CK/2 clock, a CK/4 clock divided from it (rising edges aligned, as two
/// outputs of one PLL are), and a CK/4-domain registered reset.
({Logic sclk, Logic ctrlClk, Logic rstN, Logic reset}) _clocks() {
  final sclk = SimpleClockGenerator(4).clk;
  final rstN = Logic(name: 'rst_n')..inject(0);
  // The divider only needs a defined start, so it gets its own reset.
  final divInit = Logic(name: 'div_init')..inject(1);
  Simulator.registerAction(3, () => divInit.put(0));
  final ctrlClk = Logic(name: 'ctrl_clk');
  Sequential(sclk, reset: divInit, [ctrlClk < ~ctrlClk]);
  final reset = Logic(name: 'reset');
  Sequential(ctrlClk, [reset < ~rstN]);
  return (sclk: sclk, ctrlClk: ctrlClk, rstN: rstN, reset: reset);
}

void main() {
  tearDown(() async => Simulator.reset());

  group('Ddr3Ecp5TxRegear', () {
    test('each CK/4 word becomes exactly two CK/2 halves, low first, '
        'across many ticks and a reset in the middle', () async {
      const w = 16;
      final c = _clocks();
      final word = Logic(name: 'word', width: 2 * w)..inject(0);
      final dut = Ddr3Ecp5TxRegear(
        ctrlClk: c.ctrlClk,
        sclk: c.sclk,
        reset: c.reset,
        word: word,
      );
      await dut.build();

      final ctrlRises = <int>{};
      final fullChanges = <int>[];
      c.ctrlClk.posedge.listen((_) => ctrlRises.add(Simulator.time));
      // Outside reset only: in reset the regear takes a word every CK/2 cycle.
      dut.full.changed.listen((_) {
        if (c.reset.value.isValid && c.reset.value.toInt() == 0) {
          fullChanges.add(Simulator.time);
        }
      });

      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());

      final rnd = math.Random(5);
      // Tick n carries a 12-bit tag (n) and random payload in both halves.
      int lo(int n) => (n & 0xFFF) | (rnd.nextInt(16) << 12);
      final sentLo = <int, int>{};
      final sentHi = <int, int>{};
      var n = 0;
      final halves = <int>[];
      final fulls = <int>[];
      c.sclk.negedge.listen((_) {
        final h = dut.half.value;
        final f = dut.full.value;
        if (h.isValid) halves.add(h.toInt());
        if (f.isValid) fulls.add(f.toInt());
      });

      Future<void> run(int ticks) async {
        for (var i = 0; i < ticks; i++) {
          await c.ctrlClk.nextPosedge;
          final l = lo(n);
          final h = (n & 0xFFF) | 0x8000 ^ (rnd.nextInt(8) << 12);
          sentLo[l] = n;
          sentHi[h] = n;
          word.inject((h << w) | l);
          n++;
        }
      }

      for (var i = 0; i < 4; i++) {
        await c.ctrlClk.nextPosedge;
      }
      c.rstN.inject(1);
      await run(150);
      final firstRun = List<int>.of(halves);
      halves.clear();
      c.rstN.inject(0);
      await run(5);
      c.rstN.inject(1);
      halves.clear();
      await run(150);
      final secondRun = List<int>.of(halves);
      await Simulator.endSimulation();

      for (final run in [firstRun, secondRun]) {
        // Skip the start-up latency (and the halves of the tick that was in
        // flight at the reset), then the stream must be lo(k), hi(k),
        // lo(k+1), hi(k+1), ... with no tick dropped or repeated.
        final start = run.indexWhere(sentLo.containsKey, 4);
        expect(start, greaterThanOrEqualTo(0));
        final body = run.sublist(start, run.length - 4);
        expect(body.length, greaterThan(200));
        var expectTick = sentLo[body[0]]!;
        for (var i = 0; i + 1 < body.length; i += 2) {
          expect(sentLo[body[i]], expectTick, reason: 'low half at $i');
          expect(sentHi[body[i + 1]], expectTick, reason: 'high half at $i');
          expectTick++;
        }
      }

      // The full word changes only on the sclk edge between two CK/4 edges,
      // never on a CK/4 edge (no hold race on the crossing).
      for (final t in fullChanges) {
        expect(ctrlRises.contains(t), isFalse, reason: 'full changed at $t');
      }
      expect(fullChanges.length, greaterThan(250));
      expect(fulls, isNotEmpty);
    });
  });

  group('Ddr3Ecp5RxRegear', () {
    test('two consecutive CK/2 words form one CK/4 word, none dropped or '
        'repeated, across many ticks and a reset in the middle', () async {
      const w = 16;
      final c = _clocks();
      final half = Logic(name: 'half', width: w)..inject(0);
      final dut = Ddr3Ecp5RxRegear(
        ctrlClk: c.ctrlClk,
        sclk: c.sclk,
        reset: c.reset,
        half: half,
      );
      await dut.build();
      Simulator.setMaxSimTime(100000);
      unawaited(Simulator.run());

      final rnd = math.Random(9);
      final sent = <int, int>{};
      var m = 0;
      final words = <int>[];
      c.ctrlClk.negedge.listen((_) {
        final v = dut.word.value;
        if (v.isValid) words.add(v.toInt());
      });

      Future<void> run(int sclkCycles) async {
        for (var i = 0; i < sclkCycles; i++) {
          await c.sclk.nextPosedge;
          final v = (m & 0x3FF) | (rnd.nextInt(64) << 10);
          sent[v] = m;
          half.inject(v);
          m++;
        }
      }

      for (var i = 0; i < 4; i++) {
        await c.ctrlClk.nextPosedge;
      }
      c.rstN.inject(1);
      await run(300);
      final firstRun = List<int>.of(words);
      words.clear();
      c.rstN.inject(0);
      await run(10);
      c.rstN.inject(1);
      words.clear();
      await run(300);
      final secondRun = List<int>.of(words);
      await Simulator.endSimulation();

      for (final run in [firstRun, secondRun]) {
        // The first words after a reset may hold beats from before it.
        final body = run
            .skip(3)
            .where((v) => sent.containsKey(v & 0xFFFF))
            .where((v) => sent.containsKey(v >> w))
            .toList();
        expect(body.length, greaterThan(100));
        for (var i = 0; i < body.length; i++) {
          final a = sent[body[i] & 0xFFFF]!;
          final b = sent[body[i] >> w]!;
          expect(b, a + 1, reason: 'word $i is not two consecutive beats');
          if (i > 0) {
            final prevB = sent[body[i - 1] >> w]!;
            expect(a, prevB + 1, reason: 'word $i dropped or repeated a beat');
          }
        }
      }
    });
  });

  group('Ddr3Ecp5ReadLeveler', () {
    test('center follows the litedram sdram_leveling_center_module rules', () {
      expect(Ddr3Ecp5ReadLeveler.center(0x3C), (ok: true, mid: 3));
      expect(Ddr3Ecp5ReadLeveler.center(0xFF), (ok: true, mid: 3));
      expect(Ddr3Ecp5ReadLeveler.center(0x7F), (ok: true, mid: 3));
      expect(Ddr3Ecp5ReadLeveler.center(0xC3), (ok: true, mid: 0));
      expect(Ddr3Ecp5ReadLeveler.center(0xF8), (ok: true, mid: 5));
      expect(Ddr3Ecp5ReadLeveler.center(0x01).ok, isFalse);
      expect(Ddr3Ecp5ReadLeveler.center(0x55).ok, isFalse);
      expect(Ddr3Ecp5ReadLeveler.center(0x00).ok, isFalse);
    });

    Future<
      ({
        List<int> clkSel,
        List<int> slip,
        int checks,
        int pauseInWindow,
        int changesWithoutPause,
        int pausePulses,
      })
    >
    level(
      bool Function(int lane, int slip, int clkSel) passes, {
      bool Function(int lane, int slip, int clkSel)? burst,
      bool useBurstDet = false,
    }) async {
      const lanes = 2;
      final clk = SimpleClockGenerator(4).clk;
      final reset = Logic(name: 'reset')..inject(1);
      final start = Logic(name: 'start')..inject(0);
      final check = Logic(name: 'check')..inject(0);
      final pass = Logic(name: 'pass', width: lanes)..inject(0);
      final burstSeen = Logic(name: 'burst', width: lanes)..inject(0);
      final dut = Ddr3Ecp5ReadLeveler(
        lanes: lanes,
        clk: clk,
        reset: reset,
        start: start,
        check: check,
        pass: pass,
        burstSeen: burstSeen,
        useBurstDet: useBurstDet,
      );
      await dut.build();
      Simulator.setMaxSimTime(1000000);
      unawaited(Simulator.run());

      int field(Logic v, int l, int w) =>
          (v.value.toInt() >> (l * w)) & ((1 << w) - 1);

      // The controller's test write and read run in the window before each
      // check. PAUSE must be low there, and high whenever a setting changes.
      var inWindow = false;
      var pauseInWindow = 0;
      var changesWithoutPause = 0;
      var pausePulses = 0;
      var lastPause = 0;
      var lastSetting = '';
      clk.posedge.listen((_) {
        final pz = dut.pause.value;
        if (!pz.isValid) return;
        final pv = pz.toInt();
        if (inWindow && pv == 1) pauseInWindow++;
        if (pv == 1 && lastPause == 0) pausePulses++;
        lastPause = pv;
        final setting = '${dut.slip.value}/${dut.readClkSel.value}';
        if (lastSetting.isNotEmpty && setting != lastSetting && pv == 0) {
          changesWithoutPause++;
        }
        lastSetting = setting;
      });

      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      start.inject(1);
      var checks = 0;
      while (dut.done.value.toInt() == 0 && checks < 1000) {
        // The controller writes, reads, and waits for the data before it
        // reports.
        inWindow = true;
        for (var i = 0; i < 20; i++) {
          await clk.nextPosedge;
        }
        inWindow = false;
        var p = 0;
        var b = 0;
        for (var l = 0; l < lanes; l++) {
          final s = field(dut.slip, l, Ddr3Ecp5ReadLeveler.slipBits);
          final d = field(dut.readClkSel, l, 3);
          if (passes(l, s, d)) p |= 1 << l;
          if ((burst ?? passes)(l, s, d)) b |= 1 << l;
        }
        pass.inject(p);
        burstSeen.inject(b);
        check.inject(1);
        await clk.nextPosedge;
        check.inject(0);
        checks++;
        expect(
          Ddr3Ecp5ReadLeveler.maxBusyCycles,
          lessThan(Ddr3Controller.readLevelWaitTicks),
        );
        for (
          var i = 0;
          i < Ddr3Controller.readLevelWaitTicks && dut.done.value.toInt() == 0;
          i++
        ) {
          await clk.nextPosedge;
        }
      }
      final clkSel = [
        for (var l = 0; l < lanes; l++) field(dut.readClkSel, l, 3),
      ];
      final slip = [
        for (var l = 0; l < lanes; l++)
          field(dut.slip, l, Ddr3Ecp5ReadLeveler.slipBits),
      ];
      await Simulator.endSimulation();
      return (
        clkSel: clkSel,
        slip: slip,
        checks: checks,
        pauseInWindow: pauseInWindow,
        changesWithoutPause: changesWithoutPause,
        pausePulses: pausePulses,
      );
    }

    test('sweeps every READCLKSEL x bitslip point once and picks the centre '
        'of the widest window per lane', () async {
      final r = await level((lane, s, d) {
        if (lane == 0) return s == 9 && d >= 2 && d <= 5;
        // Lane 1: a narrow window at slip 9 and a wide one at slip 10.
        return (s == 9 && d >= 6) || (s == 10 && d <= 6);
      });
      expect(r.checks, 8 * Ddr3Ecp5ReadLeveler.bitslips);
      expect(r.slip, [9, 10]);
      expect(r.clkSel, [3, 3]);
    });

    test('PAUSE is high around every setting change and low while the '
        'controller writes and reads (litedram select/deselect)', () async {
      final r = await level((lane, s, d) => s == 3 && d >= 1 && d <= 6);
      expect(r.pauseInWindow, 0);
      expect(r.changesWithoutPause, 0);
      // Two pulses (change, then sync) per point change and for the final
      // setting.
      expect(r.pausePulses, 2 * (8 * Ddr3Ecp5ReadLeveler.bitslips - 1 + 1));
      expect(r.slip, [3, 3]);
      expect(r.clkSel, [3, 3]);
    });

    test('BURSTDET gates a point when enabled', () async {
      final r = await level(
        (lane, s, d) => s == 4 && d <= 5,
        burst: (lane, s, d) => d >= 2,
        useBurstDet: true,
      );
      // Passing points are d in 2..5 once BURSTDET is required.
      expect(r.slip, [4, 4]);
      expect(r.clkSel, [3, 3]);
    });
  });

  group('Ddr3Ecp5Init', () {
    test(
      'runs the litedram ECP5DDRPHYInit timeline once after DLL lock',
      () async {
        final clk = SimpleClockGenerator(4).clk;
        final reset = Logic(name: 'reset')..inject(1);
        final lock = Logic(name: 'lock')..inject(0);
        final dut = Ddr3Ecp5Init(clk: clk, reset: reset, lock: lock);
        await dut.build();
        Simulator.setMaxSimTime(100000);
        unawaited(Simulator.run());

        final trace = <String, List<int>>{};
        var cycle = 0;
        String bits() => [
          dut.freeze,
          dut.stop,
          dut.ioReset,
          dut.pause,
          dut.uddcntln,
          dut.done,
        ].map((s) => s.value.toInt()).join();
        clk.posedge.listen((_) {
          cycle++;
          trace.putIfAbsent(bits(), () => []).add(cycle);
        });

        for (var i = 0; i < 3; i++) {
          await clk.nextPosedge;
        }
        reset.inject(0);
        for (var i = 0; i < 10; i++) {
          await clk.nextPosedge;
        }
        expect(dut.done.value.toInt(), 0, reason: 'no lock yet');
        lock.inject(1);
        final order = <String>[];
        for (var i = 0; i < 200; i++) {
          await clk.nextPosedge;
          final b = bits();
          if (order.isEmpty || order.last != b) order.add(b);
        }
        await Simulator.endSimulation();

        // freeze, stop, ioReset, pause, uddcntln, done.
        expect(order, [
          '000010',
          '100010', // freeze the DLL
          '110010', // stop ECLK
          '111010', // reset the ECLK domain
          '110010', // release the reset
          '100010', // release stop
          '000010', // release freeze
          '000110', // pause DQSBUFM
          '000100', // UDDCNTLN low: load the DDRDEL code
          '000110',
          '000010', // release pause
          '000011', // done
        ]);
      },
    );
  });
}

// Checks SdramBankTimers.strobes, the production one-hot-strobe input the
// engine drives, against the same spacing boundaries
// sdram_bank_timers_test.dart checks on the decoded cmd/cmd_bank path.

import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/sdram_bank_timers.dart';
import 'package:harbor/src/peripherals/sdram_config.dart';
import 'package:harbor/src/peripherals/sdram_cycles.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _Harness {
  final HarborSdramCycles cycles;
  final SdramBankTimers dut;
  final Logic clk;
  final Logic reset;
  final Logic act, pre, read, write, preAll, ref, mrs, cmdBeats;

  _Harness._(
    this.cycles,
    this.dut,
    this.clk,
    this.reset,
    this.act,
    this.pre,
    this.read,
    this.write,
    this.preAll,
    this.ref,
    this.mrs,
    this.cmdBeats,
  );

  static Future<_Harness> build(HarborSdramCycles cycles) async {
    final clk = SimpleClockGenerator(cycles.tCkPs).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final banks = cycles.config.banks;
    final act = Logic(name: 'act', width: banks)..inject(0);
    final pre = Logic(name: 'pre', width: banks)..inject(0);
    final read = Logic(name: 'read', width: banks)..inject(0);
    final write = Logic(name: 'write', width: banks)..inject(0);
    final preAll = Logic(name: 'pre_all')..inject(0);
    final ref = Logic(name: 'ref')..inject(0);
    final mrs = Logic(name: 'mrs')..inject(0);
    final cmdBeats = Logic(name: 'cmd_beats', width: 4)..inject(0);
    final dut = SdramBankTimers.strobes(
      cycles,
      clk: clk,
      reset: reset,
      act: act,
      pre: pre,
      read: read,
      write: write,
      preAll: preAll,
      ref: ref,
      mrs: mrs,
      cmdBeats: cmdBeats,
    );
    await dut.build();
    return _Harness._(
      cycles,
      dut,
      clk,
      reset,
      act,
      pre,
      read,
      write,
      preAll,
      ref,
      mrs,
      cmdBeats,
    );
  }

  /// Drives one edge with the given strobes, every other strobe low.
  Future<void> drive({
    int act = 0,
    int pre = 0,
    int read = 0,
    int write = 0,
    int preAll = 0,
    int ref = 0,
    int mrs = 0,
    int beats = 0,
  }) async {
    this.act.inject(act);
    this.pre.inject(pre);
    this.read.inject(read);
    this.write.inject(write);
    this.preAll.inject(preAll);
    this.ref.inject(ref);
    this.mrs.inject(mrs);
    cmdBeats.inject(beats);
    await clk.nextPosedge;
  }

  Future<void> nop() => drive();

  Future<void> nops(int n) async {
    for (var i = 0; i < n; i++) {
      await nop();
    }
  }
}

Future<void> _release(_Harness h) async {
  const maxCycles = 4000;
  Simulator.setMaxSimTime(maxCycles * h.cycles.tCkPs * 2);
  unawaited(Simulator.run());
  await h.clk.nextPosedge;
  await h.clk.nextPosedge;
  h.reset.inject(0);
}

void main() {
  tearDown(() async => Simulator.reset());

  Future<_Harness> start() async {
    final cycles = HarborSdramCycles(
      const HarborSdramConfig.as4c16m16sb6(),
      clockHz: 125000000,
    );
    final h = await _Harness.build(cycles);
    await _release(h);
    return h;
  }

  /// Drives one edge with the given strobes, then checks that [flag]
  /// first rises when the next command would be [n] cycles after it:
  /// the same boundary sdram_bank_timers_test.dart checks on the cmd path.
  Future<void> expectSpacing(
    _Harness h,
    Logic flag,
    int n,
    String what, {
    int act = 0,
    int pre = 0,
    int read = 0,
    int write = 0,
    int preAll = 0,
    int ref = 0,
    int mrs = 0,
    int beats = 0,
  }) async {
    await h.drive(
      act: act,
      pre: pre,
      read: read,
      write: write,
      preAll: preAll,
      ref: ref,
      mrs: mrs,
      beats: beats,
    );
    for (var gap = 2; gap < n; gap++) {
      expect(flag.value.toInt(), 0, reason: '$what at $gap of $n');
      await h.nop();
    }
    expect(flag.value.toInt(), 1, reason: '$what at $n');
  }

  test('rasMin, then rp after a precharge, through act/pre strobes', () async {
    final h = await start();
    final c = h.cycles;
    await expectSpacing(h, h.dut.canPre[0], c.rasMin, 'canPre after act', act: 0x1);
    await expectSpacing(h, h.dut.canAct[0], c.rp, 'canAct after pre', pre: 0x1);
    await Simulator.endSimulation();
  });

  test('rcd for read and write, through the act strobe', () async {
    final h = await start();
    final c = h.cycles;
    await expectSpacing(h, h.dut.canRead[0], c.rcd, 'canRead after act', act: 0x1);
    expect(h.dut.canWrite[0].value.toInt(), 1);
    await Simulator.endSimulation();
  });

  test('wr after a write, through the write strobe', () async {
    final h = await start();
    final c = h.cycles;
    await h.drive(act: 0x1);
    await h.nops(c.rasMin + 2);
    await expectSpacing(h, h.dut.canPre[0], c.wr, 'canPre after write', write: 0x1);
    await Simulator.endSimulation();
  });

  test('rrd on a different bank through act[1]', () async {
    final h = await start();
    await expectSpacing(h, h.dut.canAct[1], h.cycles.rrd, 'canAct[1] after act', act: 0x1);
    await Simulator.endSimulation();
  });

  test('rp before refresh, after pre and pre all strobes', () async {
    final h = await start();
    final c = h.cycles;
    await h.drive(act: 0x1);
    await h.nops(c.rasMin);
    await expectSpacing(h, h.dut.canRef, c.rp, 'canRef after pre', pre: 0x1);
    await h.drive(act: 0x2);
    await h.nops(c.rasMin);
    await expectSpacing(h, h.dut.canRef, c.rp, 'canRef after pre all', preAll: 1);
    await Simulator.endSimulation();
  });

  test('mrd and rfc blackouts, through the mrs and ref strobes', () async {
    final h = await start();
    final c = h.cycles;
    await h.nop();
    await expectSpacing(h, h.dut.canAct[0], c.mrd, 'canAct after mrs', mrs: 1);
    expect(h.dut.canRef.value.toInt(), 1);
    await expectSpacing(h, h.dut.canAct[0], c.rfc, 'canAct after ref', ref: 1);
    expect(h.dut.canRef.value.toInt(), 1);
    await Simulator.endSimulation();
  });

  // The strobes are documented as one-hot: one command, on one bank, per
  // cycle. The engine's select logic guarantees that; this module does
  // not check it. Driving two act bits at once is not rejected, both
  // banks just open, as if two activates had landed the same cycle. This
  // test records that behavior so it does not change silently.
  test(
    'more than one act strobe at once is not rejected: both banks open',
    () async {
      final h = await start();
      await h.drive(act: 0x3); // bank 0 and bank 1 together.
      await h.nop();
      expect(h.dut.anyOpen.value.toInt(), 1);
      expect(h.dut.canAct[0].value.toInt(), 0, reason: 'bank 0 now open');
      expect(h.dut.canAct[1].value.toInt(), 0, reason: 'bank 1 now open');
      await Simulator.endSimulation();
    },
  );

  // cmdBeatsNext lets the beats flags be registers loaded a cycle early
  // instead of combinational compares. Two builds, driven by the same
  // strobes, must land on the same can_* every cycle: cmdBeatsNext only
  // moves where a flag is computed, never what it is.
  test(
    'cmdBeatsNext build agrees with the plain build on every can_* output',
    () async {
      final cycles = HarborSdramCycles(
        const HarborSdramConfig.as4c16m16sb6(),
        clockHz: 125000000,
      );
      final banks = cycles.config.banks;
      final clk = SimpleClockGenerator(cycles.tCkPs).clk;
      final reset = Logic(name: 'reset')..inject(1);
      final act = Logic(name: 'act', width: banks)..inject(0);
      final pre = Logic(name: 'pre', width: banks)..inject(0);
      final read = Logic(name: 'read', width: banks)..inject(0);
      final write = Logic(name: 'write', width: banks)..inject(0);
      final preAll = Logic(name: 'pre_all')..inject(0);
      final ref = Logic(name: 'ref')..inject(0);
      final mrs = Logic(name: 'mrs')..inject(0);
      final cmdBeats = Logic(name: 'cmd_beats', width: 4)..inject(0);
      final cmdBeatsNext = Logic(name: 'cmd_beats_next', width: 4)..inject(0);

      final plain = SdramBankTimers.strobes(
        cycles,
        name: 'plain',
        clk: clk,
        reset: reset,
        act: act,
        pre: pre,
        read: read,
        write: write,
        preAll: preAll,
        ref: ref,
        mrs: mrs,
        cmdBeats: cmdBeats,
      );
      final withNext = SdramBankTimers.strobes(
        cycles,
        name: 'with_next',
        clk: clk,
        reset: reset,
        act: act,
        pre: pre,
        read: read,
        write: write,
        preAll: preAll,
        ref: ref,
        mrs: mrs,
        cmdBeats: cmdBeats,
        cmdBeatsNext: cmdBeatsNext,
      );
      await plain.build();
      await withNext.build();

      const maxCycles = 4000;
      Simulator.setMaxSimTime(maxCycles * cycles.tCkPs * 2);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      // put(), not inject(): the predicted can_* snapshot below reads
      // combinational outputs in the same synchronous step that drives
      // these inputs, and inject() only takes effect on a later tick.
      reset.put(0);

      final rng = Random(20261010);
      int nextBeats = 1 + rng.nextInt(8);
      cmdBeatsNext.put(nextBeats);

      for (var cycle = 0; cycle < 500; cycle++) {
        cmdBeats.put(nextBeats);
        nextBeats = 1 + rng.nextInt(8);
        cmdBeatsNext.put(nextBeats);

        // One strobe at most, one-hot on a random bank where the signal
        // has a bank bit. 1 of 8 picks is a nop (no strobe at all).
        act.put(0);
        pre.put(0);
        read.put(0);
        write.put(0);
        preAll.put(0);
        ref.put(0);
        mrs.put(0);
        final pick = rng.nextInt(8);
        final bank = 1 << rng.nextInt(banks);
        switch (pick) {
          case 0:
            act.put(bank);
          case 1:
            pre.put(bank);
          case 2:
            read.put(bank);
          case 3:
            write.put(bank);
          case 4:
            preAll.put(1);
          case 5:
            ref.put(1);
          case 6:
            mrs.put(1);
          default:
          // nop this cycle.
        }

        // Predicted can_* from the plain build's own next-cycle outputs,
        // sampled before the edge they describe.
        final predictedAct = [
          for (var b = 0; b < banks; b++)
            plain.actBankNext[b].value.toInt() &
                plain.actCommonNext.value.toInt(),
        ];
        final predictedRead = [
          for (var b = 0; b < banks; b++)
            plain.colBankNext[b].value.toInt() &
                plain.readCommonNext.value.toInt(),
        ];
        final predictedWrite = [
          for (var b = 0; b < banks; b++)
            plain.colBankNext[b].value.toInt() &
                plain.writeCommonNext.value.toInt(),
        ];
        final predictedPre = [
          for (var b = 0; b < banks; b++)
            plain.preBankNext[b].value.toInt() &
                plain.preCommonNext.value.toInt(),
        ];

        await clk.nextPosedge;

        for (var b = 0; b < banks; b++) {
          expect(
            withNext.canAct[b].value.toInt(),
            plain.canAct[b].value.toInt(),
            reason: 'canAct[$b] cycle $cycle',
          );
          expect(
            withNext.canRead[b].value.toInt(),
            plain.canRead[b].value.toInt(),
            reason: 'canRead[$b] cycle $cycle',
          );
          expect(
            withNext.canWrite[b].value.toInt(),
            plain.canWrite[b].value.toInt(),
            reason: 'canWrite[$b] cycle $cycle',
          );
          expect(
            withNext.canPre[b].value.toInt(),
            plain.canPre[b].value.toInt(),
            reason: 'canPre[$b] cycle $cycle',
          );
          expect(
            plain.canAct[b].value.toInt(),
            predictedAct[b],
            reason: 'actBankNext/actCommonNext[$b] one edge early, cycle $cycle',
          );
          expect(
            plain.canRead[b].value.toInt(),
            predictedRead[b],
            reason: 'colBankNext/readCommonNext[$b] one edge early, cycle $cycle',
          );
          expect(
            plain.canWrite[b].value.toInt(),
            predictedWrite[b],
            reason: 'colBankNext/writeCommonNext[$b] one edge early, cycle $cycle',
          );
          expect(
            plain.canPre[b].value.toInt(),
            predictedPre[b],
            reason: 'preBankNext/preCommonNext[$b] one edge early, cycle $cycle',
          );
        }
        expect(
          withNext.canPreAll.value.toInt(),
          plain.canPreAll.value.toInt(),
          reason: 'canPreAll cycle $cycle',
        );
        expect(
          withNext.canRef.value.toInt(),
          plain.canRef.value.toInt(),
          reason: 'canRef cycle $cycle',
        );
        expect(
          withNext.anyOpen.value.toInt(),
          plain.anyOpen.value.toInt(),
          reason: 'anyOpen cycle $cycle',
        );
        expect(
          withNext.rowAgeForce.value.toInt(),
          plain.rowAgeForce.value.toInt(),
          reason: 'rowAgeForce cycle $cycle',
        );
      }
      await Simulator.endSimulation();
    },
  );
}

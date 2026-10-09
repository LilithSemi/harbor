// Checks SdramBankTimers against a pure Dart reference model that keeps
// only command timestamps and re-derives legality from the datasheet
// rules in HarborSdramCycles, over random legal command streams, plus
// directed checks at each rule's exact cycle boundary.

import 'dart:async';
import 'dart:math';

import 'package:harbor/src/peripherals/sdram_bank_timers.dart';
import 'package:harbor/src/peripherals/sdram_command.dart';
import 'package:harbor/src/peripherals/sdram_config.dart';
import 'package:harbor/src/peripherals/sdram_cycles.dart';
import 'package:harbor/src/peripherals/sdram_timing.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Independent Dart reference: keeps only the cycle number of each past
/// command and decides legality straight from the datasheet rules in
/// [cycles], by timestamp arithmetic. It shares no counter or next-state
/// mechanism with [SdramBankTimers], and neither one reads the other.
class _BankTimersRef {
  final HarborSdramCycles cycles;
  final int banks;

  /// The step index just processed (-1 before the first step).
  int _now = -1;

  final List<int?> lastAct;
  final List<int?> lastBankPre;
  final List<int?> lastWrite;
  final List<int?> lastRead;
  final List<int?> lastReadBeats;
  int? lastPreAll;
  int? lastAnyAct;
  int? lastMrs;
  int? lastRef;
  int? lastAnyRead;
  int? lastAnyReadBeats;
  int _ageReg = 0;
  bool _openReg = false;

  /// The last command and its beats, for the one-cycle block the
  /// scheduler applies on its own.
  int lastCmd = SdramCommand.nop.index;
  int lastBeats = 0;

  /// Whether the scheduler may choose [cmd] in the cycle right after
  /// [lastCmd], on top of the flags.
  bool allowedAfterLast(int cmd) {
    final c = SdramCommand.values[cmd];
    if (c == SdramCommand.nop) return true;
    switch (SdramCommand.values[lastCmd]) {
      case SdramCommand.act ||
          SdramCommand.pre ||
          SdramCommand.preAll ||
          SdramCommand.ref ||
          SdramCommand.mrs:
        return false;
      case SdramCommand.read:
        if (c == SdramCommand.write) return false;
        final shortRead = lastBeats == 1;
        return shortRead ||
            !(c == SdramCommand.read ||
                c == SdramCommand.pre ||
                c == SdramCommand.preAll);
      case SdramCommand.write:
        return !(c == SdramCommand.pre || c == SdramCommand.preAll);
      case SdramCommand.nop:
        return true;
    }
  }

  List<bool> canAct, canRead, canWrite, canPre;
  bool canPreAll = false, canRef = false, canMrs = false;
  bool rowAgeForce = false, anyOpen = false;

  _BankTimersRef(this.cycles)
    : banks = cycles.config.banks,
      lastAct = List.filled(cycles.config.banks, null),
      lastBankPre = List.filled(cycles.config.banks, null),
      lastWrite = List.filled(cycles.config.banks, null),
      lastRead = List.filled(cycles.config.banks, null),
      lastReadBeats = List.filled(cycles.config.banks, null),
      canAct = List.filled(cycles.config.banks, false),
      canRead = List.filled(cycles.config.banks, false),
      canWrite = List.filled(cycles.config.banks, false),
      canPre = List.filled(cycles.config.banks, false);

  static int? _laterOf(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  /// True if a command chosen in the cycle after step [now] would sit at
  /// least [delay] cycles after the one seen at step [last]. Steps see
  /// registered commands, so that one was chosen at [last] - 1.
  static bool _elapsed(int? last, int now, int delay) =>
      last == null || (now + 1) - (last - 1) >= delay;

  void step({required int cmd, required int bank, required int beats}) {
    _now++;
    final now = _now;
    lastCmd = cmd;
    lastBeats = beats;
    final isAct = cmd == SdramCommand.act.index;
    final isRead = cmd == SdramCommand.read.index;
    final isWrite = cmd == SdramCommand.write.index;
    final isPre = cmd == SdramCommand.pre.index;
    final isPreAll = cmd == SdramCommand.preAll.index;
    final isRef = cmd == SdramCommand.ref.index;
    final isMrs = cmd == SdramCommand.mrs.index;

    if (isAct) {
      lastAct[bank] = now;
      lastAnyAct = now;
    }
    if (isPre) lastBankPre[bank] = now;
    if (isPreAll) lastPreAll = now;
    if (isWrite) lastWrite[bank] = now;
    if (isRead) {
      lastRead[bank] = now;
      lastReadBeats[bank] = beats;
      lastAnyRead = now;
      lastAnyReadBeats = beats;
    }
    if (isMrs) lastMrs = now;
    if (isRef) lastRef = now;

    bool bankOpenAt(int b) {
      final act = lastAct[b];
      if (act == null) return false;
      final close = _laterOf(lastBankPre[b], lastPreAll);
      return close == null || act > close;
    }

    final open = [for (var b = 0; b < banks; b++) bankOpenAt(b)];
    final anyOpenNow = open.any((x) => x);

    final mrdBusy = !_elapsed(lastMrs, now, cycles.mrd);
    final rfcBusy = !_elapsed(lastRef, now, cycles.rfc);
    final blackout = mrdBusy || rfcBusy;

    final rcReady = [
      for (var b = 0; b < banks; b++) _elapsed(lastAct[b], now, cycles.rc),
    ];
    final rpReady = [
      for (var b = 0; b < banks; b++)
        _elapsed(_laterOf(lastBankPre[b], lastPreAll), now, cycles.rp),
    ];
    final rcdReady = [
      for (var b = 0; b < banks; b++) _elapsed(lastAct[b], now, cycles.rcd),
    ];
    final rasMinReady = [
      for (var b = 0; b < banks; b++) _elapsed(lastAct[b], now, cycles.rasMin),
    ];
    final rrdReady = _elapsed(lastAnyAct, now, cycles.rrd);

    // A past write/read only still matters for the precharge gate if it
    // happened during the bank's current open period. One from a prior
    // open/close cycle is stale.
    bool wrReadyFor(int b) {
      final w = lastWrite[b];
      final act = lastAct[b];
      if (w == null || (act != null && w < act)) return true;
      return _elapsed(w, now, cycles.wr);
    }

    bool beatsReadyFor(int b) {
      final r = lastRead[b];
      final act = lastAct[b];
      if (r == null || (act != null && r < act)) return true;
      return _elapsed(r, now, lastReadBeats[b]!);
    }

    final readToWriteReady = _elapsed(
      lastAnyRead,
      now,
      lastAnyRead == null ? 0 : cycles.readToWrite(lastAnyReadBeats!),
    );
    final readSpacingReady = _elapsed(lastAnyRead, now, lastAnyReadBeats ?? 0);

    canAct = [
      for (var b = 0; b < banks; b++)
        !open[b] && rcReady[b] && rpReady[b] && rrdReady && !blackout,
    ];
    canRead = [
      for (var b = 0; b < banks; b++)
        open[b] && rcdReady[b] && readSpacingReady && !blackout,
    ];
    canWrite = [
      for (var b = 0; b < banks; b++)
        open[b] && rcdReady[b] && readToWriteReady && !blackout,
    ];
    final clearToPre = [
      for (var b = 0; b < banks; b++)
        rasMinReady[b] && wrReadyFor(b) && beatsReadyFor(b),
    ];
    canPre = [
      for (var b = 0; b < banks; b++) open[b] && clearToPre[b] && !blackout,
    ];
    canPreAll =
        List.generate(
          banks,
          (b) => !open[b] || clearToPre[b],
        ).every((x) => x) &&
        !blackout;
    // Refresh and mrs both need every bank precharged for at least tRP.
    final rpAllReady = rpReady.every((x) => x);
    canRef = !anyOpenNow && rpAllReady && !blackout;
    canMrs = !anyOpenNow && rpAllReady && !blackout;

    // The age register counts while the registered open flag is high, and
    // the force flag reads the age register.
    rowAgeForce = _ageReg >= cycles.rowAgeLimit;
    _ageReg = _openReg
        ? (_ageReg >= cycles.rowAgeLimit ? _ageReg : _ageReg + 1)
        : 0;
    _openReg = anyOpenNow;
    anyOpen = anyOpenNow;
  }
}

class _Harness {
  final HarborSdramCycles cycles;
  final SdramBankTimers dut;
  final Logic clk;
  final Logic reset;
  final Logic cmd;
  final Logic cmdBank;
  final Logic cmdBeats;

  _Harness._(
    this.cycles,
    this.dut,
    this.clk,
    this.reset,
    this.cmd,
    this.cmdBank,
    this.cmdBeats,
  );

  static Future<_Harness> build(HarborSdramCycles cycles) async {
    final clk = SimpleClockGenerator(cycles.tCkPs).clk;
    final reset = Logic(name: 'reset')..inject(1);
    final cmd = Logic(name: 'cmd', width: 3)..inject(0);
    final cmdBank = Logic(name: 'cmd_bank', width: cycles.config.bankBits)
      ..inject(0);
    final cmdBeats = Logic(name: 'cmd_beats', width: 4)..inject(0);
    final dut = SdramBankTimers(
      cycles,
      clk: clk,
      reset: reset,
      cmd: cmd,
      cmdBank: cmdBank,
      cmdBeats: cmdBeats,
    );
    await dut.build();
    return _Harness._(cycles, dut, clk, reset, cmd, cmdBank, cmdBeats);
  }

  /// Issues one command and advances one edge.
  Future<void> issue(int cmdIndex, int bank, int beats) async {
    cmd.inject(cmdIndex);
    cmdBank.inject(bank);
    cmdBeats.inject(beats);
    await clk.nextPosedge;
  }

  Future<void> nop() => issue(SdramCommand.nop.index, 0, 0);

  void expectMatches(_BankTimersRef ref, {required String reason}) {
    for (var b = 0; b < cycles.config.banks; b++) {
      expect(
        dut.canAct[b].value.toInt(),
        ref.canAct[b] ? 1 : 0,
        reason: '$reason canAct[$b]',
      );
      expect(
        dut.canRead[b].value.toInt(),
        ref.canRead[b] ? 1 : 0,
        reason: '$reason canRead[$b]',
      );
      expect(
        dut.canWrite[b].value.toInt(),
        ref.canWrite[b] ? 1 : 0,
        reason: '$reason canWrite[$b]',
      );
      expect(
        dut.canPre[b].value.toInt(),
        ref.canPre[b] ? 1 : 0,
        reason: '$reason canPre[$b]',
      );
    }
    expect(
      dut.canPreAll.value.toInt(),
      ref.canPreAll ? 1 : 0,
      reason: '$reason canPreAll',
    );
    expect(
      dut.canRef.value.toInt(),
      ref.canRef ? 1 : 0,
      reason: '$reason canRef',
    );
    expect(
      dut.rowAgeForce.value.toInt(),
      ref.rowAgeForce ? 1 : 0,
      reason: '$reason rowAgeForce',
    );
    expect(
      dut.anyOpen.value.toInt(),
      ref.anyOpen ? 1 : 0,
      reason: '$reason anyOpen',
    );
  }
}

Future<void> _release(_Harness h) async {
  // Generous enough for the 6000-cycle random cross-check test.
  const maxCycles = 8000;
  Simulator.setMaxSimTime(maxCycles * h.cycles.tCkPs * 2);
  unawaited(Simulator.run());
  await h.clk.nextPosedge;
  await h.clk.nextPosedge;
  h.reset.inject(0);
}

void main() {
  tearDown(() async => Simulator.reset());

  test('random legal command streams match the Dart reference', () async {
    final cycles = HarborSdramCycles(
      const HarborSdramConfig.as4c16m16sb6(),
      clockHz: 125000000,
    );
    final h = await _Harness.build(cycles);
    await _release(h);

    final ref = _BankTimersRef(cycles);
    final rand = Random(7);

    for (var t = 0; t < 6000; t++) {
      final candidates = <(int, int, int)>[(SdramCommand.nop.index, 0, 0)];
      for (var b = 0; b < cycles.config.banks; b++) {
        if (ref.canAct[b]) candidates.add((SdramCommand.act.index, b, 0));
        if (ref.canRead[b]) {
          candidates.add((SdramCommand.read.index, b, 1 + rand.nextInt(8)));
        }
        if (ref.canWrite[b]) candidates.add((SdramCommand.write.index, b, 0));
        if (ref.canPre[b]) candidates.add((SdramCommand.pre.index, b, 0));
      }
      if (ref.canPreAll) candidates.add((SdramCommand.preAll.index, 0, 0));
      if (ref.canRef) candidates.add((SdramCommand.ref.index, 0, 0));
      if (ref.canMrs) candidates.add((SdramCommand.mrs.index, 0, 0));

      // Bias toward exercising a non-nop command when one is legal.
      final nonNop = candidates
          .where(
            (c) => c.$1 != SdramCommand.nop.index && ref.allowedAfterLast(c.$1),
          )
          .toList();
      final pick = (nonNop.isNotEmpty && rand.nextDouble() < 0.7)
          ? nonNop[rand.nextInt(nonNop.length)]
          : (SdramCommand.nop.index, 0, 0);

      await h.issue(pick.$1, pick.$2, pick.$3);
      ref.step(cmd: pick.$1, bank: pick.$2, beats: pick.$3);
      h.expectMatches(ref, reason: 't=$t');
    }

    await Simulator.endSimulation();
  });

  // Each check issues a command, then finds the first cycle the flag
  // allows the next one. It must be exactly n cycles after the first
  // command was chosen, which is one cycle before the timers see it.
  Future<_Harness> start() async {
    final cycles = HarborSdramCycles(
      const HarborSdramConfig.as4c16m16sb6(),
      clockHz: 125000000,
    );
    final h = await _Harness.build(cycles);
    await _release(h);
    return h;
  }

  /// Issues [cmd] and checks that [flag] first rises when the next
  /// command would be [n] cycles after it.
  Future<void> expectSpacing(
    _Harness h,
    int cmd,
    int bank,
    int beats,
    Logic flag,
    int n,
    String what,
  ) async {
    await h.issue(cmd, bank, beats);
    // Right after the issue, the flag allows a command 2 cycles after.
    for (var gap = 2; gap < n; gap++) {
      expect(flag.value.toInt(), 0, reason: '$what at $gap of $n');
      await h.nop();
    }
    expect(flag.value.toInt(), 1, reason: '$what at $n');
  }

  Future<void> nops(_Harness h, int n) async {
    for (var i = 0; i < n; i++) {
      await h.nop();
    }
  }

  test('rasMin, then rp after a precharge', () async {
    final h = await start();
    final c = h.cycles;
    await expectSpacing(
      h,
      SdramCommand.act.index,
      0,
      0,
      h.dut.canPre[0],
      c.rasMin,
      'canPre after act',
    );
    await expectSpacing(
      h,
      SdramCommand.pre.index,
      0,
      0,
      h.dut.canAct[0],
      c.rp,
      'canAct after pre',
    );
    await Simulator.endSimulation();
  });

  test('rcd for read and write', () async {
    final h = await start();
    final c = h.cycles;
    await expectSpacing(
      h,
      SdramCommand.act.index,
      0,
      0,
      h.dut.canRead[0],
      c.rcd,
      'canRead after act',
    );
    expect(h.dut.canWrite[0].value.toInt(), 1);
    await Simulator.endSimulation();
  });

  test('wr after a write', () async {
    final h = await start();
    final c = h.cycles;
    await h.issue(SdramCommand.act.index, 0, 0);
    await nops(h, c.rasMin + 2);
    await expectSpacing(
      h,
      SdramCommand.write.index,
      0,
      0,
      h.dut.canPre[0],
      c.wr,
      'canPre after write',
    );
    await Simulator.endSimulation();
  });

  for (final beats in [1, 2, 5, 8]) {
    test('read with $beats beats: spacing, precharge and write', () async {
      final h = await start();
      final c = h.cycles;
      await h.issue(SdramCommand.act.index, 0, 0);
      await nops(h, c.rasMin + 2);
      await expectSpacing(
        h,
        SdramCommand.read.index,
        0,
        beats,
        h.dut.canRead[0],
        beats,
        'canRead after read',
      );
      await nops(h, 20);
      await expectSpacing(
        h,
        SdramCommand.read.index,
        0,
        beats,
        h.dut.canPre[0],
        beats,
        'canPre after read',
      );
      await nops(h, 20);
      await expectSpacing(
        h,
        SdramCommand.read.index,
        0,
        beats,
        h.dut.canWrite[0],
        c.readToWrite(beats),
        'canWrite after read',
      );
      await Simulator.endSimulation();
    });
  }

  test('mrd and rfc blackouts', () async {
    final h = await start();
    final c = h.cycles;
    await h.nop();
    await expectSpacing(
      h,
      SdramCommand.mrs.index,
      0,
      0,
      h.dut.canAct[0],
      c.mrd,
      'canAct after mrs',
    );
    expect(h.dut.canRef.value.toInt(), 1);
    await expectSpacing(
      h,
      SdramCommand.ref.index,
      0,
      0,
      h.dut.canAct[0],
      c.rfc,
      'canAct after ref',
    );
    expect(h.dut.canRef.value.toInt(), 1);
    await Simulator.endSimulation();
  });

  test('rrd on a different bank', () async {
    final h = await start();
    await expectSpacing(
      h,
      SdramCommand.act.index,
      0,
      0,
      h.dut.canAct[1],
      h.cycles.rrd,
      'canAct[1] after act',
    );
    await Simulator.endSimulation();
  });

  test('rp before refresh and mrs, after pre and pre all', () async {
    final h = await start();
    final c = h.cycles;
    await h.issue(SdramCommand.act.index, 0, 0);
    await nops(h, c.rasMin);
    await expectSpacing(
      h,
      SdramCommand.pre.index,
      0,
      0,
      h.dut.canRef,
      c.rp,
      'canRef after pre',
    );
    await h.issue(SdramCommand.act.index, 1, 0);
    await nops(h, c.rasMin);
    await expectSpacing(
      h,
      SdramCommand.preAll.index,
      0,
      0,
      h.dut.canRef,
      c.rp,
      'canRef after pre all',
    );
    await Simulator.endSimulation();
  });

  test('rc with a synthetic tRc large enough to bind', () async {
    const customTiming = HarborSdramTiming(
      tRc: 200.0,
      tRfc: 60.0,
      tRcd: 18.0,
      tRp: 18.0,
      tRasMin: 42.0,
      tRasMax: 120000.0,
      tRrd: 12.0,
      tMrd: 12.0,
      tWr: 12.0,
      tCh: 2.0,
      tCl: 2.0,
      tOh: 2.5,
      tLz: 0.0,
      tHz: 5.0,
      tIs: 1.5,
      tIh: 0.8,
      tRefi: 7800.0,
      powerUpNs: 200000.0,
      refreshPeriodNs: 64000000.0,
      tMrdNck: 2,
      refreshCount: 8192,
      initRefreshesMin: 2,
      tCkMinByCl: {2: 10.0, 3: 6.0},
      tAcByCl: {2: 6.0, 3: 5.0},
    );
    final customConfig = HarborSdramConfig(
      part: 'test-trc',
      timing: customTiming,
      rowWidth: 13,
      colWidth: 9,
    );
    final cycles = HarborSdramCycles(customConfig, clockHz: 125000000);
    final h = await _Harness.build(cycles);
    await _release(h);

    // Count cycles from the act. The pre lands at rasMin, and rp clears
    // long before rc does.
    await h.issue(SdramCommand.act.index, 0, 0);
    var gap = 2;
    while (h.dut.canPre[0].value.toInt() == 0) {
      await h.nop();
      gap++;
    }
    expect(gap, cycles.rasMin);
    await h.issue(SdramCommand.pre.index, 0, 0);
    gap++;
    while (gap < cycles.rc) {
      expect(h.dut.canAct[0].value.toInt(), 0, reason: 'canAct at $gap');
      await h.nop();
      gap++;
    }
    expect(h.dut.canAct[0].value.toInt(), 1, reason: 'canAct at rc');
    await Simulator.endSimulation();
  });
}

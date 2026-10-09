/// Sdr sdram per-bank and global command timers.
library;

import 'package:rohd/rohd.dart';

import 'sdram_command.dart';
import 'sdram_cycles.dart';

/// Tracks every per-bank and global ac-timing rule the scheduler needs, and
/// reports each one as its own flip-flop so the scheduler reads a flat set
/// of registers with no comparator chain on its own critical path.
///
/// [cmd], [cmdBank] and [cmdBeats] are the registered command, the one the
/// scheduler chose a cycle earlier (a [SdramCommand] index, its bank, and
/// the read burst length wanted, 1 to 8). A rule that needs n cycles
/// between two commands lets the second one be chosen exactly n cycles
/// after the first. The flags do not yet see the command chosen in the
/// cycle before, so the scheduler blocks what that command forbids for
/// that one cycle. as4c16m16sb datasheet rev 2.0, table 16 p21 and
/// command 12 p17.
class SdramBankTimers extends Module {
  /// The device and clock this timing is built for.
  final HarborSdramCycles cycles;

  /// Number of banks.
  int get banks => cycles.config.banks;

  /// Per-bank: the bank is closed, past rc/rp/rrd, and clear to activate.
  List<Logic> get canAct => List.generate(banks, (b) => output('can_act_$b'));

  /// Per-bank: the bank is open, past rcd, and clear to read.
  List<Logic> get canRead => List.generate(banks, (b) => output('can_read_$b'));

  /// Per-bank: the bank is open, past rcd, and clear to write.
  List<Logic> get canWrite =>
      List.generate(banks, (b) => output('can_write_$b'));

  /// Per-bank: the bank is open and past rasMin/wr/beats, clear to
  /// precharge.
  List<Logic> get canPre => List.generate(banks, (b) => output('can_pre_$b'));

  /// Every open bank is clear to precharge.
  Logic get canPreAll => output('can_pre_all');

  /// No bank is open and no refresh/mrs blackout is in effect.
  Logic get canRef => output('can_ref');

  /// A row has stayed open at least [HarborSdramCycles.rowAgeLimit] cycles.
  Logic get rowAgeForce => output('row_age_force');

  /// At least one bank is open.
  Logic get anyOpen => output('any_open');

  SdramBankTimers(
    this.cycles, {
    required Logic clk,
    required Logic reset,
    required Logic cmd,
    required Logic cmdBank,
    required Logic cmdBeats,
    super.name = 'sdram_bank_timers',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    cmd = addInput('cmd', cmd, width: 3);
    final bankBits = cycles.config.bankBits;
    cmdBank = addInput('cmd_bank', cmdBank, width: bankBits);
    const beatsWidth = 4;
    cmdBeats = addInput('cmd_beats', cmdBeats, width: beatsWidth);

    for (var b = 0; b < banks; b++) {
      addOutput('can_act_$b');
      addOutput('can_read_$b');
      addOutput('can_write_$b');
      addOutput('can_pre_$b');
    }
    addOutput('can_pre_all');
    addOutput('can_ref');
    addOutput('row_age_force');
    addOutput('any_open');

    int widthFor(int v) => v <= 0 ? 1 : v.bitLength;

    Logic isCmd(SdramCommand c) => cmd.eq(c.index);
    final isAct = isCmd(SdramCommand.act);
    final isRead = isCmd(SdramCommand.read);
    final isWrite = isCmd(SdramCommand.write);
    final isPre = isCmd(SdramCommand.pre);
    final isPreAll = isCmd(SdramCommand.preAll);
    final isRef = isCmd(SdramCommand.ref);
    final isMrs = isCmd(SdramCommand.mrs);
    Logic bankIs(int b) => cmdBank.eq(Const(b, width: bankBits));

    // The next value of a down-counter: reload to [reloadValue] when
    // [reload] fires this cycle, else decrement and floor at 0.
    Logic downNext(Logic counter, Logic reload, Logic reloadValue, int width) {
      final held = mux(counter.eq(0), Const(0, width: width), counter - 1);
      return mux(reload, reloadValue.zeroExtend(width), held);
    }

    // The counter covers n - 2 cycles: one for the command register and
    // one for the flag register.
    int span(int n) => n > 2 ? n - 2 : 0;

    Logic downNextC(Logic counter, Logic reload, int n, int width) =>
        downNext(counter, reload, Const(span(n), width: width), width);

    // Cycles from a read command until a write may issue, by beats
    // (1..8). as4c16m16sb datasheet rev 2.0, p9 text, fig 7/8 p10.
    final readToWriteMax = List.generate(
      8,
      (i) => cycles.readToWrite(i + 1),
    ).reduce((a, b) => a > b ? a : b);
    final readToWriteWidth = widthFor(readToWriteMax);
    Logic readToWriteFor(Logic beats) => cases(
      beats,
      {
        for (var n = 1; n <= 8; n++)
          Const(n, width: beatsWidth): Const(
            span(cycles.readToWrite(n)),
            width: readToWriteWidth,
          ),
      },
      defaultValue: Const(span(cycles.readToWrite(8)), width: readToWriteWidth),
      conditionalType: ConditionalType.unique,
    );

    // --- per-bank state ---
    final bankOpen = [
      for (var b = 0; b < banks; b++) Logic(name: 'bank_open_$b'),
    ];
    final rcTimer = [
      for (var b = 0; b < banks; b++)
        Logic(name: 'rc_timer_$b', width: widthFor(cycles.rc)),
    ];
    final rpTimer = [
      for (var b = 0; b < banks; b++)
        Logic(name: 'rp_timer_$b', width: widthFor(cycles.rp)),
    ];
    final rcdTimer = [
      for (var b = 0; b < banks; b++)
        Logic(name: 'rcd_timer_$b', width: widthFor(cycles.rcd)),
    ];
    final rasTimer = [
      for (var b = 0; b < banks; b++)
        Logic(name: 'ras_timer_$b', width: widthFor(cycles.rasMin)),
    ];
    final wrTimer = [
      for (var b = 0; b < banks; b++)
        Logic(name: 'wr_timer_$b', width: widthFor(cycles.wr)),
    ];
    // Holds a precharge to that bank until the wanted burst has run its
    // course. as4c16m16sb datasheet rev 2.0, fig 9, p10.
    final readBeatsTimer = [
      for (var b = 0; b < banks; b++)
        Logic(name: 'read_beats_timer_$b', width: beatsWidth),
    ];

    // --- global state ---
    final rrdTimer = Logic(name: 'rrd_timer', width: widthFor(cycles.rrd));
    final mrdTimer = Logic(name: 'mrd_timer', width: widthFor(cycles.mrd));
    final rfcTimer = Logic(name: 'rfc_timer', width: widthFor(cycles.rfc));
    final readToWriteTimer = Logic(
      name: 'read_to_write_timer',
      width: readToWriteWidth,
    );
    // Spaces back-to-back reads by the first read's beats, so two bursts
    // never collide on the data bus. as4c16m16sb datasheet rev 2.0, fig 5,
    // p9.
    final readSpacingTimer = Logic(
      name: 'read_spacing_timer',
      width: beatsWidth,
    );
    // A global row-open timer, standing in for a per-row tRAS max clock:
    // it forces a precharge-all before any open row could overrun it.
    final rowAgeWidth = widthFor(cycles.rowAgeLimit);
    final rowAge = Logic(name: 'row_age', width: rowAgeWidth);

    // --- output registers ---
    final canActReg = [
      for (var b = 0; b < banks; b++) Logic(name: 'can_act_reg_$b'),
    ];
    final canReadReg = [
      for (var b = 0; b < banks; b++) Logic(name: 'can_read_reg_$b'),
    ];
    final canWriteReg = [
      for (var b = 0; b < banks; b++) Logic(name: 'can_write_reg_$b'),
    ];
    final canPreReg = [
      for (var b = 0; b < banks; b++) Logic(name: 'can_pre_reg_$b'),
    ];
    final canPreAllReg = Logic(name: 'can_pre_all_reg');
    final canRefReg = Logic(name: 'can_ref_reg');
    final rowAgeForceReg = Logic(name: 'row_age_force_reg');
    final anyOpenReg = Logic(name: 'any_open_reg');

    for (var b = 0; b < banks; b++) {
      output('can_act_$b') <= canActReg[b];
      output('can_read_$b') <= canReadReg[b];
      output('can_write_$b') <= canWriteReg[b];
      output('can_pre_$b') <= canPreReg[b];
    }
    output('can_pre_all') <= canPreAllReg;
    output('can_ref') <= canRefReg;
    output('row_age_force') <= rowAgeForceReg;
    output('any_open') <= anyOpenReg;

    // --- next-state wires, built once and reused by the counter update
    // and the can* gating below ---
    final bankOpenNext = [
      for (var b = 0; b < banks; b++)
        mux(
          isAct & bankIs(b),
          Const(1),
          mux((isPre & bankIs(b)) | isPreAll, Const(0), bankOpen[b]),
        ),
    ];
    final rcTimerNext = [
      for (var b = 0; b < banks; b++)
        downNextC(
          rcTimer[b],
          isAct & bankIs(b),
          cycles.rc,
          widthFor(cycles.rc),
        ),
    ];
    final rpTimerNext = [
      for (var b = 0; b < banks; b++)
        downNextC(
          rpTimer[b],
          (isPre & bankIs(b)) | isPreAll,
          cycles.rp,
          widthFor(cycles.rp),
        ),
    ];
    final rcdTimerNext = [
      for (var b = 0; b < banks; b++)
        downNextC(
          rcdTimer[b],
          isAct & bankIs(b),
          cycles.rcd,
          widthFor(cycles.rcd),
        ),
    ];
    final rasTimerNext = [
      for (var b = 0; b < banks; b++)
        downNextC(
          rasTimer[b],
          isAct & bankIs(b),
          cycles.rasMin,
          widthFor(cycles.rasMin),
        ),
    ];
    final wrTimerNext = [
      for (var b = 0; b < banks; b++)
        downNextC(
          wrTimer[b],
          isWrite & bankIs(b),
          cycles.wr,
          widthFor(cycles.wr),
        ),
    ];
    final beatsSpan = mux(
      cmdBeats.gt(2),
      cmdBeats - 2,
      Const(0, width: beatsWidth),
    );
    final readBeatsTimerNext = [
      for (var b = 0; b < banks; b++)
        downNext(readBeatsTimer[b], isRead & bankIs(b), beatsSpan, beatsWidth),
    ];

    final rrdTimerNext = downNextC(
      rrdTimer,
      isAct,
      cycles.rrd,
      widthFor(cycles.rrd),
    );
    final mrdTimerNext = downNextC(
      mrdTimer,
      isMrs,
      cycles.mrd,
      widthFor(cycles.mrd),
    );
    final rfcTimerNext = downNextC(
      rfcTimer,
      isRef,
      cycles.rfc,
      widthFor(cycles.rfc),
    );
    final readToWriteTimerNext = downNext(
      readToWriteTimer,
      isRead,
      readToWriteFor(cmdBeats),
      readToWriteWidth,
    );
    final readSpacingTimerNext = downNext(
      readSpacingTimer,
      isRead,
      beatsSpan,
      beatsWidth,
    );

    final anyOpenNext = bankOpenNext.reduce((a, b) => a | b);
    // The age runs from the registered open flag and the force flag reads
    // the registered age, so the flag lags by two cycles. The limit keeps
    // a 10 percent margin under tRAS max, which covers that.
    final rowAgeAtLimit = rowAge.gte(cycles.rowAgeLimit);
    final rowAgeNext = mux(
      anyOpenReg,
      mux(rowAgeAtLimit, rowAge, rowAge + 1),
      Const(0, width: rowAgeWidth),
    );
    final rowAgeForceNext = rowAgeAtLimit;

    // Only a nop is legal while either blackout window is open.
    // as4c16m16sb datasheet rev 2.0, command 8 text p13, command 12 p17.
    final cmdBlackoutNext = mrdTimerNext.neq(0) | rfcTimerNext.neq(0);

    final canActNext = [
      for (var b = 0; b < banks; b++)
        ~bankOpenNext[b] &
            rcTimerNext[b].eq(0) &
            rpTimerNext[b].eq(0) &
            rrdTimerNext.eq(0) &
            ~cmdBlackoutNext,
    ];
    final canReadNext = [
      for (var b = 0; b < banks; b++)
        bankOpenNext[b] &
            rcdTimerNext[b].eq(0) &
            readSpacingTimerNext.eq(0) &
            ~cmdBlackoutNext,
    ];
    final canWriteNext = [
      for (var b = 0; b < banks; b++)
        bankOpenNext[b] &
            rcdTimerNext[b].eq(0) &
            readToWriteTimerNext.eq(0) &
            ~cmdBlackoutNext,
    ];
    final bankClearToPreNext = [
      for (var b = 0; b < banks; b++)
        rasTimerNext[b].eq(0) &
            wrTimerNext[b].eq(0) &
            readBeatsTimerNext[b].eq(0),
    ];
    final canPreNext = [
      for (var b = 0; b < banks; b++)
        bankOpenNext[b] & bankClearToPreNext[b] & ~cmdBlackoutNext,
    ];
    final canPreAllNext =
        [
          for (var b = 0; b < banks; b++)
            ~bankOpenNext[b] | bankClearToPreNext[b],
        ].reduce((a, b) => a & b) &
        ~cmdBlackoutNext;
    // Refresh and mrs both need every bank precharged for at least tRP,
    // not just closed. as4c16m16sb datasheet rev 2.0, command 12 p17,
    // fig 15 p14.
    final rpAllClearNext = [
      for (var b = 0; b < banks; b++) rpTimerNext[b].eq(0),
    ].reduce((a, b) => a & b);
    final canRefNext = ~anyOpenNext & rpAllClearNext & ~cmdBlackoutNext;

    Sequential(clk, [
      If(
        reset,
        then: [
          for (final r in [
            ...bankOpen,
            ...rcTimer,
            ...rpTimer,
            ...rcdTimer,
            ...rasTimer,
            ...wrTimer,
            ...readBeatsTimer,
            rrdTimer,
            mrdTimer,
            rfcTimer,
            readToWriteTimer,
            readSpacingTimer,
            rowAge,
            ...canActReg,
            ...canReadReg,
            ...canWriteReg,
            ...canPreReg,
            canPreAllReg,
            canRefReg,
            rowAgeForceReg,
            anyOpenReg,
          ])
            r < Const(0, width: r.width),
        ],
        orElse: [
          for (var b = 0; b < banks; b++) ...[
            bankOpen[b] < bankOpenNext[b],
            rcTimer[b] < rcTimerNext[b],
            rpTimer[b] < rpTimerNext[b],
            rcdTimer[b] < rcdTimerNext[b],
            rasTimer[b] < rasTimerNext[b],
            wrTimer[b] < wrTimerNext[b],
            readBeatsTimer[b] < readBeatsTimerNext[b],
            canActReg[b] < canActNext[b],
            canReadReg[b] < canReadNext[b],
            canWriteReg[b] < canWriteNext[b],
            canPreReg[b] < canPreNext[b],
          ],
          rrdTimer < rrdTimerNext,
          mrdTimer < mrdTimerNext,
          rfcTimer < rfcTimerNext,
          readToWriteTimer < readToWriteTimerNext,
          readSpacingTimer < readSpacingTimerNext,
          rowAge < rowAgeNext,
          canPreAllReg < canPreAllNext,
          canRefReg < canRefNext,
          rowAgeForceReg < rowAgeForceNext,
          anyOpenReg < anyOpenNext,
        ],
      ),
    ]);
  }
}

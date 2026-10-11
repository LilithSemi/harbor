/// Sdr sdram engine: init, refresh, bank timing and a one look-ahead
/// command scheduler in front of a [SdramPhyBase].
library;

import 'package:meta/meta.dart';
import 'package:rohd/rohd.dart';

import 'sdram_bank_timers.dart';
import 'sdram_command.dart';
import 'sdram_config.dart';
import 'sdram_cycles.dart';
import 'sdram_init.dart';
import 'sdram_port.dart';
import 'sdram_refresh.dart';

/// One queued transaction. The address is split at enqueue, and [hit] and
/// [miss] say if the bank holds this row or another row, so the issue path
/// reads flags and never compares rows.
class _Entry {
  final Logic valid, write, bank, row, col, rem, beats, fin, port, hit, miss;

  _Entry(
    String p, {
    required int bankBits,
    required int rowWidth,
    required int colWidth,
    required int remWidth,
    required int portWidth,
  }) : valid = Logic(name: '${p}_valid'),
       write = Logic(name: '${p}_write'),
       bank = Logic(name: '${p}_bank', width: bankBits),
       row = Logic(name: '${p}_row', width: rowWidth),
       col = Logic(name: '${p}_col', width: colWidth),
       rem = Logic(name: '${p}_rem', width: remWidth),
       beats = Logic(name: '${p}_beats', width: 4),
       fin = Logic(name: '${p}_fin'),
       port = Logic(name: '${p}_port', width: portWidth),
       hit = Logic(name: '${p}_hit'),
       miss = Logic(name: '${p}_miss');

  List<Logic> get fields => [
    valid,
    write,
    bank,
    row,
    col,
    rem,
    beats,
    fin,
    port,
    hit,
    miss,
  ];
}

/// Sdr sdram engine. It runs the init sequence, keeps refresh credit and
/// bank timers, and issues one command per cycle for the current
/// transaction and one look-ahead entry from [SdramPortInterface].
///
/// Every `phy_*` output comes from a register; `rd_data` returns on the
/// port [phyReadLatency] cycles after the read command leaves them. New
/// requests enter the look-ahead entry, which moves into the current
/// entry once that one is empty or finishing.
///
/// `abort` is the bus side reset: it drops queued reads and in-flight read
/// data, but queued writes still run and init, refresh and bank state
/// keep going, so the sdram keeps its contents. It keeps the reads of the
/// ports in `keepReadsOnAbort`, which have their own reset.
class SdramEngine extends Module {
  final HarborSdramConfig config;
  final HarborSdramCycles cycles;

  /// Largest request in words.
  final int maxGrantWords;

  /// Idle cycles with no request before the engine closes open rows to
  /// pull a refresh in early.
  final int pullInIdleCycles;

  /// Forces a precharge-all once a row has stayed open past
  /// [HarborSdramCycles.rowAgeLimit]. Only the test-only
  /// `debugSdramEngineWithoutRowAgeGuard` turns it off, to show tRAS max
  /// fails without it.
  final bool rowAgeGuard;

  Logic get phyCke => output('phy_cke');
  Logic get phyCsN => output('phy_cs_n');
  Logic get phyRasN => output('phy_ras_n');
  Logic get phyCasN => output('phy_cas_n');
  Logic get phyWeN => output('phy_we_n');
  Logic get phyBa => output('phy_ba');
  Logic get phyAddr => output('phy_addr');
  Logic get phyDqm => output('phy_dqm');
  Logic get phyDqOut => output('phy_dq_out');
  Logic get phyDqOe => output('phy_dq_oe');

  /// High once the init sequence is complete.
  Logic get initDone => output('init_done');

  /// Signed refresh credit from [SdramRefreshCredit.owed].
  Logic get refreshOwed => output('refresh_owed');

  SdramEngine(
    HarborSdramConfig config,
    HarborSdramCycles cycles, {
    required Logic clk,
    required Logic reset,
    required SdramPortInterface port,
    required Logic phyRdData,
    required int phyReadLatency,
    Logic? abort,
    Logic? abortNext,
    Logic? coldReset,
    Logic? timersReset,
    Logic? dataReset,
    Set<int> keepReadsOnAbort = const {},
    int maxGrantWords = 8,
    int pullInIdleCycles = 16,
    String name = 'sdram_engine',
  }) : this._(
         config,
         cycles,
         clk: clk,
         reset: reset,
         port: port,
         phyRdData: phyRdData,
         phyReadLatency: phyReadLatency,
         abort: abort,
         abortNext: abortNext,
         coldReset: coldReset,
         timersReset: timersReset,
         dataReset: dataReset,
         keepReadsOnAbort: keepReadsOnAbort,
         maxGrantWords: maxGrantWords,
         pullInIdleCycles: pullInIdleCycles,
         rowAgeGuard: true,
         name: name,
       );

  SdramEngine._(
    this.config,
    this.cycles, {
    required Logic clk,
    required Logic reset,
    required SdramPortInterface port,
    required Logic phyRdData,
    required int phyReadLatency,
    required Logic? abort,
    required Logic? abortNext,
    required Logic? coldReset,
    required Logic? timersReset,
    required Logic? dataReset,
    required Set<int> keepReadsOnAbort,
    required this.maxGrantWords,
    required this.pullInIdleCycles,
    required this.rowAgeGuard,
    required String name,
  }) : super(name: name) {
    final bankBits = config.bankBits;
    final rowW = config.rowWidth;
    final colW = config.colWidth;
    final dataW = config.dataWidth;
    final dqmW = dataW ~/ 8;
    final cl = cycles.casLatency;

    if (dataW != 16) {
      throw ArgumentError('the sdram engine needs a 16-bit data bus');
    }
    if (maxGrantWords < 1 || maxGrantWords > 64) {
      throw ArgumentError('maxGrantWords must be in 1..64');
    }
    if (port.portIdWidth < 1) {
      throw ArgumentError('the engine port needs portIdWidth >= 1');
    }
    if (port.addrWidth != config.wordAddrWidth) {
      throw ArgumentError(
        'port addrWidth must be ${config.wordAddrWidth}, got '
        '${port.addrWidth}',
      );
    }
    if ((1 << port.wordsWidth) - 1 < maxGrantWords) {
      throw ArgumentError('port wordsWidth cannot hold $maxGrantWords');
    }
    if (port.wordsWidth > colW) {
      throw ArgumentError('port wordsWidth must not exceed $colW');
    }
    if (pullInIdleCycles < 1) {
      throw ArgumentError('pullInIdleCycles must be at least 1');
    }
    if (cl < 2) {
      throw ArgumentError('cas latency must be at least 2');
    }
    if (phyReadLatency < cl) {
      throw ArgumentError('phyReadLatency must be at least the cas latency');
    }

    // Captured before `reset` below is rebound to the internal input wire:
    // a module input may not be wired from a sibling input of the same
    // module, so the no-coldReset default must come from the original
    // external signal, not from the `reset` port itself.
    final externalReset = reset;
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    phyRdData = addInput('phy_rd_data', phyRdData, width: dataW);
    // The value [abort] takes at the next edge. With it, the select reads
    // the abort from its gate registers and not from the abort net.
    final abortNextSig = abortNext == null
        ? null
        : addInput('abort_next', abortNext);
    abort = addInput('abort', abort ?? Const(0));
    // Only a real power-on clears [warmReset] below. With no [coldReset]
    // given, every reset counts as cold, so warmReset never latches and
    // init always takes the cold path: unchanged from before this input
    // existed.
    final coldResetSig = addInput('cold_reset', coldReset ?? externalReset);
    // A copy of [reset] for the bank timers, so neither reset net carries
    // every flop in the engine. It must assert and release with [reset].
    final timersResetSig = addInput(
      'timers_reset',
      timersReset ?? externalReset,
    );
    // A copy of [reset] for the command, entry and read return registers.
    // It must assert and release with [reset].
    final dataResetSig = addInput('data_reset', dataReset ?? externalReset);
    if (!port.wrLookahead) {
      throw ArgumentError('the engine port needs wrLookahead');
    }
    port = SdramPortInterface(
      addrWidth: port.addrWidth,
      wordsWidth: port.wordsWidth,
      portIdWidth: port.portIdWidth,
      wrLookahead: true,
    )..pairConnectIO(this, port, PairRole.provider);

    final remW = port.wordsWidth < 4 ? 4 : port.wordsWidth;
    final portW = port.portIdWidth;
    // The abort for a read of port [p]: low for a port that keeps its reads.
    final keep = keepReadsOnAbort.where((k) => k < (1 << portW)).toList();
    Logic abortFor(Logic a, Logic p) => keep.isEmpty
        ? a
        : a & ~[for (final k in keep) p.eq(k)].reduce((x, y) => x | y);

    final phyCkeR = Logic(name: 'phy_cke_r');
    final phyCsNR = Logic(name: 'phy_cs_n_r');
    final phyRasNR = Logic(name: 'phy_ras_n_r');
    final phyCasNR = Logic(name: 'phy_cas_n_r');
    final phyWeNR = Logic(name: 'phy_we_n_r');
    final phyBaR = Logic(name: 'phy_ba_r', width: bankBits);
    final phyAddrR = Logic(name: 'phy_addr_r', width: rowW);
    final phyDqmR = Logic(name: 'phy_dqm_r', width: dqmW);
    final phyDqOutR = Logic(name: 'phy_dq_out_r', width: dataW);
    final phyDqOeR = Logic(name: 'phy_dq_oe_r');

    addOutput('phy_cke') <= phyCkeR;
    addOutput('phy_cs_n') <= phyCsNR;
    addOutput('phy_ras_n') <= phyRasNR;
    addOutput('phy_cas_n') <= phyCasNR;
    addOutput('phy_we_n') <= phyWeNR;
    addOutput('phy_ba', width: bankBits) <= phyBaR;
    addOutput('phy_addr', width: rowW) <= phyAddrR;
    addOutput('phy_dqm', width: dqmW) <= phyDqmR;
    addOutput('phy_dq_out', width: dataW) <= phyDqOutR;
    addOutput('phy_dq_oe', width: dataW) <= phyDqOeR.replicate(dataW);

    // Sticky across a plain [reset] (mem_reset): set once init completes,
    // cleared only by [coldResetSig]. A reset that finds this set is a
    // reset after a previous power-up, so banks may still be open.
    final warmReset = Logic(name: 'warm_reset');
    final init = SdramInitSequencer(
      cycles,
      clk: clk,
      reset: reset,
      warmReset: warmReset,
    );
    final initDone = init.done;
    addOutput('init_done') <= initDone;
    Sequential(
      clk,
      [
        If(initDone, then: [warmReset < Const(1)]),
      ],
      reset: coldResetSig,
      asyncReset: true,
      resetValues: {warmReset: Const(0)},
    );

    // The last command as one registered strobe per command and bank, so
    // the timers need no decode.
    final banks = config.banks;
    final lastAct = Logic(name: 'last_act', width: banks);
    final lastPre = Logic(name: 'last_pre', width: banks);
    final lastRead = Logic(name: 'last_read', width: banks);
    final lastWrite = Logic(name: 'last_write', width: banks);
    final lastPreAll = Logic(name: 'last_pre_all');
    final lastMrs = Logic(name: 'last_mrs');
    final lastBeats = Logic(name: 'last_beats', width: 4);
    final lastRefCmd = Logic(name: 'last_ref_cmd');
    final lastBeatsNext = Logic(name: 'last_beats_next', width: 4);
    final timers = SdramBankTimers.strobes(
      cycles,
      clk: clk,
      reset: timersResetSig,
      act: lastAct,
      pre: lastPre,
      read: lastRead,
      write: lastWrite,
      preAll: lastPreAll,
      ref: lastRefCmd,
      mrs: lastMrs,
      cmdBeats: lastBeats,
      cmdBeatsNext: lastBeatsNext,
    );

    final lastRef = Logic(name: 'last_ref');
    final credit = SdramRefreshCredit(
      refi: cycles.refi,
      maxPostponed: cycles.maxPostponed,
      maxPulledIn: cycles.maxPulledIn,
      clk: clk,
      reset: reset | ~initDone,
      // Always on today; a v2 refreshHint would drive this instead.
      enable: Const(1),
      issued: lastRef,
    );
    addOutput('refresh_owed', width: credit.owedWidth) <= credit.owed;

    Logic pick(List<Logic> flags, Logic bank) => [
      for (var b = 0; b < flags.length; b++) flags[b] & bank.eq(b),
    ].reduce((a, b) => a | b);

    _Entry entry(String p) => _Entry(
      p,
      bankBits: bankBits,
      rowWidth: rowW,
      colWidth: colW,
      remWidth: remW,
      portWidth: portW,
    );
    final cur = entry('cur');
    final la = entry('la');
    final laSameBank = Logic(name: 'la_same_bank');
    final laSameRow = Logic(name: 'la_same_row');
    final laEvAct = Logic(name: 'la_ev_act');
    final laEvPre = Logic(name: 'la_ev_pre');
    final laEvAll = Logic(name: 'la_ev_all');
    // Set in the cycle after la was filled, while its hit and miss are
    // still being worked out from the registered open row compare.
    final laFresh = Logic(name: 'la_fresh');
    // The open row compare and the bank open flag for the bank of the new
    // entry, registered when it was filled.
    final laFreshHit = Logic(name: 'la_fresh_hit');
    final laFreshOpen = Logic(name: 'la_fresh_open');

    final bankOpen = [
      for (var b = 0; b < config.banks; b++) Logic(name: 'bank_open_$b'),
    ];
    final openRow = [
      for (var b = 0; b < config.banks; b++)
        Logic(name: 'open_row_$b', width: rowW),
    ];

    // Registered refresh and force requests.
    final forceAny = Logic(name: 'force_any');
    final forceRef = Logic(name: 'force_ref');
    final idleRefWant = Logic(name: 'idle_ref_want');
    final refCommit = Logic(name: 'ref_commit');
    final idleWidth = pullInIdleCycles.bitLength;
    final idleCnt = Logic(name: 'idle_cnt', width: idleWidth);
    final idleLong = Logic(name: 'idle_long');

    // The arbiter learns of a taken write word one cycle late, so right
    // after a take the word to use is its second one.
    final wrTook = Logic(name: 'wr_took');
    final wrDataNow = mux(wrTook, port.wrNextData, port.wrData);
    final wrMaskNow = mux(wrTook, port.wrNextMask, port.wrMask);

    // Timer flags picked by the bank of each entry, one register each.
    // They load from the timers' next flags and each entry's next bank.
    final curCanAct = Logic(name: 'cur_can_act');
    final curCanPre = Logic(name: 'cur_can_pre');
    final curCanColR = Logic(name: 'cur_can_col');
    // The parts of the cur and la gates that come from registers only,
    // loaded one cycle early from their next values.
    final curGo = Logic(name: 'cur_go');
    final laBase = Logic(name: 'la_base');
    final laCanAct = Logic(name: 'la_can_act');
    final laCanPre = Logic(name: 'la_can_pre');

    // --- command select, one hot ---
    // The select picks a command from registers and loads it into the
    // sel_* registers, which drive the pins and the entry state one cycle
    // later. The timers see the pick itself, so the rules count from the
    // pick. The entry state does not yet hold the
    // command on sel_*, so an entry is not picked while sel_* holds a
    // command for it, except the next column of the same request. A
    // finishing column, a precharge all and a refresh hold back both.
    final selPreAll = Logic(name: 'sel_pre_all');
    final selRef = Logic(name: 'sel_ref');
    final selCurCol = Logic(name: 'sel_cur_col');
    final selCurPre = Logic(name: 'sel_cur_pre');
    final selCurAct = Logic(name: 'sel_cur_act');
    final selLaPre = Logic(name: 'sel_la_pre');
    final selLaAct = Logic(name: 'sel_la_act');
    final selIdle = Logic(name: 'sel_idle');

    // The refresh wants and the hold that keeps the entries out of their
    // way come from registers, one cycle behind the state they read. The
    // hold is folded into [curGo] and [laBase], so no pick runs in that
    // cycle.
    final wantPreAll = Logic(name: 'want_pre_all');
    final wantRef = Logic(name: 'want_ref');
    final idleNow = ~cur.valid & ~la.valid & idleRefWant;
    // A force does not wait for the current request to end. Its precharge
    // all can cut that request, which opens its row again afterwards.
    final wantPreAllNext = initDone & (forceAny | idleNow);
    final wantRefNext = initDone & (forceRef | idleNow | refCommit);
    final holdNext = ~initDone | wantPreAllNext | wantRefNext;

    // The sel_* registers and free flags cover the cycle the timers miss.
    // This needs want_* to hold curGo and laBase low in that cycle, and no
    // promote after a column of cur that is not its last. If either rule
    // breaks, the removed one-cycle blocks must come back.
    final pickPreAll =
        (selIdle & wantPreAll & timers.anyOpen & timers.canPreAll).named(
          'pick_pre_all',
        );
    final pickRef = (selIdle & wantRef & ~timers.anyOpen & timers.canRef).named(
      'pick_ref',
    );

    final readIssue = (selCurCol & ~cur.write).named('read_issue');
    final writeIssue = (selCurCol & cur.write).named('write_issue');
    // An abort drops queued reads at the next edge, so none is picked.
    // Given [abortNextSig], cur_go and la_base hold this.
    final curKeep = abortNextSig == null
        ? ~(abortFor(abort, cur.port) & ~cur.write)
        : Const(1);
    final laKeep = abortNextSig == null
        ? ~(abortFor(abort, la.port) & ~la.write)
        : Const(1);
    // Registers loaded with the pick, so the select reads flops only.
    // cur_free: the entry state is up to date for cur.
    // cur_free_act: cur_free, and la picked no activate.
    // la_free: no precharge all, refresh or finishing column was picked.
    // col_ready: cur_free with a write word ready if cur writes, or a
    // column on sel_* that is not the last, with the next write word ready
    // or a 1-beat read followed by the last word of its request.
    // col_holds_pre: the column on sel_* is a write or a read longer than 1
    // beat, which holds back a precharge.
    final curFree = Logic(name: 'cur_free');
    final curFreeAct = Logic(name: 'cur_free_act');
    final laFree = Logic(name: 'la_free');
    final colReady = Logic(name: 'col_ready');
    final colHoldsPre = Logic(name: 'col_holds_pre');
    final pickCurCol = (curGo & curKeep & cur.hit & curCanColR & colReady)
        .named('pick_cur_col');
    final pickCurPre = (curFree & curGo & curKeep & cur.miss & curCanPre).named(
      'pick_cur_pre',
    );
    final pickCurAct =
        (curFreeAct & curGo & curKeep & ~cur.hit & ~cur.miss & curCanAct).named(
          'pick_cur_act',
        );
    final curAny = pickCurCol | pickCurPre | pickCurAct;

    // la issues a row command only when cur picks nothing.
    final laRowGo = laFree & ~selLaPre & ~selLaAct & laBase & laKeep;
    final laPreOk = laRowGo & la.miss & ~(selCurCol & colHoldsPre) & laCanPre;
    final laActOk = laRowGo & ~la.hit & ~la.miss & ~selCurAct & laCanAct;
    final pickLaPre = (laPreOk & ~curAny).named('pick_la_pre');
    final pickLaAct = (laActOk & ~curAny).named('pick_la_act');
    final pickRead = pickCurCol & ~cur.write;
    final pickWrite = pickCurCol & cur.write;
    // The fin flag of the picked column. A column picked while one is on
    // sel_* is the next word of cur: a write ends at 2 words left, and a
    // read is always its last word.
    final pickFin =
        pickCurCol & mux(selCurCol, ~cur.write | cur.rem.eq(2), cur.fin);

    final isPre = selCurPre | selLaPre;
    final curCmd = selCurCol | selCurPre | selCurAct;
    final rowAny = selCurPre | selCurAct | selLaPre | selLaAct;

    // Bank and address come from whichever side issues. With no command
    // they are don't care, so the select only needs curCmd and selPreAll.
    final baNext = mux(initDone, mux(curCmd, cur.bank, la.bank), init.cmdBa);
    // a10 picks precharge all.
    final a10 = Const(1 << 10, width: rowW);
    final initAddr =
        init.cmdAddr |
        mux(init.cmd.eq(SdramCommand.preAll.index), a10, Const(0, width: rowW));
    final zeroAddr = Const(0, width: rowW);
    final curAddr = mux(
      cur.hit,
      cur.col.zeroExtend(rowW),
      mux(cur.miss, zeroAddr, cur.row),
    );
    final laAddr = mux(la.miss, zeroAddr, la.row);
    final addrNext = mux(
      initDone,
      mux(curCmd, curAddr, mux(selPreAll, a10, laAddr)),
      initAddr,
    );

    final initPins = cases(
      init.cmd,
      {
        for (final c in SdramCommand.values)
          Const(c.index, width: 3): Const(
            (c.csN << 3) | (c.rasN << 2) | (c.casN << 1) | c.weN,
            width: 4,
          ),
      },
      width: 4,
      conditionalType: ConditionalType.unique,
    );
    final csNNext = mux(initDone, selIdle, initPins[3]);
    final rasNNext = mux(initDone, ~(rowAny | selPreAll | selRef), initPins[2]);
    final casNNext = mux(initDone, ~(selCurCol | selRef), initPins[1]);
    final weNNext = mux(
      initDone,
      ~(writeIssue | isPre | selPreAll),
      initPins[0],
    );

    // --- enqueue, always into the look-ahead entry ---
    // An entry is free unless a force waits. This comes from a register
    // loaded with the next values, so the ready has no logic path in it.
    final roomR = Logic(name: 'room_r');
    final reqReady = (initDone & roomR).named('req_ready_c');
    port.reqReady <= reqReady;
    final accept = port.reqValid & reqReady;

    final a = port.reqAddr;
    final inCol = a.getRange(0, colW);
    final Logic inBank, inRow;
    if (config.addressMap == HarborSdramAddressMap.rowBankCol) {
      inBank = a.getRange(colW, colW + bankBits);
      inRow = a.getRange(colW + bankBits, colW + bankBits + rowW);
    } else {
      inRow = a.getRange(colW, colW + rowW);
      inBank = a.getRange(colW + rowW, colW + rowW + bankBits);
    }
    final inWords = port.reqWords.zeroExtend(remW);
    final room = Const(8, width: 4) - inCol.getRange(0, 3).zeroExtend(4);
    final inFitsBlock = inWords.lte(room.zeroExtend(remW));
    final inBeats = mux(inFitsBlock, inWords.getRange(0, 4), room);
    final inFin = mux(port.reqWrite, inWords.eq(1), inFitsBlock);

    // The new entry is compared with the entry that is current after this
    // edge: cur, or la when cur is empty and la moves up. Its hit and miss
    // are worked out in the next cycle: this cycle only registers the open
    // row compare for its bank. A bank command in this cycle can only be for
    // the target entry's bank, so it is applied in the next cycle too, and
    // nothing here waits on the command select.
    final tgtBank = mux(cur.valid, cur.bank, la.bank);
    final tgtRow = mux(cur.valid, cur.row, la.row);
    final sameBank = inBank.eq(tgtBank);
    final sameRow = inRow.eq(tgtRow);
    final inOpen = pick(bankOpen, inBank);
    final inHit = pick([
      for (var b = 0; b < config.banks; b++) bankOpen[b] & openRow[b].eq(inRow),
    ], inBank);
    final inFields = [
      Const(1),
      port.reqWrite,
      inBank,
      inRow,
      inCol,
      inWords,
      inBeats,
      inFin,
      port.reqPort,
      Const(0),
      Const(0),
    ];

    // --- entry status updates ---
    final curHitNext = mux(
      selPreAll | selCurPre,
      Const(0),
      mux(selCurAct, Const(1), cur.hit),
    );
    final curMissNext = mux(
      selPreAll | selCurPre | selCurAct,
      Const(0),
      cur.miss,
    );
    // Apply the bank command that issued in the cycle la was filled.
    final laEvClosed = laEvAll | (laEvPre & laSameBank);
    final laEvOpened = laEvAct & laSameBank;
    final laHitRaw = mux(laFresh, laFreshHit, la.hit);
    final laMissRaw = mux(laFresh, laFreshOpen & ~laFreshHit, la.miss);
    final laHitBase = mux(
      laEvClosed,
      Const(0),
      mux(laEvOpened, laSameRow, laHitRaw),
    );
    final laMissBase = mux(
      laEvClosed,
      Const(0),
      mux(laEvOpened, ~laSameRow, laMissRaw),
    );
    final laShared = laSameBank & cur.valid;
    final laClosed = selPreAll | selLaPre | (selCurPre & laShared);
    final laCurAct = selCurAct & laShared;
    final laHitNext = mux(
      laClosed,
      Const(0),
      mux(selLaAct, Const(1), mux(laCurAct, laSameRow, laHitBase)),
    );
    final laMissNext = mux(
      laClosed | selLaAct,
      Const(0),
      mux(laCurAct, ~laSameRow, laMissBase),
    );

    // Column advance after a read or write of the current entry.
    final step = mux(
      cur.write,
      Const(1, width: remW),
      cur.beats.zeroExtend(remW),
    );
    final remAfter = cur.rem - step;
    final colAfter = cur.col + step.zeroExtend(colW);
    final eight = Const(8, width: remW);
    final beatsAfter = mux(
      remAfter.gte(eight),
      Const(8, width: 4),
      remAfter.getRange(0, 4),
    );
    final finAfter = mux(cur.write, remAfter.eq(1), remAfter.lte(eight));

    final curFinish = selCurCol & cur.fin;
    final Logic abortIn = abort;
    final laFieldsNext = [...la.fields.sublist(0, 9), laHitNext, laMissNext];
    final portIdx = cur.fields.indexOf(cur.port);

    // The entry state after this edge for one value of [curFinish]. Both
    // cases come from registers and the late [curFinish] only selects
    // between them at the end, so the promote does not add to the loop.
    ({List<Logic> cur, List<Logic> la, Logic promote}) entryNext(Logic fin) {
      final promote = la.valid & (~cur.valid | fin);
      final curN = <Logic>[];
      for (var i = 0; i < cur.fields.length; i++) {
        final f = cur.fields[i];
        Logic keep;
        if (f == cur.valid) {
          keep = cur.valid & ~fin;
        } else if (f == cur.col) {
          keep = mux(selCurCol, colAfter, cur.col);
        } else if (f == cur.rem) {
          keep = mux(selCurCol, remAfter, cur.rem);
        } else if (f == cur.beats) {
          keep = mux(selCurCol, beatsAfter, cur.beats);
        } else if (f == cur.fin) {
          keep = mux(selCurCol, finAfter, cur.fin);
        } else if (f == cur.hit) {
          keep = curHitNext;
        } else if (f == cur.miss) {
          keep = curMissNext;
        } else {
          keep = f;
        }
        curN.add(mux(promote, laFieldsNext[i], keep));
      }
      final laN = <Logic>[];
      for (var i = 0; i < la.fields.length; i++) {
        final f = la.fields[i];
        final keep = f == la.valid ? la.valid & ~promote : laFieldsNext[i];
        laN.add(mux(accept, inFields[i], keep));
      }
      // An abort drops a queued read but keeps a queued write.
      curN[0] = curN[0] & ~(abortFor(abortIn, curN[portIdx]) & ~curN[1]);
      laN[0] = laN[0] & ~(abortFor(abortIn, laN[portIdx]) & ~laN[1]);
      return (cur: curN, la: laN, promote: promote);
    }

    final finYes = entryNext(Const(1));
    final finNo = entryNext(Const(0));
    Logic byFinish(
      Logic Function(({List<Logic> cur, List<Logic> la, Logic promote}) e) f,
    ) => mux(curFinish, f(finYes), f(finNo));
    final curNext = [
      for (var i = 0; i < cur.fields.length; i++) byFinish((e) => e.cur[i]),
    ];
    final laNext = [
      for (var i = 0; i < la.fields.length; i++) byFinish((e) => e.la[i]),
    ];

    final laSameBankNext = mux(accept, sameBank, laSameBank);
    final tgtAct = mux(cur.valid, selCurAct, selLaAct);
    final tgtPre = mux(cur.valid, selCurPre, selLaPre);
    final laEvActNext = accept & tgtAct;
    final laEvPreNext = accept & tgtPre;
    final laEvAllNext = accept & selPreAll;
    final laSameRowNext = mux(accept, sameRow, laSameRow);

    // --- open row table, used only to classify new entries ---
    final bankOpenNext = <Logic>[];
    final openRowNext = <Logic>[];
    for (var b = 0; b < config.banks; b++) {
      final curB = cur.bank.eq(b);
      final laB = la.bank.eq(b);
      final actB = (selCurAct & curB) | (selLaAct & laB);
      bankOpenNext.add(
        mux(
          selPreAll | (selCurPre & curB) | (selLaPre & laB),
          Const(0),
          mux(actB, Const(1), bankOpen[b]),
        ),
      );
      openRowNext.add(
        mux(selCurAct & curB, cur.row, mux(selLaAct & laB, la.row, openRow[b])),
      );
    }

    Logic initIs(SdramCommand c) => init.cmd.eq(c.index);
    Logic strobes(Logic Function(int b) engine, SdramCommand c) => [
      for (var b = 0; b < banks; b++)
        mux(initDone, engine(b), initIs(c) & init.cmdBa.eq(b)),
    ].rswizzle();
    final actNext = strobes(
      (b) => (pickCurAct & cur.bank.eq(b)) | (pickLaAct & la.bank.eq(b)),
      SdramCommand.act,
    );
    final preNext = strobes(
      (b) => (pickCurPre & cur.bank.eq(b)) | (pickLaPre & la.bank.eq(b)),
      SdramCommand.pre,
    );
    final readNext = strobes(
      (b) => pickRead & cur.bank.eq(b),
      SdramCommand.read,
    );
    final writeNext = strobes(
      (b) => pickWrite & cur.bank.eq(b),
      SdramCommand.write,
    );
    final preAllNext = mux(initDone, pickPreAll, initIs(SdramCommand.preAll));
    final refNext = mux(initDone, pickRef, initIs(SdramCommand.ref));
    final mrsNext = ~initDone & initIs(SdramCommand.mrs);

    // A flag for the entry that is current after this edge. Both picks run
    // from registers and the promote only selects at the end, so the pick
    // does not wait on the command select.
    Logic forNextCur(Logic Function(Logic write, Logic bank) f) {
      final forLa = f(la.write, la.bank);
      final forCur = f(cur.write, cur.bank);
      return byFinish((e) => mux(e.promote, forLa, forCur));
    }

    // Timer flags at the next edge for one bank. Only the per-bank part
    // goes through the bank pick.
    Logic canActFor(Logic b) =>
        pick(timers.actBankNext, b) & timers.actCommonNext;
    Logic canPreFor(Logic b) =>
        pick(timers.preBankNext, b) & timers.preCommonNext;
    Logic canColFor(Logic w, Logic b) =>
        pick(timers.colBankNext, b) &
        mux(w, timers.writeCommonNext, timers.readCommonNext);

    // --- refresh policy ---
    // A precharge all for a refresh commits to that refresh, so rows are
    // never closed for nothing.
    final refCommitNext = (refCommit | (pickPreAll & wantRef)) & ~selRef;
    final busy = cur.valid | la.valid;
    final idleCntNext = mux(
      busy,
      Const(0, width: idleWidth),
      mux(idleLong, idleCnt, idleCnt + 1),
    );
    final idleLongNext = idleCnt.gte(pullInIdleCycles);
    // Pull a refresh in only after a long idle time or with every bank
    // closed. An owed refresh does not wait.
    final idleRefWantNext =
        credit.need | (credit.mayPullIn & (idleLong | ~timers.anyOpen));
    final forceRefNext = initDone & credit.force;
    final rowAgeForce = rowAgeGuard ? timers.rowAgeForce : Const(0);
    final forceAnyNext = initDone & (credit.force | rowAgeForce);

    // --- read return ---
    final pipeDepth = phyReadLatency + 1;
    final pipeValid = [
      for (var i = 0; i < pipeDepth; i++) Logic(name: 'rd_pipe_valid_$i'),
    ];
    final pipeLast = [
      for (var i = 0; i < pipeDepth; i++) Logic(name: 'rd_pipe_last_$i'),
    ];
    final pipePort = [
      for (var i = 0; i < pipeDepth; i++)
        Logic(name: 'rd_pipe_port_$i', width: portW),
    ];
    final genLeft = Logic(name: 'gen_left', width: 4);
    final genFin = Logic(name: 'gen_fin');
    final genPort = Logic(name: 'gen_port', width: portW);

    final genActive = genLeft.neq(0);
    final pipe0ValidNext = readIssue | genActive;
    final pipe0LastNext = mux(
      readIssue,
      cur.fin & cur.beats.eq(1),
      genFin & genLeft.eq(1),
    );
    final pipe0PortNext = mux(readIssue, cur.port, genPort);
    final genLeftNext = mux(
      readIssue,
      cur.beats - 1,
      mux(genActive, genLeft - 1, genLeft),
    );
    final genFinNext = mux(readIssue, cur.fin, genFin);
    final genPortNext = mux(readIssue, cur.port, genPort);

    port.rdValid <= pipeValid[phyReadLatency];
    port.rdLast <= pipeLast[phyReadLatency];
    port.rdPort <= pipePort[phyReadLatency];
    port.rdData <= phyRdData;

    // dqm is low only on the cycles that select a wanted read beat, cas
    // latency minus 2 after it. as4c16m16sb datasheet rev 2.0, command 4
    // text p9.
    final dqmLowNext = cl == 2 ? pipe0ValidNext : pipeValid[cl - 3];
    final dqmNext = mux(
      writeIssue,
      ~wrMaskNow,
      mux(
        dqmLowNext,
        Const(0, width: dqmW),
        Const((1 << dqmW) - 1, width: dqmW),
      ),
    );
    port.wrReady <= wrTook;
    port.wrPort <= cur.port;

    _checkRequests(clk, port, accept, inCol, colW);

    // The beats of the picked read. A read picked while a read is on sel_*
    // is the last word of cur.
    final pickBeats = mux(readIssue, Const(1, width: 4), cur.beats);
    lastBeatsNext <= mux(pickRead, pickBeats, Const(0, width: 4));

    // These read the next valid bits, so they are split on [curFinish] too.
    Logic keepNext(Logic write, Logic p) =>
        abortNextSig == null ? Const(1) : ~(abortFor(abortNextSig, p) & ~write);
    Logic goFor(({List<Logic> cur, List<Logic> la, Logic promote}) e) =>
        e.cur[0] & ~holdNext & keepNext(e.cur[1], e.cur[portIdx]);
    Logic laBaseFor(({List<Logic> cur, List<Logic> la, Logic promote}) e) =>
        ~holdNext &
        e.la[0] &
        ~accept &
        ~(laSameBankNext & e.cur[0]) &
        ~forceAnyNext &
        keepNext(e.la[1], e.la[portIdx]);
    final wrValidNowNext = mux(writeIssue, port.wrNextValidD, port.wrValidD);
    final wrMoreNext = mux(writeIssue, port.wrNext2ValidD, port.wrNextValidD);
    final curFreeNext = ~(curAny | pickPreAll | pickRef);
    final colMore = mux(cur.write, wrMoreNext, cur.beats.eq(1) & cur.rem.eq(2));
    final colReadyNext =
        (pickCurCol & ~pickFin & colMore) |
        (curFreeNext & (~curNext[1] | wrValidNowNext));
    Logic roomFor(({List<Logic> cur, List<Logic> la, Logic promote}) e) =>
        ~forceAnyNext & (~e.cur[0] | ~e.la[0]);

    final regs = <(Logic, Logic, int)>[
      (phyCsNR, csNNext, 1),
      (phyRasNR, rasNNext, 1),
      (phyCasNR, casNNext, 1),
      (phyWeNR, weNNext, 1),
      (phyBaR, baNext, 0),
      (phyAddrR, addrNext, 0),
      (phyDqmR, dqmNext, (1 << dqmW) - 1),
      (phyDqOutR, wrDataNow, 0),
      (wrTook, writeIssue, 0),
      (phyDqOeR, writeIssue, 0),
      (selPreAll, pickPreAll, 0),
      (selRef, pickRef, 0),
      (selCurCol, pickCurCol, 0),
      (selCurPre, pickCurPre, 0),
      (selCurAct, pickCurAct, 0),
      (selLaPre, pickLaPre, 0),
      (selLaAct, pickLaAct, 0),
      (curFree, curFreeNext, 1),
      // la_*_ok without the cur gate: the OR is the same.
      (selIdle, ~(curAny | laPreOk | laActOk | pickPreAll | pickRef), 1),
      (curFreeAct, ~(curAny | laActOk | pickPreAll | pickRef), 1),
      (laFree, ~(pickPreAll | pickRef | pickFin), 1),
      (colReady, colReadyNext, 0),
      (colHoldsPre, cur.write | (~readIssue & cur.beats.neq(1)), 0),
      (lastAct, actNext, 0),
      (lastPre, preNext, 0),
      (lastRead, readNext, 0),
      (lastWrite, writeNext, 0),
      (lastPreAll, preAllNext, 0),
      (lastRefCmd, refNext, 0),
      (lastRef, selRef, 0),
      (lastMrs, mrsNext, 0),
      (lastBeats, lastBeatsNext, 0),
      (curCanAct, forNextCur((_, b) => canActFor(b)), 0),
      (curCanPre, forNextCur((_, b) => canPreFor(b)), 0),
      (curCanColR, forNextCur(canColFor), 0),
      (curGo, byFinish(goFor), 0),
      (laBase, byFinish(laBaseFor), 0),
      (laCanAct, mux(accept, canActFor(inBank), canActFor(la.bank)), 0),
      (laCanPre, mux(accept, canPreFor(inBank), canPreFor(la.bank)), 0),
      (forceAny, forceAnyNext, 0),
      (forceRef, forceRefNext, 0),
      (idleRefWant, idleRefWantNext, 0),
      (refCommit, refCommitNext, 0),
      (wantPreAll, wantPreAllNext, 0),
      (wantRef, wantRefNext, 0),
      (idleCnt, idleCntNext, 0),
      (idleLong, idleLongNext, 0),
      for (var i = 0; i < cur.fields.length; i++)
        (cur.fields[i], curNext[i], 0),
      for (var i = 0; i < la.fields.length; i++) (la.fields[i], laNext[i], 0),
      (roomR, byFinish(roomFor), 1),
      (laSameBank, laSameBankNext, 0),
      (laSameRow, laSameRowNext, 0),
      (laEvAct, laEvActNext, 0),
      (laEvPre, laEvPreNext, 0),
      (laEvAll, laEvAllNext, 0),
      (laFresh, accept, 0),
      (laFreshHit, inHit, 0),
      (laFreshOpen, inOpen, 0),
      for (var b = 0; b < config.banks; b++) ...[
        (bankOpen[b], bankOpenNext[b], 0),
        (openRow[b], openRowNext[b], 0),
      ],
      (pipeValid[0], pipe0ValidNext & ~abortFor(abort, pipe0PortNext), 0),
      (pipeLast[0], pipe0LastNext, 0),
      (pipePort[0], pipe0PortNext, 0),
      for (var i = 1; i < pipeDepth; i++) ...[
        (pipeValid[i], pipeValid[i - 1] & ~abortFor(abort, pipePort[i - 1]), 0),
        (pipeLast[i], pipeLast[i - 1], 0),
        (pipePort[i], pipePort[i - 1], 0),
      ],
      (
        genLeft,
        mux(abortFor(abort, genPortNext), Const(0, width: 4), genLeftNext),
        0,
      ),
      (genFin, genFinNext, 0),
      (genPort, genPortNext, 0),
    ];

    // The command, entry and read return registers reset on [dataResetSig],
    // so neither reset net carries every flop in the engine.
    final dataRegs = {
      phyCsNR,
      phyRasNR,
      phyCasNR,
      phyWeNR,
      phyBaR,
      phyAddrR,
      phyDqmR,
      phyDqOutR,
      phyDqOeR,
      wrTook,
      ...cur.fields,
      ...la.fields,
      ...pipeValid,
      ...pipeLast,
      ...pipePort,
      genLeft,
      genFin,
      genPort,
    };
    List<Conditional> resetOrNext(Logic rst, bool data) {
      final rs = [
        for (final r in regs)
          if (dataRegs.contains(r.$1) == data) r,
      ];
      return [
        If(
          rst,
          then: [for (final r in rs) r.$1 < Const(r.$3, width: r.$1.width)],
          orElse: [for (final r in rs) r.$1 < r.$2],
        ),
      ];
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          // cke itself is not in [regs]: on a warm reset, the row may
          // still be open, so cke must stay high through [reset] and into
          // the init sequencer's own precharge, not drop at once.
          phyCkeR < mux(warmReset, Const(1), Const(0)),
        ],
        orElse: [phyCkeR < init.cke],
      ),
      ...resetOrNext(reset, false),
      ...resetOrNext(dataResetSig, true),
    ]);
  }

  /// Stops the simulation when a front end sends a request of 0 words,
  /// more than [maxGrantWords], or one that crosses a page. The hardware
  /// does not check this.
  void _checkRequests(
    Logic clk,
    SdramPortInterface port,
    Logic accept,
    Logic inCol,
    int colW,
  ) {
    clk.glitch.listen((args) {
      // A fresh clk net reads z before anything drives it, which a plain
      // module never shows a listener but a BridgeModule's two-step port
      // wiring can, so an invalid edge here is not a real one.
      if (!LogicValue.isPosedge(
            args.previousValue,
            args.newValue,
            ignoreInvalid: true,
          ) ||
          accept.value != LogicValue.one) {
        return;
      }
      final words = port.reqWords.value;
      final col = inCol.value;
      if (!words.isValid || !col.isValid) return;
      final n = words.toInt();
      if (n < 1 || n > maxGrantWords || col.toInt() + n > (1 << colW)) {
        Simulator.throwException(
          Exception(
            'sdram request of $n words at column ${col.toInt()} is not '
            'allowed (1..$maxGrantWords words, no page cross)',
          ),
          StackTrace.current,
        );
      }
    });
  }
}

/// Test-only: [SdramEngine] with the row-age guard disabled, to show tRAS
/// max fails without it. Not part of the public api: `harbor.dart` hides
/// this name, so a caller needs the direct `sdram_engine.dart` import.
@visibleForTesting
SdramEngine debugSdramEngineWithoutRowAgeGuard(
  HarborSdramConfig config,
  HarborSdramCycles cycles, {
  required Logic clk,
  required Logic reset,
  required SdramPortInterface port,
  required Logic phyRdData,
  required int phyReadLatency,
  Logic? abort,
  Logic? coldReset,
  int maxGrantWords = 8,
  int pullInIdleCycles = 16,
  String name = 'sdram_engine',
}) => SdramEngine._(
  config,
  cycles,
  clk: clk,
  reset: reset,
  port: port,
  phyRdData: phyRdData,
  phyReadLatency: phyReadLatency,
  abort: abort,
  abortNext: null,
  coldReset: coldReset,
  timersReset: null,
  dataReset: null,
  keepReadsOnAbort: const {},
  maxGrantWords: maxGrantWords,
  pullInIdleCycles: pullInIdleCycles,
  rowAgeGuard: false,
  name: name,
);

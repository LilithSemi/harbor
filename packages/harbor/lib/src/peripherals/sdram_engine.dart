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
/// keep going, so the sdram keeps its contents.
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
    Logic? coldReset,
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
         coldReset: coldReset,
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
    required Logic? coldReset,
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
    abort = addInput('abort', abort ?? Const(0));
    // Only a real power-on clears [warmReset] below. With no [coldReset]
    // given, every reset counts as cold, so warmReset never latches and
    // init always takes the cold path: unchanged from before this input
    // existed.
    final coldResetSig = addInput('cold_reset', coldReset ?? externalReset);
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
      [If(initDone, then: [warmReset < Const(1)])],
      reset: coldResetSig,
      asyncReset: true,
      resetValues: {warmReset: Const(0)},
    );

    final lastCmd = Logic(name: 'last_cmd', width: 3);
    final lastBank = Logic(name: 'last_bank', width: bankBits);
    final lastBeats = Logic(name: 'last_beats', width: 4);
    final timers = SdramBankTimers(
      cycles,
      clk: clk,
      reset: reset,
      cmd: lastCmd,
      cmdBank: lastBank,
      cmdBeats: lastBeats,
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
    final laHitBits = [
      for (var b = 0; b < config.banks; b++) Logic(name: 'la_hit_bit_$b'),
    ];
    final laOpenBits = [
      for (var b = 0; b < config.banks; b++) Logic(name: 'la_open_bit_$b'),
    ];

    final bankOpen = [
      for (var b = 0; b < config.banks; b++) Logic(name: 'bank_open_$b'),
    ];
    final openRow = [
      for (var b = 0; b < config.banks; b++)
        Logic(name: 'open_row_$b', width: rowW),
    ];

    // One-cycle blocks, each named for the command it holds back, for what
    // the last command forbids. The timers see that command one cycle late.
    final blkAct = Logic(name: 'blk_act');
    final blkRead = Logic(name: 'blk_read');
    final blkWrite = Logic(name: 'blk_write');
    final blkPre = Logic(name: 'blk_pre');
    final blkPreAllRef = Logic(name: 'blk_pre_all_ref');

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
    final wrValidNow = mux(wrTook, port.wrNextValid, port.wrValid);
    final wrDataNow = mux(wrTook, port.wrNextData, port.wrData);
    final wrMaskNow = mux(wrTook, port.wrNextMask, port.wrMask);

    // --- command select, one hot ---
    // The refresh wants and the hold that keeps the entries out of their
    // way come from registers, one cycle behind the state they read. The
    // one-cycle blocks cover that cycle.
    final wantPreAll = Logic(name: 'want_pre_all');
    final wantRef = Logic(name: 'want_ref');
    final hold = Logic(name: 'hold');
    final idleNow = ~cur.valid & ~la.valid & idleRefWant;
    // A force does not wait for the current request to end. Its precharge
    // all can cut that request, which opens its row again afterwards.
    final wantPreAllNext = initDone & (forceAny | idleNow);
    final wantRefNext = initDone & (forceRef | idleNow | refCommit);
    final holdNext = ~initDone | wantPreAllNext | wantRefNext;

    final selPreAll =
        (wantPreAll &
                ~blkPre &
                ~blkPreAllRef &
                timers.anyOpen &
                timers.canPreAll)
            .named('sel_pre_all');
    final selRef = (wantRef & ~blkPreAllRef & ~timers.anyOpen & timers.canRef)
        .named('sel_ref');

    final curGo = cur.valid & ~hold;
    final curCanCol = mux(
      cur.write,
      pick(timers.canWrite, cur.bank) & wrValidNow & ~blkWrite,
      pick(timers.canRead, cur.bank) & ~blkRead,
    );
    final selCurCol = (curGo & cur.hit & curCanCol).named('sel_cur_col');
    final selCurPre =
        (curGo & cur.miss & ~blkPre & pick(timers.canPre, cur.bank)).named(
          'sel_cur_pre',
        );
    final selCurAct =
        (curGo & ~cur.hit & ~cur.miss & ~blkAct & pick(timers.canAct, cur.bank))
            .named('sel_cur_act');
    final curAny = selCurCol | selCurPre | selCurAct;

    final laGo =
        ~hold &
        la.valid &
        ~laFresh &
        ~(laSameBank & cur.valid) &
        ~forceAny &
        ~curAny;
    final selLaPre = (laGo & la.miss & ~blkPre & pick(timers.canPre, la.bank))
        .named('sel_la_pre');
    final selLaAct =
        (laGo & ~la.hit & ~la.miss & ~blkAct & pick(timers.canAct, la.bank))
            .named('sel_la_act');

    final readIssue = (selCurCol & ~cur.write).named('read_issue');
    final writeIssue = (selCurCol & cur.write).named('write_issue');
    final isAct = selCurAct | selLaAct;
    final isPre = selCurPre | selLaPre;
    final curCmd = selCurCol | selCurPre | selCurAct;

    Logic oneHot(List<(Logic, Logic)> terms, int width) =>
        terms.map((t) => t.$1.replicate(width) & t.$2).reduce((a, b) => a | b);
    Const code(SdramCommand c) => Const(c.index, width: 3);

    final cmdNext = mux(
      initDone,
      oneHot([
        (selPreAll, code(SdramCommand.preAll)),
        (selRef, code(SdramCommand.ref)),
        (readIssue, code(SdramCommand.read)),
        (writeIssue, code(SdramCommand.write)),
        (isPre, code(SdramCommand.pre)),
        (isAct, code(SdramCommand.act)),
      ], 3),
      init.cmd,
    );
    // Bank and address come from whichever side issues. With no command
    // they are don't care, so the select only needs curAny and selPreAll.
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
    final anySel = selPreAll | selRef | selCurCol | isPre | isAct;
    final csNNext = mux(initDone, ~anySel, initPins[3]);
    final rasNNext = mux(
      initDone,
      ~(isAct | isPre | selPreAll | selRef),
      initPins[2],
    );
    final casNNext = mux(initDone, ~(selCurCol | selRef), initPins[1]);
    final weNNext = mux(
      initDone,
      ~(writeIssue | isPre | selPreAll),
      initPins[0],
    );

    // --- enqueue, always into the look-ahead entry ---
    final reqReady = (initDone & ~forceAny & (~la.valid | ~cur.valid)).named(
      'req_ready_c',
    );
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
    // row compare per bank. A bank command in this cycle can only be for
    // the target entry's bank, so it is applied in the next cycle too, and
    // nothing here waits on the command select.
    final tgtBank = mux(cur.valid, cur.bank, la.bank);
    final tgtRow = mux(cur.valid, cur.row, la.row);
    final sameBank = inBank.eq(tgtBank);
    final sameRow = inRow.eq(tgtRow);
    final inHitBits = [
      for (var b = 0; b < config.banks; b++) bankOpen[b] & openRow[b].eq(inRow),
    ];
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
    final freshHit = pick(laHitBits, la.bank);
    final laHitRaw = mux(laFresh, freshHit, la.hit);
    final laMissRaw = mux(
      laFresh,
      pick(laOpenBits, la.bank) & ~freshHit,
      la.miss,
    );
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
    final promote = (la.valid & (~cur.valid | curFinish)).named('promote');

    final laFieldsNext = [...la.fields.sublist(0, 9), laHitNext, laMissNext];
    final curNext = <Logic>[];
    for (var i = 0; i < cur.fields.length; i++) {
      final f = cur.fields[i];
      Logic keep;
      if (f == cur.valid) {
        keep = cur.valid & ~curFinish;
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
      curNext.add(mux(promote, laFieldsNext[i], keep));
    }

    final laNext = <Logic>[];
    for (var i = 0; i < la.fields.length; i++) {
      final f = la.fields[i];
      final keep = f == la.valid ? la.valid & ~promote : laFieldsNext[i];
      laNext.add(mux(accept, inFields[i], keep));
    }
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

    // --- refresh policy ---
    // A precharge all for a refresh commits to that refresh, so rows are
    // never closed for nothing.
    final refCommitNext = (refCommit | (selPreAll & wantRef)) & ~selRef;
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

    // A read longer than 1 beat holds back the next read and a precharge.
    final longRead = readIssue & cur.beats.neq(1);

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
      (lastCmd, cmdNext, 0),
      (lastBank, baNext, 0),
      (lastBeats, mux(readIssue, cur.beats, Const(0, width: 4)), 0),
      (lastRef, selRef, 0),
      (blkAct, ~initDone | selPreAll | selRef | isAct, 1),
      (blkRead, ~initDone | selPreAll | selRef | longRead, 1),
      (blkWrite, ~initDone | selPreAll | selRef | readIssue, 1),
      (blkPre, ~initDone | selPreAll | selRef | longRead | writeIssue, 1),
      (blkPreAllRef, ~initDone | anySel, 1),
      (forceAny, forceAnyNext, 0),
      (forceRef, forceRefNext, 0),
      (idleRefWant, idleRefWantNext, 0),
      (refCommit, refCommitNext, 0),
      (wantPreAll, wantPreAllNext, 0),
      (wantRef, wantRefNext, 0),
      (hold, holdNext, 1),
      (idleCnt, idleCntNext, 0),
      (idleLong, idleLongNext, 0),
      for (var i = 0; i < cur.fields.length; i++)
        (
          cur.fields[i],
          i == 0 ? curNext[0] & ~(abort & ~curNext[1]) : curNext[i],
          0,
        ),
      for (var i = 0; i < la.fields.length; i++)
        (
          la.fields[i],
          i == 0 ? laNext[0] & ~(abort & ~laNext[1]) : laNext[i],
          0,
        ),
      (laSameBank, laSameBankNext, 0),
      (laSameRow, laSameRowNext, 0),
      (laEvAct, laEvActNext, 0),
      (laEvPre, laEvPreNext, 0),
      (laEvAll, laEvAllNext, 0),
      (laFresh, accept, 0),
      for (var b = 0; b < config.banks; b++) ...[
        (laHitBits[b], inHitBits[b], 0),
        (laOpenBits[b], bankOpen[b], 0),
      ],
      for (var b = 0; b < config.banks; b++) ...[
        (bankOpen[b], bankOpenNext[b], 0),
        (openRow[b], openRowNext[b], 0),
      ],
      (pipeValid[0], pipe0ValidNext & ~abort, 0),
      (pipeLast[0], pipe0LastNext, 0),
      (pipePort[0], pipe0PortNext, 0),
      for (var i = 1; i < pipeDepth; i++) ...[
        (pipeValid[i], pipeValid[i - 1] & ~abort, 0),
        (pipeLast[i], pipeLast[i - 1], 0),
        (pipePort[i], pipePort[i - 1], 0),
      ],
      (genLeft, mux(abort, Const(0, width: 4), genLeftNext), 0),
      (genFin, genFinNext, 0),
      (genPort, genPortNext, 0),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          // cke itself is not in [regs]: on a warm reset, the row may
          // still be open, so cke must stay high through [reset] and into
          // the init sequencer's own precharge, not drop at once.
          phyCkeR < mux(warmReset, Const(1), Const(0)),
          for (final r in regs) r.$1 < Const(r.$3, width: r.$1.width),
        ],
        orElse: [
          phyCkeR < init.cke,
          for (final r in regs) r.$1 < r.$2,
        ],
      ),
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
  coldReset: coldReset,
  maxGrantWords: maxGrantWords,
  pullInIdleCycles: pullInIdleCycles,
  rowAgeGuard: false,
  name: name,
);

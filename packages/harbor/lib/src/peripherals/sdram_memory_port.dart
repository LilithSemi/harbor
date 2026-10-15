/// Memory waist front end for one [SdramPortInterface] client port.
library;

import 'package:rohd/rohd.dart';

import '../bus/port/memory_waist.dart';
import '../bus/port/reg_fifo.dart';
import 'sdram_port.dart';

/// Runs the requests of a 32-bit memory slave waist on one sdram client
/// port, with up to [HarborMemoryWaistConfig.outstanding] requests in
/// flight.
///
/// Each beat is one 32-bit word, two 16-bit sdram words. A full size INCR
/// or WRAP burst goes out as sdram requests of up to [maxWords] words, one
/// for each aligned 4-beat block it touches. A block never crosses a page,
/// and a WRAP burst splits at its wrap point. A narrow or FIXED beat goes
/// out as one request of 2 words, and a read beat gives the whole word.
/// Responses come back in acceptance order per direction. RDATA_ERR and
/// WRESP_ERR are always low.
///
/// A write request goes to the port only when all its beats are in the
/// write buffer, so the arbiter never waits for write data. WRESP goes out
/// when the arbiter takes the last request of the write. With a
/// [SdramPortSlice] in front of the arbiter, give its `wr_taken` pulse as
/// [writeTaken]. From then on any port that reads the sdram sees the write,
/// and its words go out even after a bus reset. A read request
/// goes to the port only when the read buffer has room for its beats,
/// because the port has no back pressure on read data.
///
/// Address bits above the sdram size are ignored for reads. A write
/// request with any of them set writes nothing.
///
/// `reset` clears everything. `abort` is the bus side reset. It drops the
/// requests and responses of the waist, but the write words of a request
/// already sent to the port still go out, so no sdram write is torn.
/// `clear` must be `reset | abort`. The front end uses only `reset` and
/// `clear`, so a build can drive each from one flop. A build can give
/// [clearNext], the value `clear` has one cycle later, in place of `clear`.
/// The port then makes `clear` with its own flop, and every waist output is
/// a flop, so the waist can cross a long distance.
class SdramMemoryPort extends Module {
  /// Largest sdram request, in 16-bit words.
  static const maxWords = 8;

  /// Beats the read buffer holds.
  final int readBeats;

  /// Beats the write buffer holds.
  final int writeBeats;

  SdramMemoryPort({
    required Logic clk,
    required Logic reset,
    required Logic abort,
    Logic? clear,
    Logic? clearNext,
    required HarborMemoryWaist waist,
    required SdramPortInterface port,
    Logic? writeTaken,
    this.readBeats = 16,
    this.writeBeats = 8,
    super.name = 'sdram_mem_port',
  }) : super(
         definitionName:
             'SdramMemoryPort_a${waist.config.addressWidth}'
             '_i${waist.config.idWidth}_n${waist.config.outstanding}'
             '_w${port.addrWidth}_r${readBeats}_b$writeBeats',
       ) {
    final cfg = waist.config;
    final aw = cfg.addressWidth;
    final memAW = port.addrWidth + 1;
    if (cfg.dataWidth != 32) {
      throw ArgumentError('the sdram memory port needs a 32-bit waist');
    }
    if (aw < memAW) {
      throw ArgumentError('the waist address must be at least $memAW bits');
    }
    if (port.wrLookahead || port.wordsWidth < 4) {
      throw ArgumentError(
        'the client port must not be lookahead and must '
        'hold $maxWords words',
      );
    }
    for (final (what, v) in [
      ('readBeats', readBeats),
      ('writeBeats', writeBeats),
    ]) {
      if (v < 4 || v & (v - 1) != 0) {
        throw ArgumentError.value(v, what, 'must be a power of two >= 4');
      }
    }

    final clearSrc = clear ?? (reset | abort);
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final Logic clr;
    Logic? clrNext;
    if (clearNext != null) {
      clrNext = addInput('clear_next', clearNext);
      clr = Logic(name: 'clear');
      Sequential(clk, [clr < clrNext]);
    } else {
      clr = addInput('clear', clearSrc);
    }
    if (writeTaken != null) writeTaken = addInput('wr_taken', writeTaken);

    final w = waist.clone()
      ..pairConnectIO(
        this,
        waist,
        PairRole.consumer,
        uniquify: (n) => 'mem_$n',
      );
    final p = SdramPortInterface(
      addrWidth: port.addrWidth,
      wordsWidth: port.wordsWidth,
    )..pairConnectIO(this, port, PairRole.consumer);

    const lenW = HarborMemoryWaistConfig.lenWidth;
    const sizeW = HarborMemoryWaistConfig.sizeWidth;
    const burstW = HarborMemoryWaistConfig.burstWidth;
    final idW = cfg.idWidth;
    final n = cfg.outstanding;

    // The nets from the other end of the waist. Queue flags make their next
    // values for each value of these nets ahead, so they select last.
    final far = [
      w.reqValid,
      w.reqWrite,
      w.wdataValid,
      w.wdataLast,
      w.rdataReady,
      w.wrespReady,
    ];
    const fRv = 0, fRw = 1, fWv = 2, fWl = 3, fRr = 4, fBr = 5;
    Logic ahead(Logic Function(_Far b) f) => _ahead(far, f);
    Logic on(bool x, Logic y) => x ? y : Const(0, width: y.width);
    final rdQPopLocal = Logic(name: 'rd_q_pop_local');

    // --- requests in ---
    final load = Logic(name: 'load');
    final rdQPop = Logic(name: 'rd_q_pop');
    final widQPop = Logic(name: 'wid_q_pop');
    final oorQPop = Logic(name: 'oor_q_pop');
    final reqFire = Logic(name: 'req_fire');
    final rdQ = _Queue(
      'rd_q',
      clk,
      clr,
      n,
      reqFire & ~w.reqWrite,
      [w.reqId, w.reqLen].rswizzle(),
      rdQPop,
      ahead: ahead,
      pushOf: (b) => on(b[fRv] && !b[fRw], w.reqReady),
      popOf: (b) => on(b[fRr], rdQPopLocal),
    );
    final widQ = _Queue(
      'wid_q',
      clk,
      clr,
      n,
      reqFire & w.reqWrite,
      w.reqId,
      widQPop,
      headRegister: clearNext != null,
      ahead: ahead,
      pushOf: (b) => on(b[fRv] && b[fRw], w.reqReady),
      popOf: (b) => on(b[fBr], w.wrespValid),
    );
    final oor = aw > memAW ? w.reqAddr.getRange(memAW).or() : Const(0);
    final oorQ = _Queue(
      'oor_q',
      clk,
      clr,
      n,
      reqFire & w.reqWrite,
      oor,
      oorQPop,
      ahead: ahead,
      pushOf: (b) => on(b[fRv] && b[fRw], w.reqReady),
      popOf: (b) => on(b[fWv] && b[fWl], w.wdataReady),
    );
    final reqWidths = [1, memAW, lenW, sizeW, burstW];
    final reqPacked = harborPack([
      w.reqWrite,
      w.reqAddr.getRange(0, memAW),
      w.reqLen,
      w.reqSize,
      w.reqBurst,
    ]);
    // With one request in flight the splitter loads straight from the
    // waist, one cycle sooner. Else a 2 entry FIFO cuts the path.
    final direct = n == 1;
    final sValid = Logic(name: 's_valid');
    final Logic headValid, headData;
    if (direct) {
      w.reqReady <= ~sValid & ~clr & rdQ.ready & widQ.ready & oorQ.ready;
      headValid = w.reqValid;
      headData = reqPacked;
    } else {
      final reqIn = HarborRegFifo(
        name: 'req_in',
        clk: clk,
        reset: clr,
        depth: 2,
        pushValid: w.reqValid & ~clr,
        pushData: reqPacked,
        popReady: load,
      );
      final ready = reqIn.pushReady & ~clr & rdQ.ready & widQ.ready;
      if (clrNext == null) {
        w.reqReady <= ready & oorQ.ready;
      } else {
        // A register with the value of `ready` in each cycle.
        final cnt = reqIn.count;
        final cntNext = mux(
          clr,
          Const(0, width: cnt.width),
          cnt +
              reqIn.pushFire.zeroExtend(cnt.width) -
              reqIn.popFire.zeroExtend(cnt.width),
        );
        final readyR = Logic(name: 'req_ready_r');
        Sequential(clk, [
          readyR <
              ~clrNext &
                  cntNext.neq(2) &
                  rdQ.readyNext &
                  widQ.readyNext &
                  oorQ.readyNext,
        ]);
        w.reqReady <= readyR;
      }
      headValid = reqIn.popValid;
      headData = reqIn.popData;
    }
    reqFire <= w.reqValid & w.reqReady;
    final head = harborUnpack(headData, reqWidths);

    // --- write buffer: beats in order, with a commit pointer that marks
    // the beats of requests already sent to the port ---
    final wbW = writeBeats.bitLength - 1;
    final wPtr = Logic(name: 'wb_wr', width: wbW + 1);
    final cPtr = Logic(name: 'wb_commit', width: wbW + 1);
    final rPtr = Logic(name: 'wb_rd', width: wbW + 1);
    final wbData = [
      for (var i = 0; i < writeBeats; i++) Logic(name: 'wb_data_$i', width: 36),
    ];
    final wbCount = (wPtr - rPtr).named('wb_count');
    // `wb_wr - wb_commit`, kept as a register.
    final wbFree = Logic(name: 'wb_uncommitted', width: wbW + 1);
    final wdReadyR = Logic(name: 'wdata_ready_r');
    w.wdataReady <=
        (clrNext == null
            ? wbCount.neq(Const(writeBeats, width: wbW + 1)) & ~clr & oorQ.valid
            : wdReadyR);
    final wPush = (w.wdataValid & w.wdataReady).named('wb_push');
    oorQPop <= wPush & w.wdataLast;
    final strb = w.wdataStrb & ~oorQ.data.replicate(4);

    // --- write word feeder: one word register in front of the port ---
    final fHalf = Logic(name: 'feed_half');
    final oValid = Logic(name: 'wr_valid_r');
    final oData = Logic(name: 'wr_data_r', width: 16);
    final oMask = Logic(name: 'wr_mask_r', width: 2);
    p.wrValid <= oValid;
    p.wrData <= oData;
    p.wrMask <= oMask;
    // The head register holds the next committed beat, so the word
    // register loads from it and not from the buffer read mux.
    final hValid = Logic(name: 'wr_head_valid');
    final hBeat = Logic(name: 'wr_head', width: 36);
    final take = (oValid & p.wrReady).named('wr_take');
    final feed = ((~oValid | take) & hValid).named('feed');
    final hLoad = ((~hValid | (feed & fHalf)) & rPtr.neq(cPtr)).named(
      'head_load',
    );
    final rIdx = rPtr.getRange(0, wbW);
    final beat = _pick(rIdx, wbData);
    final zero = Const(0, width: wbW + 1);
    Logic wNext(_Far b) => mux(
      reset,
      zero,
      mux(clr, cPtr, mux(on(b[fWv], w.wdataReady), wPtr + 1, wPtr)),
    );
    if (clrNext != null) {
      // A register with the value of the WDATA ready in each cycle, from a
      // register copy of `wb_count`.
      final cnt = Logic(name: 'wb_count_r', width: wbW + 1);
      final rNext = mux(reset, zero, mux(hLoad, rPtr + 1, rPtr));
      final clrCnt = mux(reset, zero, cPtr - rNext);
      final cut = reset | clr;
      Logic step(_Far b, Logic Function(Logic c) f) {
        final wp = on(b[fWv], w.wdataReady);
        return mux(
          cut,
          f(clrCnt),
          mux(hLoad, mux(wp, f(cnt), f(cnt - 1)), mux(wp, f(cnt + 1), f(cnt))),
        );
      }

      Logic notFull(Logic c) => c.neq(Const(writeBeats, width: wbW + 1));
      Sequential(clk, [
        cnt < ahead((b) => step(b, (c) => c)),
        wdReadyR <
            ahead((b) => ~clrNext! & step(b, notFull) & oorQ.validNextOf(b)),
      ]);
    }

    final wrespCnt = Logic(name: 'wresp_count', width: n.bitLength);
    final wrespFire = (w.wrespValid & w.wrespReady).named('wresp_fire');
    widQPop <= wrespFire;
    final wrespValidR = Logic(name: 'wresp_valid_r');
    w.wrespValid <= (clrNext == null ? wrespCnt.neq(0) : wrespValidR);
    w.wrespId <= widQ.data;
    w.wrespErr <= Const(0);

    // --- splitter ---
    final sWrite = Logic(name: 's_write');
    final sAddr = Logic(name: 's_addr', width: memAW);
    final sLeft = Logic(name: 's_left', width: lenW);
    final sSize = Logic(name: 's_size', width: sizeW);
    final sBurst = Logic(name: 's_burst', width: burstW);
    final sWrapLen = Logic(name: 's_wrap_len', width: lenW);
    final kReg = Logic(name: 's_k', width: 3);
    final kValid = Logic(name: 's_k_valid');

    final qValid = Logic(name: 'req_valid_r');
    final qWrite = Logic(name: 'req_write_r');
    // The request register holds the last request of a write.
    final qLast = Logic(name: 'req_last_r');
    final qAddr = Logic(name: 'req_addr_r', width: port.addrWidth);
    final qWords = Logic(name: 'req_words_r', width: port.wordsWidth);
    p.reqValid <= qValid;
    p.reqWrite <= qWrite;
    p.reqAddr <= qAddr;
    p.reqWords <= qWords;
    final qTake = (qValid & p.reqReady).named('req_take');

    final rbW = readBeats.bitLength;
    final credit = Logic(name: 'rd_credit', width: rbW);
    final kWide = kReg.zeroExtend(wbW + 1);
    final enough = mux(
      sWrite,
      wbFree.gte(kWide),
      credit.gte(kReg.zeroExtend(rbW)),
    );
    // A request goes out only into an empty request register, so no port
    // ready reaches the splitter.
    final issue = (sValid & kValid & ~qValid & enough & ~clr).named('issue');
    load <= ~sValid & headValid & ~clr;
    final lastChunk = sLeft.getRange(3).eq(0) & sLeft.getRange(0, 3).lt(kReg);
    // The arbiter takes the last request of a write.
    final wEvent =
        (writeTaken == null
                ? qTake & qWrite & qLast & ~clr
                : _takenLast(
                    clk,
                    reset,
                    clr,
                    qTake & qWrite,
                    qLast,
                    writeTaken,
                  ))
            .named('write_done');
    final wrespBase = wrespCnt + wEvent.zeroExtend(wrespCnt.width);
    Logic wrespNext(_Far b) => mux(
      clr,
      Const(0, width: wrespCnt.width),
      mux(on(b[fBr], w.wrespValid), wrespBase - 1, wrespBase),
    );
    if (clrNext != null) {
      // A register with the value of `wresp_count != 0` in each cycle.
      Sequential(clk, [wrespValidR < ahead((b) => wrespNext(b).neq(0))]);
    }

    // --- read data back ---
    // The port read data can come from far away, so it goes into a register
    // stage first. The beat in that stage is the tail of the read buffer:
    // while the buffer is empty it is the head, so no cycle is added.
    final rdIn = Logic(name: 'rd_in');
    final rdInData = Logic(name: 'rd_in_data', width: 16);
    final clrLate = Logic(name: 'clear_late');
    Sequential(clk, [
      rdIn < p.rdValid & ~clr,
      rdInData < p.rdData,
      clrLate < clr,
    ]);
    final rHalf = Logic(name: 'rd_half');
    final rLo = Logic(name: 'rd_lo', width: 16);
    final tailValid = (rdIn & rHalf).named('rd_tail_valid');
    final tailData = [rLo, rdInData].rswizzle();
    final rbPop = Logic(name: 'rb_pop');
    final rbPush = Logic(name: 'rb_push');
    final rbBufPop = Logic(name: 'rb_buf_pop');
    final rbBuf = _Queue('rb', clk, clr, readBeats, rbPush, tailData, rbBufPop);
    rbBufPop <= rbPop & rbBuf.valid;
    rbPush <= tailValid & ~(rbPop & ~rbBuf.valid);
    _check(clk, clr, rbPush & ~rbBuf.ready, 'read buffer pushed while full');
    final rb = (
      valid: (rbBuf.valid | tailValid).named('rb_head_valid'),
      data: mux(rbBuf.valid, rbBuf.data, tailData).named('rb_head'),
    );
    // With one request in flight the read buffer is small, so its read mux
    // drives RDATA directly. Else a 2 entry FIFO cuts the path.
    final Logic outValid, outData;
    if (direct) {
      rbPop <= rb.valid & w.rdataReady;
      outValid = rb.valid;
      outData = rb.data;
    } else if (clrNext == null) {
      final out = HarborRegFifo(
        name: 'rd_out',
        clk: clk,
        reset: clr,
        depth: 2,
        pushValid: rb.valid,
        pushData: rb.data,
        popReady: w.rdataReady,
      );
      rbPop <= out.pushFire;
      outValid = out.popValid;
      outData = out.popData;
    } else {
      outValid = Logic(name: 'rd_out_valid');
      outData = Logic(name: 'rd_out_data', width: 32);
    }
    final rBeat = Logic(name: 'rd_beat', width: lenW);
    final Logic rLast;
    final Logic rdataFire;
    if (direct || clrNext == null) {
      final rdHead = harborUnpack(rdQ.data, [idW, lenW]);
      rLast = rBeat.eq(rdHead[1]);
      w.rdataValid <= outValid;
      w.rdataData <= outData;
      w.rdataId <= rdHead[0];
      w.rdataLast <= rLast;
      rdataFire = (w.rdataValid & w.rdataReady).named('rdata_fire');
    } else {
      // A 2 entry FIFO whose head is a register. Each beat takes its ID
      // and LAST as it goes in, from the read request it belongs to.
      final rdRegs = _rdOut(
        clk,
        clr,
        rb.valid,
        rb.data,
        w.rdataReady,
        rdQ.entries,
        idW,
        lenW,
      );
      rbPop <= rdRegs.pushFire;
      rLast = rdRegs.last;
      outValid <= rdRegs.valid;
      outData <= rdRegs.data;
      w.rdataValid <= rdRegs.valid;
      w.rdataData <= rdRegs.data;
      w.rdataId <= rdRegs.id;
      w.rdataLast <= rdRegs.last;
      rdataFire = rdRegs.popFire;
    }
    w.rdataErr <= Const(0);
    rdQPop <= rdataFire & rLast;
    rdQPopLocal <= w.rdataValid & rLast;

    // A one-hot copy of the low bits of `wb_wr`, so the write enable of a
    // buffer word is one LUT.
    final wbSel = Logic(name: 'wb_wr_sel', width: writeBeats);
    Logic oneHot(Logic idx) =>
        [for (var i = writeBeats - 1; i >= 0; i--) idx.eq(i)].swizzle();
    Sequential(clk, [
      wrespCnt < ahead(wrespNext),
      wbSel <
          mux(
            reset,
            Const(1, width: writeBeats),
            mux(
              clr,
              oneHot(cPtr.getRange(0, wbW)),
              ahead(
                (b) => mux(
                  on(b[fWv], w.wdataReady),
                  [
                    wbSel.getRange(0, writeBeats - 1),
                    wbSel[writeBeats - 1],
                  ].swizzle(),
                  wbSel,
                ),
              ),
            ),
          ),
      for (var i = 0; i < writeBeats; i++)
        If(
          wPush & wbSel[i],
          then: [
            wbData[i] < [w.wdataData, strb].rswizzle(),
          ],
        ),
      If(hLoad, then: [hBeat < beat]),
      If(
        feed,
        then: [
          oData < mux(fHalf, hBeat.getRange(16, 32), hBeat.getRange(0, 16)),
          oMask < mux(fHalf, hBeat.getRange(34, 36), hBeat.getRange(32, 34)),
        ],
      ),
      // Only reset clears the buffer pointers and the word register: their
      // words belong to requests the port may already hold.
      If(
        reset,
        then: [
          wPtr < 0,
          cPtr < 0,
          rPtr < 0,
          fHalf < 0,
          hValid < 0,
          oValid < 0,
          qValid < 0,
          qWrite < 0,
        ],
        orElse: [
          wPtr < ahead(wNext),
          If(issue & sWrite, then: [cPtr < cPtr + kWide]),
          If(feed, then: [fHalf < ~fHalf]),
          If(hLoad, then: [rPtr < rPtr + 1]),
          hValid < hLoad | (hValid & ~(feed & fHalf)),
          oValid < feed | (oValid & ~take),
          If.block([
            Iff(issue, [qValid < 1, qWrite < sWrite]),
            ElseIf(qTake | (clr & ~qWrite), [qValid < 0]),
          ]),
        ],
      ),
      // A bus reset clears the flag, so a write kept across it gives no
      // WRESP to a later request.
      If(
        clr,
        then: [qLast < 0],
        orElse: [
          If(issue, then: [qLast < sWrite & lastChunk]),
        ],
      ),
      If(
        issue,
        then: [
          qAddr < [sAddr.getRange(2, memAW), Const(0)].swizzle(),
          qWords < [kReg, Const(0)].swizzle().zeroExtend(port.wordsWidth),
        ],
      ),
      If(
        load,
        then: [
          sWrite < head[0],
          sAddr < head[1],
          sLeft < head[2],
          sSize < head[3],
          sBurst < head[4],
          sWrapLen < head[2],
          kReg < _chunk(head[1], head[2], head[3], head[4], head[2]),
        ],
        orElse: [
          If(
            issue,
            then: [
              // A legal burst stays inside its 4 KB page, and the ports
              // send an illegal one as FIXED, so only the low bits move.
              if (memAW > 12)
                sAddr <
                    [
                      sAddr.getRange(12),
                      _next(
                        sAddr.getRange(0, 12),
                        kReg,
                        sSize,
                        sBurst,
                        sWrapLen,
                      ),
                    ].swizzle()
              else
                sAddr < _next(sAddr, kReg, sSize, sBurst, sWrapLen),
              sLeft < sLeft - kReg.zeroExtend(lenW),
            ],
          ),
          If(
            sValid & ~kValid,
            then: [kReg < _chunk(sAddr, sLeft, sSize, sBurst, sWrapLen)],
          ),
        ],
      ),
      If(
        clr,
        then: [
          sValid < 0,
          kValid < 0,
          credit < readBeats,
          wbFree < 0,
          rBeat < 0,
        ],
        orElse: [
          If.block([
            Iff(load, [sValid < 1, kValid < 1]),
            ElseIf(issue, [sValid < ~lastChunk, kValid < 0]),
            ElseIf(sValid, [kValid < 1]),
          ]),
          // The counts are made ahead, so the late issue and fire signals
          // only select one.
          credit <
              ahead(
                (b) => _step(
                  credit,
                  issue & ~sWrite,
                  kReg.zeroExtend(rbW),
                  on(b[fRr], w.rdataValid),
                ),
              ),
          wbFree <
              ahead(
                (b) => _step(
                  wbFree,
                  issue & sWrite,
                  kWide,
                  on(b[fWv], w.wdataReady),
                ),
              ),
          If(
            rdataFire,
            then: [rBeat < mux(rLast, Const(0, width: lenW), rBeat + 1)],
          ),
        ],
      ),
      If(
        clrLate,
        then: [rHalf < 0],
        orElse: [
          If(rdIn, then: [rHalf < ~rHalf]),
        ],
      ),
      If(rdIn & ~rHalf, then: [rLo < rdInData]),
    ]);
  }

  /// Beats in the next sdram request of a burst at [addr] with [left] beats
  /// after this one: the rest of its aligned 4-beat block, cut at the end
  /// of the burst and at a 2-beat wrap point. A narrow or FIXED beat is 1.
  static Logic _chunk(
    Logic addr,
    Logic left,
    Logic size,
    Logic burst,
    Logic wrapLen,
  ) {
    final full = size.gte(2) & burst.neq(HarborMemoryBurst.fixed.value);
    final idx = addr.getRange(2, 4).zeroExtend(3);
    final toBlock = Const(4, width: 3) - idx;
    final wrap2 = burst.eq(HarborMemoryBurst.wrap.value) & wrapLen.eq(1);
    final cap = mux(
      wrap2,
      mux(addr[2], Const(1, width: 3), Const(2, width: 3)),
      toBlock,
    );
    // left < cap - 1, with cap at most 4.
    final short =
        left.getRange(2).eq(0) & left.getRange(0, 2).zeroExtend(3).lt(cap - 1);
    final k = mux(short, left.getRange(0, 3) + 1, cap);
    return mux(full, k, Const(1, width: 3));
  }

  /// The byte address after [k] beats of a burst at [addr], by the FIXED,
  /// INCR and WRAP rules. [k] is 1 for a beat narrower than the bus.
  static Logic _next(
    Logic addr,
    Logic k,
    Logic size,
    Logic burst,
    Logic wrapLen,
  ) {
    final w = addr.width;
    final sizeMask = mux(
      size.eq(0),
      Const(0, width: w),
      mux(size.eq(1), Const(1, width: w), Const(3, width: w)),
    );
    final step = mux(
      size.gte(2),
      [k, Const(0, width: 2)].swizzle().zeroExtend(w),
      mux(size.eq(1), Const(2, width: w), Const(1, width: w)),
    );
    final incr = (addr & ~sizeMask) + step;
    final shift = mux(size.gte(2), Const(2, width: 2), size.getRange(0, 2));
    final wrapMask = (wrapLen.zeroExtend(w) << shift) | sizeMask;
    final wrapNext = (addr & ~wrapMask) | (incr & wrapMask);
    return mux(
      burst.eq(HarborMemoryBurst.fixed.value),
      addr,
      mux(burst.eq(HarborMemoryBurst.wrap.value), wrapNext, incr),
    );
  }

  /// The RDATA output FIFO: 2 entries, with the head in registers. A pushed
  /// beat gets the ID of the read request at the push side head of
  /// [rdQ], and LAST when it is the last beat of that request.
  static ({
    Logic pushFire,
    Logic popFire,
    Logic valid,
    Logic data,
    Logic id,
    Logic last,
  })
  _rdOut(
    Logic clk,
    Logic clr,
    Logic inValid,
    Logic inData,
    Logic ready,
    List<Logic> rdQ,
    int idW,
    int lenW,
  ) {
    final d = rdQ.length;
    final pSel = Logic(name: 'rd_out_req_sel', width: d);
    final pBeat = Logic(name: 'rd_out_beat', width: lenW);
    final req = [
      for (var i = 0; i < d; i++) rdQ[i] & pSel[i].replicate(rdQ[i].width),
    ].reduce((a, b) => a | b);
    final [id, len] = harborUnpack(req, [idW, lenW]);
    final pLast = pBeat.eq(len);
    final w = inData.width + idW + 1;
    final inBeat = [inData, id, pLast].swizzle();
    final oV = Logic(name: 'rd_out_valid_r');
    final sV = Logic(name: 'rd_out_spill_valid');
    final oD = Logic(name: 'rd_out_r', width: w);
    final sD = Logic(name: 'rd_out_spill', width: w);
    final pushFire = (inValid & ~(oV & sV)).named('rd_out_push_fire');
    final popFire = (oV & ready).named('rd_out_pop_fire');
    // The ready comes from far away, so it selects last.
    Logic byReady(Logic Function(Logic pop) f) =>
        mux(ready, f(oV), f(Const(0)));
    Sequential(clk, [
      oD < byReady((po) => mux(po, mux(sV, sD, inBeat), mux(oV, oD, inBeat))),
      If(pushFire & mux(popFire, sV, oV), then: [sD < inBeat]),
      If(
        clr,
        then: [oV < 0, sV < 0, pBeat < 0, pSel < 1],
        orElse: [
          oV < byReady((po) => mux(po, sV | pushFire, oV | pushFire)),
          sV < byReady((po) => mux(po, sV & pushFire, sV | (oV & pushFire))),
          If(
            pushFire,
            then: [
              If(
                pLast,
                then: [
                  pBeat < 0,
                  pSel < [pSel.getRange(0, d - 1), pSel[d - 1]].swizzle(),
                ],
                orElse: [pBeat < pBeat + 1],
              ),
            ],
          ),
        ],
      ),
    ]);
    return (
      pushFire: pushFire,
      popFire: popFire,
      valid: oV,
      data: oD.getRange(idW + 1),
      id: oD.getRange(1, idW + 1),
      last: oD[0],
    );
  }

  /// [count] minus [k] when [sub], plus 1 when [add].
  static Logic _step(Logic count, Logic sub, Logic k, Logic add) =>
      mux(add, mux(sub, count - k + 1, count + 1), mux(sub, count - k, count));

  /// [f] for each value of the [far] nets it reads, picked by those nets.
  /// A net is read only where [f] needs it, so a data net that is X while
  /// its valid is low does not make the result X.
  static Logic _ahead(List<Logic> far, Logic Function(_Far b) f) {
    Logic build(Map<int, bool> fixed) {
      try {
        return f(_Far(fixed));
      } on _Need catch (n) {
        return mux(
          far[n.index],
          build({...fixed, n.index: true}),
          build({...fixed, n.index: false}),
        );
      }
    }

    return build(const {});
  }

  /// [vals] picked by [idx], as one case mux.
  static Logic _pick(Logic idx, List<Logic> vals) => cases(
    idx,
    {for (var i = 0; i < vals.length; i++) Const(i, width: idx.width): vals[i]},
    width: vals[0].width,
    defaultValue: vals[0],
    conditionalType: ConditionalType.unique,
  );

  /// Stops the simulation when [bad] is high on a [clk] edge out of reset.
  /// The last flags of the writes the slice took and the arbiter did not
  /// yet take, at most two. Each [taken] pulse pops one, and it is the
  /// write done event when that write was the last of its burst. [clr]
  /// keeps the entries, so the pulses still line up, but clears their
  /// flags, so a write kept across a bus reset gives no WRESP.
  static Logic _takenLast(
    Logic clk,
    Logic reset,
    Logic clr,
    Logic push,
    Logic last,
    Logic taken,
  ) {
    final v = [Logic(name: 'taken_q_valid_0'), Logic(name: 'taken_q_valid_1')];
    final l = [Logic(name: 'taken_q_last_0'), Logic(name: 'taken_q_last_1')];
    final v0 = mux(taken, v[1], v[0]);
    final v1 = mux(taken, Const(0), v[1]);
    final l0 = mux(taken, l[1], l[0]);
    final in0 = push & ~v0;
    final in1 = push & v0;
    final pushLast = last & ~clr;
    _check(clk, reset, taken & ~v[0], 'write taken with none in the slice');
    _check(clk, reset, push & v1, 'more than two writes in the slice');
    Sequential(clk, [
      If(
        reset,
        then: [v[0] < 0, v[1] < 0, l[0] < 0, l[1] < 0],
        orElse: [
          v[0] < v0 | in0,
          v[1] < v1 | in1,
          l[0] < mux(in0, pushLast, l0 & ~clr),
          l[1] < mux(in1, pushLast, l[1] & ~taken & ~clr),
        ],
      ),
    ]);
    return taken & l[0] & ~clr;
  }

  static void _check(Logic clk, Logic rst, Logic bad, String what) {
    clk.glitch.listen((args) {
      if (LogicValue.isPosedge(
            args.previousValue,
            args.newValue,
            ignoreInvalid: true,
          ) &&
          rst.value == LogicValue.zero &&
          bad.value == LogicValue.one) {
        Simulator.throwException(
          Exception('sdram memory port: $what'),
          StackTrace.current,
        );
      }
    });
  }
}

/// A FIFO of [depth] entries rounded up to a power of two. [ready] is low
/// when full and [valid] high when not empty. Pushing while full and
/// popping while empty are not allowed. One-hot registers select the entry
/// to write and the entry to read, so the write enable of an entry is one
/// LUT and the read is an AND-OR. [ready] and [valid] are flops.
class _Queue {
  final Logic ready;
  final Logic valid;
  final Logic data;

  /// The values [ready] and [valid] have one cycle later.
  final Logic readyNext;
  final Logic validNext;

  /// [validNext] for the far net values `b`.
  final Logic Function(_Far b) validNextOf;

  /// The entries, in write order from the reset.
  final List<Logic> entries;

  _Queue._(
    this.ready,
    this.valid,
    this.data,
    this.readyNext,
    this.validNext,
    this.validNextOf,
    this.entries,
  );

  /// With [headRegister], [data] is a register that holds the head entry.
  ///
  /// [pushOf] and [popOf] give [push] and [pop] for the far net values `b`,
  /// and [ahead] picks by those nets, so the next state of the flags and
  /// the head is one LUT after them.
  factory _Queue(
    String name,
    Logic clk,
    Logic reset,
    int depth,
    Logic push,
    Logic pushData,
    Logic pop, {
    bool headRegister = false,
    Logic Function(Logic Function(_Far b) f)? ahead,
    Logic Function(_Far b)? pushOf,
    Logic Function(_Far b)? popOf,
  }) {
    var d = 2;
    while (d < depth) {
      d <<= 1;
    }
    final pw = d.bitLength - 1;
    final width = pushData.width;
    final wr = Logic(name: '${name}_wr', width: pw + 1);
    final rd = Logic(name: '${name}_rd', width: pw + 1);
    final entries = [
      for (var i = 0; i < d; i++) Logic(name: '${name}_e$i', width: width),
    ];
    final count = wr - rd;
    final one = count.eq(Const(1, width: pw + 1));
    final almostFull = count.eq(Const(d - 1, width: pw + 1));
    final empty = Logic(name: '${name}_empty');
    final full = Logic(name: '${name}_full');
    final sel = Logic(name: '${name}_wr_sel', width: d);
    final rSel = Logic(name: '${name}_rd_sel', width: d);
    Logic rotate(Logic x) => [x.getRange(0, d - 1), x[d - 1]].swizzle();
    Logic emptyOf(Logic pu, Logic po) =>
        reset | (~pu & mux(empty, Const(1), po & one));
    Logic fullOf(Logic pu, Logic po) =>
        ~reset & mux(pu, full | (~po & almostFull), full & ~po);
    Logic pick(Logic Function(Logic pu, Logic po) g) =>
        ahead == null ? g(push, pop) : ahead((b) => g(pushOf!(b), popOf!(b)));
    final emptyNext = pick(emptyOf);
    final fullNext = pick(fullOf);
    Sequential(clk, [
      for (var i = 0; i < d; i++)
        If(push & sel[i], then: [entries[i] < pushData]),
      empty < emptyNext,
      full < fullNext,
      If(
        reset,
        then: [wr < 0, rd < 0, sel < 1, rSel < 1],
        orElse: [
          If(push, then: [wr < wr + 1, sel < rotate(sel)]),
          If(pop, then: [rd < rd + 1, rSel < rotate(rSel)]),
        ],
      ),
    ]);
    Logic at(Logic oneHot) => [
      for (var i = 0; i < d; i++) entries[i] & oneHot[i].replicate(width),
    ].reduce((a, b) => a | b);
    var data = at(rSel);
    if (headRegister) {
      // The head after this cycle: the pushed entry when the push writes
      // the slot the head moves to, else that slot.
      Logic after(Logic oneHot, Logic pu) =>
          mux(pu & (sel & oneHot).or(), pushData, at(oneHot));
      final head = Logic(name: '${name}_head', width: width);
      Sequential(clk, [
        head <
            pick(
              (pu, po) =>
                  mux(po & ~reset, after(rotate(rSel), pu), after(rSel, pu)),
            ),
      ]);
      data = head;
    }
    return _Queue._(
      (~full).named('${name}_ready'),
      (~empty).named('${name}_valid'),
      data.named('${name}_data'),
      ~fullNext,
      ~emptyNext,
      (b) => ~emptyOf(pushOf!(b), popOf!(b)),
      entries,
    );
  }
}

/// The values of the far nets in one branch of [SdramMemoryPort._ahead].
class _Far {
  final Map<int, bool> _fixed;

  _Far(this._fixed);

  bool operator [](int i) => _fixed[i] ?? (throw _Need(i));
}

class _Need {
  final int index;

  _Need(this.index);
}

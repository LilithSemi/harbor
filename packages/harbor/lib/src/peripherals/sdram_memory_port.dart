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
/// `clear`, so a build can drive each from one flop.
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
    final clr = addInput('clear', clearSrc);
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
    );
    final widQ = _Queue(
      'wid_q',
      clk,
      clr,
      n,
      reqFire & w.reqWrite,
      w.reqId,
      widQPop,
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
      w.reqReady <=
          reqIn.pushReady & ~clr & rdQ.ready & widQ.ready & oorQ.ready;
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
    final wbFree = (wPtr - cPtr).named('wb_uncommitted');
    w.wdataReady <=
        wbCount.neq(Const(writeBeats, width: wbW + 1)) & ~clr & oorQ.valid;
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

    final wrespCnt = Logic(name: 'wresp_count', width: n.bitLength);
    final wrespFire = (w.wrespValid & w.wrespReady).named('wresp_fire');
    widQPop <= wrespFire;
    w.wrespValid <= wrespCnt.neq(0);
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

    // --- read data back ---
    final rHalf = Logic(name: 'rd_half');
    final rLo = Logic(name: 'rd_lo', width: 16);
    final rdIn = (p.rdValid & ~clr).named('rd_in');
    final rbPush = (rdIn & rHalf).named('rb_push');
    final rbPop = Logic(name: 'rb_pop');
    final rb = _Queue(
      'rb',
      clk,
      clr,
      readBeats,
      rbPush,
      [rLo, p.rdData].rswizzle(),
      rbPop,
    );
    _check(clk, clr, rbPush & ~rb.ready, 'read buffer pushed while full');
    // With one request in flight the read buffer is small, so its read mux
    // drives RDATA directly. Else a 2 entry FIFO cuts the path.
    final Logic outValid, outData;
    if (direct) {
      rbPop <= rb.valid & w.rdataReady;
      outValid = rb.valid;
      outData = rb.data;
    } else {
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
    }
    final rBeat = Logic(name: 'rd_beat', width: lenW);
    final rdHead = harborUnpack(rdQ.data, [idW, lenW]);
    final rLast = rBeat.eq(rdHead[1]);
    w.rdataValid <= outValid;
    w.rdataData <= outData;
    w.rdataId <= rdHead[0];
    w.rdataErr <= Const(0);
    w.rdataLast <= rLast;
    final rdataFire = (w.rdataValid & w.rdataReady).named('rdata_fire');
    rdQPop <= rdataFire & rLast;

    final wbIdx = wPtr.getRange(0, wbW);
    Sequential(clk, [
      for (var i = 0; i < writeBeats; i++)
        If(
          wPush & wbIdx.eq(i),
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
          If.block([
            Iff(clr, [wPtr < cPtr]),
            ElseIf(wPush, [wPtr < wPtr + 1]),
          ]),
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
          rHalf < 0,
          rBeat < 0,
          wrespCnt < 0,
        ],
        orElse: [
          If.block([
            Iff(load, [sValid < 1, kValid < 1]),
            ElseIf(issue, [sValid < ~lastChunk, kValid < 0]),
            ElseIf(sValid, [kValid < 1]),
          ]),
          credit <
              credit +
                  rdataFire.zeroExtend(rbW) -
                  mux(
                    issue & ~sWrite,
                    kReg.zeroExtend(rbW),
                    Const(0, width: rbW),
                  ),
          If(rdIn, then: [rHalf < ~rHalf]),
          If(
            rdataFire,
            then: [rBeat < mux(rLast, Const(0, width: lenW), rBeat + 1)],
          ),
          wrespCnt <
              wrespCnt +
                  wEvent.zeroExtend(wrespCnt.width) -
                  wrespFire.zeroExtend(wrespCnt.width),
        ],
      ),
      If(rdIn & ~rHalf, then: [rLo < p.rdData]),
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

/// A FIFO of [depth] entries rounded up to a power of two, with a case mux
/// on the read side. [ready] is low when full and [valid] high when not
/// empty. Pushing while full and popping while empty are not allowed.
class _Queue {
  final Logic ready;
  final Logic valid;
  final Logic data;

  _Queue._(this.ready, this.valid, this.data);

  factory _Queue(
    String name,
    Logic clk,
    Logic reset,
    int depth,
    Logic push,
    Logic pushData,
    Logic pop,
  ) {
    var d = 2;
    while (d < depth) {
      d <<= 1;
    }
    final pw = d.bitLength - 1;
    final wr = Logic(name: '${name}_wr', width: pw + 1);
    final rd = Logic(name: '${name}_rd', width: pw + 1);
    final entries = [
      for (var i = 0; i < d; i++)
        Logic(name: '${name}_e$i', width: pushData.width),
    ];
    final empty = wr.eq(rd);
    final full = (wr ^ rd).eq(Const(d, width: pw + 1));
    final wIdx = wr.getRange(0, pw);
    Sequential(clk, [
      for (var i = 0; i < d; i++)
        If(push & wIdx.eq(i), then: [entries[i] < pushData]),
      If(
        reset,
        then: [wr < 0, rd < 0],
        orElse: [
          If(push, then: [wr < wr + 1]),
          If(pop, then: [rd < rd + 1]),
        ],
      ),
    ]);
    return _Queue._(
      (~full).named('${name}_ready'),
      (~empty).named('${name}_valid'),
      SdramMemoryPort._pick(rd.getRange(0, pw), entries).named('${name}_data'),
    );
  }
}

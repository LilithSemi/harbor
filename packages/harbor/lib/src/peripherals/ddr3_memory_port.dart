/// Memory waist front end for the [Ddr3Controller] pipelined bus.
library;

import 'package:rohd/rohd.dart';

import '../bus/fabric_util.dart';
import '../bus/port/memory_waist.dart';
import '../bus/port/reg_fifo.dart';

/// Runs the requests of one or more memory slave waists on the pipelined
/// bus of a [Ddr3Controller], with up to
/// [HarborMemoryWaistConfig.outstanding] requests in flight on each waist.
///
/// Waist 0 takes reads and writes. Every other waist is a read channel and
/// takes only reads. Each waist answers in acceptance order per direction.
///
/// One controller word holds `ctrlDataWidth / dataWidth` bus beats. A full
/// size INCR or WRAP burst goes out as one controller command per word it
/// touches, cut at its wrap point. A narrow or FIXED beat is one command.
/// RDATA_ERR and WRESP_ERR are always low.
///
/// A round robin arbiter picks the next command from the write path and the
/// read channels, one command per grant. A source that has a command waits
/// for at most one command from each other source. The controller keeps one
/// command order for all of them.
///
/// WRESP goes out when the controller accepts the last command of the
/// write. So a read that any channel accepts after that WRESP comes later in
/// the controller order and returns the written data.
///
/// A read command goes out only when its channel has a free word in its read
/// buffer of [readWords] words, because the controller has no back pressure
/// on read data.
///
/// `reset` is the controller reset and clears everything. `clear` is the bus
/// side reset and must include `reset`. It drops the waist side and the next
/// command. Commands the controller holds still finish, and no new command
/// goes out until the controller answered all of them.
class Ddr3MemoryPort extends Module {
  /// Words in the read buffer of each read channel.
  final int readWords;

  /// Read channels, the waists after the first plus waist 0.
  final int readChannels;

  /// Controller commands of up to 8 read channels fit the `aux` tag.
  static const int maxReadChannels = 8;

  Ddr3MemoryPort({
    required Logic clk,
    required Logic reset,
    required Logic clear,
    required List<HarborMemoryWaist> waists,
    required int ctrlAddrWidth,
    required int ctrlDataWidth,
    required Logic ctrlStall,
    required Logic ctrlAck,
    required Logic ctrlAckAux,
    required Logic ctrlData,
    required int ctrlAckPipeDepth,
    this.readWords = 4,
    super.name = 'ddr3_mem_port',
  }) : readChannels = waists.length,
       super(
         definitionName:
             'Ddr3MemoryPort_a${waists.first.config.addressWidth}'
             '_d${waists.first.config.dataWidth}'
             '_i${waists.first.config.idWidth}'
             '_n${waists.first.config.outstanding}_c${waists.length}'
             '_w${ctrlAddrWidth}x${ctrlDataWidth}_r${readWords}'
             '_p$ctrlAckPipeDepth',
       ) {
    if (waists.isEmpty || waists.length > maxReadChannels) {
      throw ArgumentError.value(
        waists.length,
        'waists',
        'must be 1 to $maxReadChannels',
      );
    }
    final cfg = waists.first.config;
    for (final w in waists) {
      final c = w.config;
      if (c.addressWidth != cfg.addressWidth ||
          c.dataWidth != cfg.dataWidth ||
          c.idWidth != cfg.idWidth ||
          c.outstanding != cfg.outstanding) {
        throw ArgumentError('every waist must have the config of waist 0');
      }
    }
    final busDW = cfg.dataWidth;
    if (ctrlDataWidth % busDW != 0 ||
        (ctrlDataWidth ~/ busDW) & (ctrlDataWidth ~/ busDW - 1) != 0) {
      throw ArgumentError(
        'the controller word ($ctrlDataWidth) must be a power of two '
        'multiple of the bus width ($busDW)',
      );
    }
    if (readWords < 2 || readWords & (readWords - 1) != 0) {
      throw ArgumentError.value(readWords, 'readWords', 'power of two >= 2');
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final clr = addInput('clear', clear);
    ctrlStall = addInput('m_stall', ctrlStall);
    ctrlAck = addInput('m_ack', ctrlAck);
    ctrlAckAux = addInput('m_ack_aux', ctrlAckAux, width: 4);
    ctrlData = addInput('m_data_in', ctrlData, width: ctrlDataWidth);
    final mCyc = addOutput('m_cyc');
    final mStb = addOutput('m_stb');
    final mWeOut = addOutput('m_we');
    final mAddrOut = addOutput('m_addr', width: ctrlAddrWidth);
    final mDataOut = addOutput('m_data', width: ctrlDataWidth);
    final mSelOut = addOutput('m_sel', width: ctrlDataWidth ~/ 8);
    final mAuxOut = addOutput('m_aux', width: 4);

    final ws = [
      for (var c = 0; c < waists.length; c++)
        waists[c].clone()..pairConnectIO(
          this,
          waists[c],
          PairRole.consumer,
          uniquify: (n) => 'mem${c}_$n',
        ),
    ];

    const lenW = HarborMemoryWaistConfig.lenWidth;
    const sizeW = HarborMemoryWaistConfig.sizeWidth;
    const burstW = HarborMemoryWaistConfig.burstWidth;
    final aw = cfg.addressWidth;
    final idW = cfg.idWidth;
    final n = cfg.outstanding;
    final ratio = ctrlDataWidth ~/ busDW;
    final rB = ratio.bitLength - 1;
    final kw = rB + 1;
    final strbW = cfg.strbWidth;
    final busSize = strbW.bitLength - 1;
    final wordBytes = ctrlDataWidth ~/ 8;
    final wordByteBits = wordBytes.bitLength - 1;
    final rbW = readWords.bitLength - 1;

    // Address of the controller word that holds [a].
    Logic wordAddr(Logic a) {
      final hi = a.width > wordByteBits ? a.getRange(wordByteBits) : Const(0);
      return hi.width >= ctrlAddrWidth
          ? hi.getRange(0, ctrlAddrWidth)
          : hi.zeroExtend(ctrlAddrWidth);
    }

    // Beats of the next command of a burst at [a] with [left] beats after
    // it, and the beat index in the controller word where it starts.
    (Logic, Logic) chunk(
      Logic a,
      Logic left,
      Logic size,
      Logic burst,
      Logic wrapLen,
    ) {
      final idx = rB > 0 ? a.getRange(busSize, busSize + rB) : Const(0);
      if (rB == 0) return (idx, Const(1, width: kw));
      const cw = lenW + 1;
      final full = size.eq(busSize) & burst.neq(HarborMemoryBurst.fixed.value);
      final toEnd = Const(ratio, width: cw) - idx.zeroExtend(cw);
      final pos = a.getRange(busSize, busSize + 4) & wrapLen.getRange(0, 4);
      final toWrap =
          wrapLen.getRange(0, 4).zeroExtend(cw) + 1 - pos.zeroExtend(cw);
      final cap = mux(
        burst.eq(HarborMemoryBurst.wrap.value) & toWrap.lt(toEnd),
        toWrap,
        toEnd,
      );
      final rem = left.zeroExtend(cw) + 1;
      final k = mux(rem.lt(cap), rem, cap).getRange(0, kw);
      return (idx, mux(full, k, Const(1, width: kw)));
    }

    // The byte address after [k] beats by the FIXED, INCR and WRAP rules. A
    // legal burst stays in its 4 KB page, and the ports send an illegal one
    // as FIXED, so only the low 12 bits move.
    Logic next(Logic a, Logic k, Logic size, Logic burst, Logic wrapLen) {
      final lw = aw < 12 ? aw : 12;
      final lo = a.getRange(0, lw);
      final bytes = Const(1, width: lw) << size;
      final sizeMask = bytes - 1;
      final incr = (lo & ~sizeMask) + (k.zeroExtend(lw) << size);
      final wrapMask = (wrapLen.zeroExtend(lw) << size) | sizeMask;
      final wrapNext = (lo & ~wrapMask) | (incr & wrapMask);
      final nlo = mux(
        burst.eq(HarborMemoryBurst.fixed.value),
        lo,
        mux(burst.eq(HarborMemoryBurst.wrap.value), wrapNext, incr),
      );
      return aw > lw ? [a.getRange(lw), nlo].swizzle() : nlo;
    }

    Logic lane(Logic word, Logic idx) => rB == 0
        ? word
        : _pick(idx, [
            for (var l = 0; l < ratio; l++)
              word.getRange(l * busDW, (l + 1) * busDW),
          ]);

    // Commands the controller took and has not answered yet. Only the
    // controller reset clears it. Sized to the controller's ack pipe depth
    // plus the commands each channel can have queued, so back to back
    // acceptance can never wrap it.
    final inflightBound = ctrlAckPipeDepth + n;
    final inflightW = widthOf(inflightBound);
    final inflight = Logic(name: 'inflight', width: inflightW);
    final draining = Logic(name: 'draining');
    final blocked = (clr | draining).named('blocked');

    // The command register in front of the controller.
    final mValid = Logic(name: 'cmd_valid');
    final mWe = Logic(name: 'cmd_we');
    final mLast = Logic(name: 'cmd_last');
    final mAddr = Logic(name: 'cmd_addr', width: ctrlAddrWidth);
    final mData = Logic(name: 'cmd_data', width: ctrlDataWidth);
    final mSel = Logic(name: 'cmd_sel', width: ctrlDataWidth ~/ 8);
    final mAux = Logic(name: 'cmd_aux', width: 4);
    final stb = (mValid & ~clr).named('cmd_stb');
    final accepted = (stb & ~ctrlStall).named('cmd_accepted');
    final outFree = (~mValid | accepted).named('cmd_free');

    // --- read channels ---
    final rqValid = <Logic>[];
    final rqAddr = <Logic>[];
    final rqTake = [for (var c = 0; c < ws.length; c++) Logic()];
    final ringSeq = <Conditional>[];
    for (var c = 0; c < ws.length; c++) {
      final w = ws[c];
      final p = 'ch$c';
      final reqFire = (w.reqValid & w.reqReady).named('${p}_req_fire');
      final rd = (reqFire & ~w.reqWrite).named('${p}_rd_fire');
      final sLoad = Logic(name: '${p}_s_load');
      final rdataFire = (w.rdataValid & w.rdataReady).named('${p}_rd_out');
      final rLastBeat = Logic(name: '${p}_r_last');
      final rdReq = _Queue(
        '${p}_rd_req',
        clk,
        clr,
        n,
        rd,
        harborPack([w.reqAddr, w.reqLen, w.reqSize, w.reqBurst]),
        sLoad,
      );
      final rdResp = _Queue(
        '${p}_rd_resp',
        clk,
        clr,
        n,
        rd,
        harborPack([w.reqId, w.reqLen]),
        rdataFire & rLastBeat,
      );
      final reqRoom = <Logic>[rdReq.ready, rdResp.ready];

      // Splitter: one read request at a time into commands.
      final sValid = Logic(name: '${p}_s_valid');
      final sAddr = Logic(name: '${p}_s_addr', width: aw);
      final sLeft = Logic(name: '${p}_s_left', width: lenW);
      final sSize = Logic(name: '${p}_s_size', width: sizeW);
      final sBurst = Logic(name: '${p}_s_burst', width: burstW);
      final sWrap = Logic(name: '${p}_s_wrap', width: lenW);
      final (sIdx, sK) = chunk(sAddr, sLeft, sSize, sBurst, sWrap);
      final sLast = sLeft.zeroExtend(lenW + 1).lt(sK.zeroExtend(lenW + 1));
      final head = harborUnpack(rdReq.data, [aw, lenW, sizeW, burstW]);
      sLoad <= ~sValid & rdReq.valid & ~clr;

      // Read buffer ring: a word is taken at issue, filled by the controller
      // answer in order, and freed when its last beat leaves.
      final aP = Logic(name: '${p}_rb_alloc', width: rbW + 1);
      final kP = Logic(name: '${p}_rb_fill', width: rbW + 1);
      final oP = Logic(name: '${p}_rb_out', width: rbW + 1);
      final ringData = [
        for (var i = 0; i < readWords; i++)
          Logic(name: '${p}_rb_data$i', width: ctrlDataWidth),
      ];
      final ringInfo = [
        for (var i = 0; i < readWords; i++)
          Logic(name: '${p}_rb_info$i', width: rB + kw),
      ];
      final ringFull = (aP - oP).eq(Const(readWords, width: rbW + 1));
      final qValid = Logic(name: '${p}_cmd_valid');
      final qAddr = Logic(name: '${p}_cmd_addr', width: ctrlAddrWidth);
      final issue = (sValid & (~qValid | rqTake[c]) & ~ringFull & ~blocked)
          .named('${p}_issue');
      final chAck =
          (ctrlAck &
                  ctrlAckAux[0] &
                  ctrlAckAux.getRange(1, 4).eq(Const(c, width: 3)) &
                  inflight.neq(0) &
                  ~blocked)
              .named('${p}_ack');

      // Beats out of the oldest filled word.
      final beatJ = Logic(name: '${p}_beat', width: kw);
      final oIdx = oP.getRange(0, rbW);
      final info = _pick(oIdx, ringInfo);
      final infoIdx = rB > 0 ? info.getRange(0, rB) : Const(0);
      final infoK = info.getRange(rB, rB + kw);
      final have = oP.neq(kP).named('${p}_rb_have');
      final beatIdx = rB > 0
          ? (infoIdx + beatJ.getRange(0, rB)).named('${p}_beat_idx')
          : Const(0);
      final out = HarborRegFifo(
        name: '${p}_rd_outq',
        clk: clk,
        reset: clr,
        depth: 2,
        pushValid: have,
        pushData: lane(_pick(oIdx, ringData), beatIdx),
        popReady: w.rdataReady,
      );
      final wordDone = (out.pushFire & (beatJ + 1).eq(infoK)).named(
        '${p}_word_done',
      );
      final rBeat = Logic(name: '${p}_r_beat', width: lenW);
      final [rId, rLen] = harborUnpack(rdResp.data, [idW, lenW]);
      rLastBeat <= rBeat.eq(rLen);
      w.rdataValid <= out.popValid;
      w.rdataData <= out.popData;
      w.rdataId <= rId;
      w.rdataErr <= Const(0);
      w.rdataExOkay <= Const(0);
      w.rdataLast <= rLastBeat;

      final aIdx = aP.getRange(0, rbW);
      final kIdx = kP.getRange(0, rbW);
      ringSeq.addAll([
        for (var i = 0; i < readWords; i++) ...[
          If(
            issue & aIdx.eq(i),
            then: [
              ringInfo[i] < (rB > 0 ? [sK, sIdx].swizzle() : sK),
            ],
          ),
          If(chAck & kIdx.eq(i), then: [ringData[i] < ctrlData]),
        ],
        If(issue, then: [qAddr < wordAddr(sAddr)]),
        If(
          sLoad,
          then: [
            sAddr < head[0],
            sLeft < head[1],
            sSize < head[2],
            sBurst < head[3],
            sWrap < head[1],
          ],
          orElse: [
            If(
              issue,
              then: [
                sAddr < next(sAddr, sK, sSize, sBurst, sWrap),
                sLeft < sLeft - sK.zeroExtend(lenW),
              ],
            ),
          ],
        ),
        If(
          clr,
          then: [
            sValid < 0,
            qValid < 0,
            aP < 0,
            kP < 0,
            oP < 0,
            beatJ < 0,
            rBeat < 0,
          ],
          orElse: [
            If.block([
              Iff(sLoad, [sValid < 1]),
              ElseIf(issue & sLast, [sValid < 0]),
            ]),
            If.block([
              Iff(issue, [qValid < 1]),
              ElseIf(rqTake[c], [qValid < 0]),
            ]),
            If(issue, then: [aP < aP + 1]),
            If(chAck, then: [kP < kP + 1]),
            If(
              out.pushFire,
              then: [beatJ < mux(wordDone, Const(0, width: kw), beatJ + 1)],
            ),
            If(wordDone, then: [oP < oP + 1]),
            If(
              rdataFire,
              then: [rBeat < mux(rLastBeat, Const(0, width: lenW), rBeat + 1)],
            ),
          ],
        ),
      ]);
      rqValid.add(qValid);
      rqAddr.add(qAddr);

      if (c == 0) {
        reqRoom.addAll(
          _writePath(
            clk: clk,
            clr: clr,
            w: w,
            reqFire: reqFire,
            aw: aw,
            n: n,
            busDW: busDW,
            strbW: strbW,
            ratio: ratio,
            rB: rB,
            kw: kw,
            ctrlAddrWidth: ctrlAddrWidth,
            ctrlDataWidth: ctrlDataWidth,
            chunk: chunk,
            next: next,
            wordAddr: wordAddr,
            accepted: accepted,
            blocked: blocked,
            cmdWe: mWe,
            cmdLast: mLast,
          ),
        );
      } else {
        w.wdataReady <= Const(0);
        w.wrespValid <= Const(0);
        w.wrespId <= Const(0, width: idW);
        w.wrespErr <= Const(0);
        w.wrespExOkay <= Const(0);
      }
      w.reqReady <= ~clr & reqRoom.reduce((a, b) => a & b);
    }
    Sequential(clk, ringSeq);

    // --- arbiter: the write path, then each read channel ---
    final wSrc = _writeSrc!;
    final srcValid = [
      wSrc.valid.named('src0_valid'),
      for (var c = 0; c < ws.length; c++) rqValid[c].named('src${c + 1}_valid'),
    ];
    final ackCounted = (ctrlAck & inflight.neq(0)).named('ack_counted');
    _check(clk, reset, ctrlAck & inflight.eq(0), 'an answer with no command');
    _check(
      clk,
      reset,
      accepted &
          ~ackCounted &
          inflight.eq(Const(inflightBound, width: inflightW)),
      'inflight over its ${inflightBound}-command bound',
    );
    final g = roundRobin('arb', clk, reset, [
      for (final v in srcValid) v & outFree & ~blocked,
    ]);
    wSrc.take <= g[0];
    for (var c = 0; c < ws.length; c++) {
      rqTake[c] <= g[c + 1];
    }
    final [wAddr, wData, wSel, wLast] = harborUnpack(wSrc.data, [
      ctrlAddrWidth,
      ctrlDataWidth,
      ctrlDataWidth ~/ 8,
      1,
    ]);
    final rGrant = g.sublist(1);
    final anyGrant = anyOf(g);

    Sequential(clk, [
      If(
        reset,
        then: [inflight < 0, draining < 0],
        orElse: [
          // An answer with nothing in flight is ignored, so the count
          // cannot wrap.
          inflight <
              inflight +
                  accepted.zeroExtend(inflightW) -
                  ackCounted.zeroExtend(inflightW),
          draining < clr | (draining & inflight.neq(0)),
        ],
      ),
      If(
        clr,
        then: [mValid < 0],
        orElse: [
          If.block([
            Iff(anyGrant, [mValid < 1]),
            ElseIf(accepted, [mValid < 0]),
          ]),
        ],
      ),
      If(
        anyGrant,
        then: [
          mWe < g[0],
          mLast < g[0] & wLast,
          mAddr < mux(g[0], wAddr, pick(rGrant, rqAddr)),
          mAux <
              mux(
                g[0],
                Const(0, width: 4),
                [indexOf(rGrant, 3), Const(1)].swizzle(),
              ),
        ],
      ),
      If(g[0], then: [mData < wData, mSel < wSel]),
    ]);

    mCyc <= Const(1);
    mStb <= stb;
    mWeOut <= mWe;
    mAddrOut <= mAddr;
    mDataOut <= mData;
    mSelOut <= mSel;
    mAuxOut <= mAux;
  }

  _WriteSrc? _writeSrc;

  // The write path of waist 0: requests, the beat assembler that builds
  // one controller word per command, and WRESP at the controller accept.
  // Returns the REQ room flags of its queues.
  List<Logic> _writePath({
    required Logic clk,
    required Logic clr,
    required HarborMemoryWaist w,
    required Logic reqFire,
    required int aw,
    required int n,
    required int busDW,
    required int strbW,
    required int ratio,
    required int rB,
    required int kw,
    required int ctrlAddrWidth,
    required int ctrlDataWidth,
    required (Logic, Logic) Function(Logic, Logic, Logic, Logic, Logic) chunk,
    required Logic Function(Logic, Logic, Logic, Logic, Logic) next,
    required Logic Function(Logic) wordAddr,
    required Logic accepted,
    required Logic blocked,
    required Logic cmdWe,
    required Logic cmdLast,
  }) {
    const lenW = HarborMemoryWaistConfig.lenWidth;
    const sizeW = HarborMemoryWaistConfig.sizeWidth;
    const burstW = HarborMemoryWaistConfig.burstWidth;
    final wr = (reqFire & w.reqWrite).named('wr_fire');
    final aLoad = Logic(name: 'wa_load');
    final wrespFire = (w.wrespValid & w.wrespReady).named('wresp_fire');
    final wrReq = _Queue(
      'wr_req',
      clk,
      clr,
      n,
      wr,
      harborPack([w.reqAddr, w.reqLen, w.reqSize, w.reqBurst]),
      aLoad,
    );
    final wrId = _Queue('wr_id', clk, clr, n, wr, w.reqId, wrespFire);

    final aValid = Logic(name: 'wa_valid');
    final aAddr = Logic(name: 'wa_addr', width: aw);
    final aLeft = Logic(name: 'wa_left', width: lenW);
    final aSize = Logic(name: 'wa_size', width: sizeW);
    final aBurst = Logic(name: 'wa_burst', width: burstW);
    final aWrap = Logic(name: 'wa_wrap', width: lenW);
    final aJ = Logic(name: 'wa_beat', width: kw);
    final accData = [
      for (var l = 0; l < ratio; l++) Logic(name: 'wa_data$l', width: busDW),
    ];
    final accSel = [
      for (var l = 0; l < ratio; l++) Logic(name: 'wa_sel$l', width: strbW),
    ];
    final (aIdx, aK) = chunk(aAddr, aLeft, aSize, aBurst, aWrap);
    final aLast = aLeft.zeroExtend(lenW + 1).lt(aK.zeroExtend(lenW + 1));
    final lastBeat = (aJ + 1).eq(aK).named('wa_cmd_end');
    final laneIdx = rB > 0 ? (aIdx + aJ.getRange(0, rB)) : Const(0);
    final head = harborUnpack(wrReq.data, [aw, lenW, sizeW, burstW]);
    aLoad <= ~aValid & wrReq.valid & ~clr;

    final take = Logic(name: 'wq_take');
    final wqPush = Logic(name: 'wq_push');
    final wqData = Logic(
      name: 'wq_data',
      width: ctrlAddrWidth + ctrlDataWidth + ctrlDataWidth ~/ 8 + 1,
    );
    final wq = HarborRegFifo(
      name: 'wq',
      clk: clk,
      reset: clr,
      depth: 2,
      pushValid: wqPush,
      pushData: wqData,
      popReady: take,
    );
    w.wdataReady <= aValid & ~clr & (~lastBeat | wq.pushReady);
    final beat = (w.wdataValid & w.wdataReady).named('wa_beat_fire');
    final beatSel = w.wdataStrb & harborLaneMask(aAddr, aSize, strbW);
    final hit = [
      for (var l = 0; l < ratio; l++)
        (beat & (rB > 0 ? laneIdx.eq(l) : Const(1))).named('wa_hit$l'),
    ];
    final mergedData = [
      for (var l = ratio - 1; l >= 0; l--) mux(hit[l], w.wdataData, accData[l]),
    ].swizzle();
    final mergedSel = [
      for (var l = ratio - 1; l >= 0; l--) mux(hit[l], beatSel, accSel[l]),
    ].swizzle();
    wqPush <= beat & lastBeat;
    wqData <= harborPack([wordAddr(aAddr), mergedData, mergedSel, aLast]);

    // WRESP counts writes whose last command the controller accepted.
    final cw = widthOf(n);
    final wrespCnt = Logic(name: 'wresp_count', width: cw);
    final done = (accepted & cmdWe & cmdLast & ~clr).named('write_done');
    w.wrespValid <= wrespCnt.neq(0);
    w.wrespId <= wrId.data;
    w.wrespErr <= Const(0);
    w.wrespExOkay <= Const(0);

    Sequential(clk, [
      // The data resets so a masked lane never carries X to the pins.
      for (var l = 0; l < ratio; l++)
        If.block([
          Iff(clr, [accData[l] < 0]),
          ElseIf(hit[l] & ~lastBeat, [accData[l] < w.wdataData]),
        ]),
      If(
        aLoad,
        then: [
          aAddr < head[0],
          aLeft < head[1],
          aSize < head[2],
          aBurst < head[3],
          aWrap < head[1],
        ],
        orElse: [
          If(
            beat & lastBeat,
            then: [
              aAddr < next(aAddr, aK, aSize, aBurst, aWrap),
              aLeft < aLeft - aK.zeroExtend(lenW),
            ],
          ),
        ],
      ),
      If(
        clr,
        then: [aValid < 0, aJ < 0, for (final s in accSel) s < 0, wrespCnt < 0],
        orElse: [
          If.block([
            Iff(aLoad, [aValid < 1]),
            ElseIf(beat & lastBeat & aLast, [aValid < 0]),
          ]),
          If(beat, then: [aJ < mux(lastBeat, Const(0, width: kw), aJ + 1)]),
          for (var l = 0; l < ratio; l++)
            If.block([
              Iff(beat & lastBeat, [accSel[l] < 0]),
              ElseIf(hit[l], [accSel[l] < beatSel]),
            ]),
          wrespCnt < wrespCnt + done.zeroExtend(cw) - wrespFire.zeroExtend(cw),
        ],
      ),
    ]);
    _writeSrc = _WriteSrc(wq.popValid, wq.popData, take);
    return [wrReq.ready, wrId.ready];
  }

  /// Stops the simulation when [bad] is high on a [clk] edge out of reset.
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
          Exception('ddr3 memory port: $what'),
          StackTrace.current,
        );
      }
    });
  }

  /// [vals] picked by [idx], as one case mux.
  static Logic _pick(Logic idx, List<Logic> vals) => vals.length == 1
      ? vals.first
      : cases(
          idx,
          {
            for (var i = 0; i < vals.length; i++)
              Const(i, width: idx.width): vals[i],
          },
          width: vals[0].width,
          defaultValue: vals[0],
          conditionalType: ConditionalType.unique,
        );
}

class _WriteSrc {
  final Logic valid;
  final Logic data;
  final Logic take;
  _WriteSrc(this.valid, this.data, this.take);
}

/// A FIFO of [depth] entries rounded up to a power of two, with a case mux
/// on the read side. Pushing while full and popping while empty are not
/// allowed.
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
      Ddr3MemoryPort._pick(rd.getRange(0, pw), entries).named('${name}_data'),
    );
  }
}

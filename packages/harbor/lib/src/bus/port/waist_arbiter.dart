import 'dart:math';

import 'package:rohd/rohd.dart';

import 'memory_waist.dart';

/// A register slice for one valid and ready channel. The output and the
/// ready to the input are flops, so no signal goes through it without a
/// register. It takes one word on each cycle. [clear] high empties it.
({Logic valid, Logic data, Logic ready}) harborRegSlice(
  Logic clk,
  Logic reset,
  String name, {
  required Logic inValid,
  required Logic inData,
  required Logic outReady,
  Logic? clear,
}) {
  final oValid = Logic(name: '${name}_out_valid');
  final oData = Logic(name: '${name}_out_data', width: inData.width);
  final sValid = Logic(name: '${name}_skid_valid');
  final sData = Logic(name: '${name}_skid_data', width: inData.width);
  final ready = (~sValid).named('${name}_ready');
  final step = If(
    ~oValid | outReady,
    then: [
      If(
        sValid,
        then: [oData < sData, oValid < Const(1), sValid < Const(0)],
        orElse: [oData < inData, oValid < inValid],
      ),
    ],
    orElse: [
      If(inValid & ready, then: [sData < inData, sValid < Const(1)]),
    ],
  );
  Sequential(clk, reset: reset, [
    if (clear == null)
      step
    else
      If(clear, then: [oValid < Const(0), sValid < Const(0)], orElse: [step]),
  ]);
  return (valid: oValid, data: oData, ready: ready);
}

/// The value of [items] at [index]. An index past the end gives [other].
Logic _pick(Logic index, List<Logic> items, Logic other) {
  var r = other;
  for (var i = items.length - 1; i >= 0; i--) {
    r = mux(index.eq(Const(i, width: index.width)), items[i], r);
  }
  return r;
}

/// Shares one memory master waist [out] between two or more [sources].
///
/// Waiting requests take turns. The request ID on [out] is the source index
/// above the source REQ_ID. A response goes back to the source that the
/// index bits select, with the source ID bits on RDATA_ID and WRESP_ID.
/// REQ_EXCLUSIVE and EXOKAY pass through. A write request waits while the
/// data of an earlier write is not sent, so write data stays in request
/// order. WDATA_LAST on [out] comes from the request length, and the source
/// WDATA_LAST is not used. No more than `outstanding` requests are in flight.
///
/// [flush] has one signal for each source. While `flush_<i>` is high, source
/// i gets no grant, its REQ_READY is 0 and its held request is dropped. The
/// arbiter takes and drops the responses of source i until all its requests
/// in flight are back, also after `flush_<i>` goes low, and source i gets no
/// grant until then. The arbiter sends the write data that source i still
/// owes as beats with all strobes low. The arbiter ignores all inputs of a
/// flushed source, so a source in reset cannot stop the other sources.
///
/// `idle` is high when nothing is in flight or waiting. `idle_<i>` is high
/// when source i has nothing in flight, owes no write data and has no held
/// request.
///
/// Each channel of [out] goes through a register slice.
class HarborWaistArbiter extends Module {
  Logic get idle => output('idle');

  /// The idle output of source [i].
  Logic idleOf(int i) => output('idle_$i');

  HarborWaistArbiter(
    Logic clk,
    Logic reset, {
    required List<HarborMemoryWaist> sources,
    required HarborMemoryWaist out,
    List<Logic>? flush,
  }) : super(
         name: 'waist_arb',
         definitionName: definitionNameFor(sources, out, flush != null),
       ) {
    final nSrc = sources.length;
    final xb = max(1, (nSrc - 1).bitLength);
    final sw = sources.isEmpty
        ? 0
        : sources.map((s) => s.config.idWidth).reduce(max);
    final oc = out.config;
    if (nSrc < 2) {
      throw ArgumentError.value(nSrc, 'sources', 'must have at least 2');
    }
    for (final (i, s) in sources.indexed) {
      if (s.config.dataWidth != oc.dataWidth) {
        throw ArgumentError(
          'source $i data width ${s.config.dataWidth} '
          'is not the out data width ${oc.dataWidth}',
        );
      }
      if (s.config.addressWidth != oc.addressWidth) {
        throw ArgumentError(
          'source $i address width '
          '${s.config.addressWidth} is not the out address width '
          '${oc.addressWidth}',
        );
      }
    }
    if (oc.idWidth < xb + sw) {
      throw ArgumentError(
        'out idWidth ${oc.idWidth} must be at least '
        '${xb + sw}: $xb source index bits and $sw source ID bits',
      );
    }
    if (flush != null && flush.length != nSrc) {
      throw ArgumentError(
        'flush has ${flush.length} signals for $nSrc '
        'sources',
      );
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final s = [
      for (final (i, w) in sources.indexed)
        w.clone()..pairConnectIO(
          this,
          w,
          PairRole.consumer,
          uniquify: (n) => 's${i}_$n',
        ),
    ];
    final m = out.clone()
      ..pairConnectIO(this, out, PairRole.provider, uniquify: (n) => 'm_$n');
    final fl = [
      for (var i = 0; i < nSrc; i++)
        flush == null ? Const(0) : addInput('flush_$i', flush[i]),
    ];

    final n = oc.outstanding;
    final cw = n.bitLength + 1;
    final iw = oc.idWidth;
    final lw = HarborMemoryWaistConfig.lenWidth;
    Logic idx(int i) => Const(i, width: xb);
    Logic cnt(Logic b) => b.zeroExtend(cw);

    final inflight = Logic(name: 'inflight', width: cw);
    final last = Logic(name: 'last', width: xb);
    final wPend = Logic(name: 'w_pend');
    final wOwner = Logic(name: 'w_owner', width: xb);
    final wLeft = Logic(name: 'w_left', width: lw);
    final wLastQ = Logic(name: 'w_last_q');
    final rOwed = [
      for (var i = 0; i < nSrc; i++) Logic(name: 'r_owed$i', width: cw),
    ];
    final bOwed = [
      for (var i = 0; i < nSrc; i++) Logic(name: 'b_owed$i', width: cw),
    ];
    // A source in flush, or one whose responses from before a flush are
    // not all back.
    final dropQ = [
      for (var i = 0; i < nSrc; i++)
        flush == null ? Const(0) : Logic(name: 'drop_q$i'),
    ];
    final block = [
      for (var i = 0; i < nSrc; i++)
        flush == null ? Const(0) : (fl[i] | dropQ[i]).named('block$i'),
    ];

    // Each source request goes into a slice first, so the grant comes from
    // flops.
    final inReady = [
      for (var i = 0; i < nSrc; i++) Logic(name: 'in${i}_ready'),
    ];
    final src = [
      for (var i = 0; i < nSrc; i++)
        harborRegSlice(
          clk,
          reset,
          'req$i',
          inValid: s[i].reqValid & ~fl[i],
          inData: [
            s[i].reqBurst,
            s[i].reqSize,
            s[i].reqLen,
            s[i].reqAddr,
            s[i].reqWrite,
            s[i].reqExclusive,
            s[i].reqId.zeroExtend(sw),
          ].swizzle(),
          outReady: inReady[i],
          clear: flush == null ? null : fl[i],
        ),
    ];
    for (var i = 0; i < nSrc; i++) {
      s[i].reqReady <= src[i].ready & ~fl[i];
    }
    final srcWrite = [for (final x in src) x.data[sw + 1]];
    final srcLen = [
      for (final x in src)
        x.data.getRange(
          sw + 2 + oc.addressWidth,
          sw + 2 + oc.addressWidth + lw,
        ),
    ];

    final room = inflight.lt(n).named('room');
    final v = [
      for (var i = 0; i < nSrc; i++)
        (src[i].valid & room & ~(srcWrite[i] & wPend) & ~block[i]).named('v$i'),
    ];
    // Round robin: the search starts after the source of the last grant.
    final picks = [
      for (var l = 0; l < nSrc; l++)
        () {
          final order = [for (var k = 1; k <= nSrc; k++) (l + k) % nSrc];
          Logic r = idx(order.last);
          for (final o in order.reversed.skip(1)) {
            r = mux(v[o], idx(o), r);
          }
          return r;
        }(),
    ];
    final g = _pick(last, picks, idx(0)).named('grant');

    // Request channel.
    final reqValid = v.reduce((a, b) => a | b).named('req_valid');
    final word = _pick(g, [for (final x in src) x.data], src[0].data);
    final reqWrite = _pick(g, srcWrite, srcWrite[0]).named('req_write');
    final reqLen = _pick(g, srcLen, srcLen[0]).named('req_len');
    final reqId = [
      if (iw > xb + sw) Const(0, width: iw - xb - sw),
      g,
      word.getRange(0, sw),
    ].swizzle();
    final reqWord = [word.getRange(sw), reqId].swizzle().named('req_word');
    final reqSlice = harborRegSlice(
      clk,
      reset,
      'req',
      inValid: reqValid,
      inData: reqWord,
      outReady: m.reqReady,
    );
    final reqReady = reqSlice.ready;
    final reqFire = (reqValid & reqReady).named('req_fire');
    for (var i = 0; i < nSrc; i++) {
      inReady[i] <= reqReady & g.eq(idx(i)) & v[i];
    }
    // In the reset cycle the port sees no request, no data and no READY.
    m.reqValid <= reqSlice.valid & ~reset;
    var at = 0;
    Logic field(int width) {
      final f = reqSlice.data.getRange(at, at + width);
      at += width;
      return f;
    }

    m.reqId <= field(iw);
    m.reqExclusive <= field(1);
    m.reqWrite <= field(1);
    m.reqAddr <= field(oc.addressWidth);
    m.reqLen <= field(lw);
    m.reqSize <= field(HarborMemoryWaistConfig.sizeWidth);
    m.reqBurst <= field(HarborMemoryWaistConfig.burstWidth);

    // Write data channel. The arbiter sends the beats a flushed owner still
    // owes, with all strobes low.
    final wDrainQ = flush == null ? Const(0) : Logic(name: 'w_drain_q');
    final drain = flush == null
        ? Const(0)
        : (wPend & (wDrainQ | _pick(wOwner, fl, Const(0)))).named('w_drain');
    final ownValid = _pick(wOwner, [for (final x in s) x.wdataValid], Const(0));
    final wValid = (wPend & (drain | ownValid)).named('w_valid');
    final dw = oc.dataWidth;
    final sb = oc.strbWidth;
    final wData = mux(
      drain,
      Const(0, width: dw),
      _pick(wOwner, [for (final x in s) x.wdataData], s[0].wdataData),
    );
    final wStrb = mux(
      drain,
      Const(0, width: sb),
      _pick(wOwner, [for (final x in s) x.wdataStrb], s[0].wdataStrb),
    );
    final wSlice = harborRegSlice(
      clk,
      reset,
      'wdata',
      inValid: wValid,
      inData: [wLastQ, wStrb, wData].swizzle(),
      outReady: m.wdataReady,
    );
    for (var i = 0; i < nSrc; i++) {
      s[i].wdataReady <= wPend & wOwner.eq(idx(i)) & ~drain & wSlice.ready;
    }
    m.wdataValid <= wSlice.valid & ~reset;
    m.wdataData <= wSlice.data.getRange(0, dw);
    m.wdataStrb <= wSlice.data.getRange(dw, dw + sb);
    m.wdataLast <= wSlice.data[dw + sb];
    final wFire = (wValid & wSlice.ready).named('w_fire');
    final wLastFire = (wFire & wLastQ).named('w_last_fire');

    // Read data and write response channels.
    final rReady = Logic(name: 'r_ready');
    final rSlice = harborRegSlice(
      clk,
      reset,
      'rdata',
      inValid: m.rdataValid,
      inData: [
        m.rdataId.getRange(0, xb + sw),
        m.rdataExOkay,
        m.rdataLast,
        m.rdataErr,
        m.rdataData,
      ].swizzle(),
      outReady: rReady,
    );
    // The waist allows RDATA_READY and WRESP_READY only while a response
    // of that kind is owed, so count the requests that left the slice.
    final mrOwed = Logic(name: 'm_r_owed', width: cw);
    final mbOwed = Logic(name: 'm_b_owed', width: cw);
    final mReqFire = (m.reqValid & m.reqReady).named('m_req_fire');
    m.rdataReady <= rSlice.ready & mrOwed.neq(0) & ~reset;
    final bReady = Logic(name: 'b_ready');
    final bSlice = harborRegSlice(
      clk,
      reset,
      'wresp',
      inValid: m.wrespValid,
      inData: [
        m.wrespId.getRange(0, xb + sw),
        m.wrespExOkay,
        m.wrespErr,
      ].swizzle(),
      outReady: bReady,
    );
    m.wrespReady <= bSlice.ready & mbOwed.neq(0) & ~reset;
    final mRDone = (m.rdataValid & m.rdataReady & m.rdataLast).named(
      'm_r_done',
    );
    final mBDone = (m.wrespValid & m.wrespReady).named('m_b_done');
    Sequential(clk, reset: reset, [
      mrOwed < mrOwed + cnt(mReqFire & ~m.reqWrite) - cnt(mRDone),
      mbOwed < mbOwed + cnt(mReqFire & m.reqWrite) - cnt(mBDone),
    ]);

    final rd = m.rdataData.width;
    final rData = rSlice.data.getRange(0, rd);
    final rErr = rSlice.data[rd];
    final rLast = rSlice.data[rd + 1];
    final rEx = rSlice.data[rd + 2];
    final rSid = rSlice.data.getRange(rd + 3, rd + 3 + sw);
    final rIdx = rSlice.data.getRange(rd + 3 + sw, rd + 3 + sw + xb);
    final bErr = bSlice.data[0];
    final bEx = bSlice.data[1];
    final bSid = bSlice.data.getRange(2, 2 + sw);
    final bIdx = bSlice.data.getRange(2 + sw, 2 + sw + xb);
    // A response for a blocked source, or for an index with no source, is
    // taken and dropped.
    rReady <=
        _pick(rIdx, [
          for (var i = 0; i < nSrc; i++) block[i] | s[i].rdataReady,
        ], Const(1));
    bReady <=
        _pick(bIdx, [
          for (var i = 0; i < nSrc; i++) block[i] | s[i].wrespReady,
        ], Const(1));
    for (var i = 0; i < nSrc; i++) {
      final iwS = s[i].config.idWidth;
      s[i].rdataValid <= rSlice.valid & rIdx.eq(idx(i)) & ~block[i];
      s[i].rdataId <= rSid.getRange(0, iwS);
      s[i].rdataData <= rData;
      s[i].rdataErr <= rErr;
      s[i].rdataExOkay <= rEx;
      s[i].rdataLast <= rLast;
      s[i].wrespValid <= bSlice.valid & bIdx.eq(idx(i)) & ~block[i];
      s[i].wrespId <= bSid.getRange(0, iwS);
      s[i].wrespErr <= bErr;
      s[i].wrespExOkay <= bEx;
    }
    final rDone = (rSlice.valid & rReady & rLast).named('r_done');
    final bDone = (bSlice.valid & bReady).named('b_done');

    final idleOut = addOutput('idle');
    final held = [
      for (var i = 0; i < nSrc; i++)
        (src[i].valid | ~src[i].ready).named('held$i'),
    ];
    final owesW = [
      for (var i = 0; i < nSrc; i++)
        (wPend & wOwner.eq(idx(i))).named('owes_w$i'),
    ];
    for (var i = 0; i < nSrc; i++) {
      addOutput('idle_$i') <=
          rOwed[i].eq(0) & bOwed[i].eq(0) & ~owesW[i] & ~held[i];
    }

    Sequential(clk, reset: reset, [
      inflight < inflight + cnt(reqFire) - cnt(rDone) - cnt(bDone),
      If(reqFire, then: [last < g]),
      If.block([
        Iff(reqFire & reqWrite, [
          wPend < 1,
          wOwner < g,
          wLeft < reqLen,
          wLastQ < reqLen.eq(0),
        ]),
        ElseIf(wLastFire, [wPend < 0]),
        ElseIf(wFire, [wLeft < wLeft - 1, wLastQ < wLeft.eq(1)]),
      ]),
      for (var i = 0; i < nSrc; i++) ...[
        rOwed[i] <
            rOwed[i] +
                cnt(reqFire & ~reqWrite & g.eq(idx(i))) -
                cnt(rDone & rIdx.eq(idx(i))),
        bOwed[i] <
            bOwed[i] +
                cnt(reqFire & reqWrite & g.eq(idx(i))) -
                cnt(bDone & bIdx.eq(idx(i))),
      ],
      if (flush != null) ...[
        If.block([
          Iff(wLastFire, [wDrainQ < 0]),
          ElseIf(drain, [wDrainQ < 1]),
        ]),
        for (var i = 0; i < nSrc; i++)
          If.block([
            Iff(fl[i], [dropQ[i] < 1]),
            ElseIf(rOwed[i].eq(0) & bOwed[i].eq(0), [dropQ[i] < 0]),
          ]),
      ],
    ]);
    idleOut <= inflight.eq(0) & ~wPend & ~held.reduce((a, b) => a | b);
  }

  /// The definition name for one parameter set.
  static String definitionNameFor(
    List<HarborMemoryWaist> sources,
    HarborMemoryWaist out,
    bool flush,
  ) {
    final c = out.config;
    final ids = sources.map((s) => s.config.idWidth).join('_');
    return 'HarborWaistArb_s${sources.length}_a${c.addressWidth}'
        '_d${c.dataWidth}_n${c.outstanding}_i${c.idWidth}_si${ids}'
        '${flush ? '_f' : ''}';
  }
}

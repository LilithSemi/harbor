import 'package:rohd/rohd.dart';

import '../../bus/port/memory_waist.dart';

/// A register slice for one valid and ready channel. The output and the
/// ready to the input are flops, so no signal goes through it without a
/// register. It takes one word on each cycle.
({Logic valid, Logic data, Logic ready}) harborEthSlice(
  Logic clk,
  Logic reset,
  String name, {
  required Logic inValid,
  required Logic inData,
  required Logic outReady,
}) {
  final oValid = Logic(name: '${name}_out_valid');
  final oData = Logic(name: '${name}_out_data', width: inData.width);
  final sValid = Logic(name: '${name}_skid_valid');
  final sData = Logic(name: '${name}_skid_data', width: inData.width);
  final ready = (~sValid).named('${name}_ready');
  Sequential(clk, reset: reset, [
    If(
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
    ),
  ]);
  return (valid: oValid, data: oData, ready: ready);
}

/// Shares one memory master waist between the TX and the RX DMA.
///
/// Requests take turns when both wait. A request that is shown on [out]
/// stays until it is taken. The request ID is the source, 0 for TX and 1
/// for RX, and responses go back by ID. A write request waits while the
/// data of an earlier write is not sent, so write data stays in request
/// order. No more than `outstanding` requests are in flight. `idle` is high
/// when nothing is in flight or waiting.
///
/// Each channel of [out] goes through a register slice, so no path goes
/// from the DMAs to the fabric or back without a flop.
class HarborEthWaistArbiter extends Module {
  Logic get idle => output('idle');

  HarborEthWaistArbiter(
    Logic clk,
    Logic reset, {
    required HarborMemoryWaist tx,
    required HarborMemoryWaist rx,
    required HarborMemoryWaist out,
  }) : super(
         name: 'eth_waist_arb',
         definitionName:
             'HarborEthWaistArb_a${out.config.addressWidth}'
             '_n${out.config.outstanding}',
       ) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final s = [
      for (final (i, w) in [tx, rx].indexed)
        w.clone()..pairConnectIO(
          this,
          w,
          PairRole.consumer,
          uniquify: (n) => 's${i}_$n',
        ),
    ];
    final m = out.clone()
      ..pairConnectIO(this, out, PairRole.provider, uniquify: (n) => 'm_$n');
    final idleOut = addOutput('idle');

    final n = out.config.outstanding;
    final cw = n.bitLength + 1;
    final iw = out.config.idWidth;
    final inflight = Logic(name: 'inflight', width: cw);
    final hold = Logic(name: 'hold');
    final cur = Logic(name: 'cur');
    final last = Logic(name: 'last');
    final wPend = Logic(name: 'w_pend');
    final wOwner = Logic(name: 'w_owner');

    // Each source request goes into a slice first, so the grant comes from
    // flops.
    final inReady = [for (var i = 0; i < 2; i++) Logic(name: 'in${i}_ready')];
    final src = [
      for (var i = 0; i < 2; i++)
        harborEthSlice(
          clk,
          reset,
          'req$i',
          inValid: s[i].reqValid,
          inData: [
            s[i].reqBurst,
            s[i].reqSize,
            s[i].reqLen,
            s[i].reqAddr,
            s[i].reqWrite,
          ].swizzle(),
          outReady: inReady[i],
        ),
    ];
    for (var i = 0; i < 2; i++) {
      s[i].reqReady <= src[i].ready;
    }
    final srcWrite = [for (final x in src) x.data[0]];

    final room = inflight.lt(n).named('room');
    final v = [
      for (var i = 0; i < 2; i++)
        (src[i].valid & room & ~(srcWrite[i] & wPend)).named('v$i'),
    ];
    // TX wins a tie only when RX had the last grant.
    final pick = mux(v[0] & v[1], ~last, v[1]).named('pick');
    final g = mux(hold, cur, pick).named('grant');
    Logic sel(Logic a, Logic b) => mux(g, b, a);

    // Request channel.
    final reqValid = mux(g, v[1], v[0]).named('req_valid');
    final reqWrite = sel(srcWrite[0], srcWrite[1]);
    final reqWord = [
      sel(src[0].data, src[1].data),
      g.zeroExtend(iw),
    ].swizzle().named('req_word');
    final reqSlice = harborEthSlice(
      clk,
      reset,
      'req',
      inValid: reqValid,
      inData: reqWord,
      outReady: m.reqReady,
    );
    final reqReady = reqSlice.ready;
    final reqFire = (reqValid & reqReady).named('req_fire');
    inReady[0] <= reqReady & ~g & v[0];
    inReady[1] <= reqReady & g & v[1];
    // The MAC resets one cycle after the port. In that cycle the port sees
    // no request, no data and no READY.
    m.reqValid <= reqSlice.valid & ~reset;
    var at = 0;
    Logic field(Logic dst) {
      final f = reqSlice.data.getRange(at, at + dst.width);
      at += dst.width;
      return f;
    }

    m.reqId <= field(m.reqId);
    m.reqWrite <= field(m.reqWrite);
    m.reqAddr <= field(m.reqAddr);
    m.reqLen <= field(m.reqLen);
    m.reqSize <= field(m.reqSize);
    m.reqBurst <= field(m.reqBurst);
    m.reqExclusive <= Const(0);

    // Write data channel.
    Logic wsel(Logic a, Logic b) => mux(wOwner, b, a);
    final wValid = (wPend & wsel(s[0].wdataValid, s[1].wdataValid)).named(
      'w_valid',
    );
    final wLast = wsel(s[0].wdataLast, s[1].wdataLast);
    final wSlice = harborEthSlice(
      clk,
      reset,
      'wdata',
      inValid: wValid,
      inData: [
        wLast,
        wsel(s[0].wdataStrb, s[1].wdataStrb),
        wsel(s[0].wdataData, s[1].wdataData),
      ].swizzle(),
      outReady: m.wdataReady,
    );
    s[0].wdataReady <= wPend & ~wOwner & wSlice.ready;
    s[1].wdataReady <= wPend & wOwner & wSlice.ready;
    final dw = m.wdataData.width;
    m.wdataValid <= wSlice.valid & ~reset;
    m.wdataData <= wSlice.data.getRange(0, dw);
    m.wdataStrb <= wSlice.data.getRange(dw, dw + m.wdataStrb.width);
    m.wdataLast <= wSlice.data[dw + m.wdataStrb.width];
    final wLastFire = (wValid & wSlice.ready & wLast).named('w_last_fire');

    // Read data and write response channels.
    final rReady = Logic(name: 'r_ready');
    final rSlice = harborEthSlice(
      clk,
      reset,
      'rdata',
      inValid: m.rdataValid,
      inData: [m.rdataId[0], m.rdataLast, m.rdataErr, m.rdataData].swizzle(),
      outReady: rReady,
    );
    // The waist allows RDATA_READY and WRESP_READY only while a response
    // of that kind is owed, so count the requests that left the slice.
    final rOwed = Logic(name: 'r_owed', width: cw);
    final bOwed = Logic(name: 'b_owed', width: cw);
    final mReqFire = (m.reqValid & m.reqReady).named('m_req_fire');
    final mWrite = m.reqWrite;
    m.rdataReady <= rSlice.ready & rOwed.neq(0) & ~reset;
    final bReady = Logic(name: 'b_ready');
    final bSlice = harborEthSlice(
      clk,
      reset,
      'wresp',
      inValid: m.wrespValid,
      inData: [m.wrespId[0], m.wrespErr].swizzle(),
      outReady: bReady,
    );
    m.wrespReady <= bSlice.ready & bOwed.neq(0) & ~reset;
    final mRDone = (m.rdataValid & m.rdataReady & m.rdataLast).named(
      'm_r_done',
    );
    final mBDone = (m.wrespValid & m.wrespReady).named('m_b_done');
    Sequential(clk, reset: reset, [
      rOwed <
          rOwed + (mReqFire & ~mWrite).zeroExtend(cw) - mRDone.zeroExtend(cw),
      bOwed <
          bOwed + (mReqFire & mWrite).zeroExtend(cw) - mBDone.zeroExtend(cw),
    ]);

    final rd = m.rdataData.width;
    final rData = rSlice.data.getRange(0, rd);
    final rErr = rSlice.data[rd];
    final rLast = rSlice.data[rd + 1];
    final rId = rSlice.data[rd + 2];
    final bErr = bSlice.data[0];
    final bId = bSlice.data[1];
    rReady <= mux(rId, s[1].rdataReady, s[0].rdataReady);
    bReady <= mux(bId, s[1].wrespReady, s[0].wrespReady);
    for (var i = 0; i < 2; i++) {
      final mine = i == 0 ? ~rId : rId;
      final bMine = i == 0 ? ~bId : bId;
      s[i].rdataValid <= rSlice.valid & mine;
      s[i].rdataId <= Const(0, width: s[i].config.idWidth);
      s[i].rdataData <= rData;
      s[i].rdataErr <= rErr;
      s[i].rdataExOkay <= Const(0);
      s[i].rdataLast <= rLast;
      s[i].wrespValid <= bSlice.valid & bMine;
      s[i].wrespId <= Const(0, width: s[i].config.idWidth);
      s[i].wrespErr <= bErr;
      s[i].wrespExOkay <= Const(0);
    }
    final rDone = (rSlice.valid & rReady & rLast).named('r_done');
    final bDone = (bSlice.valid & bReady).named('b_done');

    Sequential(clk, reset: reset, [
      inflight <
          inflight +
              reqFire.zeroExtend(cw) -
              rDone.zeroExtend(cw) -
              bDone.zeroExtend(cw),
      hold < reqValid & ~reqReady,
      cur < g,
      If(reqFire, then: [last < g]),
      If.block([
        Iff(reqFire & reqWrite, [wPend < 1, wOwner < g]),
        Iff(wLastFire, [wPend < 0]),
      ]),
    ]);
    idleOut <= inflight.eq(0) & ~wPend & ~hold;
  }
}

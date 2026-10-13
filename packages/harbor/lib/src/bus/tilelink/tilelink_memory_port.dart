import 'dart:math';

import 'package:rohd/rohd.dart';

import '../port/memory_waist.dart';
import '../port/reg_fifo.dart';
import 'tilelink_interface.dart';

/// The TileLink-UH configuration of a memory port for [config]. SOURCE is the
/// waist ID, and a size width of 4 holds a 256 beat burst on any bus up to
/// 1024 bits.
TileLinkConfig harborTileLinkMemoryConfig(HarborMemoryWaistConfig config) =>
    TileLinkConfig(
      addressWidth: config.addressWidth,
      dataWidth: config.dataWidth,
      sizeWidth: 4,
      sourceWidth: config.idWidth,
    );

void _checkMatch(TileLinkInterface tl, HarborMemoryWaistConfig config) {
  final t = tl.config;
  if (t.addressWidth != config.addressWidth ||
      t.dataWidth != config.dataWidth ||
      t.sourceWidth != config.idWidth ||
      t.withBCE) {
    throw ArgumentError(
      'TileLink config (addr ${t.addressWidth}, data ${t.dataWidth}, '
      'source ${t.sourceWidth}, bce ${t.withBCE}) does not match $config',
    );
  }
  if (t.sizeWidth > 5) {
    throw ArgumentError.value(t.sizeWidth, 'sizeWidth', 'must be <= 5');
  }
  if (t.sinkWidth != 1) {
    // The slave drives D_SINK to 0 and the master never reads it, so
    // only width 1 is supported.
    throw ArgumentError.value(t.sinkWidth, 'sinkWidth', 'must be 1');
  }
}

int _log2(int v) => v.bitLength - 1;

Logic _counter(String name, int max) => Logic(name: name, width: max.bitLength);

Const _op(int v) => Const(v, width: 3);

// TileLink 1.8 opcodes the UH ports use beyond the TL-UL enums.
const _arithmeticData = 2;
const _logicalData = 3;
const _intent = 5;
const _hintAck = 2;

/// Beat counts of TileLink messages on a bus of `2^beatLog2` bytes.
class _Beats {
  final int beatLog2;
  final int sizeWidth;

  /// Width that holds the beat count of the largest size.
  final int width;

  _Beats(this.beatLog2, this.sizeWidth)
    : width = (1 << max(0, (1 << sizeWidth) - 1 - beatLog2)).bitLength;

  Logic big(Logic size) => size.gt(Const(beatLog2, width: sizeWidth));

  /// Beats of a message of [size] that carries data.
  Logic of(Logic size) => mux(
    big(size),
    Const(1, width: width) <<
        (size - Const(beatLog2, width: sizeWidth)).zeroExtend(width),
    Const(1, width: width),
  );

  Logic one() => Const(1, width: width);
}

/// A TileLink-UH slave in front of a memory slave waist.
///
/// - Get, PutFullData and PutPartialData of up to 256 beats become one waist
///   request. A burst Put sends its A beats as the waist write data. SOURCE
///   is the waist ID.
/// - At most `outstanding` requests are in flight on the waist. Responses go
///   out in acceptance order per direction, which TileLink allows, since it
///   has no order between sources.
/// - A read beat with err sets d_corrupt. The first beat of a read sets
///   d_denied for all beats of that AccessAckData, so d_denied is the same
///   on every beat as TileLink requires. A write err gives a denied
///   AccessAck.
/// - ArithmeticData, LogicalData, Intent, other opcodes, a size above 256
///   beats and an address not aligned to the size get a denied response and
///   never reach the waist. Their A beats are all taken first. Data opcodes
///   get AccessAckData with d_corrupt and the beat count of the size, Intent
///   gets HintAck, and the rest get AccessAck.
/// - A Put beat with a_corrupt is written with all strobes low.
class HarborTileLinkMemorySlave extends Module {
  HarborTileLinkMemorySlave({
    required Logic clk,
    required Logic reset,
    required TileLinkInterface tl,
    required HarborMemoryWaist waist,
    super.name = 'tilelink_memory_slave',
  }) : super(
         definitionName:
             'HarborTileLinkMemorySlave_a${waist.config.addressWidth}'
             '_d${waist.config.dataWidth}_i${waist.config.idWidth}'
             '_n${waist.config.outstanding}_s${tl.config.sizeWidth}',
       ) {
    final config = waist.config;
    _checkMatch(tl, config);
    final c = addInput('clk', clk);
    final r = addInput('reset', reset);
    final a = tl.clone()
      ..pairConnectIO(this, tl, PairRole.consumer, uniquify: (n) => 'tl_$n');
    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.provider, uniquify: (n) => 'm_$n');

    final n = config.outstanding;
    final idW = config.idWidth;
    final addrW = config.addressWidth;
    final dataW = config.dataWidth;
    final strbW = config.strbWidth;
    final sizeW = tl.config.sizeWidth;
    final beatLog2 = _log2(strbW);
    final beats = _Beats(beatLog2, sizeW);
    final cntW = beats.width;
    final maxSize = (1 << sizeW) - 1;
    final maxLegal = min(maxSize, beatLog2 + 8);
    const lenW = HarborMemoryWaistConfig.lenWidth;
    const wSizeW = HarborMemoryWaistConfig.sizeWidth;
    const burstW = HarborMemoryWaistConfig.burstWidth;

    // A goes through a 2 entry FIFO, so A_READY is a register.
    final aPop = Logic(name: 'a_pop');
    final aWidths = [3, sizeW, idW, addrW, strbW, dataW, 1];
    final aF = HarborRegFifo(
      name: 'a',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: a.aValid,
      pushData: harborPack([
        a.aOpcode,
        a.aSize,
        a.aSource,
        a.aAddress,
        a.aMask,
        a.aData,
        a.aCorrupt,
      ]),
      popReady: aPop,
    );
    a.aReady <= aF.pushReady;
    final [op, size, source, address, mask, data, corrupt] = harborUnpack(
      aF.popData,
      aWidths,
    );

    final aLeft = Logic(name: 'a_left', width: cntW);
    final aDrop = Logic(name: 'a_drop');
    final first = aLeft.eq(0).named('a_first');
    final isGet = op.eq(_op(TileLinkAOpcode.get.value));
    final isPut =
        op.eq(_op(TileLinkAOpcode.putFullData.value)) |
        op.eq(_op(TileLinkAOpcode.putPartialData.value));
    final isAtomic = op.eq(_op(_arithmeticData)) | op.eq(_op(_logicalData));
    final low = addrW >= 16 ? address.getRange(0, 16) : address.zeroExtend(16);
    final aligned = (low & ~(Const(0xffff, width: 16) << size)).eq(0);
    final sizeOk = maxLegal == maxSize
        ? Const(1)
        : size.lte(Const(maxLegal, width: sizeW));
    final legal = ((isGet | isPut) & sizeOk & aligned).named('a_legal');
    final aBeats = mux(isPut | isAtomic, beats.of(size), beats.one());

    final inflight = _counter('inflight', n);
    final room = inflight.lt(Const(n, width: inflight.width));
    final denyValid = Logic(name: 'deny_valid');
    final reqPushReady = Logic(name: 'req_push_ready');
    final wPushReady = Logic(name: 'w_push_ready');

    final acceptLegal =
        (aF.popValid &
                first &
                legal &
                room &
                reqPushReady &
                (~isPut | wPushReady))
            .named('accept_legal');
    final acceptDeny = (aF.popValid & first & ~legal & ~denyValid).named(
      'accept_deny',
    );
    final contBeat = (aF.popValid & ~first & ~aDrop).named('cont_beat');
    final dropBeat = (aF.popValid & ~first & aDrop).named('drop_beat');
    aPop <= acceptLegal | acceptDeny | (contBeat & wPushReady) | dropBeat;

    // Waist request.
    final wLen = (beats.of(size) - beats.one()).named('w_len');
    final reqF = HarborRegFifo(
      name: 'req',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: acceptLegal,
      pushData: harborPack([
        source,
        isPut,
        address,
        wLen.width >= lenW ? wLen.getRange(0, lenW) : wLen.zeroExtend(lenW),
        mux(
          beats.big(size),
          Const(beatLog2, width: wSizeW),
          size.width >= wSizeW
              ? size.getRange(0, wSizeW)
              : size.zeroExtend(wSizeW),
        ),
      ]),
      popReady: m.reqReady,
    );
    reqPushReady <= reqF.pushReady;
    final [qId, qWrite, qAddr, qLen, qSize] = harborUnpack(reqF.popData, [
      idW,
      1,
      addrW,
      lenW,
      wSizeW,
    ]);
    m.reqValid <= reqF.popValid;
    m.reqId <= qId;
    m.reqWrite <= qWrite;
    m.reqAddr <= qAddr;
    m.reqLen <= qLen;
    m.reqSize <= qSize;
    m.reqBurst <= Const(HarborMemoryBurst.incr.value, width: burstW);
    final reqFire = m.reqValid & m.reqReady;

    // Write data. A beat reaches the waist only while a taken write still
    // has beats to send.
    final wPend = _counter('w_pend', n);
    final wdataFire = Logic(name: 'wdata_fire');
    final wLast = mux(first, aBeats.eq(1), aLeft.eq(1));
    final wF = HarborRegFifo(
      name: 'w',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: (acceptLegal & isPut) | contBeat,
      pushData: harborPack([
        data,
        mux(corrupt, Const(0, width: strbW), mask),
        wLast,
      ]),
      popReady: wdataFire,
    );
    wPushReady <= wF.pushReady;
    final [wData, wStrb, wLastOut] = harborUnpack(wF.popData, [
      dataW,
      strbW,
      1,
    ]);
    m.wdataValid <= wF.popValid & wPend.neq(0);
    m.wdataData <= wData;
    m.wdataStrb <= wStrb;
    m.wdataLast <= wLastOut;
    wdataFire <= m.wdataValid & m.wdataReady;
    final wLastFire = wdataFire & wLastOut;

    // The size of each request, for d_size. They are pushed at acceptance,
    // a cycle or more before the request reaches the waist, so a device
    // that answers in its REQ cycle still finds its entry.
    final rdFire = Logic(name: 'rd_fire');
    final wrFire = Logic(name: 'wr_fire');
    final rMeta = HarborRegFifo(
      name: 'r_meta',
      clk: c,
      reset: r,
      depth: n,
      pushValid: acceptLegal & isGet,
      pushData: size,
      popReady: rdFire & m.rdataLast,
    );
    final wMeta = HarborRegFifo(
      name: 'w_meta',
      clk: c,
      reset: r,
      depth: n,
      pushValid: acceptLegal & isPut,
      pushData: size,
      popReady: wrFire,
    );

    // The denied response slot. It fills once the last A beat is taken.
    final denyOp = Logic(name: 'deny_op', width: 3);
    final denySize = Logic(name: 'deny_size', width: sizeW);
    final denySource = Logic(name: 'deny_source', width: idW);
    final denyBeats = Logic(name: 'deny_beats', width: cntW);
    final denyData = Logic(name: 'deny_data');
    final withData = isGet | isAtomic;
    final denyOpNow = mux(
      withData,
      _op(TileLinkDOpcode.accessAckData.value),
      mux(
        op.eq(_op(_intent)),
        _op(_hintAck),
        _op(TileLinkDOpcode.accessAck.value),
      ),
    );

    // D: read beats, write acks and denied responses share one 2 entry
    // FIFO. A burst holds the channel until its last beat, and otherwise
    // the three take turns.
    final lockRd = Logic(name: 'lock_rd');
    final lockDn = Logic(name: 'lock_dn');
    final lastGrant = Logic(name: 'last_grant', width: 2);
    final rdDenReg = Logic(name: 'rd_denied_reg');
    final v = [m.rdataValid, m.wrespValid, denyValid];
    List<Logic> order(List<int> o) {
      final g = List<Logic>.filled(3, Const(0));
      var none = Const(1) as Logic;
      for (final i in o) {
        g[i] = v[i] & none;
        none = none & ~v[i];
      }
      return g;
    }

    final after = [
      order([1, 2, 0]),
      order([2, 0, 1]),
      order([0, 1, 2]),
    ];
    Logic rr(int i) => mux(
      lastGrant.eq(Const(0, width: 2)),
      after[0][i],
      mux(lastGrant.eq(Const(1, width: 2)), after[1][i], after[2][i]),
    );
    final unlocked = ~lockRd & ~lockDn;
    final gRd = (v[0] & (lockRd | (unlocked & rr(0)))).named('grant_rd');
    final gWr = (v[1] & unlocked & rr(1)).named('grant_wr');
    final gDn = (v[2] & (lockDn | (unlocked & rr(2)))).named('grant_dn');

    final rdDenied = mux(lockRd, rdDenReg, m.rdataErr);
    final dWidths = [3, sizeW, idW, dataW, 1, 1];
    Logic dBeat(
      int opcode,
      Logic sz,
      Logic src,
      Logic dat,
      Logic denied,
      Logic corrupt,
    ) => harborPack([_op(opcode), sz, src, dat, denied, corrupt]);
    final dF = HarborRegFifo(
      name: 'd',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: gRd | gWr | gDn,
      pushData: harborBitMux(
        gRd,
        dBeat(
          TileLinkDOpcode.accessAckData.value,
          rMeta.popData,
          m.rdataId,
          m.rdataData,
          rdDenied,
          rdDenied | m.rdataErr,
        ),
        harborBitMux(
          gWr,
          dBeat(
            TileLinkDOpcode.accessAck.value,
            wMeta.popData,
            m.wrespId,
            Const(0, width: dataW),
            m.wrespErr,
            Const(0),
          ),
          harborPack([
            denyOp,
            denySize,
            denySource,
            Const(0, width: dataW),
            Const(1),
            denyData,
          ]),
        ),
      ),
      popReady: a.dReady,
    );
    m.rdataReady <= gRd & dF.pushReady;
    m.wrespReady <= gWr & dF.pushReady;
    rdFire <= m.rdataValid & m.rdataReady;
    wrFire <= m.wrespValid & m.wrespReady;
    final dnFire = gDn & dF.pushReady;

    final [dOp, dSize, dSource, dData, dDenied, dCorrupt] = harborUnpack(
      dF.popData,
      dWidths,
    );
    a.dValid <= dF.popValid;
    a.dOpcode <= dOp;
    a.dParam <= Const(0, width: 2);
    a.dSize <= dSize;
    a.dSource <= dSource;
    a.dSink <= Const(0, width: tl.config.sinkWidth);
    a.dData <= dData;
    a.dDenied <= dDenied;
    a.dCorrupt <= dCorrupt;

    final rdDone = rdFire & m.rdataLast;
    Sequential(c, reset: r, [
      // A message state.
      If.block([
        Iff(acceptLegal, [aLeft < aBeats - 1, aDrop < Const(0)]),
        ElseIf(acceptDeny, [
          aLeft < aBeats - 1,
          aDrop < Const(1),
          denyOp < denyOpNow,
          denySize < size,
          denySource < source,
          denyBeats < mux(withData, beats.of(size), beats.one()),
          denyData < withData,
          If(aBeats.eq(1), then: [denyValid < Const(1)]),
        ]),
        ElseIf(aPop & ~first, [
          aLeft < aLeft - 1,
          If(aDrop & aLeft.eq(1), then: [denyValid < Const(1)]),
        ]),
      ]),
      If(
        dnFire,
        then: [
          If(
            denyBeats.eq(1),
            then: [denyValid < Const(0)],
            orElse: [denyBeats < denyBeats - 1],
          ),
        ],
      ),
      // D arbitration state.
      If(
        rdFire,
        then: [
          lockRd < ~m.rdataLast,
          rdDenReg < rdDenied,
          lastGrant < Const(0, width: 2),
        ],
      ),
      If(wrFire, then: [lastGrant < Const(1, width: 2)]),
      If(
        dnFire,
        then: [lockDn < denyBeats.gt(1), lastGrant < Const(2, width: 2)],
      ),
      inflight <
          inflight +
              acceptLegal.zeroExtend(inflight.width) -
              rdDone.zeroExtend(inflight.width) -
              wrFire.zeroExtend(inflight.width),
      wPend <
          wPend +
              (reqFire & qWrite).zeroExtend(wPend.width) -
              wLastFire.zeroExtend(wPend.width),
    ]);
  }
}

/// A TileLink-UH master behind a memory master waist.
///
/// - Waist requests go into a 2 entry FIFO and turn into A messages in
///   order. SOURCE is the waist ID. TileLink allows one message in flight
///   per source, so a request waits while its ID is in flight, and the
///   requests behind it wait too.
/// - An INCR or WRAP burst of full bus beats with a power of two length,
///   aligned to its total size, becomes one Get or Put of that size. So
///   does every one beat request, aligned down to its size. Any other burst
///   becomes one beat messages, sent one after the other on the same
///   source.
/// - A one beat write with every lane of its size selected is PutFullData.
///   Other writes are PutPartialData.
/// - Read beats and write responses go back tagged with their ID. err is
///   d_denied or d_corrupt. Different IDs may come back in any order.
class HarborTileLinkMemoryMaster extends Module {
  HarborTileLinkMemoryMaster({
    required Logic clk,
    required Logic reset,
    required HarborMemoryWaist waist,
    required TileLinkInterface tl,
    super.name = 'tilelink_memory_master',
  }) : super(
         definitionName:
             'HarborTileLinkMemoryMaster_a${waist.config.addressWidth}'
             '_d${waist.config.dataWidth}_i${waist.config.idWidth}'
             '_n${waist.config.outstanding}_s${tl.config.sizeWidth}',
       ) {
    final config = waist.config;
    _checkMatch(tl, config);
    final c = addInput('clk', clk);
    final r = addInput('reset', reset);
    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.consumer, uniquify: (n) => 'm_$n');
    final a = tl.clone()
      ..pairConnectIO(this, tl, PairRole.provider, uniquify: (n) => 'tl_$n');

    final n = config.outstanding;
    final idW = config.idWidth;
    final addrW = config.addressWidth;
    final dataW = config.dataWidth;
    final strbW = config.strbWidth;
    final sizeW = tl.config.sizeWidth;
    final beatLog2 = _log2(strbW);
    final beats = _Beats(beatLog2, sizeW);
    const lenW = HarborMemoryWaistConfig.lenWidth;
    const wSizeW = HarborMemoryWaistConfig.sizeWidth;
    const burstW = HarborMemoryWaistConfig.burstWidth;
    const beatW = lenW + 1;

    final inflight = _counter('inflight', n);
    final reqWidths = [idW, 1, addrW, lenW, wSizeW, burstW];
    final start = Logic(name: 'start');
    final reqF = HarborRegFifo(
      name: 'req',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: m.reqValid & inflight.lt(Const(n, width: inflight.width)),
      pushData: harborPack([
        m.reqId,
        m.reqWrite,
        m.reqAddr,
        m.reqLen,
        m.reqSize,
        m.reqBurst,
      ]),
      popReady: start,
    );
    m.reqReady <= inflight.lt(Const(n, width: inflight.width)) & reqF.pushReady;
    final reqFire = m.reqValid & m.reqReady;
    final [hId, hWrite, hAddr, hLen, hSize, hBurst] = harborUnpack(
      reqF.popData,
      reqWidths,
    );

    final wPop = Logic(name: 'w_pop');
    final wF = HarborRegFifo(
      name: 'w',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: m.wdataValid,
      pushData: harborPack([m.wdataData, m.wdataStrb]),
      popReady: wPop,
    );
    m.wdataReady <= wF.pushReady;
    final [wData, wStrb] = harborUnpack(wF.popData, [dataW, strbW]);

    // One busy bit per source.
    final busy = Logic(name: 'busy', width: 1 << idW);
    final headBusy = busy[hId];

    // The request being sent.
    final act = Logic(name: 'act');
    start <= reqF.popValid & ~headBusy & ~act;
    final cId = Logic(name: 'c_id', width: idW);
    final cWrite = Logic(name: 'c_write');
    final cAddr = Logic(name: 'c_addr', width: addrW);
    final cLen = Logic(name: 'c_len', width: lenW);
    final cSize = Logic(name: 'c_size', width: wSizeW);
    final cBurst = Logic(name: 'c_burst', width: burstW);
    final cTlSize = Logic(name: 'c_tl_size', width: sizeW);
    final cSplit = Logic(name: 'c_split');
    final cBeat = Logic(name: 'c_beat', width: beatW);
    final cWait = Logic(name: 'c_wait');
    final cErr = Logic(name: 'c_err');

    // Whether the head request fits one TileLink message, and its size.
    final lenPow2 = (hLen.zeroExtend(beatW) & (hLen.zeroExtend(beatW) + 1)).eq(
      0,
    );
    final totalMask =
        (hLen.zeroExtend(lenW + beatLog2) << beatLog2) |
        Const((1 << beatLog2) - 1, width: lenW + beatLog2);
    final hLow = addrW >= lenW + beatLog2
        ? hAddr.getRange(0, lenW + beatLog2)
        : hAddr.zeroExtend(lenW + beatLog2);
    final whole =
        hLen.eq(0) |
        (hBurst.neq(Const(HarborMemoryBurst.fixed.value, width: burstW)) &
            hSize.eq(Const(beatLog2, width: wSizeW)) &
            lenPow2 &
            (hLow & totalMask).eq(0));
    final clamped = mux(
      hSize.gt(Const(beatLog2, width: wSizeW)),
      Const(beatLog2, width: wSizeW),
      hSize,
    );
    Logic log2Len = Const(0, width: sizeW);
    for (var k = 1; k <= lenW; k++) {
      log2Len = mux(
        hLen.eq(Const((1 << k) - 1, width: lenW)),
        Const(k, width: sizeW),
        log2Len,
      );
    }
    final clampedTl = clamped.width >= sizeW
        ? clamped.getRange(0, sizeW)
        : clamped.zeroExtend(sizeW);
    final hTlSize = mux(
      whole & hLen.neq(0),
      Const(beatLog2, width: sizeW) + log2Len,
      clampedTl,
    );

    // A goes out through a 2 entry FIFO.
    final aPush = Logic(name: 'a_push');
    final aPushReady = Logic(name: 'a_push_ready');
    final pieceSize = mux(
      cSize.gt(Const(beatLog2, width: wSizeW)),
      Const(beatLog2, width: wSizeW),
      cSize,
    );
    final aAddr = (cAddr & (Const(1, width: addrW, fill: true) << cTlSize))
        .named('a_addr');
    final lane = harborLaneMask(cAddr, pieceSize, strbW);
    final single = cSplit | cLen.eq(0);
    final wMask = wStrb & lane;
    final putOp = mux(
      single & wMask.eq(lane),
      _op(TileLinkAOpcode.putFullData.value),
      _op(TileLinkAOpcode.putPartialData.value),
    );
    final aOut = HarborRegFifo(
      name: 'a',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: aPush,
      pushData: harborPack([
        mux(cWrite, putOp, _op(TileLinkAOpcode.get.value)),
        cTlSize,
        cId,
        aAddr,
        mux(cWrite, wMask, lane),
        mux(cWrite, wData, Const(0, width: dataW)),
      ]),
      popReady: a.aReady,
    );
    aPushReady <= aOut.pushReady;
    final [aOp, aSize, aSrc, aAdr, aMask, aDat] = harborUnpack(aOut.popData, [
      3,
      sizeW,
      idW,
      addrW,
      strbW,
      dataW,
    ]);
    a.aValid <= aOut.popValid;
    a.aOpcode <= aOp;
    a.aParam <= Const(0, width: 3);
    a.aSize <= aSize;
    a.aSource <= aSrc;
    a.aAddress <= aAdr;
    a.aMask <= aMask;
    a.aData <= aDat;
    a.aCorrupt <= Const(0);

    final canSend = act & (~cSplit | ~cWait) & aPushReady;
    aPush <= canSend & (~cWrite | wF.popValid);
    wPop <= aPush & cWrite;
    final wholeDone =
        aPush & ~cSplit & (~cWrite | cBeat.eq(cLen.zeroExtend(beatW)));

    // The next beat address of a split burst.
    final ww = max(addrW, 16);
    final cur = cAddr.zeroExtend(ww);
    final bytes = (Const(1, width: ww) << pieceSize).named('piece_bytes');
    final alignedCur = cur & ~(bytes - 1);
    final wrapMask = ((cLen.zeroExtend(ww) + 1) << pieceSize) - 1;
    final nextWide = mux(
      cBurst.eq(Const(HarborMemoryBurst.fixed.value, width: burstW)),
      cur,
      mux(
        cBurst.eq(Const(HarborMemoryBurst.wrap.value, width: burstW)),
        (cur & ~wrapMask) | ((alignedCur + bytes) & wrapMask),
        alignedCur + bytes,
      ),
    );
    final nextAddr = nextWide.getRange(0, addrW);

    // D comes in through a 2 entry FIFO.
    final dPop = Logic(name: 'd_pop');
    final dIn = HarborRegFifo(
      name: 'd',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: a.dValid,
      pushData: harborPack([
        a.dOpcode,
        a.dSize,
        a.dSource,
        a.dData,
        a.dDenied | a.dCorrupt,
      ]),
      popReady: dPop,
    );
    a.dReady <= dIn.pushReady;
    final [dOp, dSize, dSrc, dData, dErr] = harborUnpack(dIn.popData, [
      3,
      sizeW,
      idW,
      dataW,
      1,
    ]);
    final isData = dOp.eq(_op(TileLinkDOpcode.accessAckData.value));
    final isAck = dOp.eq(_op(TileLinkDOpcode.accessAck.value));
    final piece = (act & cSplit & dSrc.eq(cId)).named('d_piece');
    final pieceLast = cBeat.eq(cLen.zeroExtend(beatW));
    final dBeat = Logic(name: 'd_beat', width: beats.width);
    final dLast = dBeat.eq(beats.of(dSize) - beats.one());

    m.rdataValid <= dIn.popValid & isData;
    m.rdataId <= dSrc;
    m.rdataData <= dData;
    m.rdataErr <= dErr;
    m.rdataLast <= mux(piece, pieceLast, dLast);
    m.wrespValid <= dIn.popValid & isAck & (~piece | pieceLast);
    m.wrespId <= dSrc;
    m.wrespErr <= dErr | (piece & cErr);
    dPop <=
        dIn.popValid &
            mux(
              isData,
              m.rdataReady,
              mux(isAck & (~piece | pieceLast), m.wrespReady, Const(1)),
            );
    final dFire = dIn.popValid & dPop;
    final rdDone = m.rdataValid & m.rdataReady & m.rdataLast;
    final wrDone = m.wrespValid & m.wrespReady;
    final pieceDone = dFire & piece & (isData | isAck);
    final freeSrc = (rdDone | wrDone).named('free_src');

    final oneHot = Const(1, width: 1 << idW);
    Sequential(c, reset: r, [
      If.block([
        Iff(start, [
          act < Const(1),
          cId < hId,
          cWrite < hWrite,
          cAddr < hAddr,
          cLen < hLen,
          cSize < hSize,
          cBurst < hBurst,
          cTlSize < hTlSize,
          cSplit < ~whole,
          cBeat < Const(0, width: beatW),
          cWait < Const(0),
          cErr < Const(0),
        ]),
        ElseIf(wholeDone, [act < Const(0)]),
        ElseIf(aPush & ~cSplit, [cBeat < cBeat + 1]),
        ElseIf(aPush & cSplit, [cWait < Const(1), cAddr < nextAddr]),
        ElseIf(pieceDone, [
          cWait < Const(0),
          cBeat < cBeat + 1,
          cErr < cErr | dErr,
          If(pieceLast, then: [act < Const(0)]),
        ]),
      ]),
      If(
        dFire & isData & ~piece,
        then: [
          dBeat < mux(dLast, Const(0, width: beats.width), dBeat + beats.one()),
        ],
      ),
      busy <
          (busy | mux(start, oneHot << hId, Const(0, width: 1 << idW))) &
              ~mux(freeSrc, oneHot << dSrc, Const(0, width: 1 << idW)),
      inflight <
          inflight +
              reqFire.zeroExtend(inflight.width) -
              rdDone.zeroExtend(inflight.width) -
              wrDone.zeroExtend(inflight.width),
    ]);
  }
}

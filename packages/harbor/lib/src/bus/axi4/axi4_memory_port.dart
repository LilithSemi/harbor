import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show Axi4RespField;

import '../port/memory_waist.dart';
import '../port/reg_fifo.dart';
import 'axi4_interface.dart';

void _checkMatch(Axi4Interface axi, HarborMemoryWaistConfig config) {
  if (axi.addressWidth != config.addressWidth ||
      axi.dataWidth != config.dataWidth ||
      axi.idWidth != config.idWidth) {
    throw ArgumentError(
      'AXI4 widths (addr ${axi.addressWidth}, data ${axi.dataWidth}, '
      'id ${axi.idWidth}) do not match $config',
    );
  }
}

int _log2(int v) => v.bitLength - 1;

Logic _counter(String name, int max) => Logic(name: name, width: max.bitLength);

/// An AXI4 subordinate in front of a memory slave waist.
///
/// - AW and AR each go into a 2 entry FIFO. A round robin arbiter merges them
///   into the waist request channel, and a choice holds until it is taken.
/// - At most `outstanding` requests are in flight on the waist. A request
///   leaves the count when its last read beat or its write response comes
///   back.
/// - W goes into a 2 entry FIFO and reaches the waist only after the request
///   of its write is taken. So up to 2 beats can arrive before their AW.
///   After that WREADY stays low until the AW comes.
/// - Responses come back in request order per direction, which is in order
///   per ID as AXI4 requires. B and R each go out through a 2 entry FIFO.
///
/// Requests that break the AXI4 burst rules get SLVERR: SIZE wider than the
/// bus, BURST 3, FIXED longer than 16 beats, WRAP not 2, 4, 8 or 16 beats or
/// not aligned to SIZE, and INCR across a 4 KB boundary. Such a request still
/// goes to the memory, as a FIXED burst of the same length at full bus size,
/// with all write strobes low and read data replaced by zero. LOCK, CACHE,
/// PROT and QOS are ignored. An exclusive access gets OKAY, which means
/// exclusive access is not supported.
class HarborAxi4MemorySlave extends Module {
  /// Depth of the W FIFO, which is the most W beats taken before their AW.
  static const int wBuffer = 2;

  HarborAxi4MemorySlave({
    required Logic clk,
    required Logic reset,
    required Axi4Interface axi,
    required HarborMemoryWaist waist,
    super.name = 'axi4_memory_slave',
  }) : super(
         definitionName:
             'HarborAxi4MemorySlave_a${waist.config.addressWidth}'
             '_d${waist.config.dataWidth}_i${waist.config.idWidth}'
             '_n${waist.config.outstanding}',
       ) {
    final config = waist.config;
    _checkMatch(axi, config);
    final c = addInput('clk', clk);
    final r = addInput('reset', reset);
    final a = axi.clone()
      ..pairConnectIO(this, axi, PairRole.consumer, uniquify: (n) => 'axi_$n');
    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.provider, uniquify: (n) => 'm_$n');

    final n = config.outstanding;
    final idW = config.idWidth;
    final addrW = config.addressWidth;
    final dataW = config.dataWidth;
    final strbW = config.strbWidth;
    final busSize = _log2(strbW);
    const lenW = Axi4Interface.lenWidth;
    const sizeW = Axi4Interface.sizeWidth;
    const burstW = Axi4Interface.burstWidth;
    final reqWidths = [idW, addrW, lenW, sizeW, burstW, 1];

    // Request FIFOs and the arbiter. The illegal-burst check runs once per
    // AW or AR, at the push, and rides along as one extra bit. The REQ
    // output path only reads the bit back, with no comparators of its own.
    final reqFire = Logic(name: 'req_fire');
    final pickWrite = Logic(name: 'pick_write');
    final awF = HarborRegFifo(
      name: 'aw',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: a.awValid,
      pushData: harborPack([
        a.awId,
        a.awAddr,
        a.awLen,
        a.awSize,
        a.awBurst,
        _illegal(a.awAddr, a.awLen, a.awSize, a.awBurst, busSize),
      ]),
      popReady: reqFire & pickWrite,
    );
    final arF = HarborRegFifo(
      name: 'ar',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: a.arValid,
      pushData: harborPack([
        a.arId,
        a.arAddr,
        a.arLen,
        a.arSize,
        a.arBurst,
        _illegal(a.arAddr, a.arLen, a.arSize, a.arBurst, busSize),
      ]),
      popReady: reqFire & ~pickWrite,
    );
    a.awReady <= awF.pushReady;
    a.arReady <= arF.pushReady;

    final inflight = _counter('inflight', n);
    final held = Logic(name: 'held');
    final heldWrite = Logic(name: 'held_write');
    final lastWrite = Logic(name: 'last_write');
    pickWrite <=
        mux(held, heldWrite, awF.popValid & (~arF.popValid | ~lastWrite));
    final canIssue = inflight.lt(Const(n, width: inflight.width));
    final head = mux(pickWrite, awF.popData, arF.popData);
    final [id, addr, len, size, burst, illegal] = harborUnpack(head, reqWidths);

    m.reqValid <= canIssue & mux(pickWrite, awF.popValid, arF.popValid);
    m.reqId <= id;
    m.reqWrite <= pickWrite;
    m.reqAddr <= addr;
    m.reqLen <= len;
    m.reqSize <= mux(illegal, Const(busSize, width: sizeW), size);
    m.reqBurst <=
        mux(
          illegal,
          Const(HarborMemoryBurst.fixed.value, width: burstW),
          burst,
        );
    reqFire <= m.reqValid & m.reqReady;

    // Write data. A beat goes out only while a taken write still has beats
    // to send.
    final wPend = _counter('w_pend', n);
    final wdataFire = Logic(name: 'wdata_fire');
    final wF = HarborRegFifo(
      name: 'w',
      clk: c,
      reset: r,
      depth: wBuffer,
      pushValid: a.wValid,
      pushData: harborPack([a.wData, a.wStrb, a.wLast]),
      popReady: wdataFire,
    );
    a.wReady <= wF.pushReady;
    final [wData, wStrb, wLast] = harborUnpack(wF.popData, [dataW, strbW, 1]);
    final wLastFire = wdataFire & wLast;
    // wPend only turns non-zero the cycle after reqFire (it is a register),
    // so wLastFire can never land on the same cycle as the push below. No
    // same-cycle bypass is needed here.
    final wFlag = HarborRegFifo(
      name: 'w_flag',
      clk: c,
      reset: r,
      depth: n,
      pushValid: reqFire & pickWrite,
      pushData: illegal,
      popReady: wLastFire,
    );
    m.wdataValid <= wF.popValid & wPend.neq(0);
    m.wdataData <= wData;
    m.wdataStrb <= mux(wFlag.popData, Const(0, width: strbW), wStrb);
    m.wdataLast <= wLast;
    wdataFire <= m.wdataValid & m.wdataReady;

    // Write responses. bypassWhenEmpty covers a device that answers WRESP
    // in the same cycle as the write's REQ, so its flag is never stale.
    final bFlag = HarborRegFifo(
      name: 'b_flag',
      clk: c,
      reset: r,
      depth: n,
      pushValid: reqFire & pickWrite,
      pushData: illegal,
      popReady: m.wrespValid & m.wrespReady,
      bypassWhenEmpty: true,
    );
    final bF = HarborRegFifo(
      name: 'b',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: m.wrespValid,
      pushData: harborPack([m.wrespId, m.wrespErr | bFlag.popData]),
      popReady: a.bReady,
      resetEntries: true,
    );
    m.wrespReady <= bF.pushReady;
    final [bId, bErr] = harborUnpack(bF.popData, [idW, 1]);
    a.bValid <= bF.popValid;
    a.bId <= bId;
    a.bResp <= _resp(bErr);

    // Read data. bypassWhenEmpty covers a device that answers RDATA in the
    // same cycle as the read's REQ (a comb memory with no outstanding read
    // ahead of it), so its flag is never stale. See
    // test/bus/port/memory_slave_port_test.dart for the regression.
    final rFlag = HarborRegFifo(
      name: 'r_flag',
      clk: c,
      reset: r,
      depth: n,
      pushValid: reqFire & ~pickWrite,
      pushData: illegal,
      popReady: m.rdataValid & m.rdataReady & m.rdataLast,
      bypassWhenEmpty: true,
    );
    final rF = HarborRegFifo(
      name: 'r',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: m.rdataValid,
      pushData: harborPack([
        m.rdataId,
        mux(rFlag.popData, Const(0, width: dataW), m.rdataData),
        m.rdataErr | rFlag.popData,
        m.rdataLast,
      ]),
      popReady: a.rReady,
      resetEntries: true,
    );
    m.rdataReady <= rF.pushReady;
    final [rId, rData, rErr, rLast] = harborUnpack(rF.popData, [
      idW,
      dataW,
      1,
      1,
    ]);
    a.rValid <= rF.popValid;
    a.rId <= rId;
    a.rData <= rData;
    a.rResp <= _resp(rErr);
    a.rLast <= rLast;

    final done = [
      m.rdataValid & m.rdataReady & m.rdataLast,
      m.wrespValid & m.wrespReady,
    ];
    Sequential(c, reset: r, [
      held < m.reqValid & ~m.reqReady,
      heldWrite < pickWrite,
      If(reqFire, then: [lastWrite < pickWrite]),
      inflight <
          inflight +
              reqFire.zeroExtend(inflight.width) -
              done[0].zeroExtend(inflight.width) -
              done[1].zeroExtend(inflight.width),
      wPend <
          wPend +
              (reqFire & pickWrite).zeroExtend(wPend.width) -
              wLastFire.zeroExtend(wPend.width),
    ]);
  }

  static Logic _resp(Logic err) => mux(
    err,
    Const(Axi4RespField.slvErr.value, width: Axi4Interface.respWidth),
    Const(Axi4RespField.okay.value, width: Axi4Interface.respWidth),
  );

  // High when the request breaks the AXI4 burst rules.
  static Logic _illegal(
    Logic addr,
    Logic len,
    Logic size,
    Logic burst,
    int busSize,
  ) {
    const sizeW = Axi4Interface.sizeWidth;
    final addr12 = addr.width >= 12
        ? addr.getRange(0, 12)
        : addr.zeroExtend(12);
    final lowMask = ~(Const(0xfff, width: 12) << size);
    final aligned = (addr12 & lowMask).eq(0);
    final start = (addr12 & ~lowMask).zeroExtend(17);
    final bytes = (len.zeroExtend(17) + 1) << size;
    final isFixed = burst.eq(HarborMemoryBurst.fixed.value);
    final isIncr = burst.eq(HarborMemoryBurst.incr.value);
    final isWrap = burst.eq(HarborMemoryBurst.wrap.value);
    final wrapLen = [1, 3, 7, 15].map((l) => len.eq(l)).reduce((x, y) => x | y);
    return size.gt(Const(busSize, width: sizeW)) |
        burst.eq(3) |
        (isFixed & len.gt(15)) |
        (isWrap & ~(wrapLen & aligned)) |
        (isIncr & (start + bytes).gt(4096));
  }
}

/// An AXI4 manager behind a memory master waist.
///
/// - The waist request goes into a 2 entry AW or AR FIFO. REQ_READY is low
///   while either FIFO is full or `outstanding` requests are in flight, so a
///   stalled AR also blocks a new write REQ. This only costs throughput:
///   the two directions still make progress on their own FIFOs once
///   REQ_READY goes high again.
/// - wdata goes into a 2 entry W FIFO and on to W. W can reach the bus
///   before its AW, which AXI4 allows.
/// - B and R come back through 2 entry FIFOs. BREADY and RREADY are low only
///   while those FIFOs are full.
///
/// The waist returns responses ordered per ID only: each one carries its ID,
/// and different IDs may come back in any order. AXI4 already keeps order
/// per ID, so AW and AR go out as soon as their FIFO and the outstanding
/// limit allow, with no extra guard.
class HarborAxi4MemoryMaster extends Module {
  HarborAxi4MemoryMaster({
    required Logic clk,
    required Logic reset,
    required HarborMemoryWaist waist,
    required Axi4Interface axi,
    super.name = 'axi4_memory_master',
  }) : super(
         definitionName:
             'HarborAxi4MemoryMaster_a${waist.config.addressWidth}'
             '_d${waist.config.dataWidth}_i${waist.config.idWidth}'
             '_n${waist.config.outstanding}',
       ) {
    final config = waist.config;
    _checkMatch(axi, config);
    final c = addInput('clk', clk);
    final r = addInput('reset', reset);
    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.consumer, uniquify: (n) => 'm_$n');
    final a = axi.clone()
      ..pairConnectIO(this, axi, PairRole.provider, uniquify: (n) => 'axi_$n');

    final n = config.outstanding;
    final idW = config.idWidth;
    final addrW = config.addressWidth;
    final dataW = config.dataWidth;
    final strbW = config.strbWidth;
    const lenW = Axi4Interface.lenWidth;
    const sizeW = Axi4Interface.sizeWidth;
    const burstW = Axi4Interface.burstWidth;
    final reqWidths = [idW, addrW, lenW, sizeW, burstW];

    final inflight = _counter('inflight', n);
    final reqFire = Logic(name: 'req_fire');
    final reqData = harborPack([
      m.reqId,
      m.reqAddr,
      m.reqLen,
      m.reqSize,
      m.reqBurst,
    ]);
    final awFire = Logic(name: 'aw_fire');
    final arFire = Logic(name: 'ar_fire');
    // resetEntries: true, since popData drives AWSIZE/ARSIZE and the rest
    // of AW/AR directly, and the rohd_hcl write checker reads those at the
    // posedge without waiting on AWVALID, so an unreset X would throw.
    final awF = HarborRegFifo(
      name: 'aw',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: reqFire & m.reqWrite,
      pushData: reqData,
      popReady: awFire,
      resetEntries: true,
    );
    final arF = HarborRegFifo(
      name: 'ar',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: reqFire & ~m.reqWrite,
      pushData: reqData,
      popReady: arFire,
      resetEntries: true,
    );
    m.reqReady <=
        inflight.lt(Const(n, width: inflight.width)) &
            awF.pushReady &
            arF.pushReady;
    reqFire <= m.reqValid & m.reqReady;

    final [awId, awAddr, awLen, awSize, awBurst] = harborUnpack(
      awF.popData,
      reqWidths,
    );
    a.awValid <= awF.popValid;
    a.awId <= awId;
    a.awAddr <= awAddr;
    a.awLen <= awLen;
    a.awSize <= awSize;
    a.awBurst <= awBurst;
    awFire <= a.awValid & a.awReady;

    final [arId, arAddr, arLen, arSize, arBurst] = harborUnpack(
      arF.popData,
      reqWidths,
    );
    a.arValid <= arF.popValid;
    a.arId <= arId;
    a.arAddr <= arAddr;
    a.arLen <= arLen;
    a.arSize <= arSize;
    a.arBurst <= arBurst;
    arFire <= a.arValid & a.arReady;

    for (final p in ['AW', 'AR']) {
      a.port('${p}LOCK') <= Const(0);
      a.port('${p}CACHE') <= Const(0, width: Axi4Interface.cacheWidth);
      a.port('${p}PROT') <= Const(0, width: Axi4Interface.protWidth);
      a.port('${p}QOS') <= Const(0, width: Axi4Interface.qosWidth);
    }

    // resetEntries: true, since popData drives WDATA/WSTRB/WLAST directly
    // and the rohd_hcl checkers read those at the posedge.
    final wF = HarborRegFifo(
      name: 'w',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: m.wdataValid,
      pushData: harborPack([m.wdataData, m.wdataStrb, m.wdataLast]),
      popReady: a.wReady,
      resetEntries: true,
    );
    m.wdataReady <= wF.pushReady;
    final [wData, wStrb, wLast] = harborUnpack(wF.popData, [dataW, strbW, 1]);
    a.wValid <= wF.popValid;
    a.wData <= wData;
    a.wStrb <= wStrb;
    a.wLast <= wLast;

    // SLVERR and DECERR both have bit 1 set.
    final bF = HarborRegFifo(
      name: 'b',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: a.bValid,
      pushData: harborPack([a.bId, a.bResp[1]]),
      popReady: m.wrespReady,
    );
    a.bReady <= bF.pushReady;
    final [bId, bErr] = harborUnpack(bF.popData, [idW, 1]);
    m.wrespValid <= bF.popValid;
    m.wrespId <= bId;
    m.wrespErr <= bErr;

    final rF = HarborRegFifo(
      name: 'r',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: a.rValid,
      pushData: harborPack([a.rId, a.rData, a.rResp[1], a.rLast]),
      popReady: m.rdataReady,
    );
    a.rReady <= rF.pushReady;
    final [rId, rData, rErr, rLast] = harborUnpack(rF.popData, [
      idW,
      dataW,
      1,
      1,
    ]);
    m.rdataValid <= rF.popValid;
    m.rdataId <= rId;
    m.rdataData <= rData;
    m.rdataErr <= rErr;
    m.rdataLast <= rLast;

    final done = [
      m.rdataValid & m.rdataReady & m.rdataLast,
      m.wrespValid & m.wrespReady,
    ];
    Sequential(c, reset: r, [
      inflight <
          inflight +
              reqFire.zeroExtend(inflight.width) -
              done[0].zeroExtend(inflight.width) -
              done[1].zeroExtend(inflight.width),
    ]);
  }
}

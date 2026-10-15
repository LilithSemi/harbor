import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart' show Axi4RespField;

import '../port/memory_waist.dart';
import '../port/reg_fifo.dart';
import 'axi4_exclusive.dart';
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
/// with all write strobes low and read data replaced by zero. CACHE, PROT
/// and QOS are ignored.
///
/// With no [exclusive] monitor, LOCK is ignored too, and an exclusive
/// access gets OKAY, which means exclusive access is not supported. With
/// one, a [HarborAxi4ExclusiveMonitor] watches the waist requests: an
/// exclusive access that it accepts gets EXOKAY, and a failed exclusive
/// write reaches the memory with all strobes low and gets OKAY.
/// [deviceAddressWidth] is the number of low address bits the memory
/// decodes. The monitor keys on them, so it sees aliases as one address.
///
/// REQ_EXCLUSIVE is LOCK with a monitor, else 0. It is a hint only: it is
/// also high for an access the monitor treats as normal or drops. The port
/// ignores RDATA_EXOKAY and WRESP_EXOKAY from the memory.
class HarborAxi4MemorySlave extends Module {
  /// Depth of the W FIFO, which is the most W beats taken before their AW.
  static const int wBuffer = 2;

  HarborAxi4MemorySlave({
    required Logic clk,
    required Logic reset,
    required Axi4Interface axi,
    required HarborMemoryWaist waist,
    HarborAxi4Exclusive? exclusive,
    int? deviceAddressWidth,
    super.name = 'axi4_memory_slave',
  }) : super(
         definitionName:
             'HarborAxi4MemorySlave_a${waist.config.addressWidth}'
             '_d${waist.config.dataWidth}_i${waist.config.idWidth}'
             '_n${waist.config.outstanding}'
             '${exclusive == null ? '' : '_${exclusive.tag}'
                       '_k${deviceAddressWidth ?? waist.config.addressWidth}'}',
       ) {
    final config = waist.config;
    _checkMatch(axi, config);
    final ex = exclusive != null;
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
    final devBits = deviceAddressWidth ?? addrW;
    final preW = ex
        ? HarborAxi4ExclusiveMonitor.preWidth(
            config: exclusive,
            addrWidth: addrW,
            busSize: busSize,
            deviceBits: devBits,
          )
        : 0;
    Logic pre(Logic addr, Logic len, Logic size, Logic burst, bool write) =>
        HarborAxi4ExclusiveMonitor.pre(
          config: exclusive!,
          addr: addr,
          len: len,
          size: size,
          burst: burst,
          busSize: busSize,
          deviceBits: devBits,
          write: write,
        );
    final reqWidths = [
      idW,
      addrW,
      lenW,
      sizeW,
      burstW,
      1,
      if (ex) ...[1, preW],
    ];

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
        if (ex) ...[
          a.awLock,
          pre(a.awAddr, a.awLen, a.awSize, a.awBurst, true),
        ],
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
        if (ex) ...[
          a.arLock,
          pre(a.arAddr, a.arLen, a.arSize, a.arBurst, false),
        ],
      ]),
      popReady: reqFire & ~pickWrite,
    );
    a.awReady <= awF.pushReady;
    a.arReady <= arF.pushReady;

    final inflight = _counter('inflight', n);
    final held = Logic(name: 'held');
    final heldWrite = Logic(name: 'held_write');
    final lastWrite = Logic(name: 'last_write');
    // With a monitor, an exclusive AW or AR head waits one cycle after its
    // push for its slot lookup. Only a LOCK push marks its entry, so other
    // heads do not wait.
    final awHead = ex ? Logic(name: 'aw_head_valid') : awF.popValid;
    final arHead = ex ? Logic(name: 'ar_head_valid') : arF.popValid;
    pickWrite <= mux(held, heldWrite, awHead & (~arHead | ~lastWrite));
    final canIssue = inflight.lt(Const(n, width: inflight.width));
    final head = mux(pickWrite, awF.popData, arF.popData);
    final [id, addr, len, size, burst, illegal, ...headLock] = harborUnpack(
      head,
      reqWidths,
    );

    m.reqValid <= canIssue & mux(pickWrite, awHead, arHead);
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
    m.reqExclusive <= (ex ? headLock.first : Const(0));
    reqFire <= m.reqValid & m.reqReady;

    HarborAxi4ExclusiveMonitor? mon;
    if (exclusive != null) {
      // The monitor reads each FIFO head on its own, so its slot lookup does
      // not wait for the arbiter.
      final [wId, wAddr, _, _, _, wIllegal, wLock, wPre] = harborUnpack(
        awF.popData,
        reqWidths,
      );
      final [rId, rAddr, _, _, _, rIllegal, rLock, rPre] = harborUnpack(
        arF.popData,
        reqWidths,
      );
      mon = HarborAxi4ExclusiveMonitor(
        clk: c,
        reset: r,
        config: exclusive,
        write: pickWrite,
        wId: wId,
        wAddr: wAddr,
        wLock: wLock,
        wIllegal: wIllegal,
        wPre: wPre,
        rId: rId,
        rAddr: rAddr,
        rLock: rLock,
        rIllegal: rIllegal,
        rPre: rPre,
        wEntryIds: [for (final e in awF.entries) harborUnpack(e, reqWidths)[0]],
        wEntryAddrs: [
          for (final e in awF.entries) harborUnpack(e, reqWidths)[1],
        ],
        wPush: [
          for (var e = 0; e < awF.entries.length; e++)
            awF.pushFire & a.awLock & awF.writeIndex.eq(e),
        ],
        wRead: awF.readIndex,
        rEntryAddrs: [
          for (final e in arF.entries) harborUnpack(e, reqWidths)[1],
        ],
        rPush: [
          for (var e = 0; e < arF.entries.length; e++)
            arF.pushFire & a.arLock & arF.writeIndex.eq(e),
        ],
        rRead: arF.readIndex,
        take: reqFire,
        done: m.wrespValid & m.wrespReady,
        busSize: busSize,
        deviceBits: devBits,
        depth: n,
      );
      awHead <= awF.popValid & ~mon.wStall;
      arHead <= arF.popValid & ~mon.rStall;
    }

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
      pushData: mon == null ? illegal : illegal | mon.drop,
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
      pushData: mon == null ? illegal : harborPack([illegal, mon.wExOkay]),
      popReady: m.wrespValid & m.wrespReady,
      bypassWhenEmpty: true,
    );
    final bF = HarborRegFifo(
      name: 'b',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: m.wrespValid,
      pushData: harborPack([
        m.wrespId,
        m.wrespErr | (ex ? bFlag.popData[0] : bFlag.popData),
        if (ex) bFlag.popData[1],
      ]),
      popReady: a.bReady,
      resetEntries: true,
    );
    m.wrespReady <= bF.pushReady;
    final [bId, bErr, ...bEx] = harborUnpack(bF.popData, [idW, 1, if (ex) 1]);
    a.bValid <= bF.popValid;
    a.bId <= bId;
    a.bResp <= (ex ? _resp(bErr, bEx.single) : _resp(bErr));

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
      pushData: mon == null ? illegal : harborPack([illegal, mon.rExOkay]),
      popReady: m.rdataValid & m.rdataReady & m.rdataLast,
      bypassWhenEmpty: true,
    );
    final rIllegal = ex ? rFlag.popData[0] : rFlag.popData;
    final rF = HarborRegFifo(
      name: 'r',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: m.rdataValid,
      pushData: harborPack([
        m.rdataId,
        mux(rIllegal, Const(0, width: dataW), m.rdataData),
        m.rdataErr | rIllegal,
        m.rdataLast,
        if (ex) rFlag.popData[1],
      ]),
      popReady: a.rReady,
      resetEntries: true,
    );
    m.rdataReady <= rF.pushReady;
    final [rId, rData, rErr, rLast, ...rEx] = harborUnpack(rF.popData, [
      idW,
      dataW,
      1,
      1,
      if (ex) 1,
    ]);
    a.rValid <= rF.popValid;
    a.rId <= rId;
    a.rData <= rData;
    a.rResp <= (ex ? _resp(rErr, rEx.single) : _resp(rErr));
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

  // SLVERR on [err], else EXOKAY on [exOkay], else OKAY.
  static Logic _resp(Logic err, [Logic? exOkay]) => mux(
    err,
    Const(Axi4RespField.slvErr.value, width: Axi4Interface.respWidth),
    exOkay == null
        ? Const(Axi4RespField.okay.value, width: Axi4Interface.respWidth)
        : mux(
            exOkay,
            Const(Axi4RespField.exOkay.value, width: Axi4Interface.respWidth),
            Const(Axi4RespField.okay.value, width: Axi4Interface.respWidth),
          ),
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

/// A read-only AXI4 subordinate in front of a memory slave waist.
///
/// Built like the read side of [HarborAxi4MemorySlave]: AR goes into a 2
/// entry FIFO, R comes back through a 2 entry FIFO, and up to `outstanding`
/// reads are in flight. The waist's write side is never used: REQ_WRITE is
/// always 0, WDATA_VALID is always 0, and WRESP_READY stays high. LOCK is
/// ignored and REQ_EXCLUSIVE is always 0.
class HarborAxi4MemorySlaveReadOnly extends Module {
  HarborAxi4MemorySlaveReadOnly({
    required Logic clk,
    required Logic reset,
    required Axi4ReadOnlyInterface axi,
    required HarborMemoryWaist waist,
    super.name = 'axi4_memory_slave_ro',
  }) : super(
         definitionName:
             'HarborAxi4MemorySlave_ro_a${waist.config.addressWidth}'
             '_d${waist.config.dataWidth}_i${waist.config.idWidth}'
             '_n${waist.config.outstanding}',
       ) {
    final config = waist.config;
    if (axi.addressWidth != config.addressWidth ||
        axi.dataWidth != config.dataWidth ||
        axi.idWidth != config.idWidth) {
      throw ArgumentError(
        'AXI4 widths (addr ${axi.addressWidth}, data ${axi.dataWidth}, '
        'id ${axi.idWidth}) do not match $config',
      );
    }
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

    final reqFire = Logic(name: 'req_fire');
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
        HarborAxi4MemorySlave._illegal(
          a.arAddr,
          a.arLen,
          a.arSize,
          a.arBurst,
          busSize,
        ),
      ]),
      popReady: reqFire,
    );
    a.arReady <= arF.pushReady;

    final inflight = _counter('inflight', n);
    final canIssue = inflight.lt(Const(n, width: inflight.width));
    final [id, addr, len, size, burst, illegal] = harborUnpack(
      arF.popData,
      reqWidths,
    );

    m.reqValid <= canIssue & arF.popValid;
    m.reqId <= id;
    m.reqWrite <= Const(0);
    m.reqExclusive <= Const(0);
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

    // Never raise a write request or write data. Keep WRESP_READY high so a
    // device that happens to echo something on this waist never stalls.
    m.wdataValid <= Const(0);
    m.wdataData <= Const(0, width: dataW);
    m.wdataStrb <= Const(0, width: strbW);
    m.wdataLast <= Const(0);
    m.wrespReady <= Const(1);

    final rFlag = HarborRegFifo(
      name: 'r_flag',
      clk: c,
      reset: r,
      depth: n,
      pushValid: reqFire,
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
    a.rResp <= HarborAxi4MemorySlave._resp(rErr);
    a.rLast <= rLast;

    final done = m.rdataValid & m.rdataReady & m.rdataLast;
    Sequential(c, reset: r, [
      inflight <
          inflight +
              reqFire.zeroExtend(inflight.width) -
              done.zeroExtend(inflight.width),
    ]);
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
///
/// REQ_EXCLUSIVE is AWLOCK or ARLOCK of its request. RDATA_EXOKAY and
/// WRESP_EXOKAY are high when RRESP or BRESP is EXOKAY. The port does not
/// check the exclusive pair rules of [HarborMemoryWaist]. The device keeps
/// them, and uses only the IDs that get a slot from the fabric master's
/// `exclusiveIds`.
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
    final reqWidths = [idW, addrW, lenW, sizeW, burstW, 1];

    final inflight = _counter('inflight', n);
    final reqFire = Logic(name: 'req_fire');
    final reqData = harborPack([
      m.reqId,
      m.reqAddr,
      m.reqLen,
      m.reqSize,
      m.reqBurst,
      m.reqExclusive,
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

    final [awId, awAddr, awLen, awSize, awBurst, awLock] = harborUnpack(
      awF.popData,
      reqWidths,
    );
    a.awValid <= awF.popValid;
    a.awId <= awId;
    a.awAddr <= awAddr;
    a.awLen <= awLen;
    a.awSize <= awSize;
    a.awBurst <= awBurst;
    a.awLock <= awLock;
    awFire <= a.awValid & a.awReady;

    final [arId, arAddr, arLen, arSize, arBurst, arLock] = harborUnpack(
      arF.popData,
      reqWidths,
    );
    a.arValid <= arF.popValid;
    a.arId <= arId;
    a.arAddr <= arAddr;
    a.arLen <= arLen;
    a.arSize <= arSize;
    a.arBurst <= arBurst;
    a.arLock <= arLock;
    arFire <= a.arValid & a.arReady;

    for (final p in ['AW', 'AR']) {
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
    Logic exOkay(Logic resp) =>
        resp.eq(Const(Axi4RespField.exOkay.value, width: resp.width));
    final bF = HarborRegFifo(
      name: 'b',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: a.bValid,
      pushData: harborPack([a.bId, a.bResp[1], exOkay(a.bResp)]),
      popReady: m.wrespReady,
    );
    a.bReady <= bF.pushReady;
    final [bId, bErr, bEx] = harborUnpack(bF.popData, [idW, 1, 1]);
    m.wrespValid <= bF.popValid;
    m.wrespId <= bId;
    m.wrespErr <= bErr;
    m.wrespExOkay <= bEx;

    final rF = HarborRegFifo(
      name: 'r',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: a.rValid,
      pushData: harborPack([
        a.rId,
        a.rData,
        a.rResp[1],
        a.rLast,
        exOkay(a.rResp),
      ]),
      popReady: m.rdataReady,
    );
    a.rReady <= rF.pushReady;
    final [rId, rData, rErr, rLast, rEx] = harborUnpack(rF.popData, [
      idW,
      dataW,
      1,
      1,
      1,
    ]);
    m.rdataValid <= rF.popValid;
    m.rdataId <= rId;
    m.rdataData <= rData;
    m.rdataErr <= rErr;
    m.rdataLast <= rLast;
    m.rdataExOkay <= rEx;

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

import 'dart:math';

import 'package:rohd/rohd.dart';

import '../port/memory_waist.dart';
import '../port/reg_fifo.dart';
import '../port/register_waist.dart';
import 'wishbone_interface.dart';

/// The Wishbone configuration of a memory port for [config]: classic cycles
/// and registered feedback bursts, with ERR, CTI and BTE.
WishboneConfig harborWishboneMemoryConfig(HarborMemoryWaistConfig config) =>
    WishboneConfig(
      addressWidth: config.addressWidth,
      dataWidth: config.dataWidth,
      useErr: true,
      useCti: true,
      useBte: true,
    );

void _checkMatch(WishboneInterface wb, HarborMemoryWaistConfig config) {
  final w = wb.config;
  if (w.addressWidth != config.addressWidth ||
      w.dataWidth != config.dataWidth ||
      w.effectiveSelWidth != config.strbWidth ||
      !w.useErr ||
      !w.useCti ||
      !w.useBte) {
    throw ArgumentError(
      'Wishbone config $w must match $config and have ERR, CTI and BTE',
    );
  }
  if (w.useRty) {
    // RTY has no waist equivalent and is left undriven, so it must stay
    // off.
    throw ArgumentError.value(w.useRty, 'useRty', 'must be false');
  }
  if (w.tgaWidth != 0) {
    throw ArgumentError.value(w.tgaWidth, 'tgaWidth', 'must be 0');
  }
  if (w.tgdWidth != 0) {
    // TGD_MISO is never driven, so a slave port cannot carry it.
    throw ArgumentError.value(w.tgdWidth, 'tgdWidth', 'must be 0');
  }
}

int _log2(int v) => v.bitLength - 1;

/// Stops the simulation when [bad] is high on a [clk] edge out of reset.
/// The generated RTL does not use [bad].
void _checkInSim(Logic clk, Logic reset, Logic bad, String what) {
  clk.glitch.listen((args) {
    if (LogicValue.isPosedge(
          args.previousValue,
          args.newValue,
          ignoreInvalid: true,
        ) &&
        reset.value == LogicValue.zero &&
        bad.value == LogicValue.one) {
      Simulator.throwException(
        Exception('wishbone memory master: $what'),
        StackTrace.current,
      );
    }
  });
}

Logic _counter(String name, int max) => Logic(name: name, width: max.bitLength);

/// Wishbone CTI codes.
const _ctiClassic = 0;
const _ctiIncr = 2;
const _ctiEnd = 7;

/// A Wishbone slave with registered feedback bursts in front of a memory
/// slave waist. One request is in flight at a time.
///
/// - A classic cycle (or a burst type it does not know) becomes a one beat
///   request. An incrementing linear burst (CTI 010, BTE 00) becomes one
///   request that runs to the end of its aligned block of [burstBeats]
///   beats. A longer burst becomes one request per block.
/// - A burst that ends before the block does (CTI 111, a dropped CYC, or a
///   beat at another address or direction) still finishes the request on
///   the waist: the port sends the rest of the write beats with all strobes
///   low, or drops the rest of the read beats. The device must have no read
///   side effects, and a write beat with every strobe low must not cause an
///   error either: the response for a short burst can cover pad beats the
///   master never named.
/// - Read beats end with ACK, or ERR when the beat has err.
/// - A write beat ends with ACK as soon as the port takes its data. The last
///   beat of a request, and the beat with CTI 111, wait for the write
///   response and end with ACK or ERR.
class HarborWishboneMemorySlave extends Module {
  /// Beats in the aligned block a burst request covers.
  final int burstBeats;

  HarborWishboneMemorySlave({
    required Logic clk,
    required Logic reset,
    required WishboneInterface wb,
    required HarborMemoryWaist waist,
    this.burstBeats = 8,
    super.name = 'wishbone_memory_slave',
  }) : super(
         definitionName:
             'HarborWishboneMemorySlave_a${waist.config.addressWidth}'
             '_d${waist.config.dataWidth}_i${waist.config.idWidth}'
             '_n${waist.config.outstanding}_b$burstBeats',
       ) {
    if (burstBeats < 1 ||
        burstBeats > 256 ||
        burstBeats & (burstBeats - 1) != 0) {
      throw ArgumentError.value(
        burstBeats,
        'burstBeats',
        'must be a power of two from 1 to 256',
      );
    }
    final config = waist.config;
    _checkMatch(wb, config);
    final c = addInput('clk', clk);
    final r = addInput('reset', reset);
    final b = wb.clone()
      ..pairConnectIO(this, wb, PairRole.consumer, uniquify: (n) => 'wb_$n');
    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.provider, uniquify: (n) => 'm_$n');

    final idW = config.idWidth;
    final addrW = config.addressWidth;
    final dataW = config.dataWidth;
    final strbW = config.strbWidth;
    final beatLog2 = _log2(strbW);
    final blockLog2 = _log2(burstBeats);
    const lenW = HarborMemoryWaistConfig.lenWidth;
    const sizeW = HarborMemoryWaistConfig.sizeWidth;
    const burstW = HarborMemoryWaistConfig.burstWidth;
    const leftW = lenW + 1;

    final wordAddr = harborWordAddress(b.adr, dataW).named('word_addr');
    final cycle = (b.cyc & b.stb).named('cycle');
    final isBurst = (b.cti!.eq(Const(_ctiIncr, width: 3)) & b.bte!.eq(0)).named(
      'is_burst',
    );
    final beatFinal = b.cti!.neq(Const(_ctiIncr, width: 3)).named('beat_final');

    // Beats from this address to the end of its block, minus one.
    Logic blockLen() {
      if (blockLog2 == 0) return Const(0, width: lenW);
      final hi = beatLog2 + blockLog2;
      final idx = addrW >= hi
          ? wordAddr.getRange(beatLog2, hi)
          : wordAddr.zeroExtend(hi).getRange(beatLog2, hi);
      return (Const(burstBeats - 1, width: blockLog2) - idx).zeroExtend(lenW);
    }

    final busy = Logic(name: 'busy');
    final write = Logic(name: 'write');
    final reqPend = Logic(name: 'req_pend');
    final qAddr = Logic(name: 'q_addr', width: addrW);
    final qLen = Logic(name: 'q_len', width: lenW);
    final left = Logic(name: 'left', width: leftW);
    final ended = Logic(name: 'ended');
    final hold = Logic(name: 'hold');
    final gotB = Logic(name: 'got_b');
    final bErr = Logic(name: 'b_err');
    final expAddr = Logic(name: 'exp_addr', width: addrW);
    final wGo = Logic(name: 'w_go');

    final start = (~busy & cycle).named('start');
    final startLen = mux(isBurst, blockLen(), Const(0, width: lenW));
    final match = (cycle & b.we.eq(write) & wordAddr.eq(expAddr)).named(
      'match',
    );
    final leftAny = left.neq(0);
    final chunkLast = left.eq(1);

    m.reqValid <= reqPend;
    m.reqId <= Const(0, width: idW);
    m.reqWrite <= write;
    m.reqAddr <= qAddr;
    m.reqLen <= qLen;
    m.reqSize <= Const(beatLog2, width: sizeW);
    m.reqBurst <= Const(HarborMemoryBurst.incr.value, width: burstW);
    m.reqExclusive <= Const(0);
    final reqFire = m.reqValid & m.reqReady;

    // Write beats, then pad beats with no strobes once the master is done.
    final wBeat = (busy & write & ~ended & ~hold & leftAny & match).named(
      'w_beat',
    );
    final pad = (busy & write & ended & leftAny).named('w_pad');
    final wF = HarborRegFifo(
      name: 'w',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: wBeat | pad,
      pushData: harborPack([
        mux(pad, Const(0, width: dataW), b.datMosi),
        mux(pad, Const(0, width: strbW), b.sel),
        chunkLast,
      ]),
      popReady: m.wdataReady & wGo,
    );
    final [wData, wStrb, wLast] = harborUnpack(wF.popData, [dataW, strbW, 1]);
    m.wdataValid <= wF.popValid & wGo;
    m.wdataData <= wData;
    m.wdataStrb <= wStrb;
    m.wdataLast <= wLast;
    final wLastFire = m.wdataValid & m.wdataReady & wLast;
    final wTaken = (wBeat & wF.pushReady).named('w_taken');
    final wPadTaken = pad & wF.pushReady;
    final wHolds = beatFinal | chunkLast;
    final ackW = wTaken & ~wHolds;

    m.wrespReady <= Const(1);
    final wrFire = m.wrespValid;
    final answer = (busy & write & gotB & hold & cycle).named('w_answer');
    final wDone = (busy & write & gotB & (~hold | answer)).named('w_done');

    // Read beats. Once the master is done the rest are dropped.
    // The entries reset, since DAT_MISO comes straight from them and a
    // master can sample it with any ACK.
    final rPop = Logic(name: 'r_pop');
    final rF = HarborRegFifo(
      name: 'r',
      clk: c,
      reset: r,
      depth: 2,
      pushValid: m.rdataValid,
      pushData: harborPack([m.rdataData, m.rdataErr]),
      popReady: rPop,
      resetEntries: true,
    );
    m.rdataReady <= rF.pushReady;
    final [rData, rErr] = harborUnpack(rF.popData, [dataW, 1]);
    final rBeat = (busy & ~write & ~ended & match & rF.popValid).named(
      'r_beat',
    );
    rPop <= rBeat | (busy & ~write & ended & rF.popValid);
    final rFire = rF.popValid & rPop;
    final rDone = rFire & chunkLast;

    b.ack <= ackW | (rBeat & ~rErr) | (answer & ~bErr);
    b.err! <= (rBeat & rErr) | (answer & bErr);
    b.datMiso <= rData;
    if (b.rty != null) b.rty! <= Const(0);

    // The master leaves the request: CYC drops, or a beat does not follow.
    final endNow =
        (busy & ~ended & ~hold & leftAny & (~b.cyc | (cycle & ~match))).named(
          'end_now',
        );
    final bytes = Const(1 << beatLog2, width: addrW);

    Sequential(c, reset: r, [
      If.block([
        Iff(start, [
          busy < Const(1),
          write < b.we,
          reqPend < Const(1),
          qAddr < wordAddr,
          qLen < startLen,
          left < startLen.zeroExtend(leftW) + 1,
          ended < Const(0),
          hold < Const(0),
          gotB < Const(0),
          expAddr < wordAddr,
        ]),
        ElseIf(wDone | rDone, [busy < Const(0)]),
        Else([
          If(endNow, then: [ended < Const(1)]),
          If(hold & ~b.cyc, then: [hold < Const(0)]),
          If(
            wTaken,
            then: [
              left < left - 1,
              expAddr < expAddr + bytes,
              If(wHolds, then: [hold < Const(1)]),
              If(beatFinal & ~chunkLast, then: [ended < Const(1)]),
            ],
          ),
          If(wPadTaken, then: [left < left - 1]),
          If(
            rFire,
            then: [
              left < left - 1,
              expAddr < expAddr + bytes,
              If(rBeat & beatFinal & ~chunkLast, then: [ended < Const(1)]),
            ],
          ),
          If(wrFire, then: [gotB < Const(1), bErr < m.wrespErr]),
        ]),
      ]),
      If(reqFire, then: [reqPend < Const(0)]),
      If.block([
        Iff(reqFire & write, [wGo < Const(1)]),
        ElseIf(wLastFire, [wGo < Const(0)]),
      ]),
    ]);
  }
}

/// A Wishbone master behind a memory master waist. One request runs on the
/// bus at a time.
///
/// - Up to `outstanding` waist requests wait in a FIFO and go out in order.
///   CYC stays high for a whole request and drops for at least one cycle
///   between requests. A write does not raise CYC until its first data
///   beat has arrived, so the bus is not held waiting for data.
/// - An INCR request of full bus beats with more than one beat is a
///   registered feedback burst: CTI 010 on each beat and 111 on the last,
///   BTE 00. Every other request is a run of classic cycles, CTI 000, one
///   per beat.
/// - ERR fails the beat and ends the cycle. The port then answers the rest
///   of the request itself with err set: read beats of zero, and write data
///   taken and dropped.
/// - Responses carry the waist ID of their request.
///
/// The port has no exclusive access. A request with REQ_EXCLUSIVE runs as a
/// plain access and gets RDATA_EXOKAY and WRESP_EXOKAY 0. So an exclusive
/// write changes memory: a device must check EXOKAY of the exclusive read
/// first.
class HarborWishboneMemoryMaster extends Module {
  HarborWishboneMemoryMaster({
    required Logic clk,
    required Logic reset,
    required HarborMemoryWaist waist,
    required WishboneInterface wb,
    super.name = 'wishbone_memory_master',
  }) : super(
         definitionName:
             'HarborWishboneMemoryMaster_a${waist.config.addressWidth}'
             '_d${waist.config.dataWidth}_i${waist.config.idWidth}'
             '_n${waist.config.outstanding}',
       ) {
    final config = waist.config;
    _checkMatch(wb, config);
    final c = addInput('clk', clk);
    final r = addInput('reset', reset);
    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.consumer, uniquify: (n) => 'm_$n');
    final b = wb.clone()
      ..pairConnectIO(this, wb, PairRole.provider, uniquify: (n) => 'wb_$n');

    if (config.outstanding == 1) {
      _buildWishboneMemoryMasterFast(c, r, m, b, config);
    } else {
      _buildWishboneMemoryMasterQueued(c, r, m, b, config);
    }
  }
}

/// One request on the bus at a time, driven straight from the waist: no
/// request queue, no registered start and no forced gap between requests.
/// Used only when [HarborMemoryWaistConfig.outstanding] is 1.
///
/// REQ_READY comes only from the `busy` register, never from WDATA_VALID,
/// RDATA_VALID or WRESP_VALID, so a device cannot close a combinational
/// loop through this port no matter how it times its own REQ_VALID: the
/// only way back from a response to a new request already crosses the
/// `busy` register.
///
/// A write holds CYC/STB low on its first beat until WDATA_VALID arrives
/// (REQ_READY still fires on REQ_VALID alone). Once a beat's CYC/STB goes
/// up it never retracts before ACK/ERR: `beatActive` freezes it, so a
/// device that lets RDATA_READY or WRESP_READY drop after its REQ never
/// pulls a live Wishbone beat back down. RDATA and WRESP leave the same
/// cycle as ACK/ERR when the device is ready that cycle. Otherwise the
/// result waits in the single `pend` register, and the next beat waits for
/// that register to drain. A device must keep RDATA_READY and WRESP_READY
/// low in a cycle where it does not take a response. So each READY is high
/// only while a request of its direction is in flight or taken in that
/// cycle. A simulation stops when a device breaks this rule. A registered
/// feedback burst (CTI 010/111) runs back to back
/// with CYC held for the whole burst whenever the device keeps up; the
/// only registers between the bus and the waist are this per-beat state
/// (address, beat count, the error latched from an earlier beat, and the
/// one-deep pend).
void _buildWishboneMemoryMasterFast(
  Logic c,
  Logic r,
  HarborMemoryWaist m,
  WishboneInterface b,
  HarborMemoryWaistConfig config,
) {
  final idW = config.idWidth;
  final addrW = config.addressWidth;
  final dataW = config.dataWidth;
  final strbW = config.strbWidth;
  final beatLog2 = _log2(strbW);
  const lenW = HarborMemoryWaistConfig.lenWidth;
  const sizeW = HarborMemoryWaistConfig.sizeWidth;
  const burstW = HarborMemoryWaistConfig.burstWidth;
  const beatW = lenW + 1;

  final busy = Logic(name: 'busy');
  final beatActive = Logic(name: 'beat_active');
  // High from the first beat's start until the last beat resolves, so CYC
  // stays up for the whole request (registered feedback bursts included)
  // through any inter-beat stall. STB alone drops for a stall.
  final cycHeld = Logic(name: 'cyc_held');
  final abort = Logic(name: 'abort');
  final cId = Logic(name: 'c_id', width: idW);
  final cWrite = Logic(name: 'c_write');
  final cAddr = Logic(name: 'c_addr', width: addrW);
  final cLen = Logic(name: 'c_len', width: lenW);
  final cSize = Logic(name: 'c_size', width: sizeW);
  final cBurst = Logic(name: 'c_burst', width: burstW);
  final cBurstMode = Logic(name: 'c_burst_mode');
  final cBeat = Logic(name: 'c_beat', width: beatW);
  final cErr = Logic(name: 'c_err');
  final pendValid = Logic(name: 'pend_valid');
  final pendData = Logic(name: 'pend_data', width: dataW);
  final pendErr = Logic(name: 'pend_err');
  final pendLast = Logic(name: 'pend_last');

  m.reqReady <= ~busy;
  final reqFire = (m.reqValid & ~busy).named('req_fire');

  final last = cBeat.eq(cLen.zeroExtend(beatW)).named('last');
  final pieceSize = mux(
    cSize.gt(Const(beatLog2, width: sizeW)),
    Const(beatLog2, width: sizeW),
    cSize,
  );
  final lane = harborLaneMask(cAddr, pieceSize, strbW);

  // A free slot (no beat on the bus, no held result) may start the next
  // beat once its data is there; a read beat has none to wait for. This
  // is checked only once, before the beat starts: it never gates a beat
  // that is already on the bus.
  final canAdvance = (busy & ~beatActive & ~pendValid).named('can_advance');
  final writeDataReady = mux(cWrite, m.wdataValid, Const(1));
  final startBus = (canAdvance & ~abort & writeDataReady).named('start_bus');
  final fakeResolve = (canAdvance & abort & writeDataReady).named(
    'fake_resolve',
  );

  // An error drops the bus straight away; the rest of the request then
  // resolves on the waist only, through fakeResolve below.
  b.cyc <= (cycHeld | startBus) & ~abort;
  b.stb <= beatActive | startBus;
  b.we <= cWrite;
  b.adr <= harborWordAddress(cAddr, dataW);
  b.datMosi <= m.wdataData;
  b.sel <= mux(cWrite, m.wdataStrb & lane, lane);
  b.cti! <=
      mux(
        cBurstMode,
        mux(last, Const(_ctiEnd, width: 3), Const(_ctiIncr, width: 3)),
        Const(_ctiClassic, width: 3),
      );
  b.bte! <= Const(0, width: 2);
  if (b.tga != null) b.tga! <= Const(0, width: b.tga!.width);
  if (b.tgdMosi != null) b.tgdMosi! <= Const(0, width: b.tgdMosi!.width);

  final busEnd = ((beatActive | startBus) & (b.ack | b.err!)).named('bus_end');
  final resolve = (busEnd | fakeResolve).named('resolve');
  // Every beat of a read has a result; a write only has one on its last
  // beat.
  final hasResponse = (~cWrite | last).named('has_response');
  final resultErr = mux(abort, Const(1), b.err!);
  final resultData = mux(abort, Const(0, width: dataW), b.datMiso);
  // A fresh result is offered the same cycle it resolves. RDATA_VALID and
  // WRESP_VALID never read the ready signals, so a device's ready cannot
  // close a combinational loop through this port.
  final freshResult = (resolve & hasResponse).named('fresh_result');
  final readyNow = mux(cWrite, m.wrespReady, m.rdataReady);
  final pendTaken = (pendValid & readyNow).named('pend_taken');
  final finalDelivered =
      ((freshResult & last & readyNow) | (pendTaken & pendLast)).named(
        'final_delivered',
      );

  m.wdataReady <= cWrite & resolve;
  m.rdataValid <= (~cWrite & freshResult) | (pendValid & ~cWrite);
  m.rdataId <= cId;
  m.rdataData <= mux(pendValid, pendData, resultData);
  m.rdataErr <= mux(pendValid, pendErr, resultErr);
  m.rdataLast <= mux(pendValid, pendLast, last);
  m.wrespValid <= (cWrite & freshResult) | (pendValid & cWrite);
  m.wrespId <= cId;
  m.wrespErr <= mux(pendValid, pendErr, resultErr);
  m.rdataExOkay <= Const(0);
  m.wrespExOkay <= Const(0);

  // Next beat address, same rule as the queued path below.
  final ww = max(addrW, 16);
  final cur = cAddr.zeroExtend(ww);
  final bytes = Const(1, width: ww) << pieceSize;
  final alignedCur = cur & ~(bytes - 1);
  final wrapMask = ((cLen.zeroExtend(ww) + 1) << pieceSize) - 1;
  final nextAddr = mux(
    cBurst.eq(Const(HarborMemoryBurst.fixed.value, width: burstW)),
    cur,
    mux(
      cBurst.eq(Const(HarborMemoryBurst.wrap.value, width: burstW)),
      (cur & ~wrapMask) | ((alignedCur + bytes) & wrapMask),
      alignedCur + bytes,
    ),
  ).getRange(0, addrW);

  final readyBad =
      ((m.wrespReady & ~((busy & cWrite) | (reqFire & m.reqWrite))) |
              (m.rdataReady & ~((busy & ~cWrite) | (reqFire & ~m.reqWrite))))
          .named('ready_bad');
  _checkInSim(
    c,
    r,
    readyBad,
    'RDATA_READY or WRESP_READY is high with no response to take',
  );

  Sequential(c, reset: r, [
    If.block([
      Iff(~busy, [
        If(
          reqFire,
          then: [
            busy < Const(1),
            beatActive < Const(0),
            cycHeld < Const(0),
            pendValid < Const(0),
            abort < Const(0),
            cId < m.reqId,
            cWrite < m.reqWrite,
            cAddr < m.reqAddr,
            cLen < m.reqLen,
            cSize < m.reqSize,
            cBurst < m.reqBurst,
            cBurstMode <
                m.reqBurst.eq(
                      Const(HarborMemoryBurst.incr.value, width: burstW),
                    ) &
                    m.reqSize.eq(Const(beatLog2, width: sizeW)) &
                    m.reqLen.neq(0),
            cBeat < Const(0, width: beatW),
            cErr < Const(0),
          ],
        ),
      ]),
      Else([
        beatActive < (startBus | beatActive) & ~busEnd,
        cycHeld < (startBus | cycHeld) & ~(resolve & last),
        If.block([
          Iff(freshResult & ~readyNow, [
            pendValid < Const(1),
            pendData < resultData,
            pendErr < resultErr,
            pendLast < last,
          ]),
          ElseIf(pendTaken, [pendValid < Const(0)]),
        ]),
        If(
          resolve,
          then: [
            cBeat < cBeat + 1,
            cAddr < nextAddr,
            cErr < cErr | (busEnd & b.err!),
            If(busEnd & b.err! & ~last, then: [abort < Const(1)]),
          ],
        ),
        If(finalDelivered, then: [busy < Const(0)]),
      ]),
    ]),
  ]);
}

/// Up to `outstanding` requests queued and issued one at a time, with a
/// registered start and a 1-cycle gap between requests. Used when
/// [HarborMemoryWaistConfig.outstanding] is more than 1.
void _buildWishboneMemoryMasterQueued(
  Logic c,
  Logic r,
  HarborMemoryWaist m,
  WishboneInterface b,
  HarborMemoryWaistConfig config,
) {
  final n = config.outstanding;
  final idW = config.idWidth;
  final addrW = config.addressWidth;
  final dataW = config.dataWidth;
  final strbW = config.strbWidth;
  final beatLog2 = _log2(strbW);
  const lenW = HarborMemoryWaistConfig.lenWidth;
  const sizeW = HarborMemoryWaistConfig.sizeWidth;
  const burstW = HarborMemoryWaistConfig.burstWidth;
  const beatW = lenW + 1;

  final inflight = _counter('inflight', n);
  final room = inflight.lt(Const(n, width: inflight.width));
  final start = Logic(name: 'start');
  final reqF = HarborRegFifo(
    name: 'req',
    clk: c,
    reset: r,
    depth: n,
    pushValid: m.reqValid & room,
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
  m.reqReady <= room & reqF.pushReady;
  final reqFire = m.reqValid & m.reqReady;
  final [hId, hWrite, hAddr, hLen, hSize, hBurst] = harborUnpack(reqF.popData, [
    idW,
    1,
    addrW,
    lenW,
    sizeW,
    burstW,
  ]);

  final beatDone = Logic(name: 'beat_done');
  // The entries reset, since DAT_MOSI comes straight from them and shows
  // on every beat.
  final wPop = Logic(name: 'w_pop');
  final wF = HarborRegFifo(
    name: 'w',
    clk: c,
    reset: r,
    depth: 2,
    pushValid: m.wdataValid,
    pushData: harborPack([m.wdataData, m.wdataStrb]),
    popReady: wPop,
    resetEntries: true,
  );
  m.wdataReady <= wF.pushReady;
  final [wData, wStrb] = harborUnpack(wF.popData, [dataW, strbW]);

  final act = Logic(name: 'act');
  final gap = Logic(name: 'gap');
  final abort = Logic(name: 'abort');
  final cId = Logic(name: 'c_id', width: idW);
  final cWrite = Logic(name: 'c_write');
  final cAddr = Logic(name: 'c_addr', width: addrW);
  final cLen = Logic(name: 'c_len', width: lenW);
  final cSize = Logic(name: 'c_size', width: sizeW);
  final cBurst = Logic(name: 'c_burst', width: burstW);
  final cBurstMode = Logic(name: 'c_burst_mode');
  final cBeat = Logic(name: 'c_beat', width: beatW);
  final cErr = Logic(name: 'c_err');
  // A write does not raise CYC until its first data beat is in the
  // FIFO, so the bus is not held while this master waits for data.
  start <= ~act & ~gap & reqF.popValid & (~hWrite | wF.popValid);

  final last = cBeat.eq(cLen.zeroExtend(beatW)).named('last');
  final rStore = Logic(name: 'r_store');
  final bStore = Logic(name: 'b_store');
  final rF = HarborRegFifo(
    name: 'r',
    clk: c,
    reset: r,
    depth: 2,
    pushValid: rStore,
    pushData: harborPack([
      cId,
      mux(abort, Const(0, width: dataW), b.datMiso),
      abort | b.err!,
      last,
    ]),
    popReady: m.rdataReady,
  );
  final bF = HarborRegFifo(
    name: 'b',
    clk: c,
    reset: r,
    depth: 2,
    pushValid: bStore,
    pushData: harborPack([cId, cErr | abort | b.err!]),
    popReady: m.wrespReady,
  );

  // A beat can run once its data is here and its response has room.
  final beatReady = mux(
    cWrite,
    wF.popValid & (~last | bF.pushReady),
    rF.pushReady,
  );
  final pieceSize = mux(
    cSize.gt(Const(beatLog2, width: sizeW)),
    Const(beatLog2, width: sizeW),
    cSize,
  );
  final lane = harborLaneMask(cAddr, pieceSize, strbW);
  b.cyc <= act & ~abort;
  b.stb <= act & ~abort & beatReady;
  b.we <= cWrite;
  b.adr <= harborWordAddress(cAddr, dataW);
  b.datMosi <= wData;
  b.sel <= mux(cWrite, wStrb & lane, lane);
  b.cti! <=
      mux(
        cBurstMode,
        mux(last, Const(_ctiEnd, width: 3), Const(_ctiIncr, width: 3)),
        Const(_ctiClassic, width: 3),
      );
  b.bte! <= Const(0, width: 2);
  if (b.tga != null) b.tga! <= Const(0, width: b.tga!.width);
  if (b.tgdMosi != null) b.tgdMosi! <= Const(0, width: b.tgdMosi!.width);

  final busEnd = b.stb & (b.ack | b.err!);
  final localEnd = act & abort & beatReady;
  beatDone <= busEnd | localEnd;
  rStore <= beatDone & ~cWrite;
  bStore <= beatDone & cWrite & last;
  wPop <= beatDone & cWrite;

  // Next beat address.
  final ww = max(addrW, 16);
  final cur = cAddr.zeroExtend(ww);
  final bytes = Const(1, width: ww) << pieceSize;
  final alignedCur = cur & ~(bytes - 1);
  final wrapMask = ((cLen.zeroExtend(ww) + 1) << pieceSize) - 1;
  final nextAddr = mux(
    cBurst.eq(Const(HarborMemoryBurst.fixed.value, width: burstW)),
    cur,
    mux(
      cBurst.eq(Const(HarborMemoryBurst.wrap.value, width: burstW)),
      (cur & ~wrapMask) | ((alignedCur + bytes) & wrapMask),
      alignedCur + bytes,
    ),
  ).getRange(0, addrW);

  final rdDone = m.rdataValid & m.rdataReady & m.rdataLast;
  final wrDone = m.wrespValid & m.wrespReady;
  final [rId, rDat, rErr, rLast] = harborUnpack(rF.popData, [idW, dataW, 1, 1]);
  m.rdataValid <= rF.popValid;
  m.rdataId <= rId;
  m.rdataData <= rDat;
  m.rdataErr <= rErr;
  m.rdataLast <= rLast;
  final [bId, bErr] = harborUnpack(bF.popData, [idW, 1]);
  m.wrespValid <= bF.popValid;
  m.wrespId <= bId;
  m.wrespErr <= bErr;
  m.rdataExOkay <= Const(0);
  m.wrespExOkay <= Const(0);

  Sequential(c, reset: r, [
    gap < Const(0),
    If.block([
      Iff(start, [
        act < Const(1),
        abort < Const(0),
        cId < hId,
        cWrite < hWrite,
        cAddr < hAddr,
        cLen < hLen,
        cSize < hSize,
        cBurst < hBurst,
        cBurstMode <
            hBurst.eq(Const(HarborMemoryBurst.incr.value, width: burstW)) &
                hSize.eq(Const(beatLog2, width: sizeW)) &
                hLen.neq(0),
        cBeat < Const(0, width: beatW),
        cErr < Const(0),
      ]),
      ElseIf(beatDone, [
        cBeat < cBeat + 1,
        cAddr < nextAddr,
        cErr < cErr | (busEnd & b.err!),
        If(busEnd & b.err! & ~last, then: [abort < Const(1)]),
        If(last, then: [act < Const(0), gap < Const(1)]),
      ]),
    ]),
    inflight <
        inflight +
            reqFire.zeroExtend(inflight.width) -
            rdDone.zeroExtend(inflight.width) -
            wrDone.zeroExtend(inflight.width),
  ]);
}

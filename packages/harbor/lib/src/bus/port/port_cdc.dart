import 'package:rohd/rohd.dart';

import '../../clock/cdc.dart';
import 'memory_waist.dart';
import 'reg_fifo.dart';

/// The clock and reset of the fabric side of a port.
///
/// A port factory that gets one whose clock is not the device clock puts a
/// clock domain crossing between the native port and the device.
class HarborFabricClock {
  final Logic clk;
  final Logic reset;

  const HarborFabricClock({required this.clk, required this.reset});

  /// True when a device on [deviceClk] needs a crossing to this clock.
  bool crossesFrom(Logic deviceClk) => !identical(clk, deviceClk);
}

/// The default depth of a memory waist crossing: [outstanding] plus 2,
/// rounded up to a power of two.
int harborCdcDepth(int outstanding) {
  var d = 2;
  while (d < outstanding + 2) {
    d <<= 1;
  }
  return d;
}

/// Crosses a memory waist between the fabric clock and the device clock.
///
/// REQ, WDATA, RDATA and WRESP each go through a [HarborCdcFifo]. The IDs,
/// lengths, LAST, REQ_EXCLUSIVE and EXOKAY pass unchanged, so the order
/// rules and the exclusive results of the waist hold on both sides. The
/// device side gets write data only after its REQ is taken.
///
/// Either reset resets both halves of every FIFO through [harborCdcJoinReset].
/// Device logic must reset on `device_reset`. The fabric side keeps its own
/// record of the requests in flight and resets only on the fabric reset:
///
/// - With [slave] set, the fabric is the requester. After a device reset, each
///   read in flight gets its remaining beats with ERR and data 0, each write
///   gets WRESP with ERR, and its write data is taken and dropped. These
///   responses have EXOKAY 0.
/// - Else the fabric is the responder. After a device reset, each write in
///   flight gets its remaining beats with all strobes low, and every
///   response in flight is dropped.
///
/// No new request crosses until this is done.
///
/// With [deviceResetCopy], each FIFO device half and the device side logic
/// of its channel reset on their own copy of `device_reset`, so no single
/// reset net spans the die. A copy is two flops after `device_reset`, so it
/// releases two cycles later, and it sets at once when either reset input
/// asserts. Only the first flop of each copy loads `device_reset`.
///
/// The `debug_*` outputs are for a status register or LEDs. They are not
/// synchronized to one clock.
class HarborMemoryWaistCdc extends Module {
  /// Entries in each FIFO.
  final int depth;

  /// The device side reset joined with the fabric reset.
  Logic get deviceReset => output('device_reset');

  /// Reads in flight on the fabric side, on the fabric clock.
  Logic get debugReads => output('debug_reads');

  /// Writes in flight on the fabric side, on the fabric clock.
  Logic get debugWrites => output('debug_writes');

  /// The fabric side answers or drops the requests from before a device
  /// reset, on the fabric clock.
  Logic get debugRecover => output('debug_recover');

  /// Empty flag of each FIFO on its read side: [0] REQ, [1] WDATA, [2]
  /// RDATA, [3] WRESP.
  Logic get debugEmpty => output('debug_empty');

  /// Full flag of each FIFO on its write side, in the order of [debugEmpty].
  Logic get debugFull => output('debug_full');

  HarborMemoryWaistCdc({
    required Logic fabricClk,
    required Logic fabricReset,
    required Logic deviceClk,
    required Logic deviceReset,
    required HarborMemoryWaist fabric,
    required HarborMemoryWaist device,
    required bool slave,
    int? depth,
    HarborResetCopy? deviceResetCopy,
    super.name = 'memory_waist_cdc',
  }) : depth = depth ?? harborCdcDepth(fabric.config.outstanding),
       super(
         definitionName:
             'HarborMemoryWaistCdc${slave ? 'Slave' : 'Master'}'
             '_a${fabric.config.addressWidth}_d${fabric.config.dataWidth}'
             '_i${fabric.config.idWidth}_n${fabric.config.outstanding}'
             '_q${depth ?? harborCdcDepth(fabric.config.outstanding)}'
             '${deviceResetCopy == null ? '' : '_r'}',
       ) {
    final config = fabric.config;
    if (device.config.addressWidth != config.addressWidth ||
        device.config.dataWidth != config.dataWidth ||
        device.config.idWidth != config.idWidth ||
        device.config.outstanding != config.outstanding) {
      throw ArgumentError('fabric $config and device ${device.config} differ');
    }
    if (this.depth < 2 || this.depth & (this.depth - 1) != 0) {
      throw ArgumentError.value(
        this.depth,
        'depth',
        'must be a power of two >= 2',
      );
    }
    final fClk = addInput('fabric_clk', fabricClk);
    final fReset = addInput('fabric_reset', fabricReset);
    final dClk = addInput('device_clk', deviceClk);
    final dReset = addInput('device_reset_in', deviceReset);
    final f = fabric.clone()
      ..pairConnectIO(
        this,
        fabric,
        slave ? PairRole.consumer : PairRole.provider,
        uniquify: (n) => 'f_$n',
      );
    final d = device.clone()
      ..pairConnectIO(
        this,
        device,
        slave ? PairRole.provider : PairRole.consumer,
        uniquify: (n) => 'd_$n',
      );

    final fJoin = harborCdcJoinReset(
      fClk,
      fReset,
      dReset,
      name: 'fabric_join_reset',
    );
    final dJoin = harborCdcJoinReset(
      dClk,
      dReset,
      fReset,
      name: 'device_join_reset',
    );
    addOutput('device_reset') <= dJoin;
    final dSet = deviceResetCopy == null
        ? null
        : (dReset | fReset).named('device_join_reset_set');
    // With copies, `early` is the next value of the channel copy.
    ({Logic early, Logic reset}) dCopy(String n) {
      if (deviceResetCopy == null) return (early: dJoin, reset: dJoin);
      final early = deviceResetCopy(
        dClk,
        dJoin,
        dSet!,
        '${n}_device_reset_early',
      );
      return (
        early: early,
        reset: deviceResetCopy(dClk, early, dSet, '${n}_device_reset'),
      );
    }

    final (early: dReqEarly, reset: dReq) = dCopy('req');
    final (early: dWdEarly, reset: dWd) = dCopy('wdata');
    final (early: dRdEarly, reset: dRd) = dCopy('rdata');
    final (early: dWrEarly, reset: dWr) = dCopy('wresp');
    // The fabric side record resets only on fReset, so it must see the
    // device reset on clock edges only.
    final fJoinSync = harborCdcSyncReset(
      fClk,
      fReset,
      fJoin,
      name: 'fabric_join_sync',
    );

    final up = slave ? f : d;
    final dn = slave ? d : f;

    final idW = config.idWidth;
    final dataW = config.dataWidth;
    const lenW = HarborMemoryWaistConfig.lenWidth;
    final reqWidths = [
      idW,
      1,
      config.addressWidth,
      lenW,
      HarborMemoryWaistConfig.sizeWidth,
      HarborMemoryWaistConfig.burstWidth,
      1,
    ];
    final wdWidths = [dataW, config.strbWidth, 1];
    final rdWidths = [idW, dataW, 1, 1, 1];
    final wrWidths = [idW, 1, 1];

    // A FIFO writes on the fabric side when the fabric sends that way.
    _Fifo fifo(String name, List<int> widths, bool down, Logic dRst) {
      final fabricWrites = down == slave;
      // With reset copies, the device side of a slave gives an enable only
      // when the FIFO can take it.
      final checked = deviceResetCopy != null && slave;
      return _Fifo(
        name,
        widths.reduce((a, b) => a + b),
        this.depth,
        fabricWrites ? fClk : dClk,
        fabricWrites ? fJoin : dRst,
        fabricWrites ? dClk : fClk,
        fabricWrites ? dRst : fJoin,
        trustWrite: checked && !down,
        trustRead: checked && down,
      );
    }

    final reqF = fifo('req_fifo', reqWidths, true, dReq);
    final wdF = fifo('wdata_fifo', wdWidths, true, dWd);
    final rdF = fifo('rdata_fifo', rdWidths, false, dRd);
    final wrF = fifo('wresp_fifo', wrWidths, false, dWr);

    final n = config.outstanding;
    final cntW = n.bitLength;
    Logic nonZero(Logic c) => ~c.eq(Const(0, width: c.width));
    final fifos = [reqF, wdF, rdF, wrF];
    addOutput('debug_empty', width: 4) <=
        [for (final q in fifos.reversed) q.rdEmpty].swizzle();
    addOutput('debug_full', width: 4) <=
        [for (final q in fifos.reversed) q.wrFull].swizzle();

    if (slave) {
      // Fabric side: the requester. The queues hold what is in flight, so
      // a device reset can still answer every request.
      final poison = Logic(name: 'poison');
      final mode = (poison | fJoinSync).named('fabric_mode_poison');
      final reqFire = Logic(name: 'f_req_fire');
      final rdLastFire = Logic(name: 'f_rdata_last_fire');
      final wrFire = Logic(name: 'f_wresp_fire');
      final rdQ = HarborRegFifo(
        name: 'read_q',
        clk: fClk,
        reset: fReset,
        depth: n,
        pushValid: reqFire & ~up.reqWrite,
        pushData: harborPack([up.reqId, up.reqLen]),
        popReady: rdLastFire,
      );
      final wrQ = HarborRegFifo(
        name: 'write_q',
        clk: fClk,
        reset: fReset,
        depth: n,
        pushValid: reqFire & up.reqWrite,
        pushData: up.reqId,
        popReady: wrFire,
      );
      final wOwed = Logic(name: 'w_owed', width: cntW);
      final rBeat = Logic(name: 'r_beat', width: lenW);
      addOutput('debug_reads', width: cntW) <= rdQ.count;
      addOutput('debug_writes', width: cntW) <= wrQ.count;
      addOutput('debug_recover') <= mode;

      up.reqReady <= ~reqF.wrFull & ~mode & rdQ.pushReady & wrQ.pushReady;
      reqFire <= up.reqValid & up.reqReady;
      reqF.push(
        reqFire,
        harborPack([
          up.reqId,
          up.reqWrite,
          up.reqAddr,
          up.reqLen,
          up.reqSize,
          up.reqBurst,
          up.reqExclusive,
        ]),
      );

      // Write data of a poisoned write is taken and dropped.
      up.wdataReady <= mux(mode, nonZero(wOwed), ~wdF.wrFull);
      final wdLastIn = up.wdataValid & up.wdataReady & up.wdataLast;
      wdF.push(
        up.wdataValid & ~mode,
        harborPack([up.wdataData, up.wdataStrb, up.wdataLast]),
      );

      final [qId, qLen] = harborUnpack(rdQ.popData, [idW, lenW]);
      final [rId, rData, rErr, rLast, rEx] = harborUnpack(rdF.rdData, rdWidths);
      up.rdataValid <= mux(mode, rdQ.popValid, ~rdF.rdEmpty);
      up.rdataId <= mux(mode, qId, rId);
      up.rdataData <= rData & (~mode).replicate(dataW);
      up.rdataErr <= mode | rErr;
      up.rdataLast <= mux(mode, rBeat.eq(qLen), rLast);
      up.rdataExOkay <= ~mode & rEx;
      rdF.pop(up.rdataReady & ~mode);
      final rdFire = up.rdataValid & up.rdataReady;
      rdLastFire <= rdFire & up.rdataLast;

      // A poisoned write gets WRESP only after all its data is taken. The
      // writes that owe data are the newest wOwed entries of wrQ.
      final wrDataDone = wrQ.count.gt(wOwed);
      final [bId, bErr, bEx] = harborUnpack(wrF.rdData, wrWidths);
      up.wrespValid <= mux(mode, wrDataDone, ~wrF.rdEmpty);
      up.wrespId <= mux(mode, wrQ.popData, bId);
      up.wrespErr <= mode | bErr;
      up.wrespExOkay <= ~mode & bEx;
      wrF.pop(up.wrespReady & ~mode);
      wrFire <= up.wrespValid & up.wrespReady;

      Sequential(fClk, reset: fReset, [
        If.block([
          Iff(rdLastFire, [rBeat < Const(0, width: lenW)]),
          ElseIf(rdFire, [rBeat < rBeat + 1]),
        ]),
        If.block([
          Iff(reqFire & up.reqWrite & ~wdLastIn, [wOwed < wOwed + 1]),
          ElseIf(wdLastIn & ~(reqFire & up.reqWrite), [wOwed < wOwed - 1]),
        ]),
        If.block([
          Iff(fJoinSync, [poison < Const(1)]),
          ElseIf(~rdQ.popValid & ~wrQ.popValid & ~nonZero(wOwed), [
            poison < Const(0),
          ]),
        ]),
      ]);

      // Device side: the memory. Write data waits for its REQ.
      final wPend = Logic(name: 'd_w_pend', width: cntW);
      // A register copy of `d_w_pend != 0`.
      final wOpen = Logic(name: 'd_w_open');
      final open = wOpen & ~dWd;
      final [id, write, addr, len, size, burst, exclusive] = harborUnpack(
        reqF.rdData,
        reqWidths,
      );
      // With reset copies, the valid and ready outputs of the device side
      // are registers with the same value in each cycle, so the device can
      // sit far away. The early copy of the channel is the next value of
      // its copy.
      final copies = dSet != null;
      // Each also has a vendor copy, low when the FIFO can move, for the
      // FIFO enable. Synthesis does not merge it with the output, so the
      // device and the FIFO do not share one LUT.
      final can = <String, Logic>{};
      Logic out(String name, Logic now, Logic next, Logic early) {
        if (!copies) {
          can[name] = now;
          return now;
        }
        final r = Logic(name: name);
        Sequential(dClk, [r < next & ~early], reset: dSet, asyncReset: true);
        can[name] = ~deviceResetCopy!(dClk, ~next | early, dSet, '${name}_n');
        return r;
      }

      // The far handshake inputs only select between values made ahead.
      final rq = dn.reqReady;
      final wd = dn.wdataReady;
      Logic ahead(Logic Function(bool rq, bool wd) f) => mux(
        rq,
        mux(wd, f(true, true), f(true, false)),
        mux(wd, f(false, true), f(false, false)),
      );
      final reqTake = ~reqF.rdEmpty & ~dReq;
      final wdTake = ~wdF.rdEmpty & open;
      Logic reqEmptyNext(bool r) => r
          ? mux(reqTake, reqF.rdEmptyIfPop, reqF.rdEmptyIfHold)
          : reqF.rdEmptyIfHold;
      Logic wdEmptyNext(bool w) => w
          ? mux(wdTake, wdF.rdEmptyIfPop, wdF.rdEmptyIfHold)
          : wdF.rdEmptyIfHold;
      // These use the flags and not the valid registers, so synthesis does
      // not share one LUT with the device for both sides.
      Logic dReqW(bool r) => r ? reqTake & write : Const(0);
      final [wData, wStrb, wLast] = harborUnpack(wdF.rdData, wdWidths);
      Logic dLast(bool w) => w ? wdTake & wLast : Const(0);
      final up1 = wPend + 1;
      final dn1 = wPend - 1;
      Logic openNext(bool r, bool w) =>
          ~dWd &
          mux(
            dReqW(r),
            mux(dLast(w), nonZero(wPend), nonZero(up1)),
            mux(dLast(w), nonZero(dn1), nonZero(wPend)),
          );
      Logic pendNext(bool r, bool w) => mux(
        dWd,
        Const(0, width: cntW),
        mux(dReqW(r), mux(dLast(w), wPend, up1), mux(dLast(w), dn1, wPend)),
      );

      dn.reqValid <=
          out(
            'd_req_valid_r',
            reqTake,
            ahead((r, _) => ~reqEmptyNext(r)),
            dReqEarly,
          );
      dn.reqId <= id;
      dn.reqWrite <= write;
      dn.reqAddr <= addr;
      dn.reqLen <= len;
      dn.reqSize <= size;
      dn.reqBurst <= burst;
      dn.reqExclusive <= exclusive;
      reqF.pop(rq & can['d_req_valid_r']!);
      dn.wdataValid <=
          out(
            'd_wdata_valid_r',
            wdTake,
            ahead((r, w) => ~wdEmptyNext(w) & openNext(r, w)),
            dWdEarly,
          );
      dn.wdataData <= wData;
      dn.wdataStrb <= wStrb;
      dn.wdataLast <= wLast;
      wdF.pop(wd & can['d_wdata_valid_r']!);
      Sequential(dClk, [wOpen < ahead(openNext), wPend < ahead(pendNext)]);
      // Nothing crosses to or from a device side in reset.
      Logic fullNext(_Fifo f, Logic valid, Logic dRst) => ~mux(
        valid,
        mux(dRst | f.wrFull, f.wrFullIfHold, f.wrFullIfPush),
        f.wrFullIfHold,
      );
      dn.rdataReady <=
          out(
            'd_rdata_ready_r',
            ~rdF.wrFull & ~dRd,
            fullNext(rdF, dn.rdataValid, dRd),
            dRdEarly,
          );
      rdF.push(
        dn.rdataValid & can['d_rdata_ready_r']!,
        harborPack([
          dn.rdataId,
          dn.rdataData,
          dn.rdataErr,
          dn.rdataLast,
          dn.rdataExOkay,
        ]),
      );
      dn.wrespReady <=
          out(
            'd_wresp_ready_r',
            ~wrF.wrFull & ~dWr,
            fullNext(wrF, dn.wrespValid, dWr),
            dWrEarly,
          );
      wrF.push(
        dn.wrespValid & can['d_wresp_ready_r']!,
        harborPack([dn.wrespId, dn.wrespErr, dn.wrespExOkay]),
      );
      return;
    }

    // Device side: the requester. Nothing crosses to or from it in reset.
    up.reqReady <= ~reqF.wrFull & ~dReq;
    reqF.push(
      up.reqValid & ~dReq,
      harborPack([
        up.reqId,
        up.reqWrite,
        up.reqAddr,
        up.reqLen,
        up.reqSize,
        up.reqBurst,
        up.reqExclusive,
      ]),
    );
    up.wdataReady <= ~wdF.wrFull & ~dWd;
    wdF.push(
      up.wdataValid & ~dWd,
      harborPack([up.wdataData, up.wdataStrb, up.wdataLast]),
    );
    final [rId, rData, rErr, rLast, rEx] = harborUnpack(rdF.rdData, rdWidths);
    up.rdataValid <= ~rdF.rdEmpty & ~dRd;
    up.rdataId <= rId;
    up.rdataData <= rData;
    up.rdataErr <= rErr;
    up.rdataLast <= rLast;
    up.rdataExOkay <= rEx;
    rdF.pop(up.rdataReady & ~dRd);
    final [bId, bErr, bEx] = harborUnpack(wrF.rdData, wrWidths);
    up.wrespValid <= ~wrF.rdEmpty & ~dWr;
    up.wrespId <= bId;
    up.wrespErr <= bErr;
    up.wrespExOkay <= bEx;
    wrF.pop(up.wrespReady & ~dWr);

    // Fabric side: the responder. Write data goes out only for a write
    // already sent, so a device reset never leaves stray beats behind.
    final recover = Logic(name: 'recover');
    final mode = (recover | fJoinSync).named('fabric_mode_recover');
    final reqFire = Logic(name: 'f_req_fire');
    final wdLastFire = Logic(name: 'f_wdata_last_fire');
    final [id, write, addr, len, size, burst, exclusive] = harborUnpack(
      reqF.rdData,
      reqWidths,
    );
    final lenQ = HarborRegFifo(
      name: 'write_len_q',
      clk: fClk,
      reset: fReset,
      depth: n,
      pushValid: reqFire & write,
      pushData: len,
      popReady: wdLastFire,
    );
    final outR = Logic(name: 'out_reads', width: cntW);
    final outW = Logic(name: 'out_writes', width: cntW);
    final wBeat = Logic(name: 'w_beat', width: lenW);
    addOutput('debug_reads', width: cntW) <= outR;
    addOutput('debug_writes', width: cntW) <= outW;
    addOutput('debug_recover') <= mode;

    final reqOpen = ~mode & lenQ.pushReady;
    dn.reqValid <= ~reqF.rdEmpty & reqOpen;
    dn.reqId <= id;
    dn.reqWrite <= write;
    dn.reqAddr <= addr;
    dn.reqLen <= len;
    dn.reqSize <= size;
    dn.reqBurst <= burst;
    dn.reqExclusive <= exclusive;
    reqF.pop(dn.reqReady & reqOpen);
    reqFire <= dn.reqValid & dn.reqReady;

    final [wData, wStrb, wLast] = harborUnpack(wdF.rdData, wdWidths);
    final wOpen = lenQ.popValid;
    dn.wdataValid <= wOpen & (mode | ~wdF.rdEmpty);
    dn.wdataData <= wData & (~mode).replicate(dataW);
    dn.wdataStrb <= mux(mode, Const(0, width: config.strbWidth), wStrb);
    dn.wdataLast <= mux(mode, wBeat.eq(lenQ.popData), wLast);
    wdF.pop(dn.wdataReady & wOpen & ~mode);
    final wdFire = dn.wdataValid & dn.wdataReady;
    wdLastFire <= wdFire & dn.wdataLast;

    // Responses to requests sent before a device reset are dropped. READY
    // stays low while nothing is in flight.
    dn.rdataReady <= (mode | ~rdF.wrFull) & nonZero(outR);
    rdF.push(
      dn.rdataValid & dn.rdataReady & ~mode,
      harborPack([
        dn.rdataId,
        dn.rdataData,
        dn.rdataErr,
        dn.rdataLast,
        dn.rdataExOkay,
      ]),
    );
    dn.wrespReady <= (mode | ~wrF.wrFull) & nonZero(outW);
    wrF.push(
      dn.wrespValid & dn.wrespReady & ~mode,
      harborPack([dn.wrespId, dn.wrespErr, dn.wrespExOkay]),
    );
    final rDone = dn.rdataValid & dn.rdataReady & dn.rdataLast;
    final bDone = dn.wrespValid & dn.wrespReady;
    final reqR = reqFire & ~write;
    final reqW = reqFire & write;

    Sequential(fClk, reset: fReset, [
      If.block([
        Iff(wdLastFire, [wBeat < Const(0, width: lenW)]),
        ElseIf(wdFire, [wBeat < wBeat + 1]),
      ]),
      If.block([
        Iff(reqR & ~rDone, [outR < outR + 1]),
        ElseIf(rDone & ~reqR, [outR < outR - 1]),
      ]),
      If.block([
        Iff(reqW & ~bDone, [outW < outW + 1]),
        ElseIf(bDone & ~reqW, [outW < outW - 1]),
      ]),
      If.block([
        Iff(fJoinSync, [recover < Const(1)]),
        ElseIf(~lenQ.popValid & ~nonZero(outR) & ~nonZero(outW), [
          recover < Const(0),
        ]),
      ]),
    ]);
  }
}

/// One [HarborWaistCdcFifo] with its clocks and resets wired.
class _Fifo {
  final Logic _wrEn;
  final Logic _wrData;
  final Logic _rdEn;
  final HarborWaistCdcFifo fifo;

  _Fifo._(this._wrEn, this._wrData, this._rdEn, this.fifo);

  factory _Fifo(
    String name,
    int width,
    int depth,
    Logic wrClk,
    Logic wrReset,
    Logic rdClk,
    Logic rdReset, {
    bool trustWrite = false,
    bool trustRead = false,
  }) {
    final wrEn = Logic(name: '${name}_wr_en');
    final wrData = Logic(name: '${name}_wr_data', width: width);
    final rdEn = Logic(name: '${name}_rd_en');
    return _Fifo._(
      wrEn,
      wrData,
      rdEn,
      HarborWaistCdcFifo(
        wrClk: wrClk,
        wrReset: wrReset,
        wrEn: wrEn,
        wrData: wrData,
        rdClk: rdClk,
        rdReset: rdReset,
        rdEn: rdEn,
        depth: depth,
        trustWrite: trustWrite,
        trustRead: trustRead,
        name: name,
      ),
    );
  }

  Logic get wrFull => fifo.wrFull;
  Logic get wrFullIfPush => fifo.output('wr_full_push');
  Logic get wrFullIfHold => fifo.output('wr_full_hold');
  Logic get rdEmpty => fifo.rdEmpty;
  Logic get rdEmptyIfPop => fifo.output('rd_empty_pop');
  Logic get rdEmptyIfHold => fifo.output('rd_empty_hold');
  Logic get rdData => fifo.rdData;

  /// Pushes [data] when [valid] is high and the FIFO is not full.
  void push(Logic valid, Logic data) {
    _wrEn <= valid;
    _wrData <= data;
  }

  /// Pops the head when [ready] is high and the FIFO is not empty.
  void pop(Logic ready) {
    _rdEn <= ready;
  }
}

/// A gray pointer FIFO between two clocks, for a waist crossing whose two
/// sides can sit far from the logic that uses them.
///
/// It has the cycle timing of a flop array [HarborCdcFifo]. The outputs are
/// flops: `rd_data` is a head register that holds the entry at the read
/// pointer. `wr_full_push` and `wr_full_hold` give the next full flag with
/// and without a push, and `rd_empty_pop` and `rd_empty_hold` the next empty
/// flag with and without a pop. With `trustWrite` or `trustRead`, the user
/// gives that enable only when the FIFO can take it. Each side makes its next state for both values of its enable
/// ahead, so `wr_en` and `rd_en` only select one.
class HarborWaistCdcFifo extends Module {
  Logic get wrFull => output('wr_full');
  Logic get rdEmpty => output('rd_empty');
  Logic get rdData => output('rd_data');

  HarborWaistCdcFifo({
    required Logic wrClk,
    required Logic wrReset,
    required Logic wrEn,
    required Logic wrData,
    required Logic rdClk,
    required Logic rdReset,
    required Logic rdEn,
    required int depth,
    bool trustWrite = false,
    bool trustRead = false,
    super.name = 'waist_cdc_fifo',
  }) : super(
         definitionName:
             'HarborWaistCdcFifo_${wrData.width}w${depth}d'
             '${trustWrite ? '_tw' : ''}${trustRead ? '_tr' : ''}',
       ) {
    if (depth < 2 || depth & (depth - 1) != 0) {
      throw ArgumentError.value(depth, 'depth', 'must be a power of two >= 2');
    }
    final width = wrData.width;
    wrClk = addInput('wr_clk', wrClk);
    wrReset = addInput('wr_reset', wrReset);
    wrEn = addInput('wr_en', wrEn);
    wrData = addInput('wr_data', wrData, width: width);
    rdClk = addInput('rd_clk', rdClk);
    rdReset = addInput('rd_reset', rdReset);
    rdEn = addInput('rd_en', rdEn);

    final pw = depth.bitLength;
    Logic gray(Logic b) => b ^ (b >>> 1);
    Logic rotate(Logic x) => [x.getRange(0, depth - 1), x[depth - 1]].swizzle();
    Logic pick(Logic sel, List<Logic> v) => [
      for (var i = 0; i < depth; i++) v[i] & sel[i].replicate(width),
    ].reduce((a, b) => a | b);
    final mem = [
      for (var i = 0; i < depth; i++) Logic(name: 'mem_$i', width: width),
    ];

    // Write side.
    final wrPtr = Logic(name: 'wr_ptr', width: pw);
    final rdGray = Logic(name: 'rd_ptr_gray', width: pw);
    final wrGray = Logic(name: 'wr_ptr_gray', width: pw);
    final wrFull = Logic(name: 'wr_full_reg');
    final wrSel = Logic(name: 'wr_sel', width: depth);
    final rdGraySync0 = Logic(name: 'rd_gray_sync0', width: pw);
    final rdGraySync = Logic(name: 'rd_ptr_gray_sync', width: pw);
    // Full: the write gray equals the read gray with the top 2 bits
    // inverted.
    Logic fullAt(Logic g) => g.eq(
      [~rdGraySync.getRange(pw - 2), rdGraySync.getRange(0, pw - 2)].swizzle(),
    );
    // Registers that hold the pointer plus one and its gray code.
    final wrPtr1 = Logic(name: 'wr_ptr_1', width: pw);
    final wrGray1 = Logic(name: 'wr_ptr_gray_1', width: pw);
    final push = (trustWrite ? wrEn : wrEn & ~wrFull).named('wr_push');
    final fullNext = mux(push, fullAt(wrGray1), fullAt(wrGray));
    addOutput('wr_full_push') <= ~wrReset & fullAt(wrGray1);
    addOutput('wr_full_hold') <= ~wrReset & fullAt(wrGray);
    Sequential(wrClk, [
      for (var i = 0; i < depth; i++)
        If(push & wrSel[i], then: [mem[i] < wrData]),
      If(
        wrReset,
        then: [
          wrPtr < 0,
          wrGray < 0,
          wrPtr1 < 1,
          wrGray1 < 1,
          wrFull < 0,
          wrSel < 1,
          rdGraySync0 < 0,
          rdGraySync < 0,
        ],
        orElse: [
          rdGraySync0 < rdGray,
          rdGraySync < rdGraySync0,
          wrPtr < mux(push, wrPtr1, wrPtr),
          wrGray < mux(push, wrGray1, wrGray),
          wrPtr1 < mux(push, wrPtr1 + 1, wrPtr1),
          wrGray1 < mux(push, gray(wrPtr1 + 1), wrGray1),
          wrFull < fullNext,
          wrSel < mux(push, rotate(wrSel), wrSel),
        ],
      ),
    ]);
    addOutput('wr_full') <= wrFull;

    // Read side. The head register loads the entry at the next read
    // pointer each cycle. An entry is written at least two read clock
    // edges before the empty flag falls, so the head holds it by then.
    final rdPtr = Logic(name: 'rd_ptr', width: pw);
    final rdEmpty = Logic(name: 'rd_empty_reg');
    final rdSel = Logic(name: 'rd_sel', width: depth);
    final head = Logic(name: 'rd_head', width: width);
    final wrGraySync0 = Logic(name: 'wr_gray_sync0', width: pw);
    final wrGraySync = Logic(name: 'wr_ptr_gray_sync', width: pw);
    final rdPtr1 = Logic(name: 'rd_ptr_1', width: pw);
    final rdGray1 = Logic(name: 'rd_ptr_gray_1', width: pw);
    final rdSel1 = rotate(rdSel);
    final pop = (trustRead ? rdEn : rdEn & ~rdEmpty).named('rd_pop');
    final emptyNext = mux(pop, rdGray1.eq(wrGraySync), rdGray.eq(wrGraySync));
    addOutput('rd_empty_pop') <= rdReset | rdGray1.eq(wrGraySync);
    addOutput('rd_empty_hold') <= rdReset | rdGray.eq(wrGraySync);
    Sequential(rdClk, [
      head < mux(pop, pick(rdSel1, mem), pick(rdSel, mem)),
      If(
        rdReset,
        then: [
          rdPtr < 0,
          rdGray < 0,
          rdPtr1 < 1,
          rdGray1 < 1,
          rdEmpty < 1,
          rdSel < 1,
          wrGraySync0 < 0,
          wrGraySync < 0,
        ],
        orElse: [
          wrGraySync0 < wrGray,
          wrGraySync < wrGraySync0,
          rdPtr < mux(pop, rdPtr1, rdPtr),
          rdGray < mux(pop, rdGray1, rdGray),
          rdPtr1 < mux(pop, rdPtr1 + 1, rdPtr1),
          rdGray1 < mux(pop, gray(rdPtr1 + 1), rdGray1),
          rdEmpty < emptyNext,
          rdSel < mux(pop, rdSel1, rdSel),
        ],
      ),
    ]);
    addOutput('rd_empty') <= rdEmpty;
    addOutput('rd_data', width: width) <= head;
  }
}

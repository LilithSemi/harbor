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
/// lengths and LAST pass unchanged, so the order rules of the waist hold on
/// both sides. The device side gets write data only after its REQ is taken.
///
/// Either reset resets both halves of every FIFO through [harborCdcJoinReset].
/// Device logic must reset on `device_reset`. The fabric side keeps its own
/// record of the requests in flight and resets only on the fabric reset:
///
/// - With [slave] set, the fabric is the requester. After a device reset, each
///   read in flight gets its remaining beats with ERR and data 0, each write
///   gets WRESP with ERR, and its write data is taken and dropped.
/// - Else the fabric is the responder. After a device reset, each write in
///   flight gets its remaining beats with all strobes low, and every
///   response in flight is dropped.
///
/// No new request crosses until this is done.
///
/// With [deviceResetCopy], each FIFO device half and the device side logic
/// of its channel reset on their own copy of `device_reset`, so no single
/// reset net spans the die. A copy is one cycle later than `device_reset`.
class HarborMemoryWaistCdc extends Module {
  /// Entries in each FIFO.
  final int depth;

  /// The device side reset joined with the fabric reset.
  Logic get deviceReset => output('device_reset');

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
    Logic dCopy(String n) => deviceResetCopy == null
        ? dJoin
        : deviceResetCopy(dClk, dJoin, dSet!, '${n}_device_reset');
    final dReq = dCopy('req');
    final dWd = dCopy('wdata');
    final dRd = dCopy('rdata');
    final dWr = dCopy('wresp');
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
    ];
    final wdWidths = [dataW, config.strbWidth, 1];
    final rdWidths = [idW, dataW, 1, 1];
    final wrWidths = [idW, 1];

    // A FIFO writes on the fabric side when the fabric sends that way.
    _Fifo fifo(String name, List<int> widths, bool down, Logic dRst) {
      final fabricWrites = down == slave;
      return _Fifo(
        name,
        widths.reduce((a, b) => a + b),
        this.depth,
        fabricWrites ? fClk : dClk,
        fabricWrites ? fJoin : dRst,
        fabricWrites ? dClk : fClk,
        fabricWrites ? dRst : fJoin,
      );
    }

    final reqF = fifo('req_fifo', reqWidths, true, dReq);
    final wdF = fifo('wdata_fifo', wdWidths, true, dWd);
    final rdF = fifo('rdata_fifo', rdWidths, false, dRd);
    final wrF = fifo('wresp_fifo', wrWidths, false, dWr);

    final n = config.outstanding;
    final cntW = n.bitLength;
    Logic nonZero(Logic c) => ~c.eq(Const(0, width: c.width));

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
      final [rId, rData, rErr, rLast] = harborUnpack(rdF.rdData, rdWidths);
      up.rdataValid <= mux(mode, rdQ.popValid, ~rdF.rdEmpty);
      up.rdataId <= mux(mode, qId, rId);
      up.rdataData <= mux(mode, Const(0, width: dataW), rData);
      up.rdataErr <= mode | rErr;
      up.rdataLast <= mux(mode, rBeat.eq(qLen), rLast);
      rdF.pop(up.rdataReady & ~mode);
      final rdFire = up.rdataValid & up.rdataReady;
      rdLastFire <= rdFire & up.rdataLast;

      // A poisoned write gets WRESP only after all its data is taken. The
      // writes that owe data are the newest wOwed entries of wrQ.
      final wrDataDone = wrQ.count.gt(wOwed);
      final [bId, bErr] = harborUnpack(wrF.rdData, wrWidths);
      up.wrespValid <= mux(mode, wrDataDone, ~wrF.rdEmpty);
      up.wrespId <= mux(mode, wrQ.popData, bId);
      up.wrespErr <= mode | bErr;
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
      final open = nonZero(wPend) & ~dWd;
      final [id, write, addr, len, size, burst] = harborUnpack(
        reqF.rdData,
        reqWidths,
      );
      dn.reqValid <= ~reqF.rdEmpty & ~dReq;
      dn.reqId <= id;
      dn.reqWrite <= write;
      dn.reqAddr <= addr;
      dn.reqLen <= len;
      dn.reqSize <= size;
      dn.reqBurst <= burst;
      reqF.pop(dn.reqReady & ~dReq);
      final [wData, wStrb, wLast] = harborUnpack(wdF.rdData, wdWidths);
      dn.wdataValid <= ~wdF.rdEmpty & open;
      dn.wdataData <= wData;
      dn.wdataStrb <= wStrb;
      dn.wdataLast <= wLast;
      wdF.pop(dn.wdataReady & open);
      final dReqW = dn.reqValid & dn.reqReady & write;
      final dLast = dn.wdataValid & dn.wdataReady & wLast;
      Sequential(dClk, reset: dWd, [
        If.block([
          Iff(dReqW & ~dLast, [wPend < wPend + 1]),
          ElseIf(dLast & ~dReqW, [wPend < wPend - 1]),
        ]),
      ]);
      // Nothing crosses to or from a device side in reset.
      dn.rdataReady <= ~rdF.wrFull & ~dRd;
      rdF.push(
        dn.rdataValid & ~dRd,
        harborPack([dn.rdataId, dn.rdataData, dn.rdataErr, dn.rdataLast]),
      );
      dn.wrespReady <= ~wrF.wrFull & ~dWr;
      wrF.push(dn.wrespValid & ~dWr, harborPack([dn.wrespId, dn.wrespErr]));
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
      ]),
    );
    up.wdataReady <= ~wdF.wrFull & ~dWd;
    wdF.push(
      up.wdataValid & ~dWd,
      harborPack([up.wdataData, up.wdataStrb, up.wdataLast]),
    );
    final [rId, rData, rErr, rLast] = harborUnpack(rdF.rdData, rdWidths);
    up.rdataValid <= ~rdF.rdEmpty & ~dRd;
    up.rdataId <= rId;
    up.rdataData <= rData;
    up.rdataErr <= rErr;
    up.rdataLast <= rLast;
    rdF.pop(up.rdataReady & ~dRd);
    final [bId, bErr] = harborUnpack(wrF.rdData, wrWidths);
    up.wrespValid <= ~wrF.rdEmpty & ~dWr;
    up.wrespId <= bId;
    up.wrespErr <= bErr;
    wrF.pop(up.wrespReady & ~dWr);

    // Fabric side: the responder. Write data goes out only for a write
    // already sent, so a device reset never leaves stray beats behind.
    final recover = Logic(name: 'recover');
    final mode = (recover | fJoinSync).named('fabric_mode_recover');
    final reqFire = Logic(name: 'f_req_fire');
    final wdLastFire = Logic(name: 'f_wdata_last_fire');
    final [id, write, addr, len, size, burst] = harborUnpack(
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

    final reqOpen = ~mode & lenQ.pushReady;
    dn.reqValid <= ~reqF.rdEmpty & reqOpen;
    dn.reqId <= id;
    dn.reqWrite <= write;
    dn.reqAddr <= addr;
    dn.reqLen <= len;
    dn.reqSize <= size;
    dn.reqBurst <= burst;
    reqF.pop(dn.reqReady & reqOpen);
    reqFire <= dn.reqValid & dn.reqReady;

    final [wData, wStrb, wLast] = harborUnpack(wdF.rdData, wdWidths);
    final wOpen = lenQ.popValid;
    dn.wdataValid <= wOpen & (mode | ~wdF.rdEmpty);
    dn.wdataData <= mux(mode, Const(0, width: dataW), wData);
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
      harborPack([dn.rdataId, dn.rdataData, dn.rdataErr, dn.rdataLast]),
    );
    dn.wrespReady <= (mode | ~wrF.wrFull) & nonZero(outW);
    wrF.push(
      dn.wrespValid & dn.wrespReady & ~mode,
      harborPack([dn.wrespId, dn.wrespErr]),
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

/// Makes a flop on [clk] that loads [d] and sets at once on [set], under
/// [name]. A vendor flop keeps synthesis from merging two copies.
typedef HarborResetCopy =
    Logic Function(Logic clk, Logic d, Logic set, String name);

/// One [HarborCdcFifo] with its clocks and resets wired.
class _Fifo {
  final HarborCdcFifo fifo;

  _Fifo(
    String name,
    int width,
    int depth,
    Logic wrClk,
    Logic wrReset,
    Logic rdClk,
    Logic rdReset,
  ) : fifo = HarborCdcFifo(dataWidth: width, depth: depth, name: name) {
    fifo.input('wr_clk').srcConnection! <= wrClk;
    fifo.input('wr_reset').srcConnection! <= wrReset;
    fifo.input('rd_clk').srcConnection! <= rdClk;
    fifo.input('rd_reset').srcConnection! <= rdReset;
  }

  Logic get wrFull => fifo.output('wr_full');
  Logic get rdEmpty => fifo.output('rd_empty');
  Logic get rdData => fifo.output('rd_data');

  /// Pushes [data] when [valid] is high and the FIFO is not full.
  void push(Logic valid, Logic data) {
    fifo.input('wr_en').srcConnection! <= valid & ~wrFull;
    fifo.input('wr_data').srcConnection! <= data;
  }

  /// Pops the head when [ready] is high and the FIFO is not empty.
  void pop(Logic ready) {
    fifo.input('rd_en').srcConnection! <= ready;
  }
}

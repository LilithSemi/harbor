import 'dart:math';

import 'package:rohd/rohd.dart';

import 'memory_waist.dart';

/// Connects a device with plain DMA request ports to a memory master waist.
///
/// The device side has one read and one write request port:
///
/// - Read: the device holds `read_req` high with `read_addr`. One cycle of
///   `read_valid` with `read_data` ends the request. In that cycle the
///   device changes `read_addr` for its next word or drops `read_req`.
/// - Write: the device holds `write_req` high with `write_addr`,
///   `write_data` and `write_be`. One cycle of `write_ack` ends the request.
///   The ack comes after the write response, so writes are never posted.
///
/// A device must hold a request until it ends. `err` is high with the
/// `read_valid` or `write_ack` of a request that got a fabric error or a
/// timeout, and `timeout` is high for a timeout. The read data of a failed
/// read is 0.
///
/// The adapter sends one single-beat request at a time with ID 0. When read
/// and write both wait, they take turns. A request that does not finish in
/// [timeoutCycles] cycles ends with a timeout. The cycle count restarts at
/// each fabric handshake. The adapter never takes back a request or a write
/// beat that the fabric has not taken, and it drops the late response of a
/// failed request. The next request waits until the fabric owes nothing,
/// with the same timeout.
class HarborDmaRequestAdapter extends Module {
  /// Cycles a request may wait for the fabric.
  final int timeoutCycles;

  Logic get readData => output('read_data');
  Logic get readValid => output('read_valid');
  Logic get writeAck => output('write_ack');
  Logic get err => output('err');
  Logic get timeout => output('timeout');

  /// Device side address bits. The waist gets the low bits, or the address
  /// with zeros added on top.
  final int requestAddressWidth;

  HarborDmaRequestAdapter({
    required Logic clk,
    required Logic reset,
    required HarborMemoryWaist waist,
    required Logic readReq,
    required Logic readAddr,
    required Logic writeReq,
    required Logic writeAddr,
    required Logic writeData,
    Logic? writeBe,
    this.timeoutCycles = 1 << 16,
    super.name = 'dma_adapter',
  }) : requestAddressWidth = readAddr.width,
       super(
         definitionName:
             'HarborDmaRequestAdapter_a${waist.config.addressWidth}'
             '_d${waist.config.dataWidth}_i${waist.config.idWidth}'
             '_r${readAddr.width}'
             '_t$timeoutCycles${writeBe == null ? '' : '_be'}',
       ) {
    final config = waist.config;
    final dw = config.dataWidth;
    final aw = config.addressWidth;
    if (timeoutCycles < 1) {
      throw RangeError.value(timeoutCycles, 'timeoutCycles', 'must be >= 1');
    }
    if (writeAddr.width != readAddr.width) {
      throw ArgumentError('read and write addresses differ in width');
    }
    if (writeData.width != dw) {
      throw ArgumentError('write data is ${writeData.width} bits, waist $dw');
    }
    if (writeBe != null && writeBe.width != config.strbWidth) {
      throw ArgumentError('write_be must be ${config.strbWidth} bits');
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    readReq = addInput('read_req', readReq);
    readAddr = addInput('read_addr', readAddr, width: readAddr.width);
    writeReq = addInput('write_req', writeReq);
    writeAddr = addInput('write_addr', writeAddr, width: writeAddr.width);
    writeData = addInput('write_data', writeData, width: dw);
    final be = writeBe == null
        ? Const(1, width: config.strbWidth, fill: true)
        : addInput('write_be', writeBe, width: config.strbWidth);
    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.provider, uniquify: (n) => 'm_$n');

    Logic fit(Logic a) => a.width >= aw ? a.slice(aw - 1, 0) : a.zeroExtend(aw);

    const sIdle = 0;
    const sStart = 1;
    const sWait = 2;
    const sDone = 3;
    final state = Logic(name: 'state', width: 2);
    Logic inState(int s) => state.eq(Const(s, width: 2));

    // The device request waits in the p* registers. The drive registers
    // change only when nothing is owed.
    final pWrite = Logic(name: 'p_write');
    final pAddr = Logic(name: 'p_addr', width: aw);
    final pData = Logic(name: 'p_data', width: dw);
    final pStrb = Logic(name: 'p_strb', width: config.strbWidth);
    final isWrite = Logic(name: 'is_write');
    final lastWrite = Logic(name: 'last_write');
    final addr = Logic(name: 'addr', width: aw);
    final wData = Logic(name: 'w_data', width: dw);
    final wStrb = Logic(name: 'w_strb', width: config.strbWidth);
    final rData = Logic(name: 'r_data', width: dw);
    final errReg = Logic(name: 'err_reg');
    final timeoutReg = Logic(name: 'timeout_reg');

    // Handshakes the fabric still owes. They stay owed after a timeout, so
    // a late beat is never taken as data for a later request.
    final reqOwe = Logic(name: 'req_owe');
    final wOwe = Logic(name: 'w_owe');
    final rOwe = Logic(name: 'r_owe');
    final bOwe = Logic(name: 'b_owe');
    final quiet = (~reqOwe & ~wOwe & ~rOwe & ~bOwe).named('quiet');

    m.reqValid <= reqOwe;
    m.reqId <= Const(0, width: config.idWidth);
    m.reqWrite <= isWrite;
    m.reqAddr <= addr;
    m.reqLen <= Const(0, width: HarborMemoryWaistConfig.lenWidth);
    m.reqSize <=
        Const(
          (config.strbWidth - 1).bitLength,
          width: HarborMemoryWaistConfig.sizeWidth,
        );
    m.reqBurst <=
        Const(
          HarborMemoryBurst.incr.value,
          width: HarborMemoryWaistConfig.burstWidth,
        );
    m.reqExclusive <= Const(0);
    m.wdataValid <= wOwe;
    m.wdataData <= wData;
    m.wdataStrb <= wStrb;
    m.wdataLast <= Const(1);

    final reqFire = (m.reqValid & m.reqReady).named('req_fire');
    m.rdataReady <= rOwe | reqFire & ~isWrite;
    m.wrespReady <= bOwe | reqFire & isWrite;
    final wFire = (m.wdataValid & m.wdataReady).named('w_fire');
    final rFire = (m.rdataValid & m.rdataReady).named('r_fire');
    final bFire = (m.wrespValid & m.wrespReady).named('b_fire');

    final timerWidth = max(1, timeoutCycles.bitLength);
    final timer = Logic(name: 'timer', width: timerWidth);
    final waiting = (inState(sStart) | inState(sWait)).named('waiting');
    final moved = (reqFire | wFire | rFire | bFire).named('moved');
    final expired = (waiting & ~moved & timer.eq(timeoutCycles - 1)).named(
      'expired',
    );
    final startNow = (inState(sStart) & quiet & ~expired).named('start_now');
    final endRead = (inState(sWait) & ~isWrite & rFire).named('end_read');
    final endWrite = (inState(sWait) & isWrite & bFire).named('end_write');

    final pickWrite = (writeReq & (~readReq | ~lastWrite)).named('pick_write');

    Sequential(clk, reset: reset, [
      timer <
          mux(
            ~waiting | moved | startNow,
            Const(0, width: timerWidth),
            timer + 1,
          ),
      If(reqFire, then: [reqOwe < 0]),
      If(wFire, then: [wOwe < 0]),
      If.block([
        Iff(reqFire & ~isWrite & ~rFire, [rOwe < 1]),
        ElseIf(rFire, [rOwe < 0]),
      ]),
      If.block([
        Iff(reqFire & isWrite & ~bFire, [bOwe < 1]),
        ElseIf(bFire, [bOwe < 0]),
      ]),
      Case(state, [
        CaseItem(Const(sIdle, width: 2), [
          If(
            readReq | writeReq,
            then: [
              pWrite < pickWrite,
              lastWrite < pickWrite,
              pAddr < fit(mux(pickWrite, writeAddr, readAddr)),
              pData < writeData,
              pStrb < be,
              state < sStart,
            ],
          ),
        ]),
        CaseItem(Const(sStart, width: 2), [
          If(
            startNow,
            then: [
              isWrite < pWrite,
              addr < pAddr,
              wData < pData,
              wStrb < pStrb,
              reqOwe < 1,
              wOwe < pWrite,
              state < sWait,
            ],
          ),
        ]),
        CaseItem(Const(sWait, width: 2), [
          If(
            endRead,
            then: [
              rData < mux(m.rdataErr, Const(0, width: dw), m.rdataData),
              errReg < m.rdataErr,
              timeoutReg < 0,
              state < sDone,
            ],
          ),
          If(
            endWrite,
            then: [errReg < m.wrespErr, timeoutReg < 0, state < sDone],
          ),
        ]),
        CaseItem(Const(sDone, width: 2), [state < sIdle]),
      ]),
      If(
        expired & ~endRead & ~endWrite,
        then: [
          rData < Const(0, width: dw),
          errReg < 1,
          timeoutReg < 1,
          state < sDone,
        ],
      ),
    ]);

    final done = inState(sDone);
    addOutput('read_data', width: dw) <= rData;
    addOutput('read_valid') <= done & ~pWrite;
    addOutput('write_ack') <= done & pWrite;
    addOutput('err') <= done & errReg;
    addOutput('timeout') <= done & timeoutReg;
  }
}

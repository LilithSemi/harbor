import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';

/// A zero-latency memory behind a master-side memory waist, for tests that
/// only ever have one read request in flight.
///
/// Accepts a request the same cycle REQ_VALID rises (REQ_READY is high
/// whenever idle) and drives its first RDATA beat that same cycle, then one
/// more beat per cycle until the burst ends. Each beat answers with [table]
/// of its byte address, or the address itself when [table] is null. Never
/// answers a write.
class EchoMemory extends Module {
  EchoMemory(
    HarborMemoryWaist waist,
    Logic clk,
    Logic reset, {
    Map<int, int>? table,
    super.name = 'echo_memory',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.consumer, uniquify: (n) => 'm_$n');

    final config = waist.config;
    final idW = config.idWidth;
    const lenW = HarborMemoryWaistConfig.lenWidth;

    final busy = Logic(name: 'busy');
    final addr = Logic(name: 'addr', width: 32);
    final id = Logic(name: 'id', width: idW);
    final len = Logic(name: 'len', width: lenW);
    final beat = Logic(name: 'beat', width: lenW);

    final reqFire = (m.reqValid & ~busy).named('req_fire');
    m.reqReady <= ~busy;
    m.wdataReady <= Const(1);
    m.wrespValid <= Const(0);
    m.wrespId <= Const(0, width: idW);
    m.wrespErr <= Const(0);

    final curAddr = mux(reqFire, m.reqAddr, addr).named('cur_addr');
    final curId = mux(reqFire, m.reqId, id).named('cur_id');
    final curLen = mux(reqFire, m.reqLen, len).named('cur_len');
    final curBeat = mux(reqFire, Const(0, width: lenW), beat).named('cur_beat');
    final active = (busy | reqFire).named('active');

    Logic dataOf(Logic a) {
      if (table == null) return a;
      Logic out = Const(0, width: config.dataWidth);
      table.forEach((k, v) {
        out = mux(
          a.eq(Const(k, width: 32)),
          Const(v, width: config.dataWidth),
          out,
        );
      });
      return out;
    }

    m.rdataValid <= active;
    m.rdataId <= curId;
    m.rdataData <= dataOf(curAddr);
    m.rdataErr <= Const(0);
    m.rdataLast <= curBeat.eq(curLen);

    Sequential(clk, reset: reset, [
      If(
        active,
        then: [
          addr < (curAddr + Const(config.dataWidth ~/ 8, width: 32)),
          id < curId,
          len < curLen,
          beat < (curBeat + Const(1, width: lenW)),
          busy < ~curBeat.eq(curLen),
        ],
        orElse: [busy < Const(0)],
      ),
    ]);
  }
}

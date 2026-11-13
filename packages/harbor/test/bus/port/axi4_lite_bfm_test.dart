import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart'
    show
        Axi4DataPacket,
        Axi4MainClusterAgent,
        Axi4ReadCluster,
        Axi4ReadComplianceChecker,
        Axi4RequestPacket,
        Axi4ResponsePacket,
        Axi4SubordinateClusterAgent,
        Axi4SubordinateMemoryAgent,
        Axi4WriteCluster,
        Axi4WriteComplianceChecker;
import 'package:rohd_vf/rohd_vf.dart';
import 'package:test/test.dart';

import 'port_harness.dart';

/// rohd_hcl AXI4 interfaces cut down to the AXI4-Lite signal set: no ID, no
/// LEN, no LOCK and no USER. The BFM agents and compliance checkers run on
/// these.
class _Bench extends Test {
  final Axi4SystemInterface sIntf = Axi4SystemInterface();
  final Axi4ReadCluster rIntf = Axi4ReadCluster(
    idWidth: 0,
    addrWidth: 16,
    lenWidth: 0,
    dataWidth: 32,
    userWidth: 0,
    useLock: false,
  );
  final Axi4WriteCluster wIntf = Axi4WriteCluster(
    idWidth: 0,
    addrWidth: 16,
    lenWidth: 0,
    dataWidth: 32,
    userWidth: 0,
    useLock: false,
  );
  final Future<void> Function(_Bench bench) body;

  /// Whether this bench drives the manager side (and so must supply RLAST to
  /// the manager agent's read-data monitor).
  final bool managerSide;

  _Bench(super.name, this.body, {this.managerSide = false})
    : super(randomSeed: 1) {
    printLevel = failLevel;
    Simulator.setMaxSimTime(20000);
    sIntf.clk <= SimpleClockGenerator(10).clk;
    sIntf.resetN.put(0);
    if (managerSide) {
      rIntf.rIntf.last! <= Const(1);
    }
    Axi4ReadComplianceChecker(sIntf, rIntf.arIntf, rIntf.rIntf, parent: this);
    Axi4WriteComplianceChecker(
      sIntf,
      wIntf.awIntf,
      wIntf.wIntf,
      wIntf.bIntf,
      parent: this,
    );
    if (managerSide) {
      main = Axi4MainClusterAgent(
        sIntf: sIntf,
        arIntf: rIntf.arIntf,
        awIntf: wIntf.awIntf,
        rIntf: rIntf.rIntf,
        wIntf: wIntf.wIntf,
        bIntf: wIntf.bIntf,
        parent: this,
      );
    }
  }

  /// The manager agent for these interfaces.
  late final Axi4MainClusterAgent main;

  Logic get clk => sIntf.clk;

  @override
  Future<void> run(Phase phase) async {
    unawaited(super.run(phase));
    final obj = phase.raiseObjection('bench');
    await clk.waitCycles(2);
    sIntf.resetN.inject(1);
    await clk.waitCycles(2);
    await body(this);
    obj.drop();
  }
}

/// AXI4-Lite pins of a module port named `bus`, by direction.
const _fromManager = {
  'AWADDR',
  'AWPROT',
  'AWVALID',
  'WDATA',
  'WSTRB',
  'WVALID',
  'BREADY',
  'ARADDR',
  'ARPROT',
  'ARVALID',
  'RREADY',
};
const _fromSubordinate = {
  'AWREADY',
  'WREADY',
  'BRESP',
  'BVALID',
  'ARREADY',
  'RDATA',
  'RRESP',
  'RVALID',
};

Logic _pin(_Bench b, String name) {
  for (final intf in [
    b.wIntf.awIntf,
    b.wIntf.wIntf,
    b.wIntf.bIntf,
    b.rIntf.arIntf,
    b.rIntf.rIntf,
  ]) {
    final port = intf.tryPort(name);
    if (port != null) return port;
  }
  throw ArgumentError.value(name, 'name', 'not a port of the bench');
}

(Axi4RequestPacket, Axi4DataPacket) _write(
  int addr,
  int data, {
  int strb = 0xf,
}) => (
  Axi4RequestPacket(
    addr: LogicValue.ofInt(addr, 16),
    prot: LogicValue.ofInt(0, 3),
    size: LogicValue.ofInt(2, 3),
    burst: LogicValue.ofInt(1, 2),
    cache: LogicValue.ofInt(0, 4),
    qos: LogicValue.ofInt(0, 4),
    region: LogicValue.ofInt(0, 4),
  ),
  Axi4DataPacket(
    data: LogicValue.ofInt(data, 32),
    strb: LogicValue.ofInt(strb, 4),
  ),
);

Axi4RequestPacket _read(int addr) => Axi4RequestPacket(
  addr: LogicValue.ofInt(addr, 16),
  prot: LogicValue.ofInt(0, 3),
  size: LogicValue.ofInt(2, 3),
  burst: LogicValue.ofInt(1, 2),
  cache: LogicValue.ofInt(0, 4),
  qos: LogicValue.ofInt(0, 4),
  region: LogicValue.ofInt(0, 4),
);

void main() {
  tearDown(() async {
    await Test.reset();
  });

  test('AXI4-Lite slave under the rohd_hcl manager BFM', () async {
    final dut = RegFile(HarborFabricKind.axi4);
    final writes = <Axi4ResponsePacket>[];
    final reads = <Axi4DataPacket>[];

    Future<void> waitFor(_Bench b, int nWrites, int nReads) async {
      while (writes.length < nWrites || reads.length < nReads) {
        await b.clk.nextPosedge;
      }
    }

    Future<void> write(_Bench b, int addr, int data, {int strb = 0xf}) async {
      final (request, payload) = _write(addr, data, strb: strb);
      b.main.writeAgent.reqAgent.sequencer.add(request);
      b.main.writeAgent.dataAgent.sequencer!.add(payload);
    }

    final bench = _Bench('axi4lite_slave_bfm', managerSide: true, (b) async {
      final rd = b.main.readAgent.reqAgent.sequencer;
      // The BFM drops VALID one edge early when READY comes late, so each
      // transfer starts with the port idle.
      await write(b, 0x0, 0x11223344);
      await waitFor(b, 1, 0);
      await write(b, 0x0, 0x0000aa00, strb: 0x2);
      await waitFor(b, 2, 0);
      rd.add(_read(0x0));
      await waitFor(b, 2, 1);
      await write(b, errWord * 4, 0x5);
      await waitFor(b, 3, 1);
      rd.add(_read(errWord * 4));
      await waitFor(b, 3, 2);
      // A write and a read in the same cycle.
      await write(b, 0x4, 0x77);
      rd.add(_read(0x0));
      await waitFor(b, 4, 3);
      rd.add(_read(0x4));
      await waitFor(b, 4, 4);
    });

    bench.main.writeAgent.respAgent.monitor.stream.listen(writes.add);
    bench.main.readAgent.dataAgent.monitor!.stream.listen(reads.add);

    dut.input('clk').srcConnection! <= bench.clk;
    dut.input('reset').srcConnection! <= ~bench.sIntf.resetN;
    for (final p in _fromManager) {
      dut.input('bus_$p').srcConnection! <= _pin(bench, p);
    }
    for (final p in _fromSubordinate) {
      _pin(bench, p) <= dut.output('bus_$p');
    }
    await dut.build();
    await bench.start();

    expect([for (final w in writes) w.resp!.toInt()], [0, 0, 2, 0]);
    expect(
      [for (final r in reads) r.data.toInt()],
      [0x1122aa44, 0, 0x1122aa44, 0x77],
    );
    expect([for (final r in reads) r.resp!.toInt()], [0, 2, 0, 0]);
  });

  test('AXI4-Lite master against the rohd_hcl subordinate BFM', () async {
    final dut = MasterShell(HarborFabricKind.axi4);
    final results = <(int, int, int)>[];

    late final Sim sim;
    late final StrobeMaster m;
    final bench = _Bench('axi4lite_master_bfm', (b) async {
      sim.running = true;
      results.addAll(
        await Future.wait([
          m.access(true, 0x0, data: 0x11223344),
          m.access(true, 0x0, data: 0x0000aa00, byteSel: 0x2),
          m.access(false, 0x0),
          m.access(true, 0x8, data: 0x55),
          m.access(false, 0x8),
          m.access(false, 0x40),
        ]),
      );
    });

    Axi4SubordinateMemoryAgent(
      sIntf: bench.sIntf,
      lanes: [
        Axi4SubordinateClusterAgent(
          sIntf: bench.sIntf,
          arIntf: bench.rIntf.arIntf,
          awIntf: bench.wIntf.awIntf,
          rIntf: bench.rIntf.rIntf,
          wIntf: bench.wIntf.wIntf,
          bIntf: bench.wIntf.bIntf,
          parent: bench,
        ),
      ],
      parent: bench,
      respondWithError: (req) => req.addr.toInt() == 0x40,
    );

    dut.input('clk').srcConnection! <= bench.clk;
    dut.input('reset').srcConnection! <= ~bench.sIntf.resetN;
    for (final p in _fromSubordinate) {
      dut.input('bus_$p').srcConnection! <= _pin(bench, p);
    }
    for (final p in _fromManager) {
      _pin(bench, p) <= dut.output('bus_$p');
    }
    // The Lite port has no SIZE, BURST, CACHE, QOS or REGION. Tie them to a
    // single full-width INCR beat for the BFM.
    for (final i in [bench.wIntf.awIntf, bench.rIntf.arIntf]) {
      final pre = i == bench.wIntf.awIntf ? 'AW' : 'AR';
      i.port('${pre}SIZE') <= Const(2, width: 3);
      i.port('${pre}BURST') <= Const(1, width: 2);
      i.port('${pre}CACHE') <= Const(0, width: 4);
      i.port('${pre}QOS') <= Const(0, width: 4);
      i.port('${pre}REGION') <= Const(0, width: 4);
    }
    bench.wIntf.wIntf.last! <= Const(1);
    // The subordinate drives its outputs only once it answers.
    for (final p in _fromSubordinate) {
      _pin(bench, p).put(0);
    }
    for (final input in dut.inputs.values) {
      if (input.name.startsWith('m_')) input.srcConnection!.put(0);
    }
    sim = Sim(dut, clk: bench.clk)..attach();
    m = StrobeMaster(
      sim,
      strobes: ['m_stb'],
      we: 'm_we',
      addr: 'm_addr',
      wdata: 'm_wdata',
      sel: 'm_sel',
      ack: 'm_ack',
      err: 'm_err',
      rdata: 'm_rdata',
      driveOnRise: true,
    );
    await dut.build();
    await bench.start();

    // Read data is only meaningful on reads.
    expect(
      [for (final r in results) (r.$2, r.$3)],
      [(1, 0), (1, 0), (1, 0), (1, 0), (1, 0), (1, 1)],
    );
    expect(results[2].$1, 0x1122aa44);
    expect(results[4].$1, 0x55);
  });
}

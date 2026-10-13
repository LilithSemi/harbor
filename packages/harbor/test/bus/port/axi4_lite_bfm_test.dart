import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart'
    show
        Axi4Channel,
        Axi4MainAgent,
        Axi4ReadComplianceChecker,
        Axi4ReadRequestPacket,
        Axi4SubordinateAgent,
        Axi4WriteComplianceChecker,
        Axi4WriteRequestPacket;
import 'package:rohd_vf/rohd_vf.dart';
import 'package:test/test.dart';

import 'port_harness.dart';

/// rohd_hcl AXI4 interfaces cut down to the AXI4-Lite signal set: no ID, no
/// LEN, no LOCK and no USER. The BFM agents and compliance checkers run on
/// these.
class _Bench extends Test {
  final Axi4SystemInterface sIntf = Axi4SystemInterface();
  final Axi4ReadInterface rIntf = Axi4ReadInterface(
    idWidth: 0,
    addrWidth: 16,
    lenWidth: 0,
    dataWidth: 32,
    aruserWidth: 0,
    ruserWidth: 0,
    useLock: false,
  );
  final Axi4WriteInterface wIntf = Axi4WriteInterface(
    idWidth: 0,
    addrWidth: 16,
    lenWidth: 0,
    dataWidth: 32,
    awuserWidth: 0,
    wuserWidth: 0,
    buserWidth: 0,
    useLock: false,
  );
  late final Axi4Channel channel = Axi4Channel(rIntf: rIntf, wIntf: wIntf);
  final Future<void> Function(_Bench bench) body;

  _Bench(super.name, this.body) : super(randomSeed: 1) {
    printLevel = failLevel;
    Simulator.setMaxSimTime(20000);
    sIntf.clk <= SimpleClockGenerator(10).clk;
    sIntf.resetN.put(0);
    rIntf.rLast! <= Const(1);
    Axi4ReadComplianceChecker(sIntf, rIntf, parent: this);
    Axi4WriteComplianceChecker(sIntf, wIntf, parent: this);
  }

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

Logic _pin(_Bench b, String name) =>
    b.wIntf.tryPort(name) ?? b.rIntf.port(name);

Axi4WriteRequestPacket _write(int addr, int data, {int strb = 0xf}) =>
    Axi4WriteRequestPacket(
      addr: LogicValue.ofInt(addr, 16),
      prot: LogicValue.ofInt(0, 3),
      data: [LogicValue.ofInt(data, 32)],
      strobe: [LogicValue.ofInt(strb, 4)],
      size: LogicValue.ofInt(2, 3),
      burst: LogicValue.ofInt(1, 2),
      cache: LogicValue.ofInt(0, 4),
      qos: LogicValue.ofInt(0, 4),
      region: LogicValue.ofInt(0, 4),
    );

Axi4ReadRequestPacket _read(int addr) => Axi4ReadRequestPacket(
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
    late final Axi4MainAgent main;
    final writes = <Axi4WriteRequestPacket>[];
    final reads = <Axi4ReadRequestPacket>[];

    Future<void> waitFor(_Bench b, int nWrites, int nReads) async {
      while (writes.length < nWrites || reads.length < nReads) {
        await b.clk.nextPosedge;
      }
    }

    final bench = _Bench('axi4lite_slave_bfm', (b) async {
      final wr = main.getWrSequencer(0)!;
      final rd = main.getRdSequencer(0)!;
      // The BFM drops VALID one edge early when READY comes late, so each
      // transfer starts with the port idle.
      wr.add(_write(0x0, 0x11223344));
      await waitFor(b, 1, 0);
      wr.add(_write(0x0, 0x0000aa00, strb: 0x2));
      await waitFor(b, 2, 0);
      rd.add(_read(0x0));
      await waitFor(b, 2, 1);
      wr.add(_write(errWord * 4, 0x5));
      await waitFor(b, 3, 1);
      rd.add(_read(errWord * 4));
      await waitFor(b, 3, 2);
      // A write and a read in the same cycle.
      wr.add(_write(0x4, 0x77));
      rd.add(_read(0x0));
      await waitFor(b, 4, 3);
      rd.add(_read(0x4));
      await waitFor(b, 4, 4);
    });

    main = Axi4MainAgent(
      sIntf: bench.sIntf,
      channels: [bench.channel],
      parent: bench,
    );
    main.getWrMonitor(0)!.stream.listen(writes.add);
    main.getRdMonitor(0)!.stream.listen(reads.add);

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

    expect([for (final w in writes) w.returnedResponse!.toInt()], [0, 0, 2, 0]);
    expect(
      [for (final r in reads) r.returnedData.single.toInt()],
      [0x1122aa44, 0, 0x1122aa44, 0x77],
    );
    expect([for (final r in reads) r.returnedResponse!.toInt()], [0, 2, 0, 0]);
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

    Axi4SubordinateAgent(
      sIntf: bench.sIntf,
      channels: [bench.channel],
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
    for (final i in [bench.wIntf, bench.rIntf]) {
      final pre = i == bench.wIntf ? 'AW' : 'AR';
      i.port('${pre}SIZE') <= Const(2, width: 3);
      i.port('${pre}BURST') <= Const(1, width: 2);
      i.port('${pre}CACHE') <= Const(0, width: 4);
      i.port('${pre}QOS') <= Const(0, width: 4);
      i.port('${pre}REGION') <= Const(0, width: 4);
    }
    bench.wIntf.wLast <= Const(1);
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

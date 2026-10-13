import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart'
    show
        Axi4Channel,
        Axi4MainAgent,
        Axi4ReadComplianceChecker,
        Axi4ReadRequestPacket,
        Axi4WriteComplianceChecker,
        Axi4WriteRequestPacket;
import 'package:rohd_vf/rohd_vf.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import '../port/port_harness.dart';
import 'axi4_fabric_harness.dart';

const _masters = [MasterCfg('m0', 4, 8)];
const _slaves = [
  SlaveCfg('s0', 5, 4, 0x00000, 0x10000),
  SlaveCfg('s1', 2, 2, 0x10000, 0x10000),
];

Axi4ReadInterface _r(int id) => Axi4ReadInterface(
  idWidth: id,
  addrWidth: addrW,
  dataWidth: dataW,
  aruserWidth: 0,
  ruserWidth: 0,
);

Axi4WriteInterface _w(int id) => Axi4WriteInterface(
  idWidth: id,
  addrWidth: addrW,
  dataWidth: dataW,
  awuserWidth: 0,
  wuserWidth: 0,
  buserWidth: 0,
);

// rohd_hcl interfaces on the master port, where the manager agent drives,
// and on s0, where the checkers only watch.
class _Bench extends Test {
  final Axi4SystemInterface sIntf = Axi4SystemInterface();
  final Axi4ReadInterface rIntf = _r(4);
  final Axi4WriteInterface wIntf = _w(4);
  final Axi4ReadInterface sR = _r(5);
  final Axi4WriteInterface sW = _w(5);
  late final Axi4Channel channel = Axi4Channel(rIntf: rIntf, wIntf: wIntf);
  final Future<void> Function() body;

  _Bench(this.body) : super('axi4_fabric_bfm', randomSeed: 1) {
    printLevel = failLevel;
    Simulator.setMaxSimTime(400000);
    sIntf.clk <= SimpleClockGenerator(10).clk;
    sIntf.resetN.put(0);
    Axi4ReadComplianceChecker(sIntf, rIntf, parent: this);
    Axi4WriteComplianceChecker(sIntf, wIntf, parent: this);
    Axi4ReadComplianceChecker(sIntf, sR, parent: this, name: 's0_read');
    Axi4WriteComplianceChecker(sIntf, sW, parent: this, name: 's0_write');
  }

  @override
  Future<void> run(Phase phase) async {
    unawaited(super.run(phase));
    final obj = phase.raiseObjection('bench');
    await sIntf.clk.waitCycles(2);
    sIntf.resetN.inject(1);
    await sIntf.clk.waitCycles(2);
    await body();
    obj.drop();
  }
}

Logic _pin(Axi4ReadInterface r, Axi4WriteInterface w, String name) =>
    w.tryPort(name) ?? r.port(name);

LogicValue _v(int value, int width) => LogicValue.ofInt(value, width);

Axi4WriteRequestPacket _write(int id, int addr, List<int> data) =>
    Axi4WriteRequestPacket(
      addr: _v(addr, addrW),
      prot: _v(0, 3),
      id: _v(id, 4),
      len: _v(data.length - 1, 8),
      size: _v(2, 3),
      burst: _v(1, 2),
      lock: _v(0, 1),
      cache: _v(0, 4),
      qos: _v(0, 4),
      region: _v(0, 4),
      data: [for (final d in data) _v(d, dataW)],
      strobe: [for (final _ in data) _v(0xf, 4)],
    );

Axi4ReadRequestPacket _read(int id, int addr, int len, {int burst = 1}) =>
    Axi4ReadRequestPacket(
      addr: _v(addr, addrW),
      prot: _v(0, 3),
      id: _v(id, 4),
      len: _v(len, 8),
      size: _v(2, 3),
      burst: _v(burst, 2),
      lock: _v(0, 1),
      cache: _v(0, 4),
      qos: _v(0, 4),
      region: _v(0, 4),
    );

final _fromManager = [
  for (final p in ['AW', 'AR']) ...[
    for (final f in [
      'ID',
      'ADDR',
      'LEN',
      'SIZE',
      'BURST',
      'LOCK',
      'CACHE',
      'PROT',
      'QOS',
      'VALID',
    ])
      '$p$f',
  ],
  'WDATA',
  'WSTRB',
  'WLAST',
  'WVALID',
  'BREADY',
  'RREADY',
];
const _fromSubordinate = [
  'AWREADY',
  'WREADY',
  'BID',
  'BRESP',
  'BVALID',
  'ARREADY',
  'RID',
  'RDATA',
  'RRESP',
  'RLAST',
  'RVALID',
];

// The manager BFM is trusted only while READY is high as VALID rises, and
// the checkers count VALID without READY. So the memories never stall,
// reads go to one slave at a time, and each write ends before the next.
Future<void> _bfm(HarborFabricTopology topology) async {
  final shell = FabricShell(topology, masters: _masters, slaves: _slaves);
  late final Axi4MainAgent main;
  late final Sim sim;
  final errors = <String>[];
  final bResp = <(int, int)>[];
  final rBeats = <(int, int, int, int)>[];

  final bench = _Bench(() async {
    sim.running = true;
    final wr = main.getWrSequencer(0)!;
    final rd = main.getRdSequencer(0)!;
    final writes = [
      (1, 0x00100, [0x11111111]),
      (2, 0x00140, [for (var i = 0; i < 4; i++) 0x2000 + i]),
      (3, 0x10200, [for (var i = 0; i < 16; i++) 0x3000 + i]),
      (4, unmapped, [0x5, 0x6]),
    ];
    for (var k = 0; k < writes.length; k++) {
      final (id, addr, data) = writes[k];
      wr.add(_write(id, addr, data));
      await waitUntil(sim, () => bResp.length == k + 1);
    }
    for (final (reads, beats) in [
      ([_read(5, 0x00100, 0), _read(6, 0x00140, 3)], 5),
      ([_read(7, 0x10200, 15), _read(8, 0x10208, 3, burst: 2)], 25),
      ([_read(9, unmapped + 0x10, 1)], 27),
    ]) {
      reads.forEach(rd.add);
      await waitUntil(sim, () => rBeats.length == beats);
    }
  });
  main = Axi4MainAgent(
    sIntf: bench.sIntf,
    channels: [bench.channel],
    parent: bench,
  );

  shell.input('clk').srcConnection! <= bench.sIntf.clk;
  shell.input('reset').srcConnection! <= ~bench.sIntf.resetN;
  for (final p in _fromManager) {
    shell.input('m0_$p').srcConnection! <= _pin(bench.rIntf, bench.wIntf, p);
  }
  for (final p in _fromSubordinate) {
    _pin(bench.rIntf, bench.wIntf, p) <= shell.output('m0_$p');
  }
  for (final p in _fromManager) {
    _pin(bench.sR, bench.sW, p) <= shell.output('s0_$p');
  }
  for (final p in _fromSubordinate) {
    _pin(bench.sR, bench.sW, p) <= shell.input('s0_$p').srcConnection!;
  }
  bench.sW.awRegion! <= Const(0, width: 4);
  bench.sR.arRegion! <= Const(0, width: 4);
  for (final input in shell.inputs.values) {
    if (input.name.startsWith('s')) input.srcConnection!.put(0);
  }
  sim = Sim(shell, clk: bench.sIntf.clk)..attach();
  final rng = Random(3);
  final mems = [
    for (final s in _slaves)
      AxiMemory(
        sim,
        s.name,
        rng,
        busBytes: busBytes,
        outstanding: s.outstanding,
        errors: errors,
        errBase: 1 << 40,
        stall: 0,
      ),
  ];
  sim.onRise(() {
    if (sim.pre('m0_BVALID') == 1 && sim.pre('m0_BREADY') == 1) {
      bResp.add((sim.pre('m0_BID'), sim.pre('m0_BRESP')));
    }
    if (sim.pre('m0_RVALID') == 1 && sim.pre('m0_RREADY') == 1) {
      rBeats.add((
        sim.pre('m0_RID'),
        sim.pre('m0_RDATA'),
        sim.pre('m0_RRESP'),
        sim.pre('m0_RLAST'),
      ));
    }
  });
  await shell.build();
  await bench.start();

  must(errors, isEmpty);
  must(bResp, [(1, 0), (2, 0), (3, 0), (4, 3)]);
  // Beats of different IDs may interleave, so compare them per ID.
  Map<int, List<(int, int, int, int)>> perId(List<(int, int, int, int)> x) {
    final out = <int, List<(int, int, int, int)>>{};
    for (final b in x) {
      out.putIfAbsent(b.$1, () => []).add(b);
    }
    return out;
  }

  must(
    perId(rBeats),
    perId([
      (5, 0x11111111, 0, 1),
      for (var i = 0; i < 4; i++) (6, 0x2000 + i, 0, i == 3 ? 1 : 0),
      for (var i = 0; i < 16; i++) (7, 0x3000 + i, 0, i == 15 ? 1 : 0),
      for (final i in [2, 3, 0, 1]) (8, 0x3000 + i, 0, i == 1 ? 1 : 0),
      (9, 0, 3, 0),
      (9, 0, 3, 1),
    ]),
  );
  must(mems.every((m) => m.awOrder.isNotEmpty), isTrue);
}

void main() {
  for (final t in HarborFabricTopology.values) {
    test(
      '${t.name} fabric under the rohd_hcl manager BFM and checkers',
      () => isolated(() => _bfm(t)),
    );
  }
}

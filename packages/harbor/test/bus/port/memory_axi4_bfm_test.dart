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
        Axi4SubordinateAgent,
        Axi4WriteComplianceChecker,
        Axi4WriteRequestPacket;
import 'package:rohd_vf/rohd_vf.dart';
import 'package:test/test.dart';

import 'memory_harness.dart';
import 'port_harness.dart';

const _config = HarborMemoryWaistConfig(
  addressWidth: 16,
  dataWidth: 32,
  idWidth: 4,
  outstanding: 8,
);

/// rohd_hcl AXI4 interfaces with the widths of [_config] and no USER.
class _Bench extends Test {
  final Axi4SystemInterface sIntf = Axi4SystemInterface();
  final Axi4ReadInterface rIntf = Axi4ReadInterface(
    idWidth: 4,
    addrWidth: 16,
    dataWidth: 32,
    aruserWidth: 0,
    ruserWidth: 0,
  );
  final Axi4WriteInterface wIntf = Axi4WriteInterface(
    idWidth: 4,
    addrWidth: 16,
    dataWidth: 32,
    awuserWidth: 0,
    wuserWidth: 0,
    buserWidth: 0,
  );
  late final Axi4Channel channel = Axi4Channel(rIntf: rIntf, wIntf: wIntf);
  final Future<void> Function(_Bench bench) body;

  _Bench(super.name, this.body) : super(randomSeed: 1) {
    printLevel = failLevel;
    Simulator.setMaxSimTime(200000);
    sIntf.clk <= SimpleClockGenerator(10).clk;
    sIntf.resetN.put(0);
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

const _fromManager = [
  'AWID',
  'AWADDR',
  'AWLEN',
  'AWSIZE',
  'AWBURST',
  'AWLOCK',
  'AWCACHE',
  'AWPROT',
  'AWQOS',
  'AWVALID',
  'WDATA',
  'WSTRB',
  'WLAST',
  'WVALID',
  'BREADY',
  'ARID',
  'ARADDR',
  'ARLEN',
  'ARSIZE',
  'ARBURST',
  'ARLOCK',
  'ARCACHE',
  'ARPROT',
  'ARQOS',
  'ARVALID',
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

Logic _pin(_Bench b, String name) =>
    b.wIntf.tryPort(name) ?? b.rIntf.port(name);

LogicValue _v(int value, int width) => LogicValue.ofInt(value, width);

Axi4WriteRequestPacket _write(int id, int addr, List<int> data) =>
    Axi4WriteRequestPacket(
      addr: _v(addr, 16),
      prot: _v(0, 3),
      id: _v(id, 4),
      len: _v(data.length - 1, 8),
      size: _v(2, 3),
      burst: _v(1, 2),
      lock: _v(0, 1),
      cache: _v(0, 4),
      qos: _v(0, 4),
      region: _v(0, 4),
      data: [for (final d in data) _v(d, 32)],
      strobe: [for (final _ in data) _v(0xf, 4)],
    );

Axi4ReadRequestPacket _read(int id, int addr, int len, {int burst = 1}) =>
    Axi4ReadRequestPacket(
      addr: _v(addr, 16),
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

void main() {
  tearDown(endAndReset);

  // The manager BFM is trusted only while READY is already high when it
  // raises VALID. So the memory never stalls, the reads in flight stay at or
  // below the outstanding depth, and each write ends before the next starts.
  test('slave port under the rohd_hcl manager BFM', () async {
    final dut = MemSlaveShell(_config);
    late final Axi4MainAgent main;
    late final Sim sim;
    late final WaistMemory mem;
    final errors = <String>[];
    final bResp = <(int, int)>[];
    final rBeats = <(int, int, int, int)>[];

    final bench = _Bench('axi4_mem_slave_bfm', (b) async {
      sim.running = true;
      final wr = main.getWrSequencer(0)!;
      final rd = main.getRdSequencer(0)!;
      final writes = [
        (1, 0x000, [0x11111111]),
        (2, 0x040, [for (var i = 0; i < 4; i++) 0x2000 + i]),
        (3, 0x100, [for (var i = 0; i < 16; i++) 0x3000 + i]),
        (4, 0xf000, [0x5]),
      ];
      for (var k = 0; k < writes.length; k++) {
        final (id, addr, data) = writes[k];
        wr.add(_write(id, addr, data));
        await waitUntil(sim, () => bResp.length == k + 1);
      }
      rd
        ..add(_read(5, 0x000, 0))
        ..add(_read(6, 0x040, 3))
        ..add(_read(7, 0x100, 15))
        ..add(_read(8, 0x048, 3, burst: 2))
        ..add(_read(9, 0xffc, 1))
        ..add(_read(10, 0xf000, 0));
      await waitUntil(sim, () => rBeats.length == 1 + 4 + 16 + 4 + 2 + 1);
    });

    main = Axi4MainAgent(
      sIntf: bench.sIntf,
      channels: [bench.channel],
      parent: bench,
    );

    dut.input('clk').srcConnection! <= bench.clk;
    dut.input('reset').srcConnection! <= ~bench.sIntf.resetN;
    for (final p in _fromManager) {
      dut.input('bus_$p').srcConnection! <= _pin(bench, p);
    }
    for (final p in _fromSubordinate) {
      _pin(bench, p) <= dut.output('bus_$p');
    }
    for (final input in dut.inputs.values) {
      if (input.name.startsWith('mem_')) input.srcConnection!.put(0);
    }
    sim = Sim(dut, clk: bench.clk)..attach();
    mem = WaistMemory(
      sim,
      'mem',
      Random(1),
      outstanding: _config.outstanding,
      busBytes: 4,
      errors: errors,
      stall: 0,
    );
    sim.onRise(() {
      if (sim.pre('bus_BVALID') == 1 && sim.pre('bus_BREADY') == 1) {
        bResp.add((sim.pre('bus_BID'), sim.pre('bus_BRESP')));
      }
      if (sim.pre('bus_RVALID') == 1 && sim.pre('bus_RREADY') == 1) {
        rBeats.add((
          sim.pre('bus_RID'),
          sim.pre('bus_RDATA'),
          sim.pre('bus_RRESP'),
          sim.pre('bus_RLAST'),
        ));
      }
    });
    await dut.build();
    await bench.start();

    expect(errors, isEmpty);
    expect(bResp, [(1, 0), (2, 0), (3, 0), (4, 2)]);
    final want = <(int, int, int, int)>[
      (5, 0x11111111, 0, 1),
      for (var i = 0; i < 4; i++) (6, 0x2000 + i, 0, i == 3 ? 1 : 0),
      for (var i = 0; i < 16; i++) (7, 0x3000 + i, 0, i == 15 ? 1 : 0),
      for (final i in [2, 3, 0, 1]) (8, 0x2000 + i, 0, i == 1 ? 1 : 0),
      (9, 0, 2, 0),
      (9, 0, 2, 1),
      (10, 0, 2, 1),
    ];
    expect(rBeats, want);
    expect(mem.maxInflight, greaterThan(1));
  });

  // The subordinate BFM drops W that comes before its AW and keeps one
  // write in progress, so the requester sends write data only after the
  // request and uses one ID.
  test('master port against the rohd_hcl subordinate BFM', () async {
    final dut = MemMasterShell(_config);
    late final Sim sim;
    late final WaistRequester req;
    final errors = <String>[];

    final bench = _Bench('axi4_mem_master_bfm', (b) async {
      sim.running = true;
      Burst w(int addr, int beats) => Burst(
        id: 1,
        write: true,
        addr: addr,
        len: beats - 1,
        size: 2,
        burst: 1,
        data: [for (var i = 0; i < beats; i++) addr * 0x100 + i],
        strb: List.filled(beats, 0xf),
      );
      Burst r(int addr, int beats) => Burst(
        id: 2,
        write: false,
        addr: addr,
        len: beats - 1,
        size: 2,
        burst: 1,
      );
      // The BFM also takes a W beat twice when an AW lands with a W of the
      // write before it, so the writes go one at a time.
      for (final x in [w(0x0, 1), w(0x40, 4), w(0x100, 16), w(0xf000, 2)]) {
        req.send(x);
        await waitUntil(sim, () => req.done && req.req.idleNow);
      }
      for (final x in [r(0x0, 1), r(0x40, 4), r(0x100, 16), r(0xf000, 2)]) {
        req.send(x);
      }
      await waitUntil(sim, () => req.done && req.req.idleNow);
    });

    Axi4SubordinateAgent(
      sIntf: bench.sIntf,
      channels: [bench.channel],
      parent: bench,
      respondWithError: (p) => p.addr.toInt() >= 0xf000,
    );

    dut.input('clk').srcConnection! <= bench.clk;
    dut.input('reset').srcConnection! <= ~bench.sIntf.resetN;
    for (final p in _fromSubordinate) {
      dut.input('bus_$p').srcConnection! <= _pin(bench, p);
    }
    for (final p in _fromManager) {
      _pin(bench, p) <= dut.output('bus_$p');
    }
    bench.wIntf.awRegion! <= Const(0, width: 4);
    bench.rIntf.arRegion! <= Const(0, width: 4);
    for (final p in _fromSubordinate) {
      _pin(bench, p).put(0);
    }
    for (final input in dut.inputs.values) {
      if (input.name.startsWith('mem_')) input.srcConnection!.put(0);
    }
    sim = Sim(dut, clk: bench.clk)..attach();
    req = WaistRequester(sim, 'mem', Random(2), errors: errors, stall: 0);
    masterPortChecks(sim, 'bus', 'mem', errors);
    await dut.build();
    await bench.start();

    expect(errors, isEmpty);
    expect(req.writeResp, [(1, 0), (1, 0), (1, 0), (1, 1)]);
    expect(req.readResp.map((beats) => [for (final x in beats) x.$2]), [
      [0],
      for (final a in [0x40, 0x100])
        [for (var i = 0; i < (a == 0x40 ? 4 : 16); i++) a * 0x100 + i],
      [0, 0],
    ]);
    expect(req.readResp.last.map((x) => x.$3), [1, 1]);
    expect(req.readResp.expand((beats) => beats.map((x) => x.$1)).toSet(), {2});
  });
}

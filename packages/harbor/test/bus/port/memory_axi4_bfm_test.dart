import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_hcl/rohd_hcl.dart'
    show
        Axi4DataPacket,
        Axi4MainClusterAgent,
        Axi4ReadCluster,
        Axi4RequestPacket,
        Axi4SubordinateClusterAgent,
        Axi4SubordinateMemoryAgent,
        Axi4WriteCluster;
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
  final Axi4ReadCluster rIntf = Axi4ReadCluster(
    idWidth: 4,
    addrWidth: 16,
    dataWidth: 32,
    userWidth: 0,
    useLock: true,
  );
  final Axi4WriteCluster wIntf = Axi4WriteCluster(
    idWidth: 4,
    addrWidth: 16,
    dataWidth: 32,
    userWidth: 0,
    useLock: true,
  );
  final Future<void> Function(_Bench bench) body;

  /// Whether this bench drives the manager side.
  final bool managerSide;

  _Bench(super.name, this.body, {this.managerSide = false})
    : super(randomSeed: 1) {
    printLevel = failLevel;
    Simulator.setMaxSimTime(200000);
    sIntf.clk <= SimpleClockGenerator(10).clk;
    sIntf.resetN.put(0);
    // The rohd_hcl 0.3.0 compliance checkers count a VALID cycle as a beat
    // even when READY is low, so they reject any stalled transfer. The
    // assertions below check the same transactions directly instead.
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

LogicValue _v(int value, int width) => LogicValue.ofInt(value, width);

(Axi4RequestPacket, Axi4DataPacket) _write(int id, int addr, List<int> data) =>
    (
      Axi4RequestPacket(
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
      ),
      Axi4DataPacket(
        id: _v(id, 4),
        data: [for (final d in data) _v(d, 32)].rconcat(),
        strb: [for (final _ in data) _v(0xf, 4)].rconcat(),
      ),
    );

Axi4RequestPacket _read(int id, int addr, int len, {int burst = 1}) =>
    Axi4RequestPacket(
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
    late final Sim sim;
    late final WaistMemory mem;
    final errors = <String>[];
    final bResp = <(int, int)>[];
    final rBeats = <(int, int, int, int)>[];

    final bench = _Bench('axi4_mem_slave_bfm', managerSide: true, (b) async {
      sim.running = true;
      final wr = b.main.writeAgent.reqAgent.sequencer;
      final wd = b.main.writeAgent.dataAgent.sequencer!;
      final rd = b.main.readAgent.reqAgent.sequencer;
      final writes = [
        (1, 0x000, [0x11111111]),
        (2, 0x040, [for (var i = 0; i < 4; i++) 0x2000 + i]),
        (3, 0x100, [for (var i = 0; i < 16; i++) 0x3000 + i]),
        (4, 0xf000, [0x5]),
      ];
      for (var k = 0; k < writes.length; k++) {
        final (id, addr, data) = writes[k];
        final (request, payload) = _write(id, addr, data);
        wr.add(request);
        wd.add(payload);
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
  test(
    'master port against the rohd_hcl subordinate BFM',
    () async {
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
        respondWithError: (p) => p.addr.toInt() >= 0xf000,
      );

      final reset = ~bench.sIntf.resetN;
      dut.input('clk').srcConnection! <= bench.clk;
      dut.input('reset').srcConnection! <= reset;
      for (final p in _fromSubordinate) {
        dut.input('bus_$p').srcConnection! <= _pin(bench, p);
      }
      for (final p in _fromManager) {
        _pin(bench, p) <= dut.output('bus_$p');
      }
      bench.wIntf.awIntf.region! <= Const(0, width: 4);
      bench.rIntf.arIntf.region! <= Const(0, width: 4);
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
      expect(req.readResp.expand((beats) => beats.map((x) => x.$1)).toSet(), {
        2,
      });
    },
    skip:
        'rohd_hcl 0.3.0 Axi4SubordinateMemoryAgent re-reads live request '
        'signals after its monitor fires, so a manager that clears AW/AR '
        'payloads on the handshake loses IDs and addresses. Re-enable when '
        'the upstream agent uses the monitor packet.',
  );
}

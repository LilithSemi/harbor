// A 64-bit AXI4 fabric with a full master and a 32-bit AXI4-Lite slave
// whose address is 16 bits wide. The fabric puts a width adapter in front
// of the slave.

import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import '../port/port_harness.dart';
import 'axi4_fabric_harness.dart'
    show exposeInterface, forEachPipeline, harnessPipeline, must;

const _liteBase = 0x10000;

class _Shell extends BridgeModule {
  _Shell(HarborFabricTopology t)
    : super('NarrowAxiShell_${t.name}', name: 'shell') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final m = Axi4Interface(addressWidth: 20, dataWidth: 64, idWidth: 2);
    exposeInterface(this, m, 'm', PairDirection.fromProvider);
    final f = Axi4Interface(addressWidth: 20, dataWidth: 64, idWidth: 2);
    exposeInterface(this, f, 'f', PairDirection.fromConsumer);
    final l = Axi4LiteInterface(addressWidth: 16, dataWidth: 32);
    exposeInterface(this, l, 'l', PairDirection.fromConsumer);
    final fabric = HarborFabric.build(
      kind: HarborFabricKind.axi4,
      pipeline: harnessPipeline,
      topology: t,
      clk: input('clk'),
      reset: input('reset'),
      masters: [HarborFabricMaster(name: 'm', interface: m, outstanding: 8)],
      slaves: [
        HarborFabricSlave(
          name: 'f',
          range: const BusAddressRange(0, 0x10000),
          interface: f,
          outstanding: 4,
        ),
        HarborFabricSlave(
          name: 'l',
          range: const BusAddressRange(_liteBase, 0x1000),
          interface: l,
          memory: false,
          offset: true,
          narrowOk: true,
        ),
      ],
    );
    createPort('bus_error', PortDirection.output);
    output('bus_error') <= fabric.busError;
  }
}

Burst _w(int id, int addr, int len, int size, List<int> data, List<int> strb) =>
    Burst(
      id: id,
      write: true,
      addr: addr,
      len: len,
      size: size,
      burst: 1,
      data: data,
      strb: strb,
    );

Burst _r(int id, int addr, int len, int size) =>
    Burst(id: id, write: false, addr: addr, len: len, size: size, burst: 1);

Future<void> _run(HarborFabricTopology t) async {
  final sim = Sim(_Shell(t));
  final rng = Random(5);
  final errors = <String>[];
  final m = AxiManager(sim, 'm', rng, stall: 0.2);
  final f = AxiMemory(
    sim,
    'f',
    rng,
    busBytes: 8,
    outstanding: 4,
    errors: errors,
    errBase: 1 << 40,
    stall: 0.2,
  );
  final l = AxiMemory(
    sim,
    'l',
    rng,
    busBytes: 4,
    outstanding: 1,
    errors: errors,
    stall: 0.2,
    lite: true,
  );
  await sim.start();
  Simulator.setMaxSimTime(4000000);
  Future<void> drain() => waitUntil(
    sim,
    () =>
        m.aw.idleNow &&
        m.bResp.length == m.awOrder.length &&
        m.ar.idleNow &&
        m.rBeats.length == m.readBeatsExpected,
    limit: 40000,
  );
  final lane0 = _liteBase + 0x10;
  final lane1 = _liteBase + 0x24;

  // 32-bit stores, one in each word of a 64-bit beat.
  m
    ..write(_w(0, lane0, 0, 2, [0xaabbccdd], [0x0f]))
    ..write(_w(1, lane1, 0, 2, [0x11223344 << 32], [0xf0]));
  await drain();
  must(l.mem.read(0x10), 0xaabbccdd);
  must(l.mem.read(0x24), 0x11223344);
  must(l.awOrder.map((x) => x.addr).toList(), [0x10, 0x24]);

  // 32-bit loads come back in the lane of their address.
  m
    ..read(_r(0, lane0, 0, 2))
    ..read(_r(1, lane1, 0, 2));
  await drain();
  must(
    m.rBeats.map((x) => (x.$1, x.$2, x.$3)).toList(),
    unorderedEquals([(0, 0xaabbccdd, 0), (1, 0x11223344 << 32, 0)]),
  );

  // A store with strobes in both words gets SLVERR and never reaches the
  // slave.
  final seen = l.awOrder.length;
  m.write(_w(2, lane0, 0, 3, [0x1122334455667788], [0xff]));
  await drain();
  must(l.awOrder.length, seen);
  must(m.bResp.where((x) => x.$1 == 2).map((x) => x.$2).toList(), [2]);

  // A burst of 32-bit beats runs as single beats, one word each.
  m.write(_w(3, lane0, 1, 2, [1, 2 << 32], [0x0f, 0xf0]));
  await drain();
  m.read(_r(3, lane0, 1, 2));
  await drain();
  must(l.awOrder.map((x) => x.addr).toList().skip(seen).toList(), [0x10, 0x14]);
  must(m.bResp.where((x) => x.$1 == 3).map((x) => x.$2).toList(), [0]);
  must(m.rBeats.where((x) => x.$1 == 3).map((x) => (x.$2, x.$3)).toList(), [
    (1, 0),
    (2 << 32, 0),
  ]);

  // A burst of full-size beats with one lane of strobes in each beat.
  m.write(_w(2, lane0, 1, 3, [3, 4], [0x0f, 0x0f]));
  await drain();
  m.read(_r(1, lane0, 3, 3));
  await drain();
  must(l.awOrder.length, seen + 4);
  must(l.arOrder.length, 8);
  must(m.bResp.where((x) => x.$1 == 2).map((x) => x.$2).toList(), [2, 0]);
  must(m.rBeats.where((x) => x.$1 == 1).map((x) => x.$3).toList(), [
    0,
    0,
    0,
    0,
    0,
  ]);
  must(l.mem.read(0x10), 3);
  must(l.mem.read(0x18), 4);

  // The slave still works, and so does the full slave.
  m.write(_w(0, _liteBase + 0x30, 0, 2, [0x55], [0x0f]));
  await drain();
  m.read(_r(2, _liteBase + 0x30, 0, 2));
  await drain();
  must(m.rBeats.last.$2, 0x55);
  final busError = sim.pre('bus_error');
  await sim.stop();
  must(busError, 0);
  must(errors, isEmpty);
  must(f.awOrder, isEmpty);
}

void main() {
  forEachPipeline((p) {
    tearDown(() async => Simulator.reset());
    for (final t in HarborFabricTopology.values) {
      test(
        '${t.name}: a 32-bit lite slave on a 64-bit AXI4 fabric',
        () async {
          await _run(t);
        },
        timeout: const Timeout(Duration(minutes: 5)),
      );
    }
  });
}

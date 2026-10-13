import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'memory_harness.dart';
import 'port_harness.dart';

/// A waist requester, the master port and an AXI4 memory.
class _Bench {
  final HarborMemoryWaistConfig config;
  final Sim sim;
  final Random rng;
  final List<String> errors = [];
  late final WaistRequester req;
  late final AxiMemory axi;
  late final BurstGen gen;

  int get busBytes => config.strbWidth;

  _Bench(
    this.config, {
    int seed = 1,
    bool earlyData = false,
    double idle = 0.2,
    double stall = 0.3,
    double axiStall = 0.3,
    double errorRate = 0,
  }) : sim = Sim(MemMasterShell(config)),
       rng = Random(seed) {
    req = WaistRequester(
      sim,
      'mem',
      rng,
      errors: errors,
      earlyData: earlyData,
      idle: idle,
      stall: stall,
    );
    axi = AxiMemory(
      sim,
      'bus',
      rng,
      busBytes: busBytes,
      outstanding: config.outstanding,
      errors: errors,
      stall: axiStall,
    );
    gen = BurstGen(
      rng,
      busBytes: busBytes,
      idWidth: config.idWidth,
      errors: errorRate,
    );
    masterPortChecks(sim, 'bus', 'mem', errors);
  }

  Future<void> start() async {
    await sim.start();
    Simulator.setMaxSimTime(10000000);
  }

  Future<void> drain() => waitUntil(sim, () => req.done && req.req.idleNow);

  int _err(Burst x) => x.addr >= 0xf000 ? 1 : 0;

  void check() {
    expect(errors, isEmpty);
    expect(axi.awOrder.length, req.writes.length);
    expect(axi.arOrder.length, req.reads.length);
    expect(<String>[
      for (var k = 0; k < req.writes.length; k++)
        ?diffReq(req.writes[k], axi.awOrder[k]),
      for (var k = 0; k < req.reads.length; k++)
        ?diffReq(req.reads[k], axi.arOrder[k]),
    ], isEmpty);
    // The AXI model can answer different IDs out of order, so only a
    // response's own ID queue has to stay in issue order.
    expect(
      diffPerId<Burst, (int, int)>(
        want: req.writes,
        got: req.writeResp,
        wantId: (x) => x.id,
        gotId: (r) => r.$1,
        matches: (x, r) => r.$2 == _err(x),
      ),
      isEmpty,
    );
    final bad = <String>[];
    for (var k = 0; k < req.reads.length; k++) {
      final x = req.reads[k];
      final want = [
        for (var i = 0; i < x.beats; i++)
          (x.id, axi.readData[k][i], _err(x), i == x.len ? 1 : 0),
      ];
      if (req.readResp[k].toString() != want.toString()) {
        bad.add('$x: got ${req.readResp[k]} want $want');
      }
    }
    expect(bad, isEmpty);
    expect(diffMemory(golden(req.writes, busBytes), axi.mem), isEmpty);
  }
}

Future<_Bench> _random(
  HarborMemoryWaistConfig config, {
  required int seed,
  int count = 120,
  bool oneId = false,
  bool earlyData = false,
  double idle = 0.2,
  double stall = 0.3,
  double axiStall = 0.3,
}) async {
  final b = _Bench(
    config,
    seed: seed,
    earlyData: earlyData,
    idle: idle,
    stall: stall,
    axiStall: axiStall,
    errorRate: 0.05,
  );
  await b.start();
  for (var i = 0; i < count; i++) {
    final write = b.rng.nextBool();
    b.req.send(b.gen.next(write: write, id: oneId ? (write ? 1 : 2) : null));
  }
  await b.drain();
  b.check();
  await b.sim.stop();
  return b;
}

void main() {
  tearDown(endAndReset);

  const c32 = HarborMemoryWaistConfig(
    addressWidth: 16,
    dataWidth: 32,
    idWidth: 4,
    outstanding: 4,
  );

  test('random IDs against a memory that reorders IDs', () async {
    await _random(c32, seed: 11);
  });

  test('one ID per direction keeps N requests in flight', () async {
    final b = await _random(c32, seed: 12, oneId: true, idle: 0);
    expect(b.axi.maxInflight, 4);
  });

  test(
    'mixed IDs also reach N in flight, with no drain at an ID change',
    () async {
      final b = await _random(c32, seed: 16, idle: 0);
      expect(b.axi.maxInflight, 4);
    },
  );

  test('AR id 2 overtakes id 1 when the model answers it first', () async {
    final b = _Bench(c32, seed: 20, idle: 0, stall: 0, axiStall: 0);
    // Hold both reads pending together before letting either answer, then
    // make id 2 the one the model always prefers.
    b.axi.holdResponses = true;
    b.axi.preferId = 2;
    final order = <int>[];
    b.sim.onRise(() {
      if (b.sim.pre('mem_RDATA_VALID') == 1 &&
          b.sim.pre('mem_RDATA_READY') == 1 &&
          b.sim.pre('mem_RDATA_LAST') == 1) {
        order.add(b.sim.pre('mem_RDATA_ID'));
      }
    });
    await b.start();
    b.req.send(
      Burst(id: 1, write: false, addr: 0x10, len: 0, size: 2, burst: 1),
    );
    b.req.send(
      Burst(id: 2, write: false, addr: 0x20, len: 0, size: 2, burst: 1),
    );
    await b.sim.cycles(20);
    b.axi.holdResponses = false;
    await b.drain();
    b.check();
    expect(order, [2, 1]);
    await b.sim.stop();
  });

  test('B id 2 overtakes id 1 when the model answers it first', () async {
    final b = _Bench(c32, seed: 21, idle: 0, stall: 0, axiStall: 0);
    b.axi.holdResponses = true;
    b.axi.preferId = 2;
    final order = <int>[];
    b.sim.onRise(() {
      if (b.sim.pre('mem_WRESP_VALID') == 1 &&
          b.sim.pre('mem_WRESP_READY') == 1) {
        order.add(b.sim.pre('mem_WRESP_ID'));
      }
    });
    await b.start();
    Burst w(int id, int addr) => Burst(
      id: id,
      write: true,
      addr: addr,
      len: 0,
      size: 2,
      burst: 1,
      data: [addr],
      strb: [0xf],
    );
    b.req.send(w(1, 0x10));
    b.req.send(w(2, 0x20));
    await b.sim.cycles(20);
    b.axi.holdResponses = false;
    await b.drain();
    b.check();
    expect(order, [2, 1]);
    await b.sim.stop();
  });

  test('write data before the request reaches W before AW', () async {
    var wFirst = 0;
    var awSeen = 0;
    var wSeen = 0;
    final b = _Bench(c32, seed: 13, earlyData: true, axiStall: 0.5);
    b.sim.onRise(() {
      if (b.sim.pre('bus_AWVALID') == 1 && b.sim.pre('bus_AWREADY') == 1) {
        awSeen++;
      }
      if (b.sim.pre('bus_WVALID') == 1 &&
          b.sim.pre('bus_WREADY') == 1 &&
          b.sim.pre('bus_WLAST') == 1) {
        wSeen++;
        if (wSeen > awSeen) wFirst++;
      }
    });
    await b.start();
    for (var i = 0; i < 60; i++) {
      b.req.send(b.gen.next(write: b.rng.nextInt(4) != 0));
    }
    await b.drain();
    b.check();
    expect(wFirst, greaterThan(0));
    await b.sim.stop();
  });

  test('narrow bursts on a 64 bit bus with 8 outstanding', () async {
    await _random(
      const HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 64,
        idWidth: 3,
        outstanding: 8,
      ),
      seed: 14,
    );
  });

  test('one outstanding request', () async {
    final b = await _random(
      const HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 32,
        idWidth: 2,
        outstanding: 1,
      ),
      seed: 15,
      count: 60,
    );
    expect(b.axi.maxInflight, 1);
  });

  test('no backpressure streams one beat per cycle', () async {
    final b = _Bench(c32, idle: 0, stall: 0, axiStall: 0);
    final rCycles = <int>[];
    var cycle = 0;
    b.sim.onRise(() {
      cycle++;
      if (b.sim.pre('mem_RDATA_VALID') == 1 &&
          b.sim.pre('mem_RDATA_READY') == 1) {
        rCycles.add(cycle);
      }
    });
    await b.start();
    for (var i = 0; i < 4; i++) {
      b.req.send(
        Burst(id: 3, write: false, addr: i * 64, len: 15, size: 2, burst: 1),
      );
    }
    await b.drain();
    expect(rCycles.last - rCycles.first, 63);
    b.check();
    await b.sim.stop();
  });
}

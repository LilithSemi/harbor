import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'memory_harness.dart';
import 'port_harness.dart';

/// An AXI4 manager, the slave port and a memory behind its waist.
class _Bench {
  final HarborMemoryWaistConfig config;
  final Sim sim;
  final Random rng;
  final List<String> errors = [];
  late final AxiManager axi;
  late final WaistMemory mem;
  late final BurstGen gen;

  int get busBytes => config.strbWidth;

  _Bench(
    this.config, {
    int seed = 1,
    double awIdle = 0.3,
    double wIdle = 0.1,
    double arIdle = 0.3,
    double stall = 0.3,
    double memStall = 0.3,
    double illegal = 0,
    double errorRate = 0,
  }) : sim = Sim(MemSlaveShell(config)),
       rng = Random(seed) {
    axi = AxiManager(
      sim,
      'bus',
      rng,
      awIdle: awIdle,
      wIdle: wIdle,
      arIdle: arIdle,
      stall: stall,
    );
    mem = WaistMemory(
      sim,
      'mem',
      rng,
      outstanding: config.outstanding,
      busBytes: busBytes,
      errors: errors,
      stall: memStall,
    );
    gen = BurstGen(
      rng,
      busBytes: busBytes,
      idWidth: config.idWidth,
      illegal: illegal,
      errors: errorRate,
    );
    slavePortChecks(sim, 'bus', 'mem', errors);
  }

  Future<void> start() async {
    await sim.start();
    Simulator.setMaxSimTime(10000000);
  }

  bool get idle =>
      axi.bResp.length == axi.awOrder.length &&
      axi.aw.idleNow &&
      axi.ar.idleNow &&
      axi.rBeats.length == axi.readBeatsExpected;

  Future<void> drain() => waitUntil(sim, () => idle);

  /// The request the memory should see for [x].
  Burst forwarded(Burst x) => illegalBurst(x, busBytes)
      ? Burst(
          id: x.id,
          write: x.write,
          addr: x.addr,
          len: x.len,
          size: busBytes.bitLength - 1,
          burst: 0,
        )
      : x;

  bool failed(Burst x) => illegalBurst(x, busBytes) || x.addr >= 0xf000;

  /// Checks requests, responses and the memory against what the manager
  /// sent.
  void check() {
    expect(errors, isEmpty);
    expect(mem.writes.length, axi.awOrder.length);
    expect(mem.reads.length, axi.arOrder.length);
    final bad = <String>[
      for (var k = 0; k < axi.awOrder.length; k++)
        ?diffReq(forwarded(axi.awOrder[k]), mem.writes[k]),
      for (var k = 0; k < axi.arOrder.length; k++)
        ?diffReq(forwarded(axi.arOrder[k]), mem.reads[k]),
    ];
    expect(bad, isEmpty);

    expect(axi.bResp, [for (final x in axi.awOrder) (x.id, failed(x) ? 2 : 0)]);

    var beat = 0;
    final rBad = <String>[];
    for (var k = 0; k < axi.arOrder.length; k++) {
      final x = axi.arOrder[k];
      for (var i = 0; i < x.beats; i++) {
        final (id, data, resp, last) = axi.rBeats[beat++];
        final want = (
          x.id,
          illegalBurst(x, busBytes) ? 0 : mem.readData[k][i],
          failed(x) ? 2 : 0,
          i == x.len ? 1 : 0,
        );
        if ((id, data, resp, last) != want) {
          rBad.add('$x beat $i: got ${(id, data, resp, last)} want $want');
        }
      }
    }
    expect(rBad, isEmpty);
    expect(beat, axi.rBeats.length);

    expect(diffMemory(golden(axi.awOrder, busBytes), mem.mem), isEmpty);
  }

  /// Reads back every word below [span] and compares with the golden
  /// memory.
  Future<void> readBack(int span) async {
    final want = golden(axi.awOrder, busBytes);
    final first = axi.arOrder.length + axi.ar.queue.length;
    final beats = 16;
    final step = beats * busBytes;
    for (var a = 0; a < span; a += step) {
      axi.read(
        Burst(
          id: 0,
          write: false,
          addr: a,
          len: beats - 1,
          size: busBytes.bitLength - 1,
          burst: 1,
        ),
      );
    }
    final beat0 = axi.rBeats.length;
    await drain();
    final bad = <String>[];
    for (var k = 0; k < axi.arOrder.length - first; k++) {
      for (var i = 0; i < beats; i++) {
        final a = (k * beats + i) * busBytes;
        final got = axi.rBeats[beat0 + k * beats + i].$2;
        if (got != want.read(a)) {
          bad.add('0x${a.toRadixString(16)}: got $got want ${want.read(a)}');
        }
      }
    }
    expect(bad, isEmpty);
  }
}

Future<void> _random(
  HarborMemoryWaistConfig config, {
  required int seed,
  int count = 120,
  double illegal = 0.05,
  double errorRate = 0.05,
  double stall = 0.3,
  double memStall = 0.3,
}) async {
  final b = _Bench(
    config,
    seed: seed,
    illegal: illegal,
    errorRate: errorRate,
    stall: stall,
    memStall: memStall,
  );
  await b.start();
  for (var i = 0; i < count; i++) {
    if (b.rng.nextBool()) {
      b.axi.write(b.gen.next(write: true));
    } else {
      b.axi.read(b.gen.next(write: false));
    }
  }
  await b.drain();
  b.check();
  expect(b.mem.maxInflight, config.outstanding);
  await b.readBack(0x2000);
  b.check();
  await b.sim.stop();
}

void main() {
  tearDown(endAndReset);

  const c32 = HarborMemoryWaistConfig(
    addressWidth: 16,
    dataWidth: 32,
    idWidth: 4,
    outstanding: 4,
  );

  test('random bursts with IDs, errors and backpressure', () async {
    await _random(c32, seed: 1);
  });

  test('random bursts, another seed and a slow memory', () async {
    await _random(c32, seed: 7, memStall: 0.6, stall: 0.1);
  });

  test('random narrow bursts on a 64 bit bus with 8 outstanding', () async {
    await _random(
      const HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 64,
        idWidth: 3,
        outstanding: 8,
      ),
      seed: 3,
    );
  });

  test('one outstanding request', () async {
    await _random(
      const HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 32,
        idWidth: 2,
        outstanding: 1,
      ),
      seed: 5,
      count: 60,
    );
  });

  test('no backpressure streams one beat per cycle', () async {
    final b = _Bench(
      c32,
      awIdle: 0,
      wIdle: 0,
      arIdle: 0,
      stall: 0,
      memStall: 0,
    );
    final rCycles = <int>[];
    final wCycles = <int>[];
    var cycle = 0;
    b.sim.onRise(() {
      cycle++;
      if (b.sim.pre('bus_RVALID') == 1 && b.sim.pre('bus_RREADY') == 1) {
        rCycles.add(cycle);
      }
      if (b.sim.pre('mem_WDATA_VALID') == 1 &&
          b.sim.pre('mem_WDATA_READY') == 1) {
        wCycles.add(cycle);
      }
    });
    await b.start();
    for (var i = 0; i < 4; i++) {
      b.axi.read(
        Burst(id: i, write: false, addr: i * 64, len: 15, size: 2, burst: 1),
      );
    }
    await b.drain();
    // 64 beats with no gap.
    expect(rCycles.last - rCycles.first, 63);
    b.axi.write(
      Burst(
        id: 1,
        write: true,
        addr: 0x100,
        len: 15,
        size: 2,
        burst: 1,
        data: List.generate(16, (i) => i),
        strb: List.filled(16, 0xf),
      ),
    );
    await b.drain();
    expect(wCycles.last - wCycles.first, 15);
    b.check();
    await b.sim.stop();
  });

  test('W before AW is held to two beats until the AW comes', () async {
    final b = _Bench(
      c32,
      awIdle: 0,
      wIdle: 0,
      arIdle: 0,
      stall: 0,
      memStall: 0,
    );
    await b.start();
    final x = b.gen.next(write: true);
    final data = Burst(
      id: 2,
      write: true,
      addr: 0x40,
      len: 7,
      size: 2,
      burst: 1,
      data: List.generate(8, (i) => 0x1000 + i),
      strb: List.filled(8, 0xf),
    );
    for (var i = 0; i < data.beats; i++) {
      b.axi.w.queue.add({
        'bus_WDATA': data.data[i],
        'bus_WSTRB': 0xf,
        'bus_WLAST': i == 7 ? 1 : 0,
      });
    }
    var wdataSeen = 0;
    b.sim.onRise(() {
      if (b.sim.pre('mem_WDATA_VALID') == 1) wdataSeen++;
    });
    await b.sim.cycles(20);
    // Two beats taken, the rest wait, and none reach the memory.
    expect(b.axi.w.queue.length, data.beats - 3);
    expect(b.sim.pre('bus_WREADY'), 0);
    expect(wdataSeen, 0);
    b.axi.write(data, data: false);
    b.axi.write(x);
    await b.drain();
    b.check();
    expect(b.mem.mem.read(0x5c), 0x1007);
    await b.sim.stop();
  });

  test('every broken burst rule gets SLVERR and leaves memory alone', () async {
    final b = _Bench(c32, stall: 0.2, memStall: 0.2);
    await b.start();
    final cases = [
      (2, 2, 2, 0x100), // WRAP of 3 beats
      (2, 3, 2, 0x102), // WRAP not aligned
      (1, 15, 2, 0xffc), // INCR across 4 KB
      (1, 0, 3, 0x200), // SIZE wider than the bus
      (3, 0, 2, 0x300), // BURST 3
      (0, 16, 2, 0x400), // FIXED of 17 beats
    ];
    for (final (burst, len, size, addr) in cases) {
      b.axi.write(
        Burst(
          id: 5,
          write: true,
          addr: addr,
          len: len,
          size: size,
          burst: burst,
          data: List.filled(len + 1, 0xdeadbeef),
          strb: List.filled(len + 1, 0xf),
        ),
      );
      b.axi.read(
        Burst(
          id: 6,
          write: false,
          addr: addr,
          len: len,
          size: size,
          burst: burst,
        ),
      );
    }
    // One legal write and read after them.
    b.axi.write(
      Burst(
        id: 1,
        write: true,
        addr: 0x500,
        len: 0,
        size: 2,
        burst: 1,
        data: [0x55],
        strb: [0xf],
      ),
    );
    b.axi.read(
      Burst(id: 1, write: false, addr: 0x500, len: 0, size: 2, burst: 1),
    );
    await b.drain();
    b.check();
    expect(b.axi.bResp.map((r) => r.$2), [...List.filled(6, 2), 0]);
    expect(b.axi.rBeats.last.$2, 0x55);
    expect(b.mem.mem.words.length, 1);
    await b.sim.stop();
  });

  test('a waiting request holds while the other direction arrives', () async {
    final b = _Bench(
      c32,
      awIdle: 0,
      wIdle: 0,
      arIdle: 0,
      stall: 0,
      memStall: 0,
    );
    var open = true;
    b.mem.req.gate = () => open;
    await b.start();
    Burst w(int addr) => Burst(
      id: 1,
      write: true,
      addr: addr,
      len: 0,
      size: 2,
      burst: 1,
      data: [addr],
      strb: [0xf],
    );
    b.axi.write(w(0x10));
    await b.drain();
    // The last grant was a write, so a fair arbiter now prefers a read.
    open = false;
    b.axi.write(w(0x20));
    await b.sim.cycles(5);
    b.axi.read(
      Burst(id: 2, write: false, addr: 0x10, len: 0, size: 2, burst: 1),
    );
    await b.sim.cycles(5);
    open = true;
    await b.drain();
    b.check();
    expect(b.mem.writes.length, 2);
    expect(b.mem.reads.length, 1);
    await b.sim.stop();
  });

  test('a combinational device answering in the REQ cycle keeps the flag '
      'in step', () async {
    const combCfg = HarborMemoryWaistConfig(
      addressWidth: 16,
      dataWidth: 32,
      idWidth: 3,
      outstanding: 1,
    );
    final sim = Sim(MemSlaveCombShell(combCfg));
    final axi = AxiManager(
      sim,
      'bus',
      Random(1),
      awIdle: 0,
      wIdle: 0,
      arIdle: 0,
      stall: 0,
    );
    await sim.start();
    Simulator.setMaxSimTime(10000000);
    // Breaks the burst rules (BURST 3). The device is combinational, so
    // it answers in the same cycle as this REQ, with the flag forced
    // illegal.
    axi.read(Burst(id: 5, write: false, addr: 0x10, len: 0, size: 2, burst: 3));
    // Legal and 1 beat. The device answers this one in its REQ cycle
    // too. Before the fix, it reused the first read's stale flag and
    // got SLVERR with data forced to 0.
    axi.read(Burst(id: 6, write: false, addr: 0x20, len: 0, size: 2, burst: 1));
    await waitUntil(sim, () => axi.rBeats.length == 2);
    expect(axi.rBeats[0], (5, 0, 2, 1));
    expect(axi.rBeats[1], (6, 0x20, 0, 1));
    await sim.stop();
  });

  test('the factories build every kind', () {
    for (final kind in HarborFabricKind.values) {
      final slave = HarborMemorySlavePort.create(
        module: BridgeModule('MemTestFactorySlave_${kind.name}'),
        name: 'mem',
        kind: kind,
        config: c32,
        clk: Logic(),
        reset: Logic(),
      );
      final master = HarborMemoryMasterPort.create(
        module: BridgeModule('MemTestFactoryMaster_${kind.name}'),
        name: 'mem',
        kind: kind,
        config: c32,
        clk: Logic(),
        reset: Logic(),
      );
      final type = switch (kind) {
        HarborFabricKind.axi4 => Axi4Interface,
        HarborFabricKind.tilelink => TileLinkInterface,
        HarborFabricKind.wishbone => WishboneInterface,
      };
      expect(slave.interfaceRef.interface.runtimeType, type);
      expect(master.interfaceRef.interface.runtimeType, type);
      expect(slave.kind, kind);
      expect(master.waist.config, c32);
    }
  });
}

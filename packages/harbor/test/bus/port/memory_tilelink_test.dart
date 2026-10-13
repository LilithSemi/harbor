import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'memory_harness.dart';
import 'memory_native_harness.dart';
import 'port_harness.dart';

const _c32 = HarborMemoryWaistConfig(
  addressWidth: 16,
  dataWidth: 32,
  idWidth: 4,
  outstanding: 4,
);

const _c64 = HarborMemoryWaistConfig(
  addressWidth: 16,
  dataWidth: 64,
  idWidth: 3,
  outstanding: 8,
);

/// A TileLink manager, the slave port and a memory behind its waist.
class _SlaveBench {
  final HarborMemoryWaistConfig config;
  final Sim sim;
  final Random rng;
  final List<String> errors = [];
  late final TlManager tl;
  late final WaistMemory mem;
  late final TlGen gen;

  int get busBytes => config.strbWidth;

  _SlaveBench(
    this.config, {
    int seed = 1,
    double idle = 0.2,
    double stall = 0.3,
    double memStall = 0.3,
    double errorRate = 0.05,
    double denied = 0.1,
  }) : sim = Sim(MemSlaveShell(config, kind: HarborFabricKind.tilelink)),
       rng = Random(seed) {
    tl = TlManager(
      sim,
      'bus',
      rng,
      sources: 1 << config.idWidth,
      busBytes: busBytes,
      errors: errors,
      idle: idle,
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
    gen = TlGen(rng, busBytes: busBytes, errors: errorRate, denied: denied);
    StableCheck(sim, 'bus_D_VALID', 'bus_D_READY', [
      for (final f in ['OPCODE', 'SIZE', 'SOURCE', 'DATA', 'DENIED', 'CORRUPT'])
        'bus_D_$f',
    ], errors);
    StableCheck(sim, 'mem_REQ_VALID', 'mem_REQ_READY', [
      for (final f in ['ID', 'WRITE', 'ADDR', 'LEN', 'SIZE', 'BURST'])
        'mem_REQ_$f',
    ], errors);
    StableCheck(sim, 'mem_WDATA_VALID', 'mem_WDATA_READY', [
      'mem_WDATA_DATA',
      'mem_WDATA_STRB',
      'mem_WDATA_LAST',
    ], errors);
  }

  Future<void> start() async {
    await sim.start();
    Simulator.setMaxSimTime(20000000);
  }

  Future<void> drain() => waitUntil(sim, () => tl.done, limit: 200000);

  Burst _req(TlMsg m) => Burst(
    id: m.source,
    write: m.isPut,
    addr: m.addr,
    len: tlBeats(m.size, busBytes) - 1,
    size: min(m.size, log2(busBytes)),
    burst: 1,
  );

  /// The D beats [m] should get. [k] is its index among the legal Gets.
  List<DBeat> want(TlMsg m, int k) {
    final err = m.addr >= 0xf000 ? 1 : 0;
    if (gen.isLegal(m)) {
      if (m.isPut) return [(tlAccessAck, m.size, m.source, 0, err, 0)];
      return [
        for (var i = 0; i < tlBeats(m.size, busBytes); i++)
          (tlAccessAckData, m.size, m.source, mem.readData[k][i], err, err),
      ];
    }
    if (m.op == tlGet || m.op == tlArithmetic || m.op == tlLogical) {
      return [
        for (var i = 0; i < tlBeats(m.size, busBytes); i++)
          (tlAccessAckData, m.size, m.source, 0, 1, 1),
      ];
    }
    return [
      (m.op == tlIntent ? tlHintAck : tlAccessAck, m.size, m.source, 0, 1, 0),
    ];
  }

  void check() {
    expect(errors, isEmpty);
    final legal = tl.sent.where(gen.isLegal).toList();
    final gets = legal.where((m) => m.op == tlGet).toList();
    final puts = legal.where((m) => m.isPut).toList();
    expect(mem.reads.length, gets.length);
    expect(mem.writes.length, puts.length);
    expect(<String>[
      for (var k = 0; k < gets.length; k++)
        ?diffReq(_req(gets[k]), mem.reads[k]),
      for (var k = 0; k < puts.length; k++)
        ?diffReq(_req(puts[k]), mem.writes[k]),
    ], isEmpty);
    final bad = <String>[];
    var k = 0;
    for (final m in tl.sent) {
      final isGet = gen.isLegal(m) && m.op == tlGet;
      final w = want(m, k);
      if (isGet) k++;
      if (m.d.toString() != w.toString()) bad.add('$m: got ${m.d} want $w');
    }
    expect(bad, isEmpty);
    expect(
      diffMemory(tlGolden(tl.sent, busBytes, gen.isLegal), mem.mem),
      isEmpty,
    );
  }

  /// Reads back every word below [span] with 16 beat Gets.
  Future<void> readBack(int span) async {
    final want = tlGolden(tl.sent, busBytes, gen.isLegal);
    final size = log2(busBytes) + 4;
    final first = tl.sent.length + tl.pending.length;
    for (var a = 0; a < span; a += 1 << size) {
      tl.send(
        TlMsg(op: tlGet, size: size, addr: a, mask: [(1 << busBytes) - 1]),
      );
    }
    await drain();
    final bad = <String>[];
    for (final m in tl.sent.skip(first)) {
      for (var i = 0; i < m.d.length; i++) {
        final a = m.addr + i * busBytes;
        if (m.d[i].$4 != want.read(a)) {
          bad.add('0x${a.toRadixString(16)}: got ${m.d[i].$4}');
        }
      }
    }
    expect(bad, isEmpty);
  }
}

Future<void> _slaveRandom(
  HarborMemoryWaistConfig config, {
  required int seed,
  int count = 150,
  double idle = 0.2,
  double stall = 0.3,
  double memStall = 0.3,
}) async {
  final b = _SlaveBench(
    config,
    seed: seed,
    idle: idle,
    stall: stall,
    memStall: memStall,
  );
  await b.start();
  for (var i = 0; i < count; i++) {
    b.tl.send(b.gen.next());
  }
  await b.drain();
  b.check();
  expect(b.mem.maxInflight, config.outstanding);
  await b.readBack(0x2000);
  b.check();
  await b.sim.stop();
}

/// A waist requester, the master port and a TileLink memory.
class _MasterBench {
  final HarborMemoryWaistConfig config;
  final Sim sim;
  final Random rng;
  final List<String> errors = [];
  late final WaistRequester req;
  late final TlMemory tl;
  late final BurstGen gen;
  final List<Burst> all = [];

  int get busBytes => config.strbWidth;

  _MasterBench(
    this.config, {
    int seed = 1,
    double idle = 0.2,
    double stall = 0.3,
    double tlStall = 0.3,
    double errorRate = 0.05,
  }) : sim = Sim(MemMasterShell(config, kind: HarborFabricKind.tilelink)),
       rng = Random(seed) {
    req = WaistRequester(
      sim,
      'mem',
      rng,
      errors: errors,
      idle: idle,
      stall: stall,
    );
    tl = TlMemory(
      sim,
      'bus',
      rng,
      busBytes: busBytes,
      errors: errors,
      stall: tlStall,
    );
    gen = BurstGen(
      rng,
      busBytes: busBytes,
      idWidth: config.idWidth,
      errors: errorRate,
    );
    StableCheck(sim, 'bus_A_VALID', 'bus_A_READY', [
      for (final f in ['OPCODE', 'SIZE', 'SOURCE', 'ADDRESS', 'MASK', 'DATA'])
        'bus_A_$f',
    ], errors);
    StableCheck(sim, 'mem_RDATA_VALID', 'mem_RDATA_READY', [
      for (final f in ['ID', 'DATA', 'ERR', 'LAST']) 'mem_RDATA_$f',
    ], errors);
    StableCheck(sim, 'mem_WRESP_VALID', 'mem_WRESP_READY', [
      'mem_WRESP_ID',
      'mem_WRESP_ERR',
    ], errors);
  }

  void send(Burst b) {
    all.add(b);
    req.send(b);
  }

  Future<void> start() async {
    await sim.start();
    Simulator.setMaxSimTime(20000000);
  }

  Future<void> drain() =>
      waitUntil(sim, () => req.done && req.req.idleNow, limit: 200000);

  int _err(Burst x) => x.addr >= 0xf000 ? 1 : 0;

  void check() {
    expect(errors, isEmpty);
    final want = [for (final b in all) ...tlExpect(b, busBytes)];
    expect(tl.msgs.length, want.length);
    expect(<String>[
      for (var i = 0; i < want.length; i++) ?diffTl(want[i], tl.msgs[i]),
    ], isEmpty);
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
    // Get beats in A order, which is the order of the waist reads.
    final beats = [
      for (final m in tl.msgs)
        if (m.op == tlGet) ...m.d,
    ];
    var at = 0;
    final bad = <String>[];
    for (var k = 0; k < req.reads.length; k++) {
      final x = req.reads[k];
      final w = [
        for (var i = 0; i < x.beats; i++)
          (
            x.id,
            beats[at + i].$4,
            beats[at + i].$5 | beats[at + i].$6,
            i == x.len ? 1 : 0,
          ),
      ];
      at += x.beats;
      if (req.readResp[k].toString() != w.toString()) {
        bad.add('$x: got ${req.readResp[k]} want $w');
      }
      if (w.any((e) => e.$3 != _err(x))) bad.add('$x: err flags $w');
    }
    expect(bad, isEmpty);
    expect(diffMemory(golden(req.writes, busBytes), tl.mem), isEmpty);
    expect(tl.maxInflight, lessThanOrEqualTo(config.outstanding));
  }
}

Future<_MasterBench> _masterRandom(
  HarborMemoryWaistConfig config, {
  required int seed,
  int count = 150,
  double idle = 0.2,
  double stall = 0.3,
  double tlStall = 0.3,
}) async {
  final b = _MasterBench(
    config,
    seed: seed,
    idle: idle,
    stall: stall,
    tlStall: tlStall,
  );
  await b.start();
  for (var i = 0; i < count; i++) {
    b.send(b.gen.next(write: b.rng.nextBool()));
  }
  await b.drain();
  b.check();
  await b.sim.stop();
  return b;
}

Future<void> _loop(HarborMemoryWaistConfig config, {required int seed}) async {
  final sim = Sim(MemLoopShell(config, kind: HarborFabricKind.tilelink));
  final rng = Random(seed);
  final errors = <String>[];
  final busBytes = config.strbWidth;
  final req = WaistRequester(sim, 'up', rng, errors: errors);
  final mem = WaistMemory(
    sim,
    'mem',
    rng,
    outstanding: config.outstanding,
    busBytes: busBytes,
    errors: errors,
  );
  final gen = BurstGen(
    rng,
    busBytes: busBytes,
    idWidth: config.idWidth,
    errors: 0.05,
  );
  await sim.start();
  Simulator.setMaxSimTime(20000000);

  // Writes first, then reads, so every read has one right answer.
  for (var i = 0; i < 50; i++) {
    req.send(gen.next(write: true));
  }
  await waitUntil(sim, () => req.done && req.req.idleNow, limit: 200000);
  for (var i = 0; i < 50; i++) {
    req.send(gen.next(write: false));
  }
  for (var a = 0; a < 0x2000; a += 16 * busBytes) {
    req.send(
      Burst(
        id: 0,
        write: false,
        addr: a,
        len: 15,
        size: log2(busBytes),
        burst: 1,
      ),
    );
  }
  await waitUntil(sim, () => req.done && req.req.idleNow, limit: 200000);

  expect(errors, isEmpty);
  expect(
    diffPerId<Burst, (int, int)>(
      want: req.writes,
      got: req.writeResp,
      wantId: (x) => x.id,
      gotId: (r) => r.$1,
      matches: (x, r) => r.$2 == (x.addr >= 0xf000 ? 1 : 0),
    ),
    isEmpty,
  );
  final want = golden(req.writes, busBytes);
  final bad = <String>[];
  for (var k = 0; k < req.reads.length; k++) {
    final x = req.reads[k];
    final err = x.addr >= 0xf000 ? 1 : 0;
    final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
    final w = [
      for (var i = 0; i < x.beats; i++)
        (x.id, err == 1 ? 0 : want.read(addrs[i]), err, i == x.len ? 1 : 0),
    ];
    if (req.readResp[k].toString() != w.toString()) {
      bad.add('$x: got ${req.readResp[k]} want $w');
    }
  }
  expect(bad, isEmpty);
  expect(diffMemory(want, mem.mem), isEmpty);
  await sim.stop();
}

void main() {
  tearDown(endAndReset);

  group('TileLink-UH slave port', () {
    test('random Get and Put bursts, sources, errors, backpressure', () async {
      await _slaveRandom(_c32, seed: 1);
    });

    test('another seed with a slow memory and a fast manager', () async {
      await _slaveRandom(_c32, seed: 8, memStall: 0.6, idle: 0, stall: 0.1);
    });

    test('64 bit bus with 8 outstanding', () async {
      await _slaveRandom(_c64, seed: 3);
    });

    test('one outstanding request', () async {
      await _slaveRandom(
        const HarborMemoryWaistConfig(
          addressWidth: 16,
          dataWidth: 32,
          idWidth: 2,
          outstanding: 1,
        ),
        seed: 5,
        count: 80,
      );
    });

    test('denied messages drain A and answer with the right beats', () async {
      final b = _SlaveBench(_c32, idle: 0, stall: 0, memStall: 0, errorRate: 0);
      final aCycles = <int>[];
      final dCycles = <int>[];
      var cycle = 0;
      b.sim.onRise(() {
        cycle++;
        if (b.sim.pre('bus_A_VALID') == 1 && b.sim.pre('bus_A_READY') == 1) {
          aCycles.add(cycle);
        }
        if (b.sim.pre('bus_D_VALID') == 1 && b.sim.pre('bus_D_READY') == 1) {
          dCycles.add(cycle);
        }
      });
      await b.start();
      final full = (1 << 4) - 1;
      List<int> d(int n) => List.generate(n, (i) => 0x100 + i);
      final msgs = [
        // ArithmeticData of 4 beats, LogicalData of 1 beat.
        TlMsg(
          op: tlArithmetic,
          size: 4,
          addr: 0x40,
          data: d(4),
          mask: List.filled(4, full),
        ),
        TlMsg(op: tlLogical, size: 2, addr: 0x44, data: d(1), mask: [full]),
        TlMsg(op: tlIntent, size: 6, addr: 0x80),
        TlMsg(op: tlAcquire, size: 2, addr: 0x80),
        // 512 beat Get and Put.
        TlMsg(op: tlGet, size: 11, addr: 0, mask: [full]),
        TlMsg(
          op: tlPutFull,
          size: 11,
          addr: 0,
          data: d(512),
          mask: List.filled(512, full),
        ),
        // Not aligned to the size.
        TlMsg(op: tlGet, size: 3, addr: 0x14, mask: [full]),
      ];
      final shapes = [
        (4, tlAccessAckData, 4, 1),
        (1, tlAccessAckData, 1, 1),
        (1, tlHintAck, 1, 0),
        (1, tlAccessAck, 1, 0),
        (1, tlAccessAckData, 512, 1),
        (512, tlAccessAck, 1, 0),
        (1, tlAccessAckData, 2, 1),
      ];
      for (var i = 0; i < msgs.length; i++) {
        final aBefore = aCycles.length;
        final dBefore = dCycles.length;
        b.tl.send(msgs[i]);
        await b.drain();
        final (aBeats, op, dBeats, corrupt) = shapes[i];
        expect(aCycles.length - aBefore, aBeats, reason: '${msgs[i]}');
        expect(dCycles.length - dBefore, dBeats, reason: '${msgs[i]}');
        // The response starts after the last A beat.
        expect(dCycles[dBefore], greaterThan(aCycles.last));
        expect(msgs[i].d, [
          for (var k = 0; k < dBeats; k++)
            (op, msgs[i].size, msgs[i].source, 0, 1, corrupt),
        ]);
      }
      expect(b.mem.reads, isEmpty);
      expect(b.mem.writes, isEmpty);
      expect(b.errors, isEmpty);
      await b.sim.stop();
    });

    test('d_denied holds from the first beat, d_corrupt follows err', () async {
      final sim = Sim(MemSlaveShell(_c32, kind: HarborFabricKind.tilelink));
      final rng = Random(4);
      final errors = <String>[];
      final tl = TlManager(
        sim,
        'bus',
        rng,
        sources: 16,
        busBytes: 4,
        errors: errors,
        idle: 0,
        stall: 0,
      );
      final rdata = Source(sim, 'mem_RDATA_VALID', 'mem_RDATA_READY', rng);
      var pattern = <int>[];
      Sink(
        sim,
        'mem_REQ_VALID',
        'mem_REQ_READY',
        ['mem_REQ_ID', 'mem_REQ_LEN'],
        rng,
        (f) {
          for (var i = 0; i < pattern.length; i++) {
            rdata.queue.add({
              'mem_RDATA_ID': f['mem_REQ_ID']!,
              'mem_RDATA_DATA': i,
              'mem_RDATA_ERR': pattern[i],
              'mem_RDATA_LAST': i == pattern.length - 1 ? 1 : 0,
            });
          }
        },
      );
      await sim.start();
      for (final p in [
        [0, 1, 0, 0],
        [1, 0, 0, 0],
      ]) {
        pattern = p;
        final m = TlMsg(op: tlGet, size: 4, addr: 0x100, mask: [0xf]);
        tl.send(m);
        await waitUntil(sim, () => tl.done);
        expect(m.d.map((e) => e.$5).toList(), List.filled(4, p[0]));
        expect(m.d.map((e) => e.$6).toList(), [for (final e in p) e | p[0]]);
      }
      expect(errors, isEmpty);
      await sim.stop();
    });

    test('a Put beat with a_corrupt writes nothing', () async {
      final b = _SlaveBench(_c32, idle: 0, stall: 0, memStall: 0);
      await b.start();
      final m = TlMsg(
        op: tlPutFull,
        size: 3,
        addr: 0x20,
        data: [0x11111111, 0x22222222],
        mask: [0xf, 0xf],
        corrupt: [1, 0],
      );
      b.tl.send(m);
      await b.drain();
      expect(b.mem.mem.words[0x20 ~/ 4], isNull);
      expect(b.mem.mem.read(0x24), 0x22222222);
      expect(m.d, [(tlAccessAck, 3, m.source, 0, 0, 0)]);
      await b.sim.stop();
    });

    for (final n in [1, 2]) {
      test('a device answering in the REQ cycle, $n outstanding', () async {
        final config = HarborMemoryWaistConfig(
          addressWidth: 16,
          dataWidth: 32,
          idWidth: 4,
          outstanding: n,
        );
        final sim = Sim(
          MemSlaveCombShell(config, kind: HarborFabricKind.tilelink),
        );
        final errors = <String>[];
        final tl = TlManager(
          sim,
          'bus',
          Random(9),
          sources: 16,
          busBytes: 4,
          errors: errors,
          idle: 0,
          stall: 0,
        );
        await sim.start();
        final msgs = <TlMsg>[];
        for (var i = 0; i < 12; i++) {
          final addr = 0x40 + i * 4;
          msgs.add(
            i % 3 == 2
                ? TlMsg(
                    op: tlPutFull,
                    size: 2,
                    addr: addr,
                    data: [i],
                    mask: [0xf],
                  )
                : TlMsg(op: tlGet, size: i % 3, addr: addr, mask: [0xf]),
          );
        }
        msgs.forEach(tl.send);
        await waitUntil(sim, () => tl.done);
        expect(errors, isEmpty);
        for (final m in msgs) {
          expect(m.d, [
            m.isPut
                ? (tlAccessAck, m.size, m.source, 0, 0, 0)
                : (tlAccessAckData, m.size, m.source, m.addr, 0, 0),
          ]);
        }
        await sim.stop();
      });
    }
  });

  group('TileLink-UH master port', () {
    test('random bursts and IDs against a memory that reorders', () async {
      await _masterRandom(_c32, seed: 11);
    });

    test('64 bit bus with 8 outstanding and narrow bursts', () async {
      await _masterRandom(_c64, seed: 13);
    });

    test('one outstanding request', () async {
      await _masterRandom(
        const HarborMemoryWaistConfig(
          addressWidth: 16,
          dataWidth: 32,
          idWidth: 2,
          outstanding: 1,
        ),
        seed: 14,
        count: 80,
      );
    });

    test('distinct IDs reach N messages in flight', () async {
      final b = _MasterBench(_c32, seed: 15, idle: 0, stall: 0, tlStall: 0.5);
      await b.start();
      for (var i = 0; i < 40; i++) {
        b.send(
          Burst(
            id: i % 8,
            write: false,
            addr: i * 16,
            len: 3,
            size: 2,
            burst: 1,
          ),
        );
      }
      await b.drain();
      b.check();
      expect(b.tl.maxInflight, 4);
      await b.sim.stop();
    });

    test('a request waits while its ID is in flight', () async {
      final b = _MasterBench(_c32, seed: 16, idle: 0, stall: 0, tlStall: 0);
      await b.start();
      b.tl.holdResponses = true;
      for (var i = 0; i < 3; i++) {
        b.send(
          Burst(id: 5, write: false, addr: i * 4, len: 0, size: 2, burst: 1),
        );
      }
      await b.sim.cycles(30);
      // Only the first one is out. The source is not reused.
      expect(b.tl.msgs.length, 1);
      b.tl.holdResponses = false;
      await b.drain();
      b.check();
      await b.sim.stop();
    });

    test('Get id 2 overtakes id 1 when the memory answers it first', () async {
      final b = _MasterBench(_c32, seed: 17, idle: 0, stall: 0, tlStall: 0);
      final order = <int>[];
      b.sim.onRise(() {
        if (b.sim.pre('mem_RDATA_VALID') == 1 &&
            b.sim.pre('mem_RDATA_READY') == 1 &&
            b.sim.pre('mem_RDATA_LAST') == 1) {
          order.add(b.sim.pre('mem_RDATA_ID'));
        }
      });
      await b.start();
      b.tl.holdResponses = true;
      b.tl.preferSource = 2;
      b.send(Burst(id: 1, write: false, addr: 0x10, len: 3, size: 2, burst: 1));
      b.send(Burst(id: 2, write: false, addr: 0x40, len: 3, size: 2, burst: 1));
      await b.sim.cycles(20);
      b.tl.holdResponses = false;
      await b.drain();
      b.check();
      expect(order, [2, 1]);
      await b.sim.stop();
    });

    test('bursts TileLink cannot carry go out as one beat messages', () async {
      final b = _MasterBench(_c32, seed: 18, idle: 0, stall: 0.2);
      await b.start();
      List<int> d(int n) => List.generate(n, (i) => 0xa0 + i);
      // FIXED, unaligned WRAP, narrow INCR, 3 beat INCR, unaligned INCR.
      for (final x in [
        Burst(id: 1, write: false, addr: 0x100, len: 3, size: 2, burst: 0),
        Burst(id: 2, write: false, addr: 0x208, len: 3, size: 2, burst: 2),
        Burst(
          id: 3,
          write: true,
          addr: 0x301,
          len: 2,
          size: 0,
          burst: 1,
          data: d(3),
          strb: [0x2, 0x4, 0x8],
        ),
        Burst(
          id: 4,
          write: true,
          addr: 0x400,
          len: 2,
          size: 2,
          burst: 1,
          data: d(3),
          strb: [0xf, 0x3, 0xf],
        ),
        Burst(id: 5, write: false, addr: 0x514, len: 3, size: 2, burst: 1),
      ]) {
        b.send(x);
      }
      await b.drain();
      b.check();
      expect(b.tl.msgs.length, 4 + 4 + 3 + 3 + 4);
      await b.sim.stop();
    });
  });

  group('TileLink-UH loopback', () {
    test('master port to slave port, 32 bit, 4 outstanding', () async {
      await _loop(_c32, seed: 21);
    });

    test('master port to slave port, 64 bit, 8 outstanding', () async {
      await _loop(_c64, seed: 22);
    });
  });

  group('TileLink-UH config checks', () {
    test('a sink width above 1 is rejected', () {
      final bad = TileLinkConfig(
        addressWidth: _c32.addressWidth,
        dataWidth: _c32.dataWidth,
        sizeWidth: 4,
        sourceWidth: _c32.idWidth,
        sinkWidth: 2,
      );
      expect(
        () => HarborTileLinkMemorySlave(
          clk: Logic(),
          reset: Logic(),
          tl: TileLinkInterface(bad),
          waist: HarborMemoryWaist(_c32),
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborTileLinkMemoryMaster(
          clk: Logic(),
          reset: Logic(),
          waist: HarborMemoryWaist(_c32),
          tl: TileLinkInterface(bad),
        ),
        throwsArgumentError,
      );
    });
  });
}

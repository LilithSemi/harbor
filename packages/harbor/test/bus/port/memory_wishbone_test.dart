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

/// The waist requests the slave port makes for [t], by its block rule.
List<Burst> wbChunks(WbTxn t, int blockBeats, int busBytes) {
  final out = <Burst>[];
  final presented = t.done + (t.gaveUp ? 1 : 0);
  var j = 0;
  while (j < presented) {
    final a = t.beats[j].addr & ~(busBytes - 1);
    // The last beat of a burst has CTI 111, so it starts a one beat request.
    final len = t.mode == WbMode.burst && j < t.beats.length - 1
        ? blockBeats - 1 - (a ~/ busBytes) % blockBeats
        : 0;
    out.add(
      Burst(
        id: 0,
        write: t.write,
        addr: a,
        len: len,
        size: log2(busBytes),
        burst: 1,
      ),
    );
    j += len + 1;
  }
  return out;
}

/// A Wishbone master, the slave port and a memory behind its waist.
class _SlaveBench {
  final HarborMemoryWaistConfig config;
  final int blockBeats;
  final Sim sim;
  final Random rng;
  final List<String> errors = [];
  final List<String> beatErrors = [];
  late final WbMaster wb;
  late final WaistMemory mem;
  late final WordMemory model;

  int get busBytes => config.strbWidth;

  _SlaveBench(
    this.config, {
    this.blockBeats = 8,
    int seed = 1,
    double gap = 0.2,
    double keepCyc = 0.3,
    double memStall = 0.3,
  }) : sim = Sim(
         MemSlaveShell(
           config,
           kind: HarborFabricKind.wishbone,
           burstBeats: blockBeats,
         ),
       ),
       rng = Random(seed) {
    model = WordMemory(config.strbWidth);
    wb = WbMaster(sim, 'bus', rng, gap: gap, keepCyc: keepCyc)
      ..onBeat = _onBeat;
    // The slave port runs one request at a time.
    mem = WaistMemory(
      sim,
      'mem',
      rng,
      outstanding: 1,
      busBytes: busBytes,
      errors: errors,
      stall: memStall,
    );
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

  // Each beat ends in bus order, so a running model gives the one right
  // answer for every read.
  void _onBeat(WbTxn t, WbBeat b) {
    final err = b.addr >= 0xf000;
    if (b.ack == 1 && b.err == 1) beatErrors.add('ACK and ERR on $b');
    if (t.write) {
      if (!err && b.ack == 1) model.write(b.addr, b.data, b.sel);
      if (!err && b.err == 1) beatErrors.add('$t: ERR on $b');
      return;
    }
    final want = err ? (0, 1, 0) : (1, 0, model.read(b.addr));
    if ((b.ack, b.err, b.err == 1 ? 0 : b.rdata) != want) {
      beatErrors.add('$t: $b, want $want');
    }
  }

  Future<void> start() async {
    await sim.start();
    Simulator.setMaxSimTime(20000000);
  }

  Future<void> drain() async {
    await waitUntil(sim, () => wb.done, limit: 200000);
    await waitUntil(
      sim,
      () => sim.pre('mem_REQ_VALID') == 0 && mem.inflight == 0,
    );
    await sim.cycles(4);
  }

  int _data() => busBytes == 8
      ? (rng.nextInt(1 << 32) << 32) | rng.nextInt(1 << 32)
      : rng.nextInt(1 << (busBytes * 8));

  /// A random bus cycle.
  WbTxn next({double errors = 0.05, double abort = 0.1}) {
    final write = rng.nextBool();
    final err = rng.nextDouble() < errors;
    final base = err ? 0xf000 : 0;
    final words = (err ? 0x400 : 0x2000) ~/ busBytes;
    final word = rng.nextInt(words - 24);
    final full = (1 << busBytes) - 1;
    WbBeat beat(int w) => WbBeat(
      base + w * busBytes,
      data: write ? _data() : 0,
      sel: write ? (rng.nextBool() ? full : rng.nextInt(full + 1)) : 0,
    );
    switch (rng.nextInt(5)) {
      case 0:
        return WbTxn(write, WbMode.classic, [
          beat(word),
        ], classicEnd: rng.nextBool());
      case 1:
        final start = word & ~3;
        return WbTxn(write, WbMode.wrap4, [
          for (var i = 0; i < 4; i++) beat(start + ((word + i) & 3)),
        ]);
      default:
        final n = 1 + rng.nextInt(20);
        final cut = n > 1 && rng.nextDouble() < abort
            ? 1 + rng.nextInt(n - 1)
            : null;
        return WbTxn(write, WbMode.burst, [
          for (var i = 0; i < n; i++) beat(word + i),
        ], abortAfter: cut);
    }
  }

  void check() {
    expect(errors, isEmpty);
    expect(beatErrors, isEmpty);
    final want = [
      for (final t in wb.finished) ...wbChunks(t, blockBeats, busBytes),
    ];
    final wReads = want.where((x) => !x.write).toList();
    final wWrites = want.where((x) => x.write).toList();
    expect(mem.reads.length, wReads.length);
    expect(mem.writes.length, wWrites.length);
    expect(<String>[
      for (var k = 0; k < wReads.length; k++) ?diffReq(wReads[k], mem.reads[k]),
      for (var k = 0; k < wWrites.length; k++)
        ?diffReq(wWrites[k], mem.writes[k]),
    ], isEmpty);
    expect(diffMemory(model, mem.mem), isEmpty);
    // A write in the error range ends its cycle with ERR unless the master
    // left first.
    final bad = <String>[];
    for (final t in wb.finished) {
      final err = t.beats.first.addr >= 0xf000;
      if (!err || t.gaveUp || t.done == 0) continue;
      if (t.abortAfter == null && t.beats[t.done - 1].err != 1) {
        bad.add('$t did not end with ERR');
      }
    }
    expect(bad, isEmpty);
  }
}

Future<void> _slaveRandom(
  HarborMemoryWaistConfig config, {
  required int seed,
  int blockBeats = 8,
  int count = 200,
  double gap = 0.2,
  double memStall = 0.3,
}) async {
  final b = _SlaveBench(
    config,
    seed: seed,
    blockBeats: blockBeats,
    gap: gap,
    memStall: memStall,
  );
  await b.start();
  for (var i = 0; i < count; i++) {
    b.wb.queue.add(b.next());
  }
  await b.drain();
  b.check();
  expect(b.mem.maxInflight, 1);
  await b.sim.stop();
}

/// A waist requester, the master port and a Wishbone memory.
class _MasterBench {
  final HarborMemoryWaistConfig config;
  final Sim sim;
  final Random rng;
  final List<String> errors = [];
  late final WaistRequester req;
  late final WbMemory wb;
  late final BurstGen gen;
  final List<Burst> all = [];

  int get busBytes => config.strbWidth;

  _MasterBench(
    this.config, {
    int seed = 1,
    double idle = 0.2,
    double stall = 0.3,
    double wait = 0.3,
    double errorRate = 0.05,
  }) : sim = Sim(MemMasterShell(config, kind: HarborFabricKind.wishbone)),
       rng = Random(seed) {
    req = WaistRequester(
      sim,
      'mem',
      rng,
      errors: errors,
      idle: idle,
      stall: stall,
    );
    wb = WbMemory(sim, 'bus', rng, busBytes: busBytes, wait: wait);
    gen = BurstGen(
      rng,
      busBytes: busBytes,
      idWidth: config.idWidth,
      errors: errorRate,
    );
    StableCheck(sim, 'mem_RDATA_VALID', 'mem_RDATA_READY', [
      for (final f in ['ID', 'DATA', 'ERR', 'LAST']) 'mem_RDATA_$f',
    ], errors);
    StableCheck(sim, 'mem_WRESP_VALID', 'mem_WRESP_READY', [
      'mem_WRESP_ID',
      'mem_WRESP_ERR',
    ], errors);
    // A beat holds STB and its request until ACK or ERR.
    Map<String, int>? held;
    sim.onRise(() {
      final stb = sim.pre('bus_CYC') == 1 && sim.pre('bus_STB') == 1;
      final now = stb
          ? {
              for (final f in ['WE', 'ADR', 'SEL', 'CTI', 'BTE'])
                f: sim.pre('bus_$f'),
              if (sim.pre('bus_WE') == 1) 'DAT_MOSI': sim.pre('bus_DAT_MOSI'),
            }
          : null;
      if (held != null && now.toString() != held.toString()) {
        errors.add('beat changed before ACK: $held -> $now');
      }
      final end = sim.pre('bus_ACK') == 1 || sim.pre('bus_ERR') == 1;
      held = stb && !end ? now : null;
    });
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
    // CYC drops between requests, so each request is one session.
    expect(wb.sessions.length, all.length);
    final bl = log2(busBytes);
    final bad = <String>[];
    final rData = <List<int>>[];
    for (var k = 0; k < all.length; k++) {
      final x = all[k];
      final s = wb.sessions[k];
      final piece = min(x.size, bl);
      final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
      final burst = x.burst == 1 && x.size == bl && x.len > 0;
      final n = _err(x) == 1 ? 1 : x.beats;
      if (s.length != n) {
        bad.add('$x: ${s.length} beats, want $n');
        continue;
      }
      for (var i = 0; i < n; i++) {
        final lanes = laneMask(addrs[i], piece, busBytes);
        final want = {
          'WE': x.write ? 1 : 0,
          'ADR': addrs[i] & ~(busBytes - 1),
          'SEL': x.write ? x.strb[i] & lanes : lanes,
          'CTI': burst ? (i == x.len ? 7 : 2) : 0,
          'BTE': 0,
        };
        for (final e in want.entries) {
          if (s[i][e.key] != e.value) {
            bad.add('$x beat $i: ${e.key} ${s[i][e.key]} want ${e.value}');
          }
        }
        if (x.write && s[i]['DAT_MOSI'] != x.data[i]) {
          bad.add('$x beat $i: data');
        }
      }
      if (!x.write) rData.add([for (final b in s) b['DAT_MISO']!]);
    }
    expect(bad, isEmpty);
    expect(req.writeResp, [for (final x in req.writes) (x.id, _err(x))]);
    final rBad = <String>[];
    for (var k = 0; k < req.reads.length; k++) {
      final x = req.reads[k];
      final e = _err(x);
      final w = [
        for (var i = 0; i < x.beats; i++)
          (x.id, e == 1 ? 0 : rData[k][i], e, i == x.len ? 1 : 0),
      ];
      if (req.readResp[k].toString() != w.toString()) {
        rBad.add('$x: got ${req.readResp[k]} want $w');
      }
    }
    expect(rBad, isEmpty);
    expect(diffMemory(golden(req.writes, busBytes), wb.mem), isEmpty);
  }
}

Future<void> _masterRandom(
  HarborMemoryWaistConfig config, {
  required int seed,
  int count = 150,
  double idle = 0.2,
  double stall = 0.3,
  double wait = 0.3,
}) async {
  final b = _MasterBench(
    config,
    seed: seed,
    idle: idle,
    stall: stall,
    wait: wait,
  );
  await b.start();
  for (var i = 0; i < count; i++) {
    b.send(b.gen.next(write: b.rng.nextBool()));
  }
  await b.drain();
  b.check();
  await b.sim.stop();
}

Future<void> _loop(
  HarborMemoryWaistConfig config, {
  required int seed,
  int blockBeats = 8,
}) async {
  final sim = Sim(
    MemLoopShell(
      config,
      kind: HarborFabricKind.wishbone,
      burstBeats: blockBeats,
    ),
  );
  final rng = Random(seed);
  final errors = <String>[];
  final busBytes = config.strbWidth;
  final req = WaistRequester(sim, 'up', rng, errors: errors);
  final mem = WaistMemory(
    sim,
    'mem',
    rng,
    outstanding: 1,
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

  // Wishbone runs one request at a time, so reads and writes can mix and
  // a running model still gives the one right answer.
  final model = WordMemory(busBytes);
  final want = <List<(int, int, int, int)>>[];
  final wantB = <(int, int)>[];
  for (var i = 0; i < 100; i++) {
    final x = gen.next(write: rng.nextBool());
    final err = x.addr >= 0xf000 ? 1 : 0;
    final addrs = beatAddrs(x.addr, x.len, x.size, x.burst);
    if (x.write) {
      if (err == 0) {
        for (var k = 0; k < x.beats; k++) {
          model.write(addrs[k], x.data[k], x.strb[k]);
        }
      }
      wantB.add((x.id, err));
    } else {
      want.add([
        for (var k = 0; k < x.beats; k++)
          (x.id, err == 1 ? 0 : model.read(addrs[k]), err, k == x.len ? 1 : 0),
      ]);
    }
    req.send(x);
  }
  await waitUntil(sim, () => req.done && req.req.idleNow, limit: 400000);

  expect(errors, isEmpty);
  expect(req.writeResp, wantB);
  final bad = <String>[];
  for (var k = 0; k < req.reads.length; k++) {
    if (req.readResp[k].toString() != want[k].toString()) {
      bad.add('${req.reads[k]}: got ${req.readResp[k]} want ${want[k]}');
    }
  }
  expect(bad, isEmpty);
  expect(diffMemory(model, mem.mem), isEmpty);
  await sim.stop();
}

void main() {
  tearDown(endAndReset);

  group('Wishbone slave port', () {
    test('random bursts, classic and wrap cycles, errors, aborts', () async {
      await _slaveRandom(_c32, seed: 1);
    });

    test('another seed with a slow memory and no wait states', () async {
      await _slaveRandom(_c32, seed: 9, gap: 0, memStall: 0.6);
    });

    test('64 bit bus with 4 beat blocks', () async {
      await _slaveRandom(_c64, seed: 3, blockBeats: 4);
    });

    test('one beat blocks make every beat its own request', () async {
      await _slaveRandom(_c32, seed: 4, blockBeats: 1, count: 100);
    });

    test('a burst to a block end is one exact request', () async {
      final b = _SlaveBench(_c32, gap: 0, memStall: 0);
      await b.start();
      b.wb.queue.add(
        WbTxn(true, WbMode.burst, [
          for (var i = 0; i < 8; i++)
            WbBeat(0x100 + i * 4, data: 0x1000 + i, sel: 0xf),
        ]),
      );
      b.wb.queue.add(
        WbTxn(false, WbMode.burst, [
          for (var i = 0; i < 8; i++) WbBeat(0x100 + i * 4),
        ]),
      );
      await b.drain();
      b.check();
      expect(b.mem.writes.single.len, 7);
      expect(b.mem.reads.single.len, 7);
      expect(b.wb.finished[1].beats.map((x) => x.rdata), [
        for (var i = 0; i < 8; i++) 0x1000 + i,
      ]);
      await b.sim.stop();
    });

    test('CTI 111 ends a burst early, then classic cycles run', () async {
      final b = _SlaveBench(_c32, gap: 0, keepCyc: 1, memStall: 0.3);
      await b.start();
      // Three beats of an eight beat block, then classic cycles.
      b.wb.queue.add(
        WbTxn(true, WbMode.burst, [
          for (var i = 0; i < 3; i++)
            WbBeat(0x200 + i * 4, data: 0x2000 + i, sel: 0xf),
        ]),
      );
      b.wb.queue.add(
        WbTxn(false, WbMode.burst, [
          for (var i = 0; i < 3; i++) WbBeat(0x200 + i * 4),
        ]),
      );
      for (var i = 0; i < 4; i++) {
        b.wb.queue.add(
          WbTxn(i.isEven, WbMode.classic, [
            WbBeat(0x220 + (i ~/ 2) * 4, data: 0x3000 + i, sel: 0xf),
          ]),
        );
      }
      await b.drain();
      b.check();
      // The write request pads the block with strobes low.
      expect(b.mem.writes.first.len, 7);
      expect(b.mem.mem.read(0x20c), WordMemory(4).read(0x20c));
      await b.sim.stop();
    });

    test('dropping CYC cuts a burst without breaking state', () async {
      for (final write in [true, false]) {
        final b = _SlaveBench(_c32, gap: 0.3, memStall: 0.3, seed: 6);
        await b.start();
        for (var round = 0; round < 6; round++) {
          b.wb.queue.add(
            WbTxn(write, WbMode.burst, [
              for (var i = 0; i < 12; i++)
                WbBeat(0x400 + i * 4, data: round * 0x100 + i, sel: 0xf),
            ], abortAfter: 1 + round),
          );
          b.wb.queue.add(
            WbTxn(!write, WbMode.burst, [
              for (var i = 0; i < 5; i++)
                WbBeat(0x404 + i * 4, data: 0x9000 + i, sel: 0xf),
            ]),
          );
        }
        await b.drain();
        b.check();
        await b.sim.stop();
        await endAndReset();
      }
    });

    test('a master that leaves a held write gets no late ACK', () async {
      final b = _SlaveBench(_c32, gap: 0, memStall: 0.9, seed: 7);
      final acks = <int>[];
      b.sim.onRise(() {
        if (b.sim.pre('bus_CYC') == 0 &&
            (b.sim.pre('bus_ACK') == 1 || b.sim.pre('bus_ERR') == 1)) {
          acks.add(1);
        }
      });
      await b.start();
      for (var i = 0; i < 4; i++) {
        b.wb.queue.add(
          WbTxn(
            true,
            WbMode.burst,
            // No strobes, so a beat the port took before the master left
            // changes nothing.
            [
              for (var k = 0; k < 2; k++)
                WbBeat(0x600 + k * 4, data: 0x700 + k, sel: 0),
            ],
            giveUpAfter: 3,
          ),
        );
        b.wb.queue.add(WbTxn(false, WbMode.classic, [WbBeat(0x600 + i * 4)]));
      }
      await b.drain();
      expect(b.wb.finished.where((t) => t.gaveUp), isNotEmpty);
      expect(acks, isEmpty);
      b.check();
      await b.sim.stop();
    });

    test('a device answering in the REQ cycle', () async {
      final sim = Sim(MemSlaveCombShell(_c32, kind: HarborFabricKind.wishbone));
      final wb = WbMaster(sim, 'bus', Random(2));
      await sim.start();
      final txns = [
        for (var i = 0; i < 10; i++)
          WbTxn(i % 3 == 2, WbMode.classic, [
            WbBeat(0x80 + i * 4, data: i, sel: 0xf),
          ]),
      ];
      txns.forEach(wb.queue.add);
      await waitUntil(sim, () => wb.done);
      for (final t in txns) {
        final b = t.beats.single;
        expect((b.ack, b.err), (1, 0));
        if (!t.write) expect(b.rdata, b.addr);
      }
      await sim.stop();
    });

    test('pad beats past the real burst never surface ERR', () async {
      final sim = Sim(MemSlaveShell(_c32, kind: HarborFabricKind.wishbone));
      final wb = WbMaster(sim, 'bus', Random(31), gap: 0, keepCyc: 0);
      WaistMemory(
        sim,
        'mem',
        Random(32),
        outstanding: 1,
        busBytes: _c32.strbWidth,
        errors: [],
        errBase: 0x110,
        perBeatErr: true,
        stall: 0,
      );
      await sim.start();
      Simulator.setMaxSimTime(200000);
      // An 8 beat block at 0x100..0x11c. Beats 4..7 (0x110..0x11c) sit in
      // the device's error range, but the master only names beats 0..3.
      final txn = WbTxn(true, WbMode.burst, [
        for (var i = 0; i < 4; i++)
          WbBeat(0x100 + i * 4, data: 0x8000 + i, sel: 0xf),
      ]);
      wb.queue.add(txn);
      await waitUntil(sim, () => wb.done);
      expect(txn.beats.map((b) => (b.ack, b.err)).toList(), [
        for (var i = 0; i < 4; i++) (1, 0),
      ]);
      await sim.stop();
    });

    test('a real beat in the error range still ends with ERR', () async {
      final sim = Sim(MemSlaveShell(_c32, kind: HarborFabricKind.wishbone));
      final wb = WbMaster(sim, 'bus', Random(33), gap: 0, keepCyc: 0);
      WaistMemory(
        sim,
        'mem',
        Random(34),
        outstanding: 1,
        busBytes: _c32.strbWidth,
        errors: [],
        errBase: 0x110,
        perBeatErr: true,
        stall: 0,
      );
      await sim.start();
      Simulator.setMaxSimTime(200000);
      // The whole 8 beat block is real this time, so beats 4..7 genuinely
      // error.
      final txn = WbTxn(true, WbMode.burst, [
        for (var i = 0; i < 8; i++)
          WbBeat(0x100 + i * 4, data: 0x9000 + i, sel: 0xf),
      ]);
      wb.queue.add(txn);
      await waitUntil(sim, () => wb.done);
      expect(txn.beats.map((b) => (b.ack, b.err)).toList(), [
        for (var i = 0; i < 7; i++) (1, 0),
        (0, 1),
      ]);
      await sim.stop();
    });
  });

  group('Wishbone master port', () {
    test('random bursts and IDs, errors and backpressure', () async {
      await _masterRandom(_c32, seed: 11);
    });

    test('64 bit bus with 8 outstanding and narrow bursts', () async {
      await _masterRandom(_c64, seed: 13);
    });

    test('no wait states', () async {
      await _masterRandom(_c32, seed: 14, idle: 0, stall: 0, wait: 0);
    });

    test('queues N requests while one runs on the bus', () async {
      final b = _MasterBench(_c32, seed: 15, idle: 0, stall: 0, wait: 0);
      var taken = 0;
      b.sim.onRise(() {
        if (b.sim.pre('mem_REQ_VALID') == 1 &&
            b.sim.pre('mem_REQ_READY') == 1) {
          taken++;
        }
      });
      await b.start();
      b.wb.hold = true;
      for (var i = 0; i < 6; i++) {
        b.send(
          Burst(id: i, write: false, addr: i * 32, len: 3, size: 2, burst: 1),
        );
      }
      await b.sim.cycles(30);
      expect(taken, 4);
      expect(b.wb.sessions.length, 1);
      b.wb.hold = false;
      await b.drain();
      b.check();
      await b.sim.stop();
    });

    test('a write holds CYC low until its data arrives', () async {
      final sim = Sim(MemMasterShell(_c32, kind: HarborFabricKind.wishbone));
      final wbMem = WbMemory(
        sim,
        'bus',
        Random(41),
        busBytes: _c32.strbWidth,
        wait: 0,
      );
      var reqDone = false;
      var dataSent = false;
      var delay = 5;
      sim.onRise(() {
        if (!reqDone &&
            sim.pre('mem_REQ_VALID') == 1 &&
            sim.pre('mem_REQ_READY') == 1) {
          reqDone = true;
        }
        if (!dataSent &&
            sim.pre('mem_WDATA_VALID') == 1 &&
            sim.pre('mem_WDATA_READY') == 1) {
          dataSent = true;
        }
      });
      sim.onFall(() {
        sim.set('mem_REQ_VALID', reqDone ? 0 : 1);
        sim.set('mem_REQ_ID', 0);
        sim.set('mem_REQ_WRITE', 1);
        sim.set('mem_REQ_ADDR', 0x40);
        sim.set('mem_REQ_LEN', 0);
        sim.set('mem_REQ_SIZE', 2);
        sim.set('mem_REQ_BURST', 1);
        var sendData = false;
        if (reqDone && !dataSent) {
          if (delay > 0) {
            delay--;
          } else {
            sendData = true;
          }
        }
        sim.set('mem_WDATA_VALID', sendData ? 1 : 0);
        sim.set('mem_WDATA_DATA', 0x1234);
        sim.set('mem_WDATA_STRB', 0xf);
        sim.set('mem_WDATA_LAST', 1);
        sim.set('mem_RDATA_READY', 1);
        sim.set('mem_WRESP_READY', 1);
      });
      await sim.start();
      Simulator.setMaxSimTime(200000);
      await waitUntil(sim, () => reqDone);
      // CYC stays low while the write waits for its data, so it never
      // holds a shared bus.
      for (var i = 0; i < 4; i++) {
        expect(sim.pre('bus_CYC'), 0);
        await sim.cycles(1);
      }
      await waitUntil(sim, () => dataSent);
      await waitUntil(sim, () => sim.pre('mem_WRESP_VALID') == 1);
      expect(wbMem.mem.read(0x40), 0x1234);
      await sim.stop();
    });
  });

  group('Wishbone loopback', () {
    test('master port to slave port, 32 bit', () async {
      await _loop(_c32, seed: 21);
    });

    test('master port to slave port, 64 bit, 4 beat blocks', () async {
      await _loop(_c64, seed: 22, blockBeats: 4);
    });
  });

  group('Wishbone config checks', () {
    test('RTY is rejected', () {
      final wb = WishboneInterface(
        harborWishboneMemoryConfig(_c32).copyWith(useRty: true),
      );
      expect(
        () => HarborWishboneMemorySlave(
          clk: Logic(),
          reset: Logic(),
          wb: wb,
          waist: HarborMemoryWaist(_c32),
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborWishboneMemoryMaster(
          clk: Logic(),
          reset: Logic(),
          waist: HarborMemoryWaist(_c32),
          wb: wb,
        ),
        throwsArgumentError,
      );
    });

    test('a tag address width above 0 is rejected', () {
      final wb = WishboneInterface(
        harborWishboneMemoryConfig(_c32).copyWith(tgaWidth: 4),
      );
      expect(
        () => HarborWishboneMemorySlave(
          clk: Logic(),
          reset: Logic(),
          wb: wb,
          waist: HarborMemoryWaist(_c32),
        ),
        throwsArgumentError,
      );
    });

    test('a tag data width above 0 is rejected', () {
      final wb = WishboneInterface(
        harborWishboneMemoryConfig(_c32).copyWith(tgdWidth: 8),
      );
      expect(
        () => HarborWishboneMemorySlave(
          clk: Logic(),
          reset: Logic(),
          wb: wb,
          waist: HarborMemoryWaist(_c32),
        ),
        throwsArgumentError,
      );
    });
  });
}

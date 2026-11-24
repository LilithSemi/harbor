import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../port/memory_harness.dart';
import '../port/port_harness.dart';
import 'axi4_fabric_harness.dart'
    show
        ReadWant,
        checkReads,
        checkWrites,
        exposeInterface,
        forEachPipeline,
        harnessPipeline,
        isolated,
        must;

const _liteBase = 0x10000;
const _fullBase = 0x00000;

// One full master with a full slave at 0 and an AXI4-Lite slave at 0x10000.
class _Shell extends BridgeModule {
  late final HarborFabricModule fabric;

  _Shell(
    HarborFabricTopology t,
    int dw, {
    int liteSize = 0x1000,
    int timeout = 0,
    bool offset = false,
  }) : super(
         'LiteSplitShell_${t.name}_${dw}_${liteSize}_${timeout}_$offset',
         name: 'shell',
       ) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final m = Axi4Interface(addressWidth: 20, dataWidth: dw, idWidth: 2);
    exposeInterface(this, m, 'm', PairDirection.fromProvider);
    final f = Axi4Interface(addressWidth: 20, dataWidth: dw, idWidth: 2);
    exposeInterface(this, f, 'f', PairDirection.fromConsumer);
    final l = Axi4LiteInterface(addressWidth: 20, dataWidth: dw);
    exposeInterface(this, l, 'l', PairDirection.fromConsumer);
    fabric = HarborFabric.build(
      kind: HarborFabricKind.axi4,
      pipeline: harnessPipeline,
      topology: t,
      clk: input('clk'),
      reset: input('reset'),
      masters: [HarborFabricMaster(name: 'm', interface: m, outstanding: 8)],
      slaves: [
        HarborFabricSlave(
          name: 'f',
          range: const BusAddressRange(_fullBase, 0x10000),
          interface: f,
          outstanding: 4,
        ),
        HarborFabricSlave(
          name: 'l',
          range: BusAddressRange(_liteBase, liteSize),
          interface: l,
          outstanding: 1,
          memory: false,
          timeout: timeout,
          offset: offset,
        ),
      ],
    );
    createPort('bus_error', PortDirection.output);
    output('bus_error') <= fabric.busError;
  }
}

bool _never(Burst x) => false;

class _Bench {
  final Sim sim;
  final AxiManager m;
  final AxiMemory f;
  final AxiMemory l;
  final List<String> errors;
  final int bytes;
  _Bench(this.sim, this.m, this.f, this.l, this.errors, this.bytes);

  static Future<_Bench> start(
    HarborFabricTopology t,
    int dw, {
    int errBase = 1 << 40,
    double stall = 0.3,
    int liteSize = 0x1000,
    int timeout = 0,
    bool offset = false,
  }) async {
    final sim = Sim(
      _Shell(t, dw, liteSize: liteSize, timeout: timeout, offset: offset),
    );
    final rng = Random(7);
    final errors = <String>[];
    final bytes = dw ~/ 8;
    final m = AxiManager(sim, 'm', rng, stall: stall);
    final f = AxiMemory(
      sim,
      'f',
      rng,
      busBytes: bytes,
      outstanding: 4,
      errors: errors,
      errBase: 1 << 40,
      stall: stall,
    );
    final l = AxiMemory(
      sim,
      'l',
      rng,
      busBytes: bytes,
      outstanding: 1,
      errors: errors,
      errBase: errBase,
      stall: stall,
      lite: true,
    );
    await sim.start();
    Simulator.setMaxSimTime(4000000);
    return _Bench(sim, m, f, l, errors, bytes);
  }

  Future<void> drain() => waitUntil(
    sim,
    () =>
        m.aw.idleNow &&
        m.bResp.length == m.awOrder.length &&
        m.ar.idleNow &&
        m.rBeats.length == m.readBeatsExpected,
    limit: 40000,
  );

  Burst wr(int id, int addr, int len, {int burst = 1, int? size}) {
    final sz = size ?? bytes.bitLength - 1;
    final n = len + 1;
    final mask = (1 << (bytes * 8 - 2)) - 1;
    return Burst(
      id: id,
      write: true,
      addr: addr,
      len: len,
      size: sz,
      burst: burst,
      data: [
        for (var i = 0; i < n; i++)
          ((addr * 0x9e3779b1 + i * 0x10001 + id) & mask) | 1,
      ],
      strb: [
        for (final a in beatAddrs(addr, len, sz, burst))
          (((1 << (1 << sz)) - 1) << (a & (bytes - 1) & ~((1 << sz) - 1))),
      ],
    );
  }

  Burst rd(int id, int addr, int len, {int burst = 1, int? size}) => Burst(
    id: id,
    write: false,
    addr: addr,
    len: len,
    size: size ?? bytes.bitLength - 1,
    burst: burst,
  );

  // Expected data and response of each read, after [writes].
  ReadWant Function(Burst) want(
    List<Burst> writes, {
    bool Function(Burst) bad = _never,
  }) {
    final g = WordMemory(bytes);
    for (final x in writes) {
      if (bad(x)) continue;
      final a = beatAddrs(x.addr, x.len, x.size, x.burst);
      for (var i = 0; i < x.beats; i++) {
        g.write(a[i], x.data[i], x.strb[i]);
      }
    }
    return (x) {
      if (bad(x)) return (2, null);
      return (
        0,
        [for (final a in beatAddrs(x.addr, x.len, x.size, x.burst)) g.read(a)],
      );
    };
  }

  List<String> check(List<Burst> writes, {bool Function(Burst) bad = _never}) =>
      [
        ...errors,
        ...checkReads('m', m.arOrder, m.rBeats, want(writes, bad: bad)),
        ...checkWrites('m', m.awOrder, m.bResp, (x) => bad(x) ? 2 : 0),
      ];
}

// Writes and reads INCR, WRAP and FIXED bursts, one drain between them.
Future<void> _bursts(
  HarborFabricTopology t,
  int dw, {
  int timeout = 0,
  bool offset = false,
}) async {
  final b = await _Bench.start(t, dw, timeout: timeout, offset: offset);
  final w = b.bytes;
  final writes = [
    b.wr(0, _liteBase + 0x000, 3),
    b.wr(1, _liteBase + 0x100, 7),
    b.wr(2, _liteBase + 0x200, 15),
    b.wr(3, _liteBase + 0x300 + 2 * w, 3, burst: 2),
    b.wr(0, _liteBase + 0x400 + 5 * w, 7, burst: 2),
    b.wr(1, _liteBase + 0x500, 3, burst: 0),
    b.wr(2, _liteBase + 0x600 + w, 1, burst: 2),
    b.wr(3, _liteBase + 0x700 + 9 * w, 15, burst: 2),
  ];
  for (final x in writes) {
    b.m.write(x);
  }
  await b.drain();
  final reads = [
    b.rd(0, _liteBase + 0x000, 3),
    b.rd(1, _liteBase + 0x100, 7),
    b.rd(2, _liteBase + 0x200, 15),
    b.rd(3, _liteBase + 0x300 + 2 * w, 3, burst: 2),
    b.rd(0, _liteBase + 0x400 + 5 * w, 7, burst: 2),
    b.rd(1, _liteBase + 0x500, 3, burst: 0),
    b.rd(2, _liteBase + 0x600 + w, 1, burst: 2),
    b.rd(3, _liteBase + 0x700 + 9 * w, 15, burst: 2),
    b.rd(2, _liteBase + 0x300, 3),
    b.rd(3, _liteBase + 0x400, 7),
  ];
  for (final x in reads) {
    b.m.read(x);
  }
  await b.drain();
  final busError = b.sim.pre('bus_error');
  await b.sim.stop();
  must(busError, 0);
  must(b.check(writes).take(20).toList(), isEmpty);
  // Every burst reached the slave as single beats at the AXI4 addresses,
  // minus the region start when the slave sees an offset.
  final shift = offset ? _liteBase : 0;
  must(b.l.awOrder.map((x) => x.addr).toList(), [
    for (final x in writes)
      for (final a in beatAddrs(x.addr, x.len, x.size, x.burst)) a - shift,
  ]);
  must(b.l.arOrder.map((x) => x.addr).toList(), [
    for (final x in reads)
      for (final a in beatAddrs(x.addr, x.len, x.size, x.burst)) a - shift,
  ]);
  must(b.l.arOrder.every((x) => x.len == 0), true);
}

// An error on a middle beat goes back on that beat and the burst goes on.
Future<void> _middleError(HarborFabricTopology t, int dw) async {
  final w = dw ~/ 8;
  final bad = _liteBase + 0x800 + 2 * w;
  final b = await _Bench.start(t, dw, errBase: bad);
  final good = [b.wr(0, _liteBase + 0x800 - 2 * w, 3)];
  b.m.write(good[0]);
  await b.drain();
  // Beats 0 and 1 are ok, beats 2 and 3 fail.
  final rBad = b.rd(1, _liteBase + 0x800, 3);
  final wBad = b.wr(2, _liteBase + 0x800, 3);
  b.m
    ..write(wBad)
    ..read(rBad)
    ..read(b.rd(3, _liteBase + 0x800 - 2 * w, 3));
  await b.drain();
  b.m.write(b.wr(0, _liteBase + 0x20, 3));
  b.m.read(b.rd(0, _liteBase + 0x20, 3));
  await b.drain();
  await b.sim.stop();
  must(b.errors, isEmpty);
  final r1 = b.m.rBeats.where((x) => x.$1 == 1).toList();
  must(r1.map((x) => x.$3).toList(), [0, 0, 2, 2]);
  must(r1.map((x) => x.$4).toList(), [0, 0, 0, 1]);
  must(b.m.bResp.where((x) => x.$1 == 2).toList(), [(2, 2)]);
  must(b.m.bResp.where((x) => x.$1 == 0).toList(), [(0, 0), (0, 0)]);
  final r0 = b.m.rBeats.where((x) => x.$1 == 0).toList();
  must(r0.map((x) => x.$3).toList(), [0, 0, 0, 0]);
  must(b.l.awOrder.length, 4 + 4 + 4);
}

// A narrow burst runs as single beats that advance by SIZE.
Future<void> _narrow(HarborFabricTopology t, int dw) async {
  final b = await _Bench.start(t, dw);
  // Full words first, so a narrow write has known bytes around it.
  final sizes = [
    for (final size in [0, 1, 2])
      if (1 << size <= b.bytes) size,
  ];
  final fills = [
    for (final size in sizes) b.wr(2, _liteBase + 0x40 + size * 0x40, 3),
  ];
  final narrow = [
    for (final size in sizes)
      b.wr(0, _liteBase + 0x41 + size * 0x40, 3, size: size),
  ];
  for (final x in [...fills, ...narrow]) {
    b.m.write(x);
  }
  await b.drain();
  for (final x in narrow) {
    b.m.read(b.rd(1, x.addr, 3, size: x.size));
  }
  await b.drain();
  await b.sim.stop();
  must(b.errors, isEmpty);
  must(b.check([...fills, ...narrow]).take(20).toList(), isEmpty);
  must(b.l.awOrder.map((y) => y.addr).toList(), [
    for (final x in [...fills, ...narrow])
      for (final a in beatAddrs(x.addr, x.len, x.size, x.burst)) a,
  ]);
}

// Bursts and single beats to the lite and the full slave with no drain
// between them keep their order per ID.
Future<void> _backToBack(HarborFabricTopology t, int dw) async {
  final b = await _Bench.start(t, dw, stall: 0.15);
  final w = b.bytes;
  final writes = <Burst>[];
  final rng = Random(3);
  for (var i = 0; i < 24; i++) {
    final lite = rng.nextBool();
    final len = [0, 0, 3, 7, 15][rng.nextInt(5)];
    final base = lite ? _liteBase : _fullBase + 0x1000;
    writes.add(b.wr(i & 3, base + (i * 0x40), len));
  }
  for (final x in writes) {
    b.m.write(x);
  }
  await b.drain();
  // Reads of the first writes run with a second set of writes to other
  // addresses.
  final more = [
    for (var i = 0; i < 12; i++)
      b.wr(
        i & 3,
        (i.isEven ? _liteBase : _fullBase + 0x1000) + 0x800 + i * 0x40,
        [0, 3, 7][i % 3],
      ),
  ];
  for (final x in more) {
    b.m.write(x);
  }
  final reads = [
    for (final x in writes) b.rd(x.id, x.addr, x.len),
    for (var i = 0; i < 8; i++) b.rd(i & 3, _liteBase + i * w * 4, i & 3),
  ];
  for (final x in reads) {
    b.m.read(x);
  }
  await b.drain();
  await b.sim.stop();
  must(b.check([...writes, ...more]).take(20).toList(), isEmpty);
}

// Bursts the AXI4 rules forbid get SLVERR on every beat and never reach the
// slave: WRAP of 1, 3 or 6 beats, WRAP of 1 beat, and the reserved type.
Future<void> _badBursts(HarborFabricTopology t, int dw) async {
  final b = await _Bench.start(t, dw);
  final w = b.bytes;
  final writes = [
    b.wr(0, _liteBase + 0x100, 2, burst: 2),
    b.wr(1, _liteBase + 0x200, 5, burst: 2),
    b.wr(2, _liteBase + 0x300, 3, burst: 3),
    b.wr(3, _liteBase + 0x400, 0, burst: 3),
    b.wr(0, _liteBase + 0x500, 0, burst: 2),
  ];
  final reads = [
    b.rd(0, _liteBase + 0x100, 2, burst: 2),
    b.rd(1, _liteBase + 0x200 + w, 5, burst: 2),
    b.rd(2, _liteBase + 0x300, 3, burst: 3),
    b.rd(3, _liteBase + 0x400, 0, burst: 3),
    b.rd(0, _liteBase + 0x500, 0, burst: 2),
  ];
  for (final x in writes) {
    b.m.write(x);
  }
  for (final x in reads) {
    b.m.read(x);
  }
  await b.drain();
  await b.sim.stop();
  must(b.errors, isEmpty);
  must(b.m.bResp.map((x) => x.$2).toList(), everyElement(2));
  must(b.m.bResp.length, writes.length);
  must(b.m.rBeats.map((x) => x.$3).toList(), everyElement(2));
  must(b.m.rBeats.length, reads.fold<int>(0, (n, x) => n + x.beats));
  must(b.l.awOrder.length + b.l.arOrder.length, 0);
}

// A lite region under 4 KB has no address bits above it, so a burst that
// leaves it is an error and no beat reaches the slave.
Future<void> _smallRegion(HarborFabricTopology t, int dw) async {
  final w = dw ~/ 8;
  final size = 8 * w;
  final b = await _Bench.start(t, dw, liteSize: size);
  final good = [
    b.wr(0, _liteBase, 3),
    b.wr(1, _liteBase + 4 * w, 3),
    b.wr(2, _liteBase + 3 * w, 7, burst: 2),
    b.wr(3, _liteBase, 7),
    b.wr(0, _liteBase + 2 * w, 3, burst: 2),
    b.wr(1, _liteBase + 2 * w + 2, 3, size: 1),
  ];
  final bad = [
    b.wr(3, _liteBase + size - 2, 3, size: 1),
    b.wr(1, _liteBase + 6 * w, 3),
    b.wr(2, _liteBase + 8 * w - w, 1),
    b.wr(3, _liteBase + 4 * w, 15, burst: 2),
  ];
  bool isBad(Burst x) => bad.any((y) => y.id == x.id && y.addr == x.addr);
  for (final x in [...good, ...bad]) {
    b.m.write(x);
  }
  await b.drain();
  for (final x in [...good, ...bad]) {
    b.m.read(b.rd(x.id, x.addr, x.len, burst: x.burst));
  }
  await b.drain();
  await b.sim.stop();
  must(b.check(good, bad: isBad).take(20).toList(), isEmpty);
  must(b.l.awOrder.map((x) => x.addr).toList(), [
    for (final x in good)
      for (final a in beatAddrs(x.addr, x.len, x.size, x.burst)) a,
  ]);
  must(b.l.arOrder.length, good.fold<int>(0, (n, x) => n + x.beats));
}

// A WRAP burst of 2-byte beats wraps inside its 8 byte window.
Future<void> _narrowWrap(HarborFabricTopology t, int dw) async {
  final b = await _Bench.start(t, dw);
  final fill = b.wr(2, _liteBase, 3);
  final wrap = b.wr(0, _liteBase + 0xc, 3, burst: 2, size: 1);
  b.m.write(fill);
  await b.drain();
  b.m.write(wrap);
  await b.drain();
  b.m.read(b.rd(1, _liteBase + 0xc, 3, burst: 2, size: 1));
  await b.drain();
  await b.sim.stop();
  must(b.errors, isEmpty);
  must(b.check([fill, wrap]).take(20).toList(), isEmpty);
  must(b.l.awOrder.map((x) => x.addr).skip(4).toList(), [
    _liteBase + 0xc,
    _liteBase + 0xe,
    _liteBase + 0x8,
    _liteBase + 0xa,
  ]);
}

void main() {
  forEachPipeline((p) {
    const long = Timeout(Duration(minutes: 5));
    for (final t in HarborFabricTopology.values) {
      for (final dw in [32, 64]) {
        group('${t.name} $dw-bit', () {
          test(
            'INCR, WRAP and FIXED bursts to an AXI4-Lite slave',
            () => isolated(() => _bursts(t, dw)),
            timeout: long,
          );
          test(
            'an error on a middle beat',
            () => isolated(() => _middleError(t, dw)),
            timeout: long,
          );
          test(
            'a narrow burst runs as single beats',
            () => isolated(() => _narrow(t, dw)),
            timeout: long,
          );
          test(
            'a narrow WRAP burst wraps by SIZE',
            () => isolated(() => _narrowWrap(t, dw)),
            timeout: long,
          );
          test(
            'bursts with a guard timeout',
            () => isolated(() => _bursts(t, dw, timeout: 64)),
            timeout: long,
          );
          test(
            'bursts to a slave that sees an offset',
            () => isolated(() => _bursts(t, dw, offset: true)),
            timeout: long,
          );
          test(
            'forbidden bursts are an error',
            () => isolated(() => _badBursts(t, dw)),
            timeout: long,
          );
          test(
            'a burst out of a region under 4 KB is an error',
            () => isolated(() => _smallRegion(t, dw)),
            timeout: long,
          );
          test(
            'back to back bursts and single beats',
            () => isolated(() => _backToBack(t, dw)),
            timeout: long,
          );
        });
      }
    }
  });
}

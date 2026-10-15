// Exclusive access from a memory master waist, through an AXI4 fabric to a
// memory slave with an exclusive monitor, and as plain access on Wishbone
// and TileLink.

import 'dart:collection';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'cdc_harness.dart';
import 'memory_harness.dart';
import 'port_harness.dart';

const _master = HarborMemoryWaistConfig(
  addressWidth: 16,
  dataWidth: 32,
  outstanding: 2,
);

/// The fabric puts the master index above the 1 bit master ID.
const _slave = HarborMemoryWaistConfig(
  addressWidth: 16,
  dataWidth: 32,
  idWidth: 2,
  outstanding: 4,
);

HarborAxi4Exclusive _excl(int granule) => HarborAxi4Exclusive.forMasters(
  [1, 1],
  [HarborExclusive.auto, HarborExclusive.auto],
  granuleBytes: granule,
)!;

/// A memory master port with its waist on ports `<p>_*`. With [cross], the
/// device runs on `clk` and the native port on `fclk`.
class _WaistMaster extends BridgeModule {
  _WaistMaster(String p, {required bool cross})
    : super('WexMaster_${p}_c$cross', name: 'master_$p') {
    for (final n in ['clk', 'reset', 'fclk', 'freset']) {
      createPort(n, PortDirection.input);
    }
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.axi4,
      config: _master,
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: cross
          ? HarborFabricClock(clk: input('fclk'), reset: input('freset'))
          : null,
    );
    exposeWaist(this, port.waist, p, PairRole.consumer);
  }
}

/// Two memory master waists `a_*` and `b_*` on an AXI4 fabric with one
/// monitored memory slave, its waist on `mem_*`. With [cross], master a
/// runs on `clk_a` and master b on `clk_b`, and both cross to the fabric
/// clock `clk`.
class _FabricTop extends BridgeModule {
  _FabricTop(int granule, {bool cross = false})
    : super('WexFabricTop_g${granule}_c$cross', name: 'top') {
    for (final n in [
      'clk',
      'reset',
      if (cross) ...['clk_a', 'reset_a', 'clk_b', 'reset_b'],
    ]) {
      createPort(n, PortDirection.input);
    }
    final excl = _excl(granule);
    final ms = <HarborFabricMaster>[];
    for (final p in ['a', 'b']) {
      final m = addSubModule(_WaistMaster(p, cross: cross));
      m.input('clk').srcConnection! <= input(cross ? 'clk_$p' : 'clk');
      m.input('reset').srcConnection! <= input(cross ? 'reset_$p' : 'reset');
      m.input('fclk').srcConnection! <= input('clk');
      m.input('freset').srcConnection! <= input('reset');
      pullUpInterface(m.interface(p), newIntfName: p);
      ms.add(
        HarborFabricMaster(
          name: p,
          interface: m.interface('bus').interface,
          exclusiveIds: HarborExclusive.auto,
        ),
      );
    }
    final mem = addSubModule(MemSlaveShell(_slave, exclusive: excl));
    for (final n in ['clk', 'reset']) {
      mem.input(n).srcConnection! <= input(n);
    }
    pullUpInterface(mem.interface('mem'), newIntfName: 'mem');
    HarborFabric.build(
      kind: HarborFabricKind.axi4,
      topology: HarborFabricTopology.shared,
      clk: input('clk'),
      reset: input('reset'),
      masters: ms,
      slaves: [
        HarborFabricSlave(
          name: 'mem',
          range: BusAddressRange(0, 0x10000),
          interface: mem.interface('bus').interface,
          outstanding: _slave.outstanding,
          exclusive: excl,
        ),
      ],
    );
  }
}

/// A requester on a master waist on ports `<p>_*`, one word per request.
/// Requests can be in flight together, and responses are kept per ID.
class _Requester {
  final Sim s;
  final String p;
  late final Source _req;
  late final Source _wdata;
  final Queue<Map<String, int>> _data = Queue();
  int _reads = 0;
  int _writes = 0;

  /// Read beats as (data, err, exOkay), per ID.
  final Map<int, List<(int, int, int)>> rBeats = {};

  /// Write responses as (err, exOkay), per ID.
  final Map<int, List<(int, int)>> bResps = {};

  _Requester(this.s, this.p) {
    final rng = Random(p.hashCode);
    _req = Source(s, '${p}_REQ_VALID', '${p}_REQ_READY', rng)
      ..onFire = (f) {
        if (f['${p}_REQ_WRITE'] == 1) {
          _writes++;
          _wdata.queue.add(_data.removeFirst());
        } else {
          _reads++;
        }
      };
    _wdata = Source(s, '${p}_WDATA_VALID', '${p}_WDATA_READY', rng);
    Sink(
      s,
      '${p}_RDATA_VALID',
      '${p}_RDATA_READY',
      [
        '${p}_RDATA_ID',
        '${p}_RDATA_DATA',
        '${p}_RDATA_ERR',
        '${p}_RDATA_EXOKAY',
        '${p}_RDATA_LAST',
      ],
      rng,
      (f) {
        rBeats.putIfAbsent(f['${p}_RDATA_ID']!, () => []).add((
          f['${p}_RDATA_DATA']!,
          f['${p}_RDATA_ERR']!,
          f['${p}_RDATA_EXOKAY']!,
        ));
        if (f['${p}_RDATA_LAST'] == 1) _reads--;
      },
      gate: () => _reads > 0,
    );
    Sink(
      s,
      '${p}_WRESP_VALID',
      '${p}_WRESP_READY',
      ['${p}_WRESP_ID', '${p}_WRESP_ERR', '${p}_WRESP_EXOKAY'],
      rng,
      (f) {
        bResps.putIfAbsent(f['${p}_WRESP_ID']!, () => []).add((
          f['${p}_WRESP_ERR']!,
          f['${p}_WRESP_EXOKAY']!,
        ));
        _writes--;
      },
      gate: () => _writes > 0,
    );
  }

  void _send(int id, int addr, bool write, bool ex) => _req.queue.add({
    '${p}_REQ_ID': id,
    '${p}_REQ_WRITE': write ? 1 : 0,
    '${p}_REQ_ADDR': addr,
    '${p}_REQ_LEN': 0,
    '${p}_REQ_SIZE': 2,
    '${p}_REQ_BURST': HarborMemoryBurst.incr.value,
    '${p}_REQ_EXCLUSIVE': ex ? 1 : 0,
  });

  /// Reads the word at [addr] on [id] and returns (data, err, exOkay). Call
  /// it for one request per ID at a time.
  Future<(int, int, int)> read(int addr, {bool ex = false, int id = 0}) async {
    final l = rBeats.putIfAbsent(id, () => []);
    final n = l.length;
    _send(id, addr, false, ex);
    await waitUntil(s, () => l.length > n);
    return l.last;
  }

  /// Writes [data] to the word at [addr] on [id] and returns (err,
  /// exOkay). Call it for one request per ID at a time.
  Future<(int, int)> write(
    int addr,
    int data, {
    bool ex = false,
    int id = 0,
  }) async {
    final l = bResps.putIfAbsent(id, () => []);
    final n = l.length;
    _data.add({
      '${p}_WDATA_DATA': data,
      '${p}_WDATA_STRB': 0xf,
      '${p}_WDATA_LAST': 1,
    });
    _send(id, addr, true, ex);
    await waitUntil(s, () => l.length > n);
    return l.last;
  }
}

/// The pass and fail cases of master [a] against master [b] on one memory
/// with a monitor of [granule] bytes. Returns the errors.
Future<List<String>> _cases(
  _Requester a,
  _Requester b,
  WaistMemory mem,
  int granule,
) async {
  final bad = <String>[];
  void check(String what, Object? got, Object? want) {
    if (got != want) bad.add('$what: got $got, want $want');
  }

  // A pair with nothing between passes.
  var (_, err, ex) = await a.read(0x100, ex: true);
  check('pass read', (err, ex), (0, 1));
  check('pass write', await a.write(0x100, 0xa1, ex: true), (0, 1));
  check('pass memory', mem.mem.read(0x100), 0xa1);

  // A plain write from b to the same word clears the reservation.
  (_, err, ex) = await a.read(0x200, ex: true);
  check('lost read', (err, ex), (0, 1));
  check('plain write', await b.write(0x200, 0xb2), (0, 0));
  check('lost write', await a.write(0x200, 0xa2, ex: true), (0, 0));
  check('lost memory', mem.mem.read(0x200), 0xb2);

  // A plain write from b to another word of a 64 byte granule.
  (_, err, ex) = await a.read(0x300, ex: true);
  check('granule read', (err, ex), (0, 1));
  check('granule plain write', await b.write(0x304, 0xb3), (0, 0));
  final wide = granule >= 8;
  final before = mem.mem.read(0x300);
  check('granule write', await a.write(0x300, 0xa3, ex: true), (
    0,
    wide ? 0 : 1,
  ));
  check('granule memory', mem.mem.read(0x300), wide ? before : 0xa3);

  // A read from b leaves the reservation.
  (_, err, ex) = await a.read(0x400, ex: true);
  check('shared read', (err, ex), (0, 1));
  (_, err, ex) = await b.read(0x400);
  check('plain read', (err, ex), (0, 0));
  check('shared write', await a.write(0x400, 0xa4, ex: true), (0, 1));
  check('shared memory', mem.mem.read(0x400), 0xa4);

  // A bus error is not a lost reservation.
  (_, err, ex) = await a.read(0xf000, ex: true);
  check('error read', (err, ex), (1, 0));
  check('error write', await a.write(0xf000, 0xa5, ex: true), (1, 0));

  // Two IDs of a with requests in flight together. One reservation breaks
  // and the other does not, once each way, so a response that takes the
  // EXOKAY of the other ID or of the other request fails.
  for (final (lost, kept) in [(1, 0), (0, 1)]) {
    final at = [0x500, 0x600];
    final (r0, r1) = await (
      a.read(at[kept], ex: true, id: kept),
      a.read(at[lost], id: lost),
    ).wait;
    check('mixed read, exclusive id $kept', (r0.$2, r0.$3), (0, 1));
    check('mixed read, plain id $lost', (r1.$2, r1.$3), (0, 0));
    (_, err, ex) = await a.read(at[lost], ex: true, id: lost);
    check('read id $lost', (err, ex), (0, 1));
    check('break id $lost', await b.write(at[lost], 0xb6), (0, 0));
    final (w0, w1) = await (
      a.write(at[kept], 0xc0 + kept, ex: true, id: kept),
      a.write(at[lost], 0xc0 + lost, ex: true, id: lost),
    ).wait;
    check('kept write id $kept', w0, (0, 1));
    check('lost write id $lost', w1, (0, 0));
    check('kept memory id $kept', mem.mem.read(at[kept]), 0xc0 + kept);
    check('lost memory id $lost', mem.mem.read(at[lost]), 0xb6);
  }
  return bad;
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final granule in [4, 64]) {
    test('exclusive access on a fabric, granule $granule', () async {
      final s = Sim(_FabricTop(granule));
      await s.start();
      final errors = <String>[];
      final mem = WaistMemory(
        s,
        'mem',
        Random(granule),
        outstanding: _slave.outstanding,
        busBytes: 4,
        errors: errors,
        stall: 0.2,
      );
      final bad = await _cases(
        _Requester(s, 'a'),
        _Requester(s, 'b'),
        mem,
        granule,
      );
      await s.stop();
      expect(bad, isEmpty);
      expect(errors, isEmpty);
    });

    test('exclusive access through a master crossing, granule $granule', () {
      return isolated(() async {
        final ms = MultiSim(
          _FabricTop(granule, cross: true),
          const Ratio(20, 28, 14),
        );
        await ms.start();
        final errors = <String>[];
        final mem = WaistMemory(
          ms.fabric,
          'mem',
          Random(granule),
          outstanding: _slave.outstanding,
          busBytes: 4,
          errors: errors,
          stall: 0.2,
        );
        final bad = await _cases(
          _Requester(ms.a, 'a'),
          _Requester(ms.b, 'b'),
          mem,
          granule,
        );
        await ms.stop();
        must(bad, isEmpty);
        must(errors, isEmpty);
      });
    });
  }

  final plain = [
    ('AXI4 with no monitor', HarborFabricKind.axi4, 2),
    ('Wishbone, one in flight', HarborFabricKind.wishbone, 1),
    ('Wishbone, queued', HarborFabricKind.wishbone, 2),
    ('TileLink', HarborFabricKind.tilelink, 2),
  ];
  for (final (what, kind, outstanding) in plain) {
    test('$what: exclusive access runs as plain access', () async {
      final config = HarborMemoryWaistConfig(
        addressWidth: 16,
        dataWidth: 32,
        outstanding: outstanding,
      );
      final s = Sim(MemLoopShell(config, kind: kind));
      await s.start();
      final errors = <String>[];
      final mem = WaistMemory(
        s,
        'mem',
        Random(outstanding),
        outstanding: outstanding,
        busBytes: 4,
        errors: errors,
        stall: 0.2,
      );
      final up = _Requester(s, 'up');
      final (data, err, ex) = await up.read(0x100, ex: true);
      expect((data, err, ex), (mem.mem.read(0x100), 0, 0));
      expect(await up.write(0x100, 0x5a, ex: true), (0, 0));
      expect(mem.mem.read(0x100), 0x5a);
      await s.stop();
      expect(errors, isEmpty);
    });
  }
}

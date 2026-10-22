import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/mem_target.dart';
import '../../util/pcie_fabric_memory.dart';
import '../../util/pcie_host_model.dart';

const _completerId = 0x0400;
const _requesterId = 0x0010;
const _barBytes = 1 << 16;
const _addressWidth = 20;

int _fill(int address) => (address * 7 + (address >> 8) + 3) & 0xff;

class _Config {
  final int width;
  final int dataWidth;
  final HarborFabricKind kind;
  final int memoryOffset;
  final int maxPayloadBytes;

  const _Config({
    this.width = 64,
    this.dataWidth = 64,
    this.kind = HarborFabricKind.axi4,
    this.memoryOffset = 0x4000,
    this.maxPayloadBytes = 256,
  });

  @override
  String toString() =>
      'W$width D$dataWidth ${kind.name} offset 0x'
      '${memoryOffset.toRadixString(16)} buffer $maxPayloadBytes';
}

class _Bench {
  final _Config config;
  final Logic clk;
  final Logic reset;
  final Logic maxPayload;
  final Logic rcb128;
  final MasterTop top;
  final PcieFabricMemory memory;
  final PcieStreamDriver driver;
  final PcieStreamSink sink;

  /// Expected memory, by fabric address.
  final Map<int, int> shadow = {};

  _Bench._(
    this.config,
    this.clk,
    this.reset,
    this.maxPayload,
    this.rcb128,
    this.top,
    this.memory,
    this.driver,
    this.sink,
  );

  static Future<_Bench> create(
    _Config config, {
    int seed = 1,
    double gapChance = 0.3,
    double readyChance = 0.6,
  }) async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final maxPayload = Logic(name: 'max_payload', width: 3);
    final rcb128 = Logic(name: 'rcb_128');
    final completerId = Logic(name: 'completer_id', width: 16);
    final dut = HarborPcieMemoryCompleter(
      clk: Logic(),
      reset: Logic(),
      maxPayload: Logic(width: 3),
      rcb128: Logic(),
      completerId: Logic(width: 16),
      rx: HarborPcieStream(width: config.width, name: 'dut_rx'),
      tx: HarborPcieStream(width: config.width, name: 'dut_tx'),
      fabricKind: config.kind,
      dataWidth: config.dataWidth,
      addressWidth: _addressWidth,
      barBytes: _barBytes,
      memoryOffset: config.memoryOffset,
      maxPayloadBytes: config.maxPayloadBytes,
    );
    final top = MasterTop(
      dut,
      iface: 'memory',
      kind: config.kind,
      config: HarborMemoryWaistConfig(
        addressWidth: _addressWidth,
        dataWidth: config.dataWidth,
      ),
      withErr: true,
    );
    await top.build();

    final rx = HarborPcieStream(width: config.width, name: 'rx');
    final tx = HarborPcieStream(width: config.width, name: 'tx');
    top.input('clk').srcConnection! <= clk;
    top.input('reset').srcConnection! <= reset;
    top.input('max_payload').srcConnection! <= maxPayload;
    top.input('rcb_128').srcConnection! <= rcb128;
    top.input('completer_id').srcConnection! <= completerId;
    for (final s in ['data', 'keep', 'last', 'valid', 'user']) {
      top.input('rx_$s').srcConnection! <= _field(rx, s);
      _field(tx, s) <= top.output('tx_$s');
    }
    rx.ready <= top.output('rx_ready');
    top.input('tx_ready').srcConnection! <= tx.ready;

    completerId.inject(_completerId);
    maxPayload.inject(1);
    rcb128.inject(0);
    reset.inject(1);
    final memory = PcieFabricMemory(top, clk, seed: seed + 7, fill: _fill);
    memory.start();
    return _Bench._(
      config,
      clk,
      reset,
      maxPayload,
      rcb128,
      top,
      memory,
      PcieStreamDriver(clk: clk, stream: rx, seed: seed, gapChance: gapChance),
      PcieStreamSink(
        clk: clk,
        stream: tx,
        seed: seed + 1,
        readyChance: readyChance,
      ),
    );
  }

  static Logic _field(HarborPcieStream s, String f) => switch (f) {
    'data' => s.data,
    'keep' => s.keep,
    'last' => s.last,
    'valid' => s.valid,
    _ => s.user,
  };

  int get writeErrors => top.output('write_errors').value.toInt();

  int fabric(int hostAddress) =>
      config.memoryOffset + (hostAddress & (_barBytes - 1));

  /// Fabric bytes of a write, out to 16 byte bounds, so a write that
  /// changes bytes next to it is seen.
  Iterable<int> span(int hostAddress, int bytes) sync* {
    final first = fabric(hostAddress) & ~15;
    final last = fabric(hostAddress + bytes - 1) | 15;
    for (var a = first; a <= last; a++) {
      yield a;
    }
  }

  int expected(int fabricAddress) =>
      shadow[fabricAddress] ?? _fill(fabricAddress);

  Uint8List expectedHost(int hostAddress, int length) => Uint8List.fromList([
    for (var i = 0; i < length; i++) expected(fabric(hostAddress + i)),
  ]);

  /// Sends raw header DWs as one packet with no gaps.
  Future<void> sendRaw(List<int> dwords) async {
    final per = config.width ~/ 32;
    final rx = driver.stream;
    for (var s = 0; s < dwords.length; s += per) {
      var data = BigInt.zero;
      var keep = 0;
      final end = min(s + per, dwords.length);
      for (var i = s; i < end; i++) {
        data |= BigInt.from(dwords[i]) << (32 * (i - s));
        keep |= 0xf << (4 * (i - s));
      }
      rx.data.inject(data);
      rx.keep.inject(keep);
      rx.last.inject(end == dwords.length ? 1 : 0);
      rx.user.inject(HarborPcieStream.userBar2);
      rx.valid.inject(1);
      for (var moved = false; !moved;) {
        await clk.nextNegedge;
        moved = rx.ready.value.toBool();
        await clk.nextPosedge;
      }
    }
    rx.valid.inject(0);
    rx.last.inject(0);
  }

  Future<void> start() async {
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;
    sink.start();
  }

  /// Sends a write and records it in [shadow].
  Future<void> write(PcieTlp tlp) async {
    for (var dw = 0; dw < tlp.lengthDw; dw++) {
      final enable = dw == 0
          ? tlp.firstBe
          : (dw == tlp.lengthDw - 1 ? tlp.lastBe : 0xf);
      for (var b = 0; b < 4; b++) {
        if ((enable >> b) & 1 == 1) {
          shadow[fabric(tlp.address + dw * 4 + b)] = tlp.data[dw * 4 + b];
        }
      }
    }
    await driver.send(tlp, user: HarborPcieStream.userBar2);
  }

  /// Sends a read. Returns the bytes the read must see.
  Future<Uint8List> read(PcieTlp tlp) async {
    final want = expectedHost(tlp.address, tlp.lengthDw * 4);
    await driver.send(tlp, user: HarborPcieStream.userBar2);
    return want;
  }

  /// Checks the completions of [reads] in order. They must be the only
  /// TLPs the sink has.
  Future<void> checkReads(
    List<(PcieTlp, Uint8List)> reads, {
    required int rcb,
    required int maxPayload,
    Set<int> aborted = const {},
  }) async {
    var index = 0;
    for (final (i, (request, want)) in reads.indexed) {
      final group = <PcieTlp>[];
      for (var done = false; !done;) {
        await sink.waitFor(index + 1);
        final c = sink.received[index++];
        group.add(c);
        done =
            c.status != PcieCplStatus.success ||
            c.byteCount <= c.lengthDw * 4 - (c.lowerAddress & 3);
      }
      final errors = pcieCheckReadCompletions(
        request,
        group,
        rcb: rcb,
        maxPayload: maxPayload,
        completerId: _completerId,
        read: (address, length) => Uint8List.sublistView(
          want,
          address - request.address,
        ).sublist(0, length),
        allowAbort: aborted.contains(i),
      );
      expect(errors, isEmpty, reason: '$request');
      if (aborted.contains(i)) {
        expect(group.last.status, PcieCplStatus.abort);
      }
    }
    expect(sink.received.length, index);
  }

  /// Checks that fabric memory matches [shadow] at [addresses].
  void checkMemory(Iterable<int> addresses) {
    for (final a in addresses) {
      final got = memory.byte(a);
      final want = expected(a);
      if (got != want) {
        fail('fabric byte 0x${a.toRadixString(16)} is $got, expected $want');
      }
    }
  }

  Future<void> finish() async {
    sink.stop();
    await clk.nextPosedge;
    await Simulator.endSimulation();
  }
}

List<int> _bytes(Random r, int count) => [
  for (var i = 0; i < count; i++) r.nextInt(256),
];

/// A random request inside one 4 KB page of the BAR at [barBase].
(int, int) _place(Random r, int barBase, int maxDw) {
  final len = 1 + r.nextInt(maxDw);
  final page = r.nextInt(_barBytes ~/ 4096);
  final dw = r.nextInt(1024 - len + 1);
  return (barBase + page * 4096 + dw * 4, len);
}

int _be(Random r) => 1 + r.nextInt(15);

/// Runs [count] random writes and reads back to back and checks them.
Future<void> _mixed(
  _Config config, {
  required int seed,
  required int count,
  int barBase = 0xc0000000,
  bool wide = false,
  int mpsCode = 1,
  bool rcb128 = false,
}) async {
  final bench = await _Bench.create(config, seed: seed);
  final r = Random(seed);
  final mps = min(128 << mpsCode, config.maxPayloadBytes);
  bench.maxPayload.inject(mpsCode);
  bench.rcb128.inject(rcb128 ? 1 : 0);
  await bench.start();
  final reads = <(PcieTlp, Uint8List)>[];
  final touched = <int>{};
  for (var i = 0; i < count; i++) {
    if (r.nextBool()) {
      final (address, len) = _place(r, barBase, mps ~/ 4);
      final tlp = PcieTlp.memWrite(
        address: address,
        data: _bytes(r, len * 4),
        requesterId: _requesterId,
        firstBe: _be(r),
        lastBe: len > 1 ? _be(r) : 0,
        wide: wide,
      );
      touched.addAll(bench.span(address, len * 4));
      await bench.write(tlp);
    } else {
      final (address, len) = _place(r, barBase, 128);
      final tlp = PcieTlp.memRead(
        address: address,
        lengthDw: len,
        requesterId: _requesterId,
        tag: i & 0xff,
        firstBe: len == 1 ? r.nextInt(16) : _be(r),
        lastBe: len > 1 ? _be(r) : 0,
        wide: wide,
      );
      reads.add((tlp, await bench.read(tlp)));
    }
  }
  // A last read flushes the writes before the memory check.
  final flush = PcieTlp.memRead(address: barBase, lengthDw: 1, tag: 0xff);
  reads.add((flush, await bench.read(flush)));
  await bench.checkReads(reads, rcb: rcb128 ? 128 : 64, maxPayload: mps);
  bench.checkMemory(touched);
  expect(bench.writeErrors, 0);
  await bench.finish();
}

void main() {
  tearDown(() async => Simulator.reset());

  test('the BAR size comes from the endpoint BAR2 size', () {
    HarborPcieMemoryCompleter make({
      HarborPcieEndpointConfig? endpoint,
      int? barBytes,
    }) => HarborPcieMemoryCompleter(
      clk: Logic(),
      reset: Logic(),
      maxPayload: Logic(width: 3),
      rcb128: Logic(),
      completerId: Logic(width: 16),
      rx: HarborPcieStream(width: 64),
      tx: HarborPcieStream(width: 64),
      endpointConfig: endpoint,
      barBytes: barBytes,
    );
    const bar2 = HarborPcieEndpointConfig(bar2Bytes: 1 << 20);
    expect(make(endpoint: bar2).barBytes, 1 << 20);
    expect(make(endpoint: bar2, barBytes: 1 << 20).barBytes, 1 << 20);
    expect(make(endpoint: bar2).definitionName, contains('_S100000_'));
    expect(() => make(endpoint: bar2, barBytes: 16 << 20), throwsArgumentError);
    expect(
      () => make(endpoint: const HarborPcieEndpointConfig()),
      throwsArgumentError,
      reason: 'no BAR2',
    );
    expect(make(barBytes: 1 << 16).barBytes, 1 << 16);
    // The BAR2 hit bit comes from the endpoint too.
    expect(make(endpoint: bar2).barHitBit, 4);
    expect(
      () => HarborPcieMemoryCompleter(
        clk: Logic(),
        reset: Logic(),
        maxPayload: Logic(width: 3),
        rcb128: Logic(),
        completerId: Logic(width: 16),
        rx: HarborPcieStream(width: 64),
        tx: HarborPcieStream(width: 64),
        endpointConfig: bar2,
        barHitBit: 2,
      ),
      throwsArgumentError,
    );
    expect(make().barBytes, 16 << 20);
  });

  test('definition names differ per parameter set', () async {
    String nameOf(_Config c) => HarborPcieMemoryCompleter(
      clk: Logic(),
      reset: Logic(),
      maxPayload: Logic(width: 3),
      rcb128: Logic(),
      completerId: Logic(width: 16),
      rx: HarborPcieStream(width: c.width),
      tx: HarborPcieStream(width: c.width),
      fabricKind: c.kind,
      dataWidth: c.dataWidth,
      memoryOffset: c.memoryOffset,
      maxPayloadBytes: c.maxPayloadBytes,
    ).definitionName;
    final names = {
      nameOf(const _Config()),
      nameOf(const _Config(width: 128)),
      nameOf(const _Config(dataWidth: 32)),
      nameOf(const _Config(kind: HarborFabricKind.wishbone)),
      nameOf(const _Config(memoryOffset: 0)),
      nameOf(const _Config(maxPayloadBytes: 512)),
    };
    expect(names, hasLength(6));
  });

  test('rejects bad parameters', () {
    HarborPcieMemoryCompleter make({
      int dataWidth = 64,
      int barBytes = 4096,
      int memoryOffset = 0,
      int maxPayloadBytes = 256,
    }) => HarborPcieMemoryCompleter(
      clk: Logic(),
      reset: Logic(),
      maxPayload: Logic(width: 3),
      rcb128: Logic(),
      completerId: Logic(width: 16),
      rx: HarborPcieStream(width: 64),
      tx: HarborPcieStream(width: 64),
      dataWidth: dataWidth,
      addressWidth: 16,
      barBytes: barBytes,
      memoryOffset: memoryOffset,
      maxPayloadBytes: maxPayloadBytes,
    );
    expect(() => make(dataWidth: 16), throwsArgumentError);
    expect(() => make(barBytes: 2048), throwsArgumentError);
    expect(() => make(memoryOffset: 2), throwsArgumentError);
    expect(() => make(memoryOffset: 0xf004), throwsArgumentError);
    expect(() => make(maxPayloadBytes: 64), throwsArgumentError);
  });

  test('writes with every first and last byte enable, 1 to 64 DW', () async {
    const config = _Config(width: 64, dataWidth: 32);
    final bench = await _Bench.create(config, seed: 3);
    await bench.start();
    final r = Random(3);
    final touched = <int>{};
    var address = 0xc0000000;
    Future<void> send(int len, int firstBe, int lastBe) async {
      if ((address & 0xfff) + len * 4 > 0x1000) {
        address = (address & ~0xfff) + 0x1000;
      }
      final tlp = PcieTlp.memWrite(
        address: address,
        data: _bytes(r, len * 4),
        firstBe: firstBe,
        lastBe: lastBe,
      );
      touched.addAll(bench.span(address, len * 4));
      await bench.write(tlp);
      address += len * 4 + 4 * r.nextInt(3);
    }

    for (var first = 0; first < 16; first++) {
      await send(1, first, 0);
    }
    for (final len in [2, 3]) {
      for (var first = 1; first < 16; first++) {
        for (var last = 1; last < 16; last++) {
          await send(len, first, last);
        }
      }
    }
    for (var len = 1; len <= 64; len++) {
      await send(len, _be(r), len > 1 ? _be(r) : 0);
    }
    final flush = PcieTlp.memRead(address: 0xc0000000, lengthDw: 1);
    final want = await bench.read(flush);
    await bench.checkReads([(flush, want)], rcb: 64, maxPayload: 256);
    bench.checkMemory(touched);
    expect(bench.writeErrors, 0);
    await bench.finish();
  });

  for (final (mpsCode, rcb128) in [
    (0, false),
    (0, true),
    (1, false),
    (1, true),
  ]) {
    test('reads split by max payload ${128 << mpsCode} and RCB '
        '${rcb128 ? 128 : 64}', () async {
      const config = _Config(width: 64, dataWidth: 64);
      final bench = await _Bench.create(config, seed: 5 + mpsCode);
      bench.maxPayload.inject(mpsCode);
      bench.rcb128.inject(rcb128 ? 1 : 0);
      await bench.start();
      final r = Random(11 + mpsCode * 2 + (rcb128 ? 1 : 0));
      final reads = <(PcieTlp, Uint8List)>[];
      Future<void> read(int address, int len, int firstBe, int lastBe) async {
        final tlp = PcieTlp.memRead(
          address: address,
          lengthDw: len,
          requesterId: _requesterId,
          tag: reads.length,
          firstBe: firstBe,
          lastBe: lastBe,
        );
        reads.add((tlp, await bench.read(tlp)));
      }

      // Zero length, a full 4 KB page, and reads that end at a page end.
      await read(0xc0001010, 1, 0, 0);
      await read(0xc0002000, 1024, 0xf, 0xf);
      await read(0xc0003f00, 64, 0xe, 0x7);
      await read(0xc0004ffc, 1, 0x6, 0);
      for (var i = 0; i < 30; i++) {
        final (address, len) = _place(r, 0xc0000000, 256);
        await read(
          address,
          len,
          len == 1 ? r.nextInt(16) : _be(r),
          len > 1 ? _be(r) : 0,
        );
      }
      await bench.checkReads(
        reads,
        rcb: rcb128 ? 128 : 64,
        maxPayload: 128 << mpsCode,
      );
      await bench.finish();
    });
  }

  test('a fabric read error gives a CA completion', () async {
    const config = _Config(width: 64, dataWidth: 64);
    final bench = await _Bench.create(config, seed: 21);
    await bench.start();
    bench.memory.errorBeats.add(bench.fabric(0xc0000140));
    final reads = <(PcieTlp, Uint8List)>[];
    for (final (address, len) in [
      (0xc0000100, 128),
      (0xc0000140, 1),
      (0xc0000200, 16),
    ]) {
      final tlp = PcieTlp.memRead(
        address: address,
        lengthDw: len,
        tag: reads.length,
      );
      reads.add((tlp, await bench.read(tlp)));
    }
    await bench.checkReads(reads, rcb: 64, maxPayload: 256, aborted: {0, 1});
    // The first read sends the chunk before the error, then CA.
    final firstCa = bench.sink.received.indexWhere(
      (c) => c.status == PcieCplStatus.abort,
    );
    expect(firstCa, 1);
    expect(bench.sink.received[1].byteCount, 512 - 0x40);
    expect(bench.sink.received[1].lowerAddress, 0x40);
    await bench.finish();
  });

  test('write errors and poisoned writes are dropped and counted', () async {
    const config = _Config(width: 64, dataWidth: 32);
    final bench = await _Bench.create(config, seed: 23);
    await bench.start();
    bench.memory.errorBeats.add(bench.fabric(0xc0000208));
    final r = Random(23);
    final poisoned = PcieTlp.memWrite(
      address: 0xc0000100,
      data: _bytes(r, 16),
      poisoned: true,
    );
    await bench.driver.send(poisoned, user: HarborPcieStream.userBar2);
    final failing = PcieTlp.memWrite(address: 0xc0000200, data: _bytes(r, 32));
    await bench.driver.send(failing, user: HarborPcieStream.userBar2);
    final good = PcieTlp.memWrite(address: 0xc0000300, data: _bytes(r, 32));
    await bench.write(good);
    final flush = PcieTlp.memRead(address: 0xc0000100, lengthDw: 4);
    final want = await bench.read(flush);
    await bench.checkReads([(flush, want)], rcb: 64, maxPayload: 256);
    expect(bench.writeErrors, 2);
    bench.checkMemory([
      for (var i = 0; i < 16; i++) bench.fabric(0xc0000100 + i),
    ]);
    bench.checkMemory([
      for (var i = 0; i < 32; i++) bench.fabric(0xc0000300 + i),
    ]);
    await bench.finish();
  });

  for (final width in [64, 128]) {
    test('a non-posted request that is not a read gets UR, W$width', () async {
      final bench = await _Bench.create(_Config(width: width), seed: 25);
      await bench.start();
      // An IO read with tag 0x1a, then a memory read behind it.
      await bench.sendRaw([0x02502001, 0x00101a0f, 0x00000010]);
      final tlp = PcieTlp.memRead(address: 0xc0000010, lengthDw: 2, tag: 3);
      final want = await bench.read(tlp);
      await bench.sink.waitFor(2);
      final ur = bench.sink.received.first;
      expect(ur.kind, PcieTlpKind.cpl);
      expect(ur.status, PcieCplStatus.unsupported);
      expect(ur.tag, 0x1a);
      expect(ur.tc, 5);
      expect(ur.attr, 2);
      expect(ur.requesterId, 0x0010);
      expect(ur.completerId, _completerId);
      bench.sink.received.removeAt(0);
      await bench.checkReads([(tlp, want)], rcb: 64, maxPayload: 256);
      await bench.finish();
    });
  }

  test('completions echo the request TC and attr', () async {
    const config = _Config(width: 64, dataWidth: 64);
    final bench = await _Bench.create(config, seed: 33);
    await bench.start();
    final reads = <(PcieTlp, Uint8List)>[];
    for (final (i, (tc, attr, len)) in [
      (1, 1, 4),
      (7, 3, 100),
      (3, 2, 1),
      (6, 0, 70),
    ].indexed) {
      final tlp = PcieTlp.memRead(
        address: 0xc0000100 + i * 0x400,
        lengthDw: len,
        tag: i,
        tc: tc,
        attr: attr,
      );
      reads.add((tlp, await bench.read(tlp)));
    }
    await bench.checkReads(reads, rcb: 64, maxPayload: 256);
    expect(bench.sink.received.every((c) => c.tc != 0 || c.attr != 0), isTrue);
    await bench.finish();
  });

  test('read after write sees the write', () async {
    const config = _Config(width: 64, dataWidth: 64);
    final bench = await _Bench.create(config, seed: 27);
    await bench.start();
    final r = Random(27);
    final reads = <(PcieTlp, Uint8List)>[];
    for (var i = 0; i < 20; i++) {
      final (address, len) = _place(r, 0xc0000000, 64);
      await bench.write(
        PcieTlp.memWrite(
          address: address,
          data: _bytes(r, len * 4),
          firstBe: _be(r),
          lastBe: len > 1 ? _be(r) : 0,
        ),
      );
      final tlp = PcieTlp.memRead(address: address, lengthDw: len, tag: i);
      reads.add((tlp, await bench.read(tlp)));
    }
    await bench.checkReads(reads, rcb: 64, maxPayload: 256);
    await bench.finish();
  });

  test('bursts across a fabric 4 KB boundary and the 256 beat limit', () async {
    // Fabric page ends are at host offsets 0x7f0, 0x17f0 and 0x27f0.
    const config = _Config(
      width: 64,
      dataWidth: 32,
      memoryOffset: 0x4810,
      maxPayloadBytes: 2048,
    );
    final bench = await _Bench.create(config, seed: 29);
    bench.maxPayload.inject(4);
    await bench.start();
    final r = Random(29);
    final touched = <int>{};
    final reads = <(PcieTlp, Uint8List)>[];
    for (final (address, bytes) in [
      (0xc0000600, 512),
      (0xc0001000, 2048),
      (0xc0002600, 512),
    ]) {
      final tlp = PcieTlp.memWrite(
        address: address,
        data: _bytes(r, bytes),
        firstBe: 0xe,
        lastBe: 0x3,
      );
      touched.addAll(bench.span(address, bytes));
      await bench.write(tlp);
    }
    for (final (address, len) in [(0xc0000700, 64), (0xc0001000, 1024)]) {
      final tlp = PcieTlp.memRead(
        address: address,
        lengthDw: len,
        tag: reads.length,
      );
      reads.add((tlp, await bench.read(tlp)));
    }
    await bench.checkReads(reads, rcb: 64, maxPayload: 2048);
    bench.checkMemory(touched);
    await bench.finish();
  });

  for (final (seed, config) in [
    (41, const _Config(width: 64, dataWidth: 32)),
    (42, const _Config(width: 64, dataWidth: 64, memoryOffset: 0x4004)),
    (43, const _Config(width: 128, dataWidth: 128, memoryOffset: 0x4008)),
    (44, const _Config(kind: HarborFabricKind.wishbone, memoryOffset: 0x400c)),
    (45, const _Config(kind: HarborFabricKind.tilelink, memoryOffset: 0x400c)),
    (
      46,
      const _Config(width: 128, dataWidth: 64, kind: HarborFabricKind.wishbone),
    ),
  ]) {
    test('mixed writes and reads, $config', () async {
      await _mixed(config, seed: seed, count: 60);
    });
  }

  test('mixed writes and reads with 4DW headers', () async {
    await _mixed(
      const _Config(width: 128, dataWidth: 128),
      seed: 31,
      count: 40,
      barBase: 0x200000000,
      rcb128: true,
    );
  });
}

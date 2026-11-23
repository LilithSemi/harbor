import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'mem_target.dart';
import 'pcie_fabric_memory.dart';
import 'pcie_host_model.dart';

const kCompleterId = 0x0400;
const kRequesterId = 0x0010;
const kBarBytes = 1 << 16;
const kAddressWidth = 20;

int completerFill(int address) => (address * 7 + (address >> 8) + 3) & 0xff;

class CompleterConfig {
  final int width;
  final int dataWidth;
  final HarborFabricKind kind;
  final int memoryOffset;
  final int maxPayloadBytes;

  const CompleterConfig({
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

class CompleterBench {
  final CompleterConfig config;
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

  CompleterBench._(
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

  static Future<CompleterBench> create(
    CompleterConfig config, {
    int seed = 1,
    double gapChance = 0.3,
    double readyChance = 0.6,
    int timeoutCycles = 8192,
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
      addressWidth: kAddressWidth,
      barBytes: kBarBytes,
      memoryOffset: config.memoryOffset,
      maxPayloadBytes: config.maxPayloadBytes,
      timeoutCycles: timeoutCycles,
    );
    final top = MasterTop(
      dut,
      iface: 'memory',
      kind: config.kind,
      config: HarborMemoryWaistConfig(
        addressWidth: kAddressWidth,
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

    completerId.inject(kCompleterId);
    maxPayload.inject(1);
    rcb128.inject(0);
    reset.inject(1);
    final memory = PcieFabricMemory(
      top,
      clk,
      seed: seed + 7,
      fill: completerFill,
    );
    memory.start();
    return CompleterBench._(
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

  int get timeoutErrors => top.output('timeout_errors').value.toInt();

  int get wedged => top.output('wedged').value.toInt();

  Future<void> idle(int cycles) async {
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
    }
  }

  int fabric(int hostAddress) =>
      config.memoryOffset + (hostAddress & (kBarBytes - 1));

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
      shadow[fabricAddress] ?? completerFill(fabricAddress);

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
        completerId: kCompleterId,
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

List<int> randomBytes(Random r, int count) => [
  for (var i = 0; i < count; i++) r.nextInt(256),
];

/// A random request inside one 4 KB page of the BAR at [barBase].
(int, int) placeRequest(Random r, int barBase, int maxDw) {
  final len = 1 + r.nextInt(maxDw);
  final page = r.nextInt(kBarBytes ~/ 4096);
  final dw = r.nextInt(1024 - len + 1);
  return (barBase + page * 4096 + dw * 4, len);
}

int randomBe(Random r) => 1 + r.nextInt(15);

/// Runs [count] random writes and reads back to back and checks them.
Future<void> runMixed(
  CompleterConfig config, {
  required int seed,
  required int count,
  int barBase = 0xc0000000,
  bool wide = false,
  int mpsCode = 1,
  bool rcb128 = false,
}) async {
  final bench = await CompleterBench.create(config, seed: seed);
  final r = Random(seed);
  final mps = min(128 << mpsCode, config.maxPayloadBytes);
  bench.maxPayload.inject(mpsCode);
  bench.rcb128.inject(rcb128 ? 1 : 0);
  await bench.start();
  final reads = <(PcieTlp, Uint8List)>[];
  final touched = <int>{};
  for (var i = 0; i < count; i++) {
    if (r.nextBool()) {
      final (address, len) = placeRequest(r, barBase, mps ~/ 4);
      final tlp = PcieTlp.memWrite(
        address: address,
        data: randomBytes(r, len * 4),
        requesterId: kRequesterId,
        firstBe: randomBe(r),
        lastBe: len > 1 ? randomBe(r) : 0,
        wide: wide,
      );
      touched.addAll(bench.span(address, len * 4));
      await bench.write(tlp);
    } else {
      final (address, len) = placeRequest(r, barBase, 128);
      final tlp = PcieTlp.memRead(
        address: address,
        lengthDw: len,
        requesterId: kRequesterId,
        tag: i & 0xff,
        firstBe: len == 1 ? r.nextInt(16) : randomBe(r),
        lastBe: len > 1 ? randomBe(r) : 0,
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

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/mem_target.dart';
import '../../util/pcie_fabric_memory.dart';
import '../../util/pcie_host_model.dart';

const _completerId = 0x0100;
const _bar0 = 0xf7000000;
const _addressWidth = 20;
const _cplBase = 0x90000000;

int _fill(int address) => (address * 13 + (address >> 8) + 5) & 0xff;

int _hostFill(int address) => (address * 7 + (address >> 9) + 0x31) & 0xff;

class _Config {
  final int width;
  final int dataWidth;
  final HarborFabricKind kind;
  final int queueDepth;
  final int readTags;
  final int irqLines;
  final List<int> infoWords;
  final int timeoutCycles;
  final int maxReadRequestBytes;

  const _Config({
    this.width = 64,
    this.dataWidth = 64,
    this.kind = HarborFabricKind.axi4,
    this.queueDepth = 64,
    this.readTags = 8,
    this.irqLines = 0,
    this.infoWords = const [],
    this.timeoutCycles = 6250000,
    this.maxReadRequestBytes = 512,
  });

  @override
  String toString() => 'W$width D$dataWidth ${kind.name}';
}

class _Record {
  final int cookie;
  final int code;
  final bool phase;
  final int bytes;

  _Record(Uint8List b)
    : cookie = _le(b, 0),
      code = _le(b, 4) & 0xff,
      phase = (_le(b, 4) >> 31) == 1,
      bytes = _le(b, 8);

  static int _le(Uint8List b, int o) =>
      b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;

  @override
  String toString() =>
      'record(cookie $cookie code $code phase $phase '
      'bytes $bytes)';
}

List<int> _leBytes(int value, [int count = 4]) => [
  for (var i = 0; i < count; i++) (value >> (8 * i)) & 0xff,
];

class _Bench {
  final _Config config;
  final HarborPcieDma dut;
  final MasterTop top;
  final Logic clk;
  final Logic reset;
  final Logic maxPayload;
  final Logic maxReadRequest;
  final Logic busMaster;
  final Logic msiEnable;
  final Logic granted;
  final Logic? lines;
  final PcieFabricMemory memory;
  final PcieStreamDriver driver;
  final PcieStreamSink sink;
  final PcieHostModel host;
  int _tag = 0;
  int cplBase = _cplBase;
  Future<void> _sendLock = Future.value();

  /// Completions wait while this is set.
  bool holdCompletions = false;

  /// TLPs sent before the responder completions.
  final List<PcieTlp> injected = [];
  bool _pumping = false;

  _Bench._(
    this.config,
    this.dut,
    this.top,
    this.clk,
    this.reset,
    this.maxPayload,
    this.maxReadRequest,
    this.busMaster,
    this.msiEnable,
    this.granted,
    this.lines,
    this.memory,
    this.driver,
    this.sink,
    this.host,
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
    final maxReadRequest = Logic(name: 'max_read_request', width: 3);
    final busMaster = Logic(name: 'bus_master');
    final msiEnable = Logic(name: 'msi_enable');
    final granted = Logic(name: 'granted', width: 3);
    final completerId = Logic(name: 'completer_id', width: 16);
    final lines = config.irqLines == 0
        ? null
        : Logic(name: 'lines', width: config.irqLines);
    final dut = HarborPcieDma(
      clk: Logic(),
      reset: Logic(),
      completerId: Logic(width: 16),
      maxPayload: Logic(width: 3),
      maxReadRequest: Logic(width: 3),
      rcb128: Logic(),
      busMasterEnable: Logic(),
      msiEnable: Logic(),
      msiVectorsGranted: Logic(width: 3),
      rx: HarborPcieStream(width: config.width, name: 'dut_rx'),
      tx: HarborPcieStream(width: config.width, name: 'dut_tx'),
      irqInputs: config.irqLines == 0 ? null : Logic(width: config.irqLines),
      fabricKind: config.kind,
      dataWidth: config.dataWidth,
      addressWidth: _addressWidth,
      queueDepth: config.queueDepth,
      readTags: config.readTags,
      irqLines: config.irqLines,
      infoWords: config.infoWords,
      timeoutCycles: config.timeoutCycles,
      maxReadRequestBytes: config.maxReadRequestBytes,
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
    top.input('completer_id').srcConnection! <= completerId;
    top.input('max_payload').srcConnection! <= maxPayload;
    top.input('max_read_request').srcConnection! <= maxReadRequest;
    top.input('rcb_128').srcConnection! <= Const(0);
    top.input('bus_master_enable').srcConnection! <= busMaster;
    top.input('msi_enable').srcConnection! <= msiEnable;
    top.input('msi_vectors_granted').srcConnection! <= granted;
    if (lines != null) top.input('irq_lines').srcConnection! <= lines;
    for (final s in ['data', 'keep', 'last', 'valid', 'user']) {
      top.input('rx_$s').srcConnection! <= _field(rx, s);
      _field(tx, s) <= top.output('tx_$s');
    }
    rx.ready <= top.output('rx_ready');
    top.input('tx_ready').srcConnection! <= tx.ready;

    completerId.inject(_completerId);
    maxPayload.inject(0);
    maxReadRequest.inject(2);
    busMaster.inject(1);
    msiEnable.inject(0);
    granted.inject(0);
    lines?.inject(0);
    reset.inject(1);
    final memory = PcieFabricMemory(top, clk, seed: seed + 7, fill: _fill);
    memory.start();
    final host = PcieHostModel(seed: seed, maxPayload: 128);
    return _Bench._(
      config,
      dut,
      top,
      clk,
      reset,
      maxPayload,
      maxReadRequest,
      busMaster,
      msiEnable,
      granted,
      lines,
      memory,
      PcieStreamDriver(clk: clk, stream: rx, seed: seed, gapChance: gapChance),
      PcieStreamSink(
        clk: clk,
        stream: tx,
        seed: seed + 1,
        readyChance: readyChance,
        onTlp: host.receive,
      ),
      host,
    );
  }

  static Logic _field(HarborPcieStream s, String f) => switch (f) {
    'data' => s.data,
    'keep' => s.keep,
    'last' => s.last,
    'valid' => s.valid,
    _ => s.user,
  };

  int get irqPending => top.output('irq_pending').value.toInt();

  Future<void> start() async {
    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;
    sink.start();
    _pumping = true;
    unawaited(_pump());
  }

  /// Sends TLPs on RX one at a time.
  Future<void> send(PcieTlp tlp) {
    final done = _sendLock.then((_) => driver.send(tlp));
    _sendLock = done;
    return done;
  }

  Future<void> _pump() async {
    while (_pumping) {
      final tlp = holdCompletions
          ? null
          : (injected.isNotEmpty
                ? injected.removeAt(0)
                : host.responder.next());
      if (tlp == null) {
        await clk.nextPosedge;
      } else {
        await send(tlp);
      }
    }
  }

  Future<void> finish() async {
    _pumping = false;
    sink.stop();
    await clk.nextPosedge;
    await Simulator.endSimulation();
  }

  Future<void> cycles(int count) async {
    for (var i = 0; i < count; i++) {
      await clk.nextPosedge;
    }
  }

  Future<void> waitUntil(
    bool Function() done, {
    int timeout = 20000,
    String what = 'condition',
  }) async {
    for (var i = 0; !done(); i++) {
      if (i >= timeout) fail('timeout waiting for $what');
      await clk.nextPosedge;
    }
  }

  Future<void> writeRegs(int offset, List<int> values, {int firstBe = 0xf}) =>
      send(
        PcieTlp.memWrite(
          address: _bar0 + offset,
          data: [for (final v in values) ..._leBytes(v)],
          firstBe: firstBe,
        ),
      );

  Future<void> writeReg(int offset, int value, {int firstBe = 0xf}) =>
      writeRegs(offset, [value], firstBe: firstBe);

  /// Sends a BAR0 read and returns its completion.
  Future<PcieTlp> readRaw(int offset, int lengthDw) async {
    final tag = _tag++ & 0xff;
    final request = PcieTlp.memRead(
      address: _bar0 + offset,
      lengthDw: lengthDw,
      tag: tag,
      tc: 2,
      attr: 1,
    );
    final before = host.completions.length;
    await send(request);
    await waitUntil(
      () => host.completions.length > before,
      what: 'BAR0 read 0x${offset.toRadixString(16)}',
    );
    final c = host.completions[before];
    expect(c.tag, tag);
    expect(c.completerId, _completerId);
    expect(c.tc, 2);
    expect(c.attr, 1);
    return c;
  }

  Future<List<int>> readRegs(int offset, int count) async {
    final c = await readRaw(offset, count);
    expect(c.status, PcieCplStatus.success);
    expect(c.lengthDw, count);
    expect(c.byteCount, count * 4);
    expect(c.lowerAddress, (_bar0 + offset) & 0x7f);
    return [for (var i = 0; i < count; i++) _Record._le(c.data, 4 * i)];
  }

  Future<int> readReg(int offset) async => (await readRegs(offset, 1)).first;

  Future<void> setupRing(int base, int log2) async {
    cplBase = base;
    await writeReg(HarborPcieDma.registerCplBaseLow, base & 0xffffffff);
    await writeReg(HarborPcieDma.registerCplBaseHigh, base >> 32);
    await writeReg(HarborPcieDma.registerCplSize, log2);
  }

  Future<void> enable({int mask = 0}) async {
    await writeReg(HarborPcieDma.registerIrqMask, mask);
    await writeReg(HarborPcieDma.registerControl, HarborPcieDma.controlEnable);
  }

  Future<void> engineReset() => writeReg(
    HarborPcieDma.registerControl,
    HarborPcieDma.controlEnable | HarborPcieDma.controlEngineReset,
  );

  Future<void> push({
    required int hostAddress,
    required int localAddress,
    required int length,
    bool deviceToHost = true,
    bool irq = false,
    int cookie = 0,
  }) => writeRegs(HarborPcieDma.registerPush, [
    hostAddress & 0xffffffff,
    hostAddress >> 32,
    localAddress & 0xffffffff,
    localAddress >> 32,
    length,
    (deviceToHost ? HarborPcieDma.flagDeviceToHost : 0) |
        (irq ? HarborPcieDma.flagIrq : 0),
    cookie,
    0,
  ]);

  int recordAddress(int slot) => cplBase + 16 * slot;

  _Record record(int slot) =>
      _Record(host.memory.read(recordAddress(slot), 16));

  /// Index in the sink of the memory write to a record slot.
  List<int> recordWrites(int slot) => [
    for (final (i, t) in sink.received.indexed)
      if (t.kind.isRequest &&
          t.kind.hasData &&
          t.address == recordAddress(slot))
        i,
  ];

  Future<void> waitRecordWrites(int slot, int count) => waitUntil(
    () => recordWrites(slot).length >= count,
    what: 'record write $count at slot $slot',
  );

  /// Memory reads the engine sent.
  List<PcieTlp> get reads => [
    for (final t in sink.received)
      if (t.kind == PcieTlpKind.memRead32 || t.kind == PcieTlpKind.memRead64) t,
  ];

  /// Fills host memory with a pattern.
  void seedHost(int address, int length) {
    host.memory.write(address, [
      for (var i = 0; i < length; i++) _hostFill(address + i),
    ]);
  }

  /// Returns the first local byte that differs from the host, or null.
  String? localDiff(int hostAddress, int localAddress, int length) {
    final want = host.memory.read(hostAddress, length);
    for (var i = 0; i < length; i++) {
      if (want[i] != memory.byte(localAddress + i)) {
        return 'local byte 0x${(localAddress + i).toRadixString(16)} is '
            '${memory.byte(localAddress + i)}, expected ${want[i]}';
      }
    }
    return null;
  }

  /// Checks fabric bytes against host bytes.
  void checkLocal(int hostAddress, int localAddress, int length) {
    final diff = localDiff(hostAddress, localAddress, length);
    if (diff != null) fail(diff);
  }

  /// Checks host bytes against fabric bytes.
  void checkCopy(int hostAddress, int localAddress, int length) {
    final got = host.memory.read(hostAddress, length);
    for (var i = 0; i < length; i++) {
      if (got[i] != memory.byte(localAddress + i)) {
        fail(
          'host byte 0x${(hostAddress + i).toRadixString(16)} is ${got[i]}, '
          'expected ${memory.byte(localAddress + i)}',
        );
      }
    }
  }
}

HarborPcieDma _dma({
  int width = 64,
  bool ringSource = false,
  bool fifoSource = true,
  int queueDepth = 64,
  int readTags = 8,
  int irqLines = 0,
  int timeoutCycles = 6250000,
  int maxReadRequestBytes = 512,
  List<int> infoWords = const [],
}) => HarborPcieDma(
  clk: Logic(),
  reset: Logic(),
  completerId: Logic(width: 16),
  maxPayload: Logic(width: 3),
  maxReadRequest: Logic(width: 3),
  rcb128: Logic(),
  busMasterEnable: Logic(),
  msiEnable: Logic(),
  msiVectorsGranted: Logic(width: 3),
  rx: HarborPcieStream(width: width),
  tx: HarborPcieStream(width: width),
  irqInputs: irqLines == 0 ? null : Logic(width: irqLines),
  fifoSource: fifoSource,
  ringSource: ringSource,
  queueDepth: queueDepth,
  readTags: readTags,
  irqLines: irqLines,
  timeoutCycles: timeoutCycles,
  maxReadRequestBytes: maxReadRequestBytes,
  infoWords: infoWords,
);

void main() {
  tearDown(() async => Simulator.reset());

  // ROHD keeps the wires of earlier benches in the tick loop after a reset,
  // so later tests run slower. Long simulations go first, the build checks
  // last.
  for (final (config, count) in [
    (const _Config(), 500),
    (const _Config(width: 128, dataWidth: 128), 60),
    (const _Config(width: 128, kind: HarborFabricKind.wishbone), 60),
  ]) {
    test(
      'random mix of $count descriptors, $config',
      () async {
        await _randomMix(config, count);
      },
      timeout: const Timeout(Duration(hours: 3)),
    );
  }

  for (final config in [
    const _Config(),
    const _Config(width: 128, dataWidth: 128),
    const _Config(dataWidth: 32),
    const _Config(dataWidth: 128),
    const _Config(width: 128, kind: HarborFabricKind.wishbone),
  ]) {
    test('host to device copies edge sizes, $config', () async {
      final b = await _Bench.create(
        config,
        seed: config.width + config.dataWidth + 3,
      );
      final jobs = [
        (0x80000000, 0x01000, 4),
        (0x80001000, 0x02000, 128),
        (0x80002000, 0x03004, 132),
        (0x80003f40, 0x04008, 0x180),
        (0x180004104, 0x0500c, 1000),
        (0x80006000, 0x06000, 0),
        (0x80008004, 0x08008, 0x2000),
      ];
      for (final (h, _, len) in jobs) {
        b.seedHost(h, len);
      }
      // Each record must come after the local data of its descriptor.
      final early = <String>[];
      b.sink.onTlp = (t) {
        final slot = (t.address - _cplBase) ~/ 16;
        if (t.kind.hasData && slot >= 0 && slot < jobs.length) {
          final (h, l, len) = jobs[slot];
          final diff = b.localDiff(h, l, len);
          if (diff != null) early.add('record $slot: $diff');
        }
        b.host.receive(t);
      };
      await b.start();
      await b.setupRing(_cplBase, 4);
      await b.enable();
      for (final (i, (h, l, len)) in jobs.indexed) {
        await b.push(
          hostAddress: h,
          localAddress: l,
          length: len,
          deviceToHost: false,
          cookie: 0xd00 + i,
        );
      }
      await b.waitRecordWrites(jobs.length - 1, 1);
      expect(b.host.violations, isEmpty);
      expect(early, isEmpty);
      for (final (i, (h, l, len)) in jobs.indexed) {
        b.checkLocal(h, l, len);
        expect(b.memory.bytes.containsKey(l - 1), isFalse, reason: 'job $i');
        expect(b.memory.bytes.containsKey(l + len), isFalse, reason: 'job $i');
        final r = b.record(i);
        expect(r.cookie, 0xd00 + i);
        expect(r.code, 0);
        expect(r.bytes, len);
      }
      for (final t in b.reads) {
        expect(t.requesterId, _completerId);
        expect(t.lengthDw * 4, lessThanOrEqualTo(512));
        expect(
          t.kind,
          t.address > 0xffffffff
              ? PcieTlpKind.memRead64
              : PcieTlpKind.memRead32,
        );
      }
      expect(b.reads.where((t) => t.address > 0xffffffff), isNotEmpty);
      expect(await b.readReg(HarborPcieDma.registerStaleCompletions), 0);
      expect(await b.readReg(HarborPcieDma.registerStatus) & 3, 0);
      await b.finish();
    });
  }

  test('8 reads in flight at the host', () async {
    final b = await _Bench.create(const _Config(), seed: 21);
    b.seedHost(0x80010000, 0x2000);
    b.holdCompletions = true;
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable();
    await b.push(
      hostAddress: 0x80010000,
      localAddress: 0x10000,
      length: 0x2000,
      deviceToHost: false,
    );
    await b.waitUntil(() => b.reads.length >= 8, what: '8 reads');
    await b.cycles(300);
    expect(b.reads, hasLength(8));
    expect(b.reads.map((t) => t.tag).toSet(), hasLength(8));
    expect(b.reads.every((t) => t.lengthDw == 128), isTrue);
    b.holdCompletions = false;
    await b.waitRecordWrites(0, 1);
    expect(b.reads, hasLength(16));
    expect(b.record(0).bytes, 0x2000);
    b.checkLocal(0x80010000, 0x10000, 0x2000);
    expect(b.host.violations, isEmpty);
    await b.finish();
  });

  test('read size follows max read request and the build limit', () async {
    final b = await _Bench.create(const _Config(width: 128, dataWidth: 128));
    b.host.responder.rcb = 128;
    b.host.responder.maxPayload = 256;
    b.seedHost(0x80000000, 0x3000);
    b.maxReadRequest.inject(0);
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable();
    await b.push(
      hostAddress: 0x80000040,
      localAddress: 0x100,
      length: 0x7c0,
      deviceToHost: false,
    );
    await b.waitRecordWrites(0, 1);
    expect(b.reads.map((t) => t.lengthDw * 4).toSet(), {64, 128});
    b.checkLocal(0x80000040, 0x100, 0x7c0);
    // 1024 is above the 512 byte buffer of a tag.
    b.maxReadRequest.inject(3);
    final before = b.reads.length;
    await b.push(
      hostAddress: 0x80001000,
      localAddress: 0x2000,
      length: 0x1000,
      deviceToHost: false,
    );
    await b.waitRecordWrites(1, 1);
    expect(b.reads.skip(before).map((t) => t.lengthDw * 4), [
      512,
      512,
      512,
      512,
      512,
      512,
      512,
      512,
    ]);
    b.checkLocal(0x80001000, 0x2000, 0x1000);
    expect(b.host.violations, isEmpty);
    await b.finish();
  });

  test('no memory read goes out without bus master enable', () async {
    final b = await _Bench.create(const _Config());
    b.seedHost(0x80000000, 64);
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable();
    b.busMaster.inject(0);
    await b.push(
      hostAddress: 0x80000000,
      localAddress: 0,
      length: 64,
      deviceToHost: false,
    );
    await b.cycles(300);
    expect(b.sink.received.where((t) => t.kind.isRequest), isEmpty);
    b.busMaster.inject(1);
    await b.waitRecordWrites(0, 1);
    b.checkLocal(0x80000000, 0, 64);
    await b.finish();
  });

  test('completion errors and timeout halt with their code', () async {
    final b = await _Bench.create(const _Config(timeoutCycles: 3000));
    b.seedHost(0x80000000, 0x400);
    String? mode;
    PcieTlp? dropped;
    b.sink.onTlp = (t) {
      final isRead =
          t.kind == PcieTlpKind.memRead32 || t.kind == PcieTlpKind.memRead64;
      if (!isRead || mode == null) {
        b.host.receive(t);
        return;
      }
      final bytes = b.host.memory.read(t.address, t.lengthDw * 4);
      PcieTlp cpl({
        PcieCplStatus status = PcieCplStatus.success,
        int? byteCount,
        int? lowerAddress,
        List<int>? data,
        bool poisoned = false,
      }) => PcieTlp.completion(
        completerId: 0x55,
        requesterId: t.requesterId,
        tag: t.tag,
        status: status,
        byteCount: byteCount ?? t.lengthDw * 4,
        lowerAddress: lowerAddress ?? t.address & 0x7f,
        data: data ?? (status == PcieCplStatus.success ? bytes : const []),
        poisoned: poisoned,
      );
      switch (mode) {
        case 'ur':
          b.injected.add(cpl(status: PcieCplStatus.unsupported));
        case 'ca':
          b.injected.add(cpl(status: PcieCplStatus.abort));
        case 'poisoned':
          b.injected.add(cpl(poisoned: true));
        case 'byte count':
          b.injected.add(cpl(byteCount: t.lengthDw * 4 + 4));
        case 'lower address':
          b.injected.add(cpl(lowerAddress: (t.address + 4) & 0x7f));
        case 'too long':
          b.injected.add(cpl(data: [...bytes, 1, 2, 3, 4]));
        case 'no data':
          b.injected.add(cpl(data: const []));
        case 'timeout':
          dropped = cpl();
      }
      mode = null;
    };
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable(mask: HarborPcieDma.causeError);

    // A completion with no read in flight is dropped and counted.
    b.injected.add(
      PcieTlp.completion(
        completerId: 0x55,
        requesterId: _completerId,
        tag: 3,
        byteCount: 4,
        data: const [1, 2, 3, 4],
      ),
    );
    await b.waitUntil(() => b.injected.isEmpty, what: 'stale send');
    await b.cycles(20);
    expect(await b.readReg(HarborPcieDma.registerStaleCompletions), 1);

    final cases = [
      ('ur', HarborPcieDma.errorCompletion),
      ('ca', HarborPcieDma.errorCompletion),
      ('poisoned', HarborPcieDma.errorPoisoned),
      ('byte count', HarborPcieDma.errorLength),
      ('lower address', HarborPcieDma.errorLength),
      ('too long', HarborPcieDma.errorLength),
      ('no data', HarborPcieDma.errorLength),
      ('timeout', HarborPcieDma.errorTimeout),
    ];
    for (final (i, (name, code)) in cases.indexed) {
      mode = name;
      await b.push(
        hostAddress: 0x80000000 + 0x40 * i,
        localAddress: 0x40000 + 0x100 * i,
        length: 0x40,
        deviceToHost: false,
        cookie: 0x60 + i,
      );
      await b.push(
        hostAddress: 0x80000300,
        localAddress: 0x50000,
        length: 4,
        deviceToHost: false,
      );
      await b.waitRecordWrites(0, i + 1);
      final r = b.record(0);
      expect(r.code, code, reason: name);
      expect(r.cookie, 0x60 + i, reason: name);
      expect(r.bytes, 0, reason: name);
      expect(b.memory.bytes.containsKey(0x40000 + 0x100 * i), isFalse);
      await b.cycles(100);
      expect(b.recordWrites(1), isEmpty, reason: 'halted, $name');
      final status = await b.readReg(HarborPcieDma.registerStatus);
      expect(status & HarborPcieDma.statusHalted, isNonZero);
      expect(status >> 8 & 0xff, code);
      expect(b.irqPending, 1);
      await b.writeReg(
        HarborPcieDma.registerIrqCause,
        HarborPcieDma.causeError,
      );
      await b.engineReset();
      await b.cycles(2);
      expect(await b.readReg(HarborPcieDma.registerStatus), 64 << 16);
    }
    expect(b.memory.bytes.containsKey(0x50000), isFalse);

    // The late completion of the read that timed out is dropped.
    b.injected.add(dropped!);
    await b.waitUntil(() => b.injected.isEmpty, what: 'late send');
    await b.cycles(20);
    expect(await b.readReg(HarborPcieDma.registerStaleCompletions), 1);
    expect(await b.readReg(HarborPcieDma.registerStatus), 64 << 16);
    await b.push(
      hostAddress: 0x80000300,
      localAddress: 0x50000,
      length: 0x80,
      deviceToHost: false,
    );
    await b.waitRecordWrites(0, cases.length + 1);
    expect(b.record(0).code, 0);
    b.checkLocal(0x80000300, 0x50000, 0x80);
    await b.finish();
  });

  test('a fabric write error gives code 4', () async {
    final b = await _Bench.create(const _Config());
    b.seedHost(0x80000000, 0x400);
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable();
    b.memory.errorBeats.add(0x2000 + 0x250);
    await b.push(
      hostAddress: 0x80000000,
      localAddress: 0x2000,
      length: 0x400,
      deviceToHost: false,
      cookie: 8,
    );
    await b.waitRecordWrites(0, 1);
    final r = b.record(0);
    expect(r.code, HarborPcieDma.errorFabric);
    expect(r.cookie, 8);
    // Only whole reads before the failing one count.
    expect(r.bytes, 0x200);
    b.checkLocal(0x80000000, 0x2000, 0x200);
    expect(await b.readReg(HarborPcieDma.registerStatus) >> 8 & 0xff, 4);
    await b.finish();
  });

  test(
    'a late completion after timeout and reset does not hit 15 tags',
    () async {
      final b = await _Bench.create(
        const _Config(readTags: 15, timeoutCycles: 2000),
        seed: 15,
      );
      b.seedHost(0x80000000, 0x3000);
      PcieTlp? late;
      var drop = true;
      b.sink.onTlp = (t) {
        final isRead =
            t.kind == PcieTlpKind.memRead32 || t.kind == PcieTlpKind.memRead64;
        if (isRead && drop) {
          drop = false;
          late = PcieTlp.completion(
            completerId: 0x55,
            requesterId: t.requesterId,
            tag: t.tag,
            byteCount: t.lengthDw * 4,
            lowerAddress: t.address & 0x7f,
            data: b.host.memory.read(t.address, t.lengthDw * 4),
          );
          return;
        }
        b.host.receive(t);
      };
      await b.start();
      await b.setupRing(_cplBase, 4);
      await b.enable();
      await b.push(
        hostAddress: 0x80000000,
        localAddress: 0x1000,
        length: 0x40,
        deviceToHost: false,
      );
      await b.waitRecordWrites(0, 1);
      expect(b.record(0).code, HarborPcieDma.errorTimeout);
      await b.engineReset();
      b.holdCompletions = true;
      await b.push(
        hostAddress: 0x80001000,
        localAddress: 0x4000,
        length: 0x1e00,
        deviceToHost: false,
        cookie: 2,
      );
      await b.waitUntil(() => b.reads.length >= 16, what: 'new reads');
      expect(b.reads.skip(1).map((t) => t.tag), contains(late!.tag + 15));
      b.injected.add(late!);
      b.holdCompletions = false;
      await b.waitRecordWrites(0, 2);
      expect(b.record(0).cookie, 2);
      expect(b.record(0).code, 0);
      b.checkLocal(0x80001000, 0x4000, 0x1e00);
      expect(await b.readReg(HarborPcieDma.registerStaleCompletions), 1);
      expect(b.memory.bytes.containsKey(0x1000), isFalse);
      await b.finish();
    },
  );

  for (final width in [64, 128]) {
    test('a 1024 DW completion stays in its slot, W$width', () async {
      final b = await _Bench.create(
        _Config(width: width, dataWidth: width, maxReadRequestBytes: 4096),
        seed: 40 + width,
      );
      b.seedHost(0x80002000, 0x2000);
      b.maxReadRequest.inject(5);
      final reads = <PcieTlp>[];
      b.sink.onTlp = (t) {
        if (t.kind != PcieTlpKind.memRead32) {
          b.host.receive(t);
          return;
        }
        reads.add(t);
        if (reads.length < 2) return;
        // The second read is answered first, then one 1024 DW completion
        // for the first read.
        for (final r in reads.reversed) {
          b.injected.add(
            PcieTlp.completion(
              completerId: 0x55,
              requesterId: r.requesterId,
              tag: r.tag,
              byteCount: 4096,
              data: b.host.memory.read(r.address, 4096),
            ),
          );
        }
      };
      await b.start();
      await b.setupRing(_cplBase, 4);
      await b.enable();
      await b.push(
        hostAddress: 0x80002000,
        localAddress: 0x8000,
        length: 0x2000,
        deviceToHost: false,
      );
      await b.waitRecordWrites(0, 1);
      expect(reads.map((t) => t.lengthDw), [1024, 1024]);
      expect(b.record(0).code, 0);
      b.checkLocal(0x80002000, 0x8000, 0x2000);
      await b.finish();
    });
  }

  test('engine reset with reads in flight drops their completions', () async {
    final b = await _Bench.create(const _Config(), seed: 9);
    b.seedHost(0x80000000, 0x2000);
    b.holdCompletions = true;
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable();
    await b.push(
      hostAddress: 0x80000000,
      localAddress: 0x1000,
      length: 0x1000,
      deviceToHost: false,
    );
    await b.waitUntil(() => b.reads.length >= 8, what: 'old reads');
    await b.engineReset();
    await b.cycles(5);
    expect(await b.readReg(HarborPcieDma.registerStatus), 64 << 16);
    // The new reads use other tags, so old completions do not match them.
    await b.push(
      hostAddress: 0x80001000,
      localAddress: 0x3000,
      length: 0x1000,
      deviceToHost: false,
      cookie: 5,
    );
    await b.waitUntil(() => b.reads.length >= 16, what: 'new reads');
    final oldTags = b.reads.take(8).map((t) => t.tag).toSet();
    final newTags = b.reads.skip(8).map((t) => t.tag).toSet();
    expect(oldTags.intersection(newTags), isEmpty);
    b.holdCompletions = false;
    await b.waitRecordWrites(0, 1);
    expect(b.record(0).cookie, 5);
    expect(b.record(0).code, 0);
    b.checkLocal(0x80001000, 0x3000, 0x1000);
    expect(b.memory.bytes.containsKey(0x1000), isFalse);
    expect(
      await b.readReg(HarborPcieDma.registerStaleCompletions),
      greaterThanOrEqualTo(8),
    );
    await b.finish();
  });

  for (final (config, caps) in [
    (const _Config(), 1 | 6 << 4 | 8 << 8 | 2 << 16 | 1 << 20),
    (
      const _Config(
        width: 128,
        dataWidth: 128,
        queueDepth: 16,
        readTags: 4,
        irqLines: 7,
      ),
      1 | 4 << 4 | 4 << 8 | 4 << 16 | 8 << 20,
    ),
  ]) {
    test('registers read and write, $config', () async {
      final b = await _Bench.create(config);
      await b.start();
      expect(await b.readReg(HarborPcieDma.registerId), 0x48444d41);
      expect(await b.readReg(HarborPcieDma.registerCaps), caps);
      expect(
        await b.readReg(HarborPcieDma.registerStatus),
        config.queueDepth << HarborPcieDma.statusFreeShift,
      );

      await b.writeReg(HarborPcieDma.registerControl, 0xffffffff & ~2);
      expect(await b.readReg(HarborPcieDma.registerControl), 1);
      await b.writeReg(HarborPcieDma.registerIrqMask, 0xffffffff);
      expect(
        await b.readReg(HarborPcieDma.registerIrqMask),
        3 | ((1 << config.irqLines) - 1) << 8,
      );

      await b.writeReg(HarborPcieDma.registerCplBaseLow, 0x11223344);
      await b.writeReg(HarborPcieDma.registerCplBaseHigh, 0x55667788);
      await b.writeReg(HarborPcieDma.registerCplSize, 0xfffffff5);
      await b.writeReg(HarborPcieDma.registerCplHead, 0x00010003);
      // Bits 3:0 of the ring base read 0.
      expect(await b.readReg(HarborPcieDma.registerCplBaseLow), 0x11223340);
      expect(await b.readReg(HarborPcieDma.registerCplBaseHigh), 0x55667788);
      expect(await b.readReg(HarborPcieDma.registerCplSize), 5);
      expect(await b.readReg(HarborPcieDma.registerCplHead), 3);
      expect(await b.readReg(HarborPcieDma.registerCplTail), 0);

      // Byte enables: only bytes 1 and 2 change.
      await b.writeReg(
        HarborPcieDma.registerCplBaseLow,
        0xaabbccdd,
        firstBe: 0x6,
      );
      expect(await b.readReg(HarborPcieDma.registerCplBaseLow), 0x11bbcc40);

      // A 2 DW write and a 2 DW read.
      await b.writeRegs(HarborPcieDma.registerCplBaseLow, [
        0xcafef00d,
        0x00000012,
      ]);
      expect(await b.readRegs(HarborPcieDma.registerCplBaseLow, 2), [
        0xcafef000,
        0x12,
      ]);

      for (var i = 0; i < 7; i++) {
        await b.writeReg(HarborPcieDma.registerPush + 4 * i, 0x100 + i);
      }
      expect(await b.readRegs(HarborPcieDma.registerPush, 2), [0x100, 0x101]);
      expect(await b.readReg(HarborPcieDma.registerPush + 24), 0x106);
      expect(await b.readReg(HarborPcieDma.registerPushCommit), 0);
      expect(await b.readReg(HarborPcieDma.registerDescBaseLow), 0);
      expect(await b.readReg(0x0a0), 0);

      // A read longer than 32 DW gets CA with the full byte count.
      final ca = await b.readRaw(HarborPcieDma.registerId, 33);
      expect(ca.status, PcieCplStatus.abort);
      expect(ca.kind, PcieTlpKind.cpl);
      expect(ca.byteCount, 132);
      expect(b.sink.received.where((t) => t.kind.isRequest), isEmpty);
      await b.finish();
    });
  }

  for (final width in [64, 128]) {
    test('info words read back, read 0 past the list, ignore writes, '
        'W$width', () async {
      const words = [0x47444556, 1, 0, 0x5a5a1234];
      final b = await _Bench.create(
        _Config(width: width, dataWidth: width, infoWords: words),
      );
      await b.start();
      const first = HarborPcieDma.infoFirstWord * 4;
      for (var i = 0; i < words.length; i++) {
        expect(await b.readReg(first + 4 * i), words[i], reason: 'word $i');
      }
      expect(await b.readReg(first + 4 * words.length), 0);
      expect(await b.readReg(0xffc), 0);
      expect(await b.readRegs(first, 2), [words[0], words[1]]);
      await b.writeReg(first, 0xdeadbeef);
      expect(await b.readReg(first), words[0]);
      expect(await b.readReg(HarborPcieDma.registerId), 0x48444d41);
      await b.finish();
    });
  }

  for (final config in [
    const _Config(),
    const _Config(width: 128, dataWidth: 128),
    const _Config(dataWidth: 32),
    const _Config(width: 128, kind: HarborFabricKind.wishbone),
  ]) {
    test('device to host copies edge sizes, $config', () async {
      final b = await _Bench.create(
        config,
        seed: config.width + config.dataWidth,
      );
      await b.start();
      await b.setupRing(_cplBase, 4);
      await b.enable();
      final jobs = [
        (0x80000000, 0x01000, 4),
        (0x80001000, 0x02000, 128),
        (0x80002000, 0x03004, 132),
        (0x80003f40, 0x04008, 0x180),
        (0x180004104, 0x0500c, 1000),
        (0x80006000, 0x06000, 0),
      ];
      for (final (i, (h, l, len)) in jobs.indexed) {
        await b.push(
          hostAddress: h,
          localAddress: l,
          length: len,
          cookie: 0xc00 + i,
        );
      }
      await b.waitRecordWrites(jobs.length - 1, 1);
      expect(b.host.violations, isEmpty);
      for (final (i, (h, l, len)) in jobs.indexed) {
        b.checkCopy(h, l, len);
        final r = b.record(i);
        expect(r.cookie, 0xc00 + i);
        expect(r.code, 0);
        expect(r.phase, isTrue);
        expect(r.bytes, len);
        // The record follows every data write of its descriptor.
        final rec = b.recordWrites(i).single;
        final data = [
          for (final (k, t) in b.sink.received.indexed)
            if (t.kind.hasData && t.address >= h && t.address < h + len) k,
        ];
        expect(data.every((k) => k < rec), isTrue, reason: 'job $i');
        if (h > 0xffffffff) {
          expect(b.sink.received[data.first].kind, PcieTlpKind.memWrite64);
        }
      }
      for (final t in b.sink.received) {
        expect(t.requesterId, _completerId);
        expect(t.lengthDw * 4, lessThanOrEqualTo(128));
      }
      expect(await b.readReg(HarborPcieDma.registerCplTail), jobs.length);
      expect(await b.readReg(HarborPcieDma.registerStatus) & 3, 0);
      await b.finish();
    });
  }

  test('max payload 256 splits at 256 bytes', () async {
    final b = await _Bench.create(const _Config(width: 128, dataWidth: 128));
    b.maxPayload.inject(1);
    b.host.responder.maxPayload = 256;
    await b.start();
    await b.setupRing(0x123400000, 3);
    await b.enable();
    await b.push(hostAddress: 0x80000100, localAddress: 0x100, length: 0x300);
    await b.waitRecordWrites(0, 1);
    expect(b.host.violations, isEmpty);
    b.checkCopy(0x80000100, 0x100, 0x300);
    final sizes = [
      for (final t in b.sink.received)
        if (t.address < 0x100000000) t.lengthDw * 4,
    ];
    expect(sizes, [256, 256, 256]);
    expect(b.sink.received.last.kind, PcieTlpKind.memWrite64);
    expect(b.record(0).bytes, 0x300);
    await b.finish();
  });

  test('records flip phase on each ring wrap', () async {
    final b = await _Bench.create(const _Config());
    await b.start();
    await b.setupRing(_cplBase, 2);
    await b.enable();
    for (var i = 0; i < 7; i++) {
      await b.push(
        hostAddress: 0x80000000 + 0x100 * i,
        localAddress: 0x100 * i,
        length: 8,
        cookie: i,
      );
      final slot = i % 4;
      await b.waitRecordWrites(slot, i ~/ 4 + 1);
      final r = b.record(slot);
      expect(r.cookie, i);
      expect(r.phase, i ~/ 4 % 2 == 0, reason: 'descriptor $i');
      await b.writeReg(HarborPcieDma.registerCplHead, (slot + 1) % 4);
    }
    await b.finish();
  });

  test('the engine waits while the completion ring is full', () async {
    final b = await _Bench.create(const _Config());
    await b.start();
    await b.setupRing(_cplBase, 1);
    await b.enable();
    await b.push(hostAddress: 0x80000000, localAddress: 0, length: 16);
    await b.push(
      hostAddress: 0x80000100,
      localAddress: 0x100,
      length: 16,
      cookie: 7,
    );
    await b.waitRecordWrites(0, 1);
    await b.cycles(300);
    expect(b.recordWrites(1), isEmpty);
    // The data is out, the record waits.
    b.checkCopy(0x80000100, 0x100, 16);
    expect(await b.readReg(HarborPcieDma.registerStatus) & 1, 1);
    await b.writeReg(HarborPcieDma.registerCplHead, 1);
    await b.waitRecordWrites(1, 1);
    expect(b.record(1).cookie, 7);
    expect(await b.readReg(HarborPcieDma.registerStatus) & 1, 0);
    await b.finish();
  });

  test('bad alignment gives code 5, halt, reset', () async {
    final b = await _Bench.create(const _Config(width: 128, dataWidth: 128));
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable(mask: HarborPcieDma.causeError);
    final bad = [
      (0x80000002, 0x0, 8, true),
      (0x80000000, 0x1, 8, true),
      (0x80000000, 0x0, 6, true),
      (0x80000000, 0x2, 8, false),
      // Local ranges that do not fit in 20 address bits.
      (0x80000000, 0xffff0, 0x20, true),
      (0x80000000, 1 << 32, 8, true),
    ];
    for (final (i, (h, l, len, d2h)) in bad.indexed) {
      await b.push(
        hostAddress: h,
        localAddress: l,
        length: len,
        deviceToHost: d2h,
        cookie: 0x50 + i,
      );
      await b.push(hostAddress: 0x80001000, localAddress: 0, length: 4);
      // An engine reset starts the ring again at slot 0.
      await b.waitRecordWrites(0, i + 1);
      final r = b.record(0);
      expect(r.code, HarborPcieDma.errorAlignment, reason: 'case $i');
      expect(r.cookie, 0x50 + i);
      expect(r.bytes, 0);
      await b.cycles(100);
      expect(b.recordWrites(1), isEmpty, reason: 'halted, case $i');
      final status = await b.readReg(HarborPcieDma.registerStatus);
      expect(status & HarborPcieDma.statusHalted, isNonZero);
      expect(status >> 8 & 0xff, HarborPcieDma.errorAlignment);
      expect(status >> 16, 63);
      expect(status & HarborPcieDma.statusBusy, 0);
      expect(
        await b.readReg(HarborPcieDma.registerIrqCause),
        HarborPcieDma.causeError,
      );
      expect(b.irqPending, 1);
      await b.writeReg(
        HarborPcieDma.registerIrqCause,
        HarborPcieDma.causeError,
      );
      await b.engineReset();
      await b.cycles(2);
      final after = await b.readReg(HarborPcieDma.registerStatus);
      expect(after, 64 << 16, reason: 'reset clears halt and queue');
      expect(b.irqPending, 0);
    }
    expect(b.host.memory.read(0x80001000, 4), everyElement(0));
    await b.push(hostAddress: 0x80001000, localAddress: 0, length: 4);
    await b.waitRecordWrites(0, bad.length + 1);
    expect(b.record(0).code, 0);
    b.checkCopy(0x80001000, 0, 4);
    await b.finish();
  });

  test('a fabric error gives code 4 and halts', () async {
    final b = await _Bench.create(const _Config());
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable(mask: HarborPcieDma.causeError);
    b.memory.errorBeats.add(0x2000 + 0x150);
    await b.push(
      hostAddress: 0x80000000,
      localAddress: 0x2000,
      length: 0x200,
      cookie: 9,
    );
    await b.push(hostAddress: 0x80004000, localAddress: 0, length: 4);
    await b.waitRecordWrites(0, 1);
    final r = b.record(0);
    expect(r.code, HarborPcieDma.errorFabric);
    expect(r.cookie, 9);
    expect(r.bytes, 0x100);
    b.checkCopy(0x80000000, 0x2000, 0x100);
    expect(b.host.memory.read(0x80000100, 0x80), everyElement(0));
    await b.cycles(100);
    expect(b.recordWrites(1), isEmpty);
    expect(
      await b.readReg(HarborPcieDma.registerStatus) >> 8 & 0xff,
      HarborPcieDma.errorFabric,
    );
    expect(b.irqPending, 1);
    b.memory.errorBeats.clear();
    await b.engineReset();
    await b.push(hostAddress: 0x80004000, localAddress: 0, length: 4);
    await b.waitRecordWrites(0, 2);
    expect(b.record(0).code, 0);
    await b.finish();
  });

  test('no memory write goes out without bus master enable', () async {
    final b = await _Bench.create(const _Config());
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable();
    b.busMaster.inject(0);
    await b.push(hostAddress: 0x80000000, localAddress: 0, length: 64);
    await b.cycles(300);
    expect(b.sink.received.where((t) => t.kind.isRequest), isEmpty);
    b.busMaster.inject(1);
    await b.waitRecordWrites(0, 1);
    b.checkCopy(0x80000000, 0, 64);
    await b.finish();
  });

  test('a commit to a full queue sets overflow', () async {
    final b = await _Bench.create(const _Config(queueDepth: 2));
    await b.start();
    for (var i = 0; i < 3; i++) {
      await b.push(hostAddress: 0x80000000, localAddress: 0, length: 4);
    }
    // The engine is off, so the queue is not busy.
    expect(
      await b.readReg(HarborPcieDma.registerStatus),
      HarborPcieDma.statusOverflow,
    );
    await b.engineReset();
    expect(await b.readReg(HarborPcieDma.registerStatus), 2 << 16);
    await b.finish();
  });

  test('interrupt causes, mask, W1C and vector groups', () async {
    final b = await _Bench.create(const _Config(irqLines: 7));
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable(mask: 0x7f03);
    b.msiEnable.inject(1);
    b.granted.inject(3);

    // No done cause without the irq flag.
    await b.push(hostAddress: 0x80000000, localAddress: 0, length: 4);
    await b.waitRecordWrites(0, 1);
    await b.cycles(2);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), 0);
    await b.push(
      hostAddress: 0x80000000,
      localAddress: 0,
      length: 4,
      irq: true,
    );
    await b.waitRecordWrites(1, 1);
    await b.cycles(2);
    expect(
      await b.readReg(HarborPcieDma.registerIrqCause),
      HarborPcieDma.causeDone,
    );
    expect(b.irqPending, 0x01);

    // Line 2 is vector 3 when 8 vectors are granted.
    b.lines!.inject(1 << 2);
    await b.cycles(2);
    expect(b.irqPending, 0x09);
    await b.writeReg(HarborPcieDma.registerIrqCause, 0xffffffff);
    await b.cycles(2);
    // A line that stays high sets its cause again.
    expect(await b.readReg(HarborPcieDma.registerIrqCause), 1 << 10);
    expect(b.irqPending, 0x08);
    b.lines!.inject(1 << 6);
    await b.cycles(2);
    expect(b.irqPending, 0x88);
    b.lines!.inject(0);
    await b.writeReg(HarborPcieDma.registerIrqCause, 1 << 10);
    await b.cycles(2);
    expect(b.irqPending, 0x80);

    // Fewer vectors than groups: all on vector 0.
    b.granted.inject(2);
    await b.cycles(1);
    expect(b.irqPending, 0x01);
    b.granted.inject(3);
    b.msiEnable.inject(0);
    await b.cycles(1);
    expect(b.irqPending, 0x01);

    // The mask hides a cause.
    await b.writeReg(HarborPcieDma.registerIrqMask, 0x3f03);
    await b.cycles(2);
    expect(b.irqPending, 0);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), 1 << 14);
    await b.writeReg(HarborPcieDma.registerIrqCause, 1 << 14);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), 0);
    await b.finish();
  });

  for (final width in [64, 128]) {
    test('long BAR0 reads return every DW, W$width', () async {
      final words = [for (var i = 0; i < 20; i++) 0x01010101 * i + 0x10];
      final b = await _Bench.create(
        _Config(width: width, dataWidth: width, infoWords: words),
      );
      await b.start();
      List<int> info(int from, int count) => [
        for (var i = from; i < from + count; i++)
          i >= 0 && i < words.length ? words[i] : 0,
      ];
      expect(await b.readRegs(HarborPcieDma.registerId, 3), [
        HarborPcieDma.identifier,
        b.dut.caps,
        0,
      ]);
      for (var i = 0; i < 7; i++) {
        await b.writeReg(HarborPcieDma.registerPush + 4 * i, 0x100 + i);
      }
      expect(await b.readRegs(HarborPcieDma.registerPush, 16), [
        for (var i = 0; i < 7; i++) 0x100 + i,
        ...List.filled(9, 0),
      ]);
      const first = HarborPcieDma.infoFirstWord * 4;
      expect(await b.readRegs(first, 32), info(0, 32));
      expect(await b.readRegs(first + 8, 16), info(2, 16));
      expect(await b.readRegs(first - 16, 32), [0, 0, 0, 0, ...info(0, 28)]);
      expect(await b.readRegs(0xf80, 32), List.filled(32, 0));
      // Writes in between still work.
      await b.writeReg(HarborPcieDma.registerIrqMask, 3);
      expect(await b.readRegs(HarborPcieDma.registerIrqCause, 3), [0, 3, 0]);
      await b.finish();
    });
  }

  test('records stay 16 byte aligned', () async {
    final b = await _Bench.create(const _Config());
    await b.start();
    await b.setupRing(0x90000ffc, 4);
    b.cplBase = 0x90000ff0;
    expect(await b.readReg(HarborPcieDma.registerCplBaseLow), 0x90000ff0);
    await b.enable();
    await b.push(hostAddress: 0x80000000, localAddress: 0, length: 4);
    await b.waitRecordWrites(0, 1);
    expect(b.record(0).bytes, 4);
    expect(b.host.violations, isEmpty);
    await b.finish();
  });

  test('engine reset during the ring full wait', () async {
    final b = await _Bench.create(const _Config());
    await b.start();
    await b.setupRing(_cplBase, 1);
    await b.enable();
    await b.push(hostAddress: 0x80000000, localAddress: 0, length: 16);
    await b.push(hostAddress: 0x80000100, localAddress: 0x100, length: 16);
    await b.push(hostAddress: 0x80000200, localAddress: 0x200, length: 16);
    await b.waitRecordWrites(0, 1);
    await b.cycles(200);
    expect(await b.readReg(HarborPcieDma.registerStatus), 1 | 63 << 16);
    await b.engineReset();
    await b.cycles(2);
    expect(await b.readReg(HarborPcieDma.registerStatus), 64 << 16);
    expect(await b.readReg(HarborPcieDma.registerCplTail), 0);
    await b.cycles(100);
    expect(b.recordWrites(1), isEmpty);
    expect(b.host.memory.read(0x80000200, 16), everyElement(0));
    await b.push(
      hostAddress: 0x80000300,
      localAddress: 0x300,
      length: 16,
      cookie: 3,
    );
    await b.waitRecordWrites(0, 2);
    expect(b.record(0).cookie, 3);
    b.checkCopy(0x80000300, 0x300, 16);
    await b.finish();
  });

  test('engine reset during the bus master wait', () async {
    final b = await _Bench.create(const _Config());
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable();
    b.busMaster.inject(0);
    await b.push(hostAddress: 0x80000000, localAddress: 0, length: 64);
    await b.cycles(200);
    expect(await b.readReg(HarborPcieDma.registerStatus), 1 | 64 << 16);
    await b.engineReset();
    await b.cycles(2);
    expect(await b.readReg(HarborPcieDma.registerStatus), 64 << 16);
    b.busMaster.inject(1);
    await b.cycles(200);
    expect(b.sink.received.where((t) => t.kind.isRequest), isEmpty);
    await b.push(
      hostAddress: 0x80001000,
      localAddress: 0x40,
      length: 64,
      cookie: 4,
    );
    await b.waitRecordWrites(0, 1);
    expect(b.record(0).cookie, 4);
    b.checkCopy(0x80001000, 0x40, 64);
    expect(b.host.memory.read(0x80000000, 64), everyElement(0));
    await b.finish();
  });

  test('lines with no vectors granted all use vector 0', () async {
    final b = await _Bench.create(const _Config(irqLines: 2));
    await b.start();
    await b.enable(mask: 0x0303);
    b.msiEnable.inject(1);
    b.granted.inject(0);
    b.lines!.inject(2);
    await b.cycles(3);
    expect(b.irqPending, 0x01);
    b.granted.inject(2);
    await b.cycles(2);
    expect(b.irqPending, 0x04);
    await b.finish();
  });

  test('1 vector granted with no lines uses vector 0', () async {
    final b = await _Bench.create(const _Config());
    await b.start();
    await b.setupRing(_cplBase, 4);
    await b.enable(mask: HarborPcieDma.causeDone);
    b.msiEnable.inject(1);
    await b.push(
      hostAddress: 0x80000000,
      localAddress: 0,
      length: 4,
      irq: true,
    );
    await b.waitRecordWrites(0, 1);
    await b.cycles(2);
    expect(b.irqPending, 1);
    await b.finish();
  });

  for (final width in [64, 128]) {
    test('the done cause rises after the record leaves the router, '
        'W$width', () async {
      await _causeAfterLastBeat(width);
    });
  }
  group('build', () {
    test('definition names differ per parameter set', () {
      final names = {
        _dma().definitionName,
        _dma(width: 128).definitionName,
        _dma(queueDepth: 16).definitionName,
        _dma(readTags: 4).definitionName,
        _dma(irqLines: 3).definitionName,
        _dma(timeoutCycles: 100).definitionName,
        _dma(infoWords: const [1]).definitionName,
        _dma(infoWords: const [2]).definitionName,
        _dma(maxReadRequestBytes: 1024).definitionName,
      };
      expect(names, hasLength(9));
    });

    test('bad parameters are refused', () {
      expect(() => _dma(ringSource: true), throwsArgumentError);
      expect(() => _dma(fifoSource: false), throwsArgumentError);
      expect(() => _dma(queueDepth: 48), throwsArgumentError);
      expect(() => _dma(readTags: 0), throwsRangeError);
      expect(() => _dma(readTags: 16), throwsRangeError);
      expect(() => _dma(maxReadRequestBytes: 64), throwsArgumentError);
      expect(() => _dma(maxReadRequestBytes: 768), throwsArgumentError);
      expect(() => _dma(irqLines: 8), throwsRangeError);
      expect(
        () => _dma(
          infoWords: List<int>.filled(HarborPcieDma.infoMaxWords + 1, 0),
        ),
        throwsRangeError,
      );
    });

    test('an empty info list emits no info logic', () async {
      final empty = _dma();
      await empty.build();
      expect(empty.generateSynth(), isNot(contains('info_word')));
      Simulator.reset();
      final full = _dma(infoWords: const [0x12345678]);
      await full.build();
      expect(full.generateSynth(), contains('info_word'));
    });
  });
}

/// Runs a D2H descriptor with the router between the engine and the
/// upstream port. The upstream ready stays low for 12 cycles before each
/// last beat.
Future<void> _causeAfterLastBeat(int width) async {
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final dut = HarborPcieDma(
    clk: Logic(),
    reset: Logic(),
    completerId: Logic(width: 16),
    maxPayload: Logic(width: 3),
    maxReadRequest: Logic(width: 3),
    rcb128: Logic(),
    busMasterEnable: Logic(),
    msiEnable: Logic(),
    msiVectorsGranted: Logic(width: 3),
    rx: HarborPcieStream(width: width, name: 'dut_rx'),
    tx: HarborPcieStream(width: width, name: 'dut_tx'),
    dataWidth: width,
    addressWidth: _addressWidth,
  );
  final top = MasterTop(
    dut,
    iface: 'memory',
    kind: HarborFabricKind.axi4,
    config: HarborMemoryWaistConfig(
      addressWidth: _addressWidth,
      dataWidth: width,
    ),
    withErr: true,
  );
  await top.build();

  final clientRx = HarborPcieStream(width: width, name: 'client_rx');
  final clientTx = HarborPcieStream(width: width, name: 'client_tx');
  final upRx = HarborPcieStream(width: width, name: 'up_rx');
  final upTx = HarborPcieStream(width: width, name: 'up_tx');
  final router = HarborPcieRouter(
    clk: clk,
    reset: reset,
    width: width,
    completerId: Const(_completerId, width: 16),
    upstreamRx: upRx,
    upstreamTx: upTx,
    clients: [
      HarborPcieRouterClient(
        name: 'dma',
        barMask: HarborPcieStream.userBar0,
        takesCompletions: true,
        rx: clientRx,
        tx: clientTx,
      ),
    ],
  );
  await router.build();

  top.input('clk').srcConnection! <= clk;
  top.input('reset').srcConnection! <= reset;
  top.input('completer_id').srcConnection! <= Const(_completerId, width: 16);
  top.input('max_payload').srcConnection! <= Const(0, width: 3);
  top.input('max_read_request').srcConnection! <= Const(2, width: 3);
  top.input('rcb_128').srcConnection! <= Const(0);
  top.input('bus_master_enable').srcConnection! <= Const(1);
  top.input('msi_enable').srcConnection! <= Const(1);
  top.input('msi_vectors_granted').srcConnection! <= Const(0, width: 3);
  for (final s in ['data', 'keep', 'last', 'valid', 'user']) {
    top.input('rx_$s').srcConnection! <= _Bench._field(clientRx, s);
    _Bench._field(clientTx, s) <= top.output('tx_$s');
  }
  clientRx.ready <= top.output('rx_ready');
  top.input('tx_ready').srcConnection! <= clientTx.ready;

  reset.inject(1);
  final memory = PcieFabricMemory(top, clk, seed: 3, fill: _fill);
  memory.start();
  final driver = PcieStreamDriver(clk: clk, stream: upRx, seed: 5);
  upTx.ready.inject(0);
  Simulator.setMaxSimTime(10000000);
  unawaited(Simulator.run());
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  await clk.nextPosedge;

  Future<void> write(int offset, List<int> values) => driver.send(
    PcieTlp.memWrite(
      address: _bar0 + offset,
      data: [for (final v in values) ..._leBytes(v)],
    ),
  );

  await write(HarborPcieDma.registerCplBaseLow, [_cplBase, 0, 4]);
  await write(HarborPcieDma.registerIrqMask, [HarborPcieDma.causeDone]);
  await write(HarborPcieDma.registerControl, [HarborPcieDma.controlEnable]);
  await write(HarborPcieDma.registerPush, [
    0x80000000,
    0,
    0x400,
    0,
    200,
    HarborPcieDma.flagDeviceToHost | HarborPcieDma.flagIrq,
    0x77,
    0,
  ]);

  // Per cycle at the falling edge: (fire, last, irq_pending[0]).
  final samples = <(bool, bool, bool)>[];
  final beats = <PcieBeat>[];
  final tlps = <PcieTlp>[];
  var hold = 0;
  var after = 0;
  for (var cycle = 0; cycle < 4000 && after < 4; cycle++) {
    if (tlps.length >= 3) after++;
    final valid = upTx.valid.value.toBool();
    final last = valid && upTx.last.value.toBool();
    var ready = true;
    if (last && hold < 12) {
      ready = false;
      hold++;
    }
    upTx.ready.inject(ready ? 1 : 0);
    await clk.nextNegedge;
    final fire = ready && upTx.valid.value.toBool();
    samples.add((
      fire,
      fire && upTx.last.value.toBool(),
      top.output('irq_pending').value.toInt() & 1 == 1,
    ));
    if (fire) {
      beats.add(
        PcieBeat(
          upTx.data.value.toBigInt(),
          upTx.keep.value.toInt(),
          last: upTx.last.value.toBool(),
        ),
      );
      if (beats.last.last) {
        tlps.add(PcieTlp.fromBeats(beats));
        beats.clear();
        hold = 0;
      }
    }
    await clk.nextPosedge;
  }
  // Two data writes (128 + 72 bytes), then the record.
  expect(tlps, hasLength(3));
  expect(tlps.last.address, _cplBase);
  final lastFires = [
    for (final (i, s) in samples.indexed)
      if (s.$2) i,
  ];
  final recordEnd = lastFires.last;
  for (var i = 0; i <= recordEnd; i++) {
    expect(samples[i].$3, isFalse, reason: 'irq_pending high at cycle $i');
  }
  for (var i = recordEnd + 1; i < samples.length; i++) {
    expect(samples[i].$3, isTrue, reason: 'irq_pending low at cycle $i');
  }
  expect(samples.length, greaterThan(recordEnd + 1));
  await Simulator.endSimulation();
}

/// Runs [count] random descriptors in both directions and compares both
/// memories with a model at the end.
Future<void> _randomMix(_Config config, int count) async {
  final b = await _Bench.create(config, seed: count + config.width);
  final random = Random(count * 31 + config.width);
  const hostBase = 0x80000000;
  const hostHigh = 0x240000000;
  const hostSpan = 0x10000;
  const localSpan = 0x40000;
  b.seedHost(hostBase, hostSpan);
  b.seedHost(hostHigh, hostSpan);
  final modelHost = <int, int>{};
  final modelLocal = <int, int>{};
  int hostByte(int a) => modelHost[a] ?? b.host.memory.read(a, 1)[0];
  int localByte(int a) => modelLocal[a] ?? _fill(a);

  final jobs = <(int, int, int, bool)>[];
  for (var i = 0; i < count; i++) {
    final roll = random.nextInt(10);
    final len = roll == 0 ? 4 * random.nextInt(1025) : 4 * random.nextInt(97);
    final h =
        (random.nextBool() ? hostBase : hostHigh) +
        4 * random.nextInt((hostSpan - len) ~/ 4 + 1);
    final l = 4 * random.nextInt((localSpan - len) ~/ 4 + 1);
    final d2h = random.nextBool();
    jobs.add((h, l, len, d2h));
    for (var k = 0; k < len; k++) {
      if (d2h) {
        modelHost[h + k] = localByte(l + k);
      } else {
        modelLocal[l + k] = hostByte(h + k);
      }
    }
  }

  var records = 0;
  b.sink.onTlp = (t) {
    if (t.kind.hasData &&
        t.address >= _cplBase &&
        t.address < _cplBase + 16 * 1024) {
      records++;
    }
    b.host.receive(t);
  };
  await b.start();
  await b.setupRing(_cplBase, 10);
  await b.enable();
  for (final (i, (h, l, len, d2h)) in jobs.indexed) {
    while (i - records >= config.queueDepth - 4) {
      await b.cycles(20);
    }
    await b.push(
      hostAddress: h,
      localAddress: l,
      length: len,
      deviceToHost: d2h,
      cookie: i,
    );
  }
  await b.waitUntil(
    () => records >= count,
    timeout: 4000000,
    what: 'all records',
  );
  expect(b.host.violations, isEmpty);
  for (final (i, (h, l, len, _)) in jobs.indexed) {
    final r = b.record(i);
    expect(r.cookie, i);
    expect(r.code, 0, reason: 'descriptor $i');
    expect(r.bytes, len);
    final host = b.host.memory.read(h, len);
    for (var k = 0; k < len; k++) {
      if (host[k] != hostByte(h + k)) {
        fail('descriptor $i: host byte 0x${(h + k).toRadixString(16)}');
      }
      if (b.memory.byte(l + k) != localByte(l + k)) {
        fail('descriptor $i: local byte 0x${(l + k).toRadixString(16)}');
      }
    }
  }
  await b.finish();
}

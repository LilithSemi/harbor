import 'dart:async';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'mem_target.dart';
import 'pcie_fabric_memory.dart';
import 'pcie_host_model.dart';

const dmaCompleterId = 0x0100;
const dmaBar0 = 0xf7000000;
const dmaAddressWidth = 20;
const dmaCplBase = 0x90000000;

int dmaFill(int address) => (address * 13 + (address >> 8) + 5) & 0xff;

int dmaHostFill(int address) => (address * 7 + (address >> 9) + 0x31) & 0xff;

class DmaConfig {
  final int width;
  final int dataWidth;
  final HarborFabricKind kind;
  final int queueDepth;
  final int readTags;
  final int irqLines;
  final List<int> infoWords;
  final int timeoutCycles;
  final int maxReadRequestBytes;
  final bool fifoSource;
  final bool ringSource;
  final int addressWidth;

  /// Puts an [AxiStallGate] on the fabric port. See [DmaBench.hold].
  final bool axiGate;

  /// Builds the reset status input. See [DmaBench.resetStatus].
  final bool resetStatus;

  const DmaConfig({
    this.width = 64,
    this.dataWidth = 64,
    this.kind = HarborFabricKind.axi4,
    this.queueDepth = 64,
    this.readTags = 8,
    this.irqLines = 0,
    this.infoWords = const [],
    this.timeoutCycles = 6250000,
    this.maxReadRequestBytes = 512,
    this.fifoSource = true,
    this.ringSource = false,
    this.addressWidth = dmaAddressWidth,
    this.axiGate = false,
    this.resetStatus = false,
  });

  @override
  String toString() => 'W$width D$dataWidth ${kind.name}';
}

class DmaRecord {
  final int cookie;
  final int code;
  final bool phase;
  final int bytes;

  /// DW3: [31] from the ring, [15:0] ring slot or push sequence number.
  final int src;

  DmaRecord(Uint8List b)
    : cookie = le(b, 0),
      code = le(b, 4) & 0xff,
      phase = (le(b, 4) >> 31) == 1,
      bytes = le(b, 8),
      src = le(b, 12);

  static int le(Uint8List b, int o) =>
      b[o] | b[o + 1] << 8 | b[o + 2] << 16 | b[o + 3] << 24;

  @override
  String toString() =>
      'record(cookie $cookie code $code phase $phase '
      'bytes $bytes)';
}

List<int> leBytes(int value, [int count = 4]) => [
  for (var i = 0; i < count; i++) (value >> (8 * i)) & 0xff,
];

/// A HarborPcieDma bench with a host model on the stream and a fabric memory.
class DmaBench {
  final DmaConfig config;
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
  final Map<String, Logic> _gates;

  /// The DMA reset status input, for the test to drive.
  final Logic? resetStatus;
  final PcieStreamDriver driver;
  final PcieStreamSink sink;
  final PcieHostModel host;
  int _tag = 0;
  int cplBase = dmaCplBase;
  int descBase = 0;
  int descLog2 = 0;
  Future<void> _sendLock = Future.value();

  /// Completions wait while this is set.
  bool holdCompletions = false;

  /// TLPs sent before the responder completions.
  final List<PcieTlp> injected = [];
  bool _pumping = false;

  DmaBench._(
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
    this._gates,
    this.resetStatus,
    this.driver,
    this.sink,
    this.host,
  );

  static Future<DmaBench> create(
    DmaConfig config, {
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
      addressWidth: config.addressWidth,
      queueDepth: config.queueDepth,
      readTags: config.readTags,
      irqLines: config.irqLines,
      endpointConfig: const HarborPcieEndpointConfig(msiVectors: 8),
      infoWords: config.infoWords,
      timeoutCycles: config.timeoutCycles,
      maxReadRequestBytes: config.maxReadRequestBytes,
      fifoSource: config.fifoSource,
      ringSource: config.ringSource,
      resetStatus: config.resetStatus ? Logic(width: 64) : null,
    );
    final top = MasterTop(
      dut,
      iface: 'memory',
      kind: config.kind,
      config: HarborMemoryWaistConfig(
        addressWidth: config.addressWidth,
        dataWidth: config.dataWidth,
      ),
      withErr: true,
      axiGate: config.axiGate,
    );
    await top.build();
    final gates = {
      if (config.axiGate)
        for (final c in AxiStallGate.channels.keys) c: Logic(name: 'pass_$c'),
    };
    final resetStatus = config.resetStatus
        ? Logic(name: 'reset_status', width: 64)
        : null;
    if (resetStatus != null) {
      top.input('reset_status').srcConnection! <= resetStatus;
    }
    for (final MapEntry(:key, :value) in gates.entries) {
      top.input('pass_$key').srcConnection! <= value;
      value.inject(1);
    }

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
      top.input('rx_$s').srcConnection! <= field(rx, s);
      field(tx, s) <= top.output('tx_$s');
    }
    rx.ready <= top.output('rx_ready');
    top.input('tx_ready').srcConnection! <= tx.ready;

    completerId.inject(dmaCompleterId);
    maxPayload.inject(0);
    maxReadRequest.inject(2);
    busMaster.inject(1);
    msiEnable.inject(0);
    granted.inject(0);
    lines?.inject(0);
    reset.inject(1);
    final memory = PcieFabricMemory(top, clk, seed: seed + 7, fill: dmaFill);
    memory.start();
    final host = PcieHostModel(seed: seed, maxPayload: 128);
    return DmaBench._(
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
      gates,
      resetStatus,
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

  static Logic field(HarborPcieStream s, String f) => switch (f) {
    'data' => s.data,
    'keep' => s.keep,
    'last' => s.last,
    'valid' => s.valid,
    _ => s.user,
  };

  /// Holds AXI channel [channel] (`ar`, `r`, `aw`, `w` or `b`) while
  /// [held] is set. Needs [DmaConfig.axiGate].
  void hold(String channel, {bool held = true}) =>
      _gates[channel]!.inject(held ? 0 : 1);

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
          address: dmaBar0 + offset,
          data: [for (final v in values) ...leBytes(v)],
          firstBe: firstBe,
        ),
      );

  Future<void> writeReg(int offset, int value, {int firstBe = 0xf}) =>
      writeRegs(offset, [value], firstBe: firstBe);

  /// Sends a BAR0 read and returns its completion.
  Future<PcieTlp> readRaw(int offset, int lengthDw) async {
    final tag = _tag++ & 0xff;
    final request = PcieTlp.memRead(
      address: dmaBar0 + offset,
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
    expect(c.completerId, dmaCompleterId);
    expect(c.tc, 2);
    expect(c.attr, 1);
    return c;
  }

  Future<List<int>> readRegs(int offset, int count) async {
    final c = await readRaw(offset, count);
    expect(c.status, PcieCplStatus.success);
    expect(c.lengthDw, count);
    expect(c.byteCount, count * 4);
    expect(c.lowerAddress, (dmaBar0 + offset) & 0x7f);
    return [for (var i = 0; i < count; i++) DmaRecord.le(c.data, 4 * i)];
  }

  Future<int> readReg(int offset) async => (await readRegs(offset, 1)).first;

  Future<void> setupDescRing(int base, int log2) async {
    descBase = base;
    descLog2 = log2;
    await writeReg(HarborPcieDma.registerDescBaseLow, base & 0xffffffff);
    await writeReg(HarborPcieDma.registerDescBaseHigh, base >> 32);
    await writeReg(HarborPcieDma.registerDescSize, log2);
  }

  /// Writes a descriptor to slot [slot] of the host descriptor ring.
  void writeDesc(
    int slot, {
    required int hostAddress,
    required int localAddress,
    required int length,
    bool deviceToHost = true,
    bool irq = false,
    int cookie = 0,
  }) {
    host.memory.write(descBase + 32 * slot, [
      ...leBytes(hostAddress, 8),
      ...leBytes(localAddress, 8),
      ...leBytes(length),
      ...leBytes(
        (deviceToHost ? HarborPcieDma.flagDeviceToHost : 0) |
            (irq ? HarborPcieDma.flagIrq : 0),
      ),
      ...leBytes(cookie),
      ...leBytes(0),
    ]);
  }

  Future<void> doorbell(int tail) =>
      writeReg(HarborPcieDma.registerDescTail, tail);

  bool isFetch(PcieTlp t) =>
      (t.kind == PcieTlpKind.memRead32 || t.kind == PcieTlpKind.memRead64) &&
      t.address >= descBase &&
      t.address < descBase + (32 << descLog2);

  /// Descriptor reads the engine sent.
  List<PcieTlp> get fetches => [
    for (final t in sink.received)
      if (isFetch(t)) t,
  ];

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

  DmaRecord record(int slot) =>
      DmaRecord(host.memory.read(recordAddress(slot), 16));

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
      for (var i = 0; i < length; i++) dmaHostFill(address + i),
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

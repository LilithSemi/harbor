import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'pcie_dma_bench.dart';
import 'pcie_host_model.dart';
import 'pcie_waist_memory.dart';

const gpuAddressWidth = 24;
const gpuBar0 = 0xf7000000;
const gpuBar2 = 0x3800000000;
const gpuRom = 0xf7100000;
const gpuRomBytes = 4096;
const gpuInfoWords = [0x47504955, 0x00010002, 0, 0xdeadbeef];

int gpuRomWord(int index) => (index * 0x01030507 + 0x55aa1234) & 0xffffffff;

/// Wishbone ROM memory with `rom_t_*` beat ports.
class _RomMemory extends BridgeModule {
  _RomMemory(int addressWidth) : super('PcieGpuRomMemory_A$addressWidth') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      kind: HarborFabricKind.wishbone,
      addressWidth: addressWidth,
      dataWidth: 32,
      clk: input('clk'),
      reset: input('reset'),
    );
    bus.dataOut <= addInput('t_rdata', Logic(width: 32), width: 32);
    bus.ack <= bus.stb & addInput('t_ack', Logic());
    addOutput('t_stb') <= bus.stb;
    addOutput('t_addr', width: addressWidth) <= bus.addr;
  }
}

/// Router, DMA, memory completer, option ROM and interrupt block on one
/// upstream stream, as an endpoint sees them.
class PcieGpuTop extends BridgeModule {
  final int width;
  late final HarborPcieDma dma;
  late final HarborPcieMemoryCompleter completer;
  HarborPcieOptionRom? rom;

  PcieGpuTop({
    required this.width,
    required HarborPcieStream upRx,
    required HarborPcieStream upTx,
    required Logic completerId,
    required Logic maxPayload,
    required Logic maxReadRequest,
    required Logic busMasterEnable,
    required Logic msiEnable,
    required Logic msiVectorsGranted,
    required Logic interruptDisable,
    required Logic interruptRdyN,
    required Logic irqLine,
    required bool withRom,
  }) : super('PcieGpuTop_W${width}_R${withRom ? 1 : 0}', name: 'top') {
    final clk = createPort('clk', PortDirection.input).port;
    final reset = createPort('reset', PortDirection.input).port;
    completerId = addInput('completer_id', completerId, width: 16);
    maxPayload = addInput('max_payload', maxPayload, width: 3);
    maxReadRequest = addInput('max_read_request', maxReadRequest, width: 3);
    busMasterEnable = addInput('bus_master_enable', busMasterEnable);
    msiEnable = addInput('msi_enable', msiEnable);
    msiVectorsGranted = addInput(
      'msi_vectors_granted',
      msiVectorsGranted,
      width: 3,
    );
    interruptDisable = addInput('interrupt_disable', interruptDisable);
    interruptRdyN = addInput('interrupt_rdy_n', interruptRdyN);
    irqLine = addInput('irq_line', irqLine);
    final rx = HarborPcieStream.addSink(this, upRx, prefix: 'up_rx_');
    final tx = HarborPcieStream.addSource(this, upTx, prefix: 'up_tx_');
    final rcb128 = Const(0);

    HarborPcieStream s(String n) => HarborPcieStream(width: width, name: n);
    final dmaRx = s('dma_rx');
    final dmaTx = s('dma_tx');
    final memRx = s('mem_rx');
    final memTx = s('mem_tx');
    final romRx = withRom ? s('rom_rx') : null;
    final romTx = withRom ? s('rom_tx') : null;

    dma = HarborPcieDma(
      clk: clk,
      reset: reset,
      completerId: completerId,
      maxPayload: maxPayload,
      maxReadRequest: maxReadRequest,
      rcb128: rcb128,
      busMasterEnable: busMasterEnable,
      msiEnable: msiEnable,
      msiVectorsGranted: msiVectorsGranted,
      rx: dmaRx,
      tx: dmaTx,
      irqInputs: irqLine,
      dataWidth: width,
      addressWidth: gpuAddressWidth,
      ringSource: true,
      queueDepth: 16,
      irqLines: 1,
      infoWords: gpuInfoWords,
    );
    completer = HarborPcieMemoryCompleter(
      clk: clk,
      reset: reset,
      maxPayload: maxPayload,
      rcb128: rcb128,
      completerId: completerId,
      rx: memRx,
      tx: memTx,
      dataWidth: width,
      addressWidth: gpuAddressWidth,
    );
    addSubModule(dma);
    addSubModule(completer);
    if (withRom) {
      rom = HarborPcieOptionRom(
        clk: clk,
        reset: reset,
        completerId: completerId,
        rx: romRx!,
        tx: romTx!,
        romSize: gpuRomBytes,
        memoryAddressWidth: 12,
        readCompletionBoundary128: rcb128,
      );
      addSubModule(rom!);
    }
    HarborPcieRouter(
      clk: clk,
      reset: reset,
      width: width,
      completerId: completerId,
      upstreamRx: rx,
      upstreamTx: tx,
      clients: [
        HarborPcieRouterClient(
          name: 'dma',
          barMask: HarborPcieStream.userBar0,
          rx: dmaRx,
          tx: dmaTx,
          takesCompletions: true,
        ),
        HarborPcieRouterClient(
          name: 'mem',
          barMask: HarborPcieStream.userBar2,
          rx: memRx,
          tx: memTx,
        ),
        if (withRom)
          HarborPcieRouterClient(
            name: 'rom',
            barMask: HarborPcieStream.userRom,
            rx: romRx!,
            tx: romTx!,
          ),
      ],
    );
    final interrupt = HarborPcieInterrupt(
      clk: clk,
      reset: reset,
      irqPending: dma.irqPending,
      txBusy: tx.valid,
      msiEnable: msiEnable,
      mmEnable: msiVectorsGranted,
      busMasterEnable: busMasterEnable,
      interruptDisable: interruptDisable,
      interruptRdyN: interruptRdyN,
    );
    addOutput('interrupt_n') <= interrupt.interruptN;
    addOutput('interrupt_di', width: 8) <= interrupt.interruptDi;
    addOutput('interrupt_assert_n') <= interrupt.interruptAssertN;
    addOutput('write_errors', width: 16) <= completer.writeErrors;

    final cfg = HarborMemoryWaistConfig(
      addressWidth: gpuAddressWidth,
      dataWidth: width,
    );
    for (final (prefix, master) in [('dma', dma), ('mem', completer)]) {
      final target = addSubModule(WaistTarget(HarborFabricKind.axi4, cfg));
      target.input('clk').srcConnection! <= clk;
      target.input('reset').srcConnection! <= reset;
      connectInterfaces(master.interface('memory'), target.interface('bus'));
      for (final p in WaistTarget.portNames) {
        pullUpPort(target.port(p), newPortName: '${prefix}_$p');
      }
    }
    if (withRom) {
      final memory = addSubModule(_RomMemory(12));
      memory.input('clk').srcConnection! <= clk;
      memory.input('reset').srcConnection! <= reset;
      connectInterfaces(rom!.interface('memory'), memory.interface('bus'));
      for (final p in ['t_rdata', 't_ack', 't_stb', 't_addr']) {
        pullUpPort(memory.port(p), newPortName: 'rom_$p');
      }
    }
  }
}

/// One D2H or H2D descriptor of the SG list.
class GpuDesc {
  final int host;
  final int local;
  final int length;
  final bool d2h;
  final bool irq;
  final int cookie;

  const GpuDesc(
    this.host,
    this.local,
    this.length, {
    required this.d2h,
    required this.irq,
    required this.cookie,
  });
}

/// A whole-system bench: host model, router and all clients.
class PcieGpuBench {
  final int width;
  final bool withRom;
  final PcieGpuTop top;
  final Logic clk;
  final Logic reset;
  final Logic msiEnable;
  final Logic busMaster;
  final Logic irqLine;
  final Logic rdyN;
  final PcieHostModel host;
  final PcieStreamDriver driver;
  final PcieStreamSink sink;
  final Map<int, int> local = {};
  final Random random;
  int _tag = 0;
  Future<void> _sendLock = Future.value();
  bool _running = false;

  /// Each MSI as (vector, sink packet count at that time).
  final List<(int, int)> msiLog = [];
  final List<String> violations = [];

  PcieGpuBench._(
    this.width,
    this.withRom,
    this.top,
    this.clk,
    this.reset,
    this.msiEnable,
    this.busMaster,
    this.irqLine,
    this.rdyN,
    this.host,
    this.driver,
    this.sink,
    this.random,
  );

  static Future<PcieGpuBench> create(int width, {int seed = 3}) async {
    final withRom = width == 64;
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final completerId = Logic(name: 'completer_id', width: 16);
    final maxPayload = Logic(name: 'max_payload', width: 3);
    final maxReadRequest = Logic(name: 'max_read_request', width: 3);
    final busMaster = Logic(name: 'bus_master');
    final msiEnable = Logic(name: 'msi_enable');
    final granted = Logic(name: 'granted', width: 3);
    final intDisable = Logic(name: 'interrupt_disable');
    final rdyN = Logic(name: 'rdy_n');
    final irqLine = Logic(name: 'irq_line');
    final rx = HarborPcieStream(width: width, name: 'rx');
    final tx = HarborPcieStream(width: width, name: 'tx');
    final top = PcieGpuTop(
      width: width,
      upRx: rx,
      upTx: tx,
      completerId: completerId,
      maxPayload: maxPayload,
      maxReadRequest: maxReadRequest,
      busMasterEnable: busMaster,
      msiEnable: msiEnable,
      msiVectorsGranted: granted,
      interruptDisable: intDisable,
      interruptRdyN: rdyN,
      irqLine: irqLine,
      withRom: withRom,
    );
    await top.build();
    top.input('clk').srcConnection! <= clk;
    top.input('reset').srcConnection! <= reset;

    completerId.inject(dmaCompleterId);
    maxPayload.inject(1);
    maxReadRequest.inject(2);
    busMaster.inject(1);
    msiEnable.inject(1);
    granted.inject(3);
    intDisable.inject(1);
    rdyN.inject(1);
    irqLine.inject(0);
    reset.inject(1);

    final host = PcieHostModel(seed: seed, maxPayload: 256);
    final bench = PcieGpuBench._(
      width,
      withRom,
      top,
      clk,
      reset,
      msiEnable,
      busMaster,
      irqLine,
      rdyN,
      host,
      PcieStreamDriver(clk: clk, stream: rx, seed: seed, gapChance: 0.05),
      PcieStreamSink(
        clk: clk,
        stream: tx,
        seed: seed + 1,
        readyChance: 0.9,
        onTlp: host.receive,
      ),
      Random(seed + 2),
    );
    for (final (p, s) in [('dma_w_', seed + 7), ('mem_w_', seed + 8)]) {
      WaistMemory(
        top,
        clk,
        prefix: p,
        bytes: bench.local,
        fill: dmaFill,
        seed: s,
      ).start();
    }
    if (withRom) bench._romMemory();
    return bench;
  }

  void _romMemory() {
    final ack = Logic(name: 'tb_rom_ack');
    final data = Logic(name: 'tb_rom_rdata', width: 32);
    top.input('rom_t_ack').srcConnection! <= ack;
    top.input('rom_t_rdata').srcConnection! <= data;
    ack.inject(0);
    data.inject(0);
    clk.negedge.listen((_) {
      final stb = top.output('rom_t_stb').value;
      if (ack.value.toBool() || !stb.isValid || !stb.toBool()) {
        ack.inject(0);
        return;
      }
      final address = top.output('rom_t_addr').value.toInt();
      data.inject(gpuRomWord(address ~/ 4));
      ack.inject(1);
    });
  }

  Future<void> start() async {
    Simulator.setMaxSimTime(1 << 40);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;
    sink.start();
    _running = true;
    unawaited(_pump());
    unawaited(_hardBlock());
  }

  Future<void> finish() async {
    _running = false;
    sink.stop();
    await clk.nextPosedge;
    await Simulator.endSimulation();
  }

  Future<void> _pump() async {
    while (_running) {
      final tlp = host.responder.next();
      if (tlp == null) {
        await clk.nextPosedge;
      } else {
        await send(tlp, user: 0);
      }
    }
  }

  /// Answers cfg_interrupt like the hard block, after a random delay.
  Future<void> _hardBlock() async {
    int? delay;
    while (_running) {
      await clk.nextNegedge;
      if (rdyN.value.toInt() == 0) {
        rdyN.inject(1);
        continue;
      }
      if (top.output('interrupt_n').value.toInt() != 0) {
        delay = null;
        continue;
      }
      delay ??= random.nextInt(5);
      if (delay > 0) {
        delay--;
        continue;
      }
      delay = null;
      rdyN.inject(0);
      if (busMaster.value.toInt() == 0) violations.add('MSI without BME');
      final vector = top.output('interrupt_di').value.toInt();
      host.recordMsi(vector);
      msiLog.add((vector, sink.received.length));
    }
  }

  Future<void> send(PcieTlp tlp, {int user = HarborPcieStream.userBar0}) {
    final done = _sendLock.then((_) => driver.send(tlp, user: user));
    _sendLock = done;
    return done;
  }

  Future<void> waitUntil(
    bool Function() done, {
    int timeout = 50000,
    String what = 'condition',
  }) async {
    for (var i = 0; !done(); i++) {
      if (i >= timeout) fail('timeout waiting for $what');
      await clk.nextPosedge;
    }
  }

  int _nextTag(int base) => base | (_tag++ & 0x7f);

  /// Sends a memory read and returns its completions in order.
  Future<(PcieTlp, List<PcieTlp>)> read(
    int address,
    int lengthDw, {
    required int user,
    int firstBe = 0xf,
    int? lastBe,
  }) async {
    final request = PcieTlp.memRead(
      address: address,
      lengthDw: lengthDw,
      tag: _nextTag(user == HarborPcieStream.userBar0 ? 0 : 0x80),
      firstBe: firstBe,
      lastBe: lastBe,
    );
    final start = host.completions.length;
    await send(request, user: user);
    final got = <PcieTlp>[];
    var scanned = start;
    await waitUntil(() {
      for (; scanned < host.completions.length; scanned++) {
        final c = host.completions[scanned];
        if (c.tag == request.tag) got.add(c);
      }
      if (got.isEmpty) return false;
      final last = got.last;
      return last.status != PcieCplStatus.success ||
          last.lengthDw * 4 - (last.lowerAddress & 3) >= last.byteCount;
    }, what: 'read 0x${address.toRadixString(16)}');
    return (request, got);
  }

  Future<int> readReg(int offset) async {
    final (_, c) = await read(
      gpuBar0 + offset,
      1,
      user: HarborPcieStream.userBar0,
    );
    expect(c, hasLength(1));
    expect(c.single.status, PcieCplStatus.success);
    return DmaRecord.le(c.single.data, 0);
  }

  Future<void> writeRegs(int offset, List<int> values) => send(
    PcieTlp.memWrite(
      address: gpuBar0 + offset,
      data: [for (final v in values) ...leBytes(v)],
    ),
  );

  Future<void> writeReg(int offset, int value) => writeRegs(offset, [value]);

  int localByte(int address) => local[address] ?? dmaFill(address);
}

/// Host SG list memory, pages and checks for one run.
class PcieGpuRun {
  final PcieGpuBench b;
  static const cplBase = 0x90000000;
  static const cplLog = 10;
  static const descBase = 0x80000000;
  static const descLog = 10;
  static const page = 4096;
  static const d2hLocal = 0x000000;
  static const h2dLocal = 0x100000;
  static const fifoLocal = 0x300000;
  static const bar2Window = 0x800000;
  static const bar2WindowBytes = 0x10000;

  final List<GpuDesc> descs = [];
  final Map<int, int> shadow = {};
  int recordsSeen = 0;
  int clearedAtPackets = 0;
  int bar2Writes = 0;
  int bar2Reads = 0;
  int bar2SourceReads = 0;

  /// Bytes in each direction.
  final int size;

  PcieGpuRun(this.b, {this.size = 1 << 20});

  /// Scattered host pages: D2H pages above 4 GB, H2D pages below.
  void buildSgList() {
    final order = List<int>.generate(size ~/ page, (i) => i)..shuffle(b.random);
    for (var i = 0; i < size ~/ page; i++) {
      final last = i == size ~/ page - 1;
      descs.add(
        GpuDesc(
          0x200000000 + order[i] * 2 * page,
          d2hLocal + i * page,
          page,
          d2h: true,
          irq: i % 64 == 63 || last,
          cookie: 0x1000 + 2 * i,
        ),
      );
      final hostPage = 0x40000000 + order[i] * 3 * page;
      b.host.memory.write(hostPage, [
        for (var k = 0; k < page; k++) dmaHostFill(hostPage + k),
      ]);
      descs.add(
        GpuDesc(
          hostPage,
          h2dLocal + i * page,
          page,
          d2h: false,
          irq: i % 64 == 63 || last,
          cookie: 0x1001 + 2 * i,
        ),
      );
    }
    for (final (slot, d) in descs.indexed) {
      b.host.memory.write(descBase + 32 * slot, [
        ...leBytes(d.host, 8),
        ...leBytes(d.local, 8),
        ...leBytes(d.length),
        ...leBytes(
          (d.d2h ? HarborPcieDma.flagDeviceToHost : 0) |
              (d.irq ? HarborPcieDma.flagIrq : 0),
        ),
        ...leBytes(d.cookie),
        ...leBytes(0),
      ]);
    }
  }

  DmaRecord record(int slot) =>
      DmaRecord(b.host.memory.read(cplBase + 16 * slot, 16));

  /// Clears the causes and frees the record slots, as a driver does.
  Future<void> serviceIrq() async {
    final cause = await b.readReg(HarborPcieDma.registerIrqCause);
    clearedAtPackets = b.sink.received.length;
    await b.writeReg(HarborPcieDma.registerIrqCause, cause);
    final tail = await b.readReg(HarborPcieDma.registerCplTail);
    await b.writeReg(HarborPcieDma.registerCplHead, tail);
    if (cause & HarborPcieDma.causeError != 0) {
      fail(
        'DMA error cause, STATUS 0x'
        '${(await b.readReg(HarborPcieDma.registerStatus)).toRadixString(16)}',
      );
    }
  }

  /// Number of record writes with the IRQ flag in sink packets [from] to
  /// [to].
  int irqRecords(int from, [int? to]) {
    var n = 0;
    final received = b.sink.received;
    for (var i = from; i < (to ?? received.length); i++) {
      final t = received[i];
      if (!t.kind.hasData || !t.kind.isRequest) continue;
      final slot = (t.address - cplBase) ~/ 16;
      if (t.address < cplBase || slot >= 1 << cplLog) continue;
      final cookie = DmaRecord.le(t.data, 0);
      if (slot == 0 && cookie == 1) {
        n++;
      } else if (slot >= 1 && descs[slot - 1].irq) {
        n++;
      }
    }
    return n;
  }

  /// Random BAR2 writes and reads while [busy] holds.
  Future<void> bar2Traffic(bool Function() busy) async {
    while (busy() || bar2Reads < 8) {
      final r = b.random;
      if (r.nextBool()) {
        final dw = 1 + r.nextInt(64);
        final offset = bar2Window + r.nextInt(bar2WindowBytes ~/ 4 - dw) * 4;
        final data = [for (var i = 0; i < dw * 4; i++) r.nextInt(256)];
        final firstBe = 1 + r.nextInt(15);
        final lastBe = dw == 1 ? 0 : 1 + r.nextInt(15);
        final tlp = PcieTlp.memWrite(
          address: gpuBar2 + offset,
          data: data,
          firstBe: firstBe,
          lastBe: lastBe,
        );
        for (var d = 0; d < dw; d++) {
          final be = d == 0 ? firstBe : (d == dw - 1 ? lastBe : 0xf);
          for (var k = 0; k < 4; k++) {
            if ((be >> k) & 1 == 1)
              shadow[offset + 4 * d + k] = data[4 * d + k];
          }
        }
        await b.send(tlp, user: HarborPcieStream.userBar2);
        bar2Writes++;
      } else {
        final source = r.nextInt(4) == 0;
        final dw = 1 + r.nextInt(128);
        final offset = source
            ? d2hLocal + r.nextInt(size ~/ 4 - dw) * 4
            : bar2Window + r.nextInt(bar2WindowBytes ~/ 4 - dw) * 4;
        final (request, completions) = await b.read(
          gpuBar2 + offset,
          dw,
          user: HarborPcieStream.userBar2,
        );
        final errors = pcieCheckReadCompletions(
          request,
          completions,
          rcb: 64,
          maxPayload: 256,
          completerId: dmaCompleterId,
          read: (address, length) => Uint8List.fromList([
            for (var i = 0; i < length; i++)
              () {
                final o = (address + i) & 0xffffff;
                return shadow[o] ?? dmaFill(o);
              }(),
          ]),
        );
        if (errors.isNotEmpty) fail(errors.join('\n'));
        bar2Reads++;
        if (source) bar2SourceReads++;
      }
    }
  }

  Future<void> run() async {
    await b.start();
    final dma = b.top.dma;

    expect(await b.readReg(HarborPcieDma.registerId), HarborPcieDma.identifier);
    expect(await b.readReg(HarborPcieDma.registerCaps), dma.caps);
    for (final (i, w) in gpuInfoWords.indexed) {
      expect(await b.readReg(0x100 + 4 * i), w);
    }
    expect(await b.readReg(0x100 + 4 * gpuInfoWords.length), 0);

    if (b.withRom) {
      final (request, c) = await b.read(
        gpuRom + 0x40,
        6,
        user: HarborPcieStream.userRom,
      );
      final errors = pcieCheckReadCompletions(
        request,
        c,
        rcb: 64,
        maxPayload: 256,
        completerId: dmaCompleterId,
        read: (address, length) => Uint8List.fromList([
          for (var i = 0; i < length; i++)
            (gpuRomWord(((address + i) & 0xfff) ~/ 4) >>
                    8 * ((address + i) & 3)) &
                0xff,
        ]),
      );
      if (errors.isNotEmpty) fail(errors.join('\n'));
    }

    buildSgList();
    await b.writeReg(HarborPcieDma.registerCplBaseLow, cplBase);
    await b.writeReg(HarborPcieDma.registerCplBaseHigh, 0);
    await b.writeReg(HarborPcieDma.registerCplSize, cplLog);
    await b.writeReg(HarborPcieDma.registerDescBaseLow, descBase);
    await b.writeReg(HarborPcieDma.registerDescBaseHigh, 0);
    await b.writeReg(HarborPcieDma.registerDescSize, descLog);
    await b.writeReg(
      HarborPcieDma.registerIrqMask,
      HarborPcieDma.causeDone |
          HarborPcieDma.causeError |
          1 << HarborPcieDma.causeLineShift,
    );
    await b.writeReg(
      HarborPcieDma.registerControl,
      HarborPcieDma.controlEnable,
    );

    // One descriptor through the BAR0 push FIFO first.
    await b.writeRegs(HarborPcieDma.registerPush, [
      0x70000000,
      0,
      fifoLocal,
      0,
      page,
      HarborPcieDma.flagDeviceToHost | HarborPcieDma.flagIrq,
      1,
      0,
    ]);
    await b.waitUntil(() => b.host.msis.isNotEmpty, what: 'FIFO MSI');
    expect(b.host.msis.first, 0);
    expect(irqRecords(0, b.msiLog.first.$2), 1);
    await serviceIrq();
    expect(record(0).cookie, 1);
    expect(record(0).code, 0);

    // Then the SG list through the host ring.
    await b.writeReg(
      HarborPcieDma.registerControl,
      HarborPcieDma.controlEnable | HarborPcieDma.controlRingSource,
    );
    while ((await b.readReg(HarborPcieDma.registerStatus) &
            HarborPcieDma.statusRingSource) ==
        0) {}

    var dmaDone = false;
    final traffic = bar2Traffic(() => !dmaDone);
    var handled = 1;
    var tail = 0;
    var lineDone = false;
    final total = descs.length;
    while (true) {
      if (tail < total) {
        final head = await b.readReg(HarborPcieDma.registerDescHead);
        if (tail - head < 64) {
          tail = min(total, tail + 128);
          await b.writeReg(HarborPcieDma.registerDescTail, tail);
        }
      }
      if (!lineDone && tail >= total ~/ 2) {
        b.irqLine.inject(1);
        // An MSI waits while TX is busy, so this can wait for the queue.
        await b.waitUntil(
          () => b.host.msis.contains(1),
          timeout: 2000000,
          what: 'SoC line MSI',
        );
        b.irqLine.inject(0);
        lineDone = true;
      }
      if (b.host.msis.length > handled) {
        final (v, packets) = b.msiLog[handled];
        if (v == 0 && irqRecords(clearedAtPackets, packets) == 0) {
          fail('MSI $handled came before its record');
        }
        handled++;
        await serviceIrq();
      }
      final done = await b.readReg(HarborPcieDma.registerCplTail);
      if (done == total + 1) break;
      for (var i = 0; i < 200; i++) {
        await b.clk.nextPosedge;
      }
    }
    dmaDone = true;
    await traffic;
    await b.waitUntil(
      () => record(total).cookie == descs.last.cookie,
      what: 'last record',
    );
    // A done event can fall between the cause read and its clear, so wait
    // for MSIs until none comes.
    while (true) {
      for (var i = 0; i < 2000; i++) {
        await b.clk.nextPosedge;
      }
      if (b.host.msis.length == handled) break;
      handled = b.host.msis.length;
      await serviceIrq();
    }

    // Records, data and counters.
    for (var slot = 1; slot <= total; slot++) {
      final r = record(slot);
      final d = descs[slot - 1];
      expect(r.cookie, d.cookie, reason: 'slot $slot');
      expect(r.code, 0, reason: 'slot $slot');
      expect(r.bytes, d.length, reason: 'slot $slot');
      expect(r.phase, true, reason: 'slot $slot');
    }
    for (var k = 0; k < page; k++) {
      expect(
        b.host.memory.read(0x70000000 + k, 1).single,
        b.localByte(fifoLocal + k),
      );
    }
    for (final d in descs) {
      final hostBytes = b.host.memory.read(d.host, d.length);
      for (var k = 0; k < d.length; k++) {
        final want = d.d2h ? b.localByte(d.local + k) : hostBytes[k];
        final got = d.d2h ? hostBytes[k] : b.localByte(d.local + k);
        if (want != got) {
          fail(
            '${d.d2h ? 'D2H' : 'H2D'} cookie ${d.cookie} byte $k is '
            '$got, expected $want',
          );
        }
      }
    }
    final status = await b.readReg(HarborPcieDma.registerStatus);
    expect(status & 0xffff, HarborPcieDma.statusRingSource, reason: 'STATUS');
    expect(await b.readReg(HarborPcieDma.registerStaleCompletions), 0);
    expect(await b.readReg(HarborPcieDma.registerIrqCause), 0);
    expect(b.top.output('write_errors').value.toInt(), 0);
    expect(b.host.violations, isEmpty);
    expect(b.violations, isEmpty);
    expect(b.host.msis.where((v) => v == 1), hasLength(1));
    expect(b.host.msis.where((v) => v == 0).length, greaterThanOrEqualTo(2));
    expect(b.host.msis.where((v) => v > 1), isEmpty);
    expect(bar2SourceReads, greaterThan(0));
    expect(bar2Writes, greaterThan(0));
    await b.finish();
  }
}

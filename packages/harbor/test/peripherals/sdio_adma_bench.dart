import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import '../util/reg_bus.dart';

const admaCtrl = 0x00;
const admaStatus = 0x08;
const admaClkDiv = 0x10;
const admaCmd = 0x18;
const admaBlkSize = 0x50;
const admaIntStatus = 0x60;
const admaIntEnable = 0x68;
const admaAdmaAddr = 0x70;

const admaDataDone = 0x02;
const admaWriteErr = 0x20;
const admaAdmaErr = 0x80;
const admaErrBase = 0x8000;

const admaCmdRead = 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10);
const admaCmdWrite = 24 | (1 << 6) | (1 << 8) | (1 << 10);
const admaTable = 1 << 11;

List<int> admaBitsMsb(int value, int width) => [
  for (var i = width - 1; i >= 0; i--) (value >> i) & 1,
];

List<int> admaResp48() => [
  0,
  0,
  ...admaBitsMsb(0, 6),
  ...admaBitsMsb(0, 32),
  ...admaBitsMsb(0, 7),
  1,
];

List<int> admaCrc16(List<int> bits) {
  var c = List<int>.filled(16, 0);
  for (final b in bits) {
    final inv = b ^ c[15];
    c = [
      for (var i = 0; i < 16; i++)
        if (i == 0)
          inv
        else if (i == 5)
          c[4] ^ inv
        else if (i == 12)
          c[11] ^ inv
        else
          c[i - 1],
    ];
  }
  return [for (var i = 15; i >= 0; i--) c[i]];
}

/// The 4-bit DAT groups of one block of [words]: start, data nibbles (byte 0
/// first, high nibble first), then the per-lane CRC16.
List<int> admaFourBitBlock(List<int> words) {
  final data = <int>[
    for (final w in words)
      for (var b = 0; b < 4; b++) ...[
        (w >> (8 * b + 4)) & 0xF,
        (w >> (8 * b)) & 0xF,
      ],
  ];
  final laneCrc = [
    for (var l = 0; l < 4; l++) admaCrc16([for (final g in data) (g >> l) & 1]),
  ];
  final crc = [
    for (var t = 0; t < 16; t++)
      [for (var l = 0; l < 4; l++) laneCrc[l][t] << l].reduce((a, b) => a | b),
  ];
  return [0, ...data, ...crc];
}

/// The SDIO controller with its ADMA master on a memory slave port of the same
/// kind. The slave waist is on ports `mem_*`, the register port on `bus_*`.
class AdmaSdioMemTop extends BridgeModule {
  AdmaSdioMemTop(
    HarborSdioController dut,
    HarborFabricKind kind,
    HarborMemoryWaistConfig config,
  ) : super('SdioMemTop_${dut.definitionName}', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    addSubModule(dut);
    final slave = addSubModule(MemSlaveShell(config, kind: kind));
    for (final m in [dut, slave]) {
      m.input('clk').srcConnection! <= input('clk');
      m.input('reset').srcConnection! <= input('reset');
    }
    connectInterfaces(dut.interface('dma'), slave.interface('bus'));
    pullUpInterface(dut.interface('bus'), newIntfName: 'bus');
    pullUpInterface(slave.interface('mem'), newIntfName: 'mem');
    for (final p in [...dut.inputs.keys, ...dut.outputs.keys]) {
      if (p == 'clk' || p == 'reset') continue;
      if (p.startsWith('bus_') || p.startsWith('dma_')) continue;
      pullUpPort(dut.port(p), newPortName: p);
    }
  }
}

/// Watches the ADMA master waist and records what crosses it.
class AdmaProbe {
  final List<Burst> writes = [];
  final List<Burst> reads = [];
  final List<String> errors = [];
  int cycle = 0;
  int lastResp = -1;
  int doneAt = -1;
  int _inflight = 0;

  AdmaProbe(HarborMemoryWaist w, Logic clk, Logic irq) {
    bool hi(Logic l) => l.value.isValid && l.value.toBool();
    clk.negedge.listen((_) {
      cycle++;
      if (hi(w.reqValid) && hi(w.reqReady)) {
        final b = Burst(
          id: w.reqId.value.toInt(),
          write: hi(w.reqWrite),
          addr: w.reqAddr.value.toInt(),
          len: w.reqLen.value.toInt(),
          size: w.reqSize.value.toInt(),
          burst: w.reqBurst.value.toInt(),
        );
        if (b.write) {
          writes.add(b);
          _inflight++;
        } else {
          reads.add(b);
          if (_inflight != 0) errors.add('$b sent with a write in flight');
        }
      }
      if (hi(w.wrespValid) && hi(w.wrespReady)) {
        _inflight--;
        lastResp = cycle;
      }
      if (doneAt < 0 && hi(irq)) doneAt = cycle;
    });
  }
}

class AdmaBench {
  final HarborFabricKind kind;
  final int dataWidth;

  /// Requests the ADMA master can have in flight. 1 takes the Wishbone
  /// fast path when [kind] is wishbone.
  final int dmaOutstanding;

  /// How often the memory slave goes idle on its own channels, 0 to 1.
  final double stall;

  /// SD clocks the controller waits for the end of a card's busy.
  final int writeBusyTimeout;
  final int burstBeats;
  final int writeBatch;
  final bool sampleFall;
  final int errBase;
  late final HarborSdioController sdio;
  late final AdmaSdioMemTop top;
  late final Sim sim;
  late final RegBus bus;
  late final WaistMemory mem;
  late final AdmaProbe probe;
  final List<String> errors = [];
  final Logic cmdIn = Logic(name: 'tb_cmd_in');
  final Logic datIn = Logic(name: 'tb_dat_in', width: 4);

  AdmaBench(
    this.kind,
    this.dataWidth, {
    this.dmaOutstanding = 4,
    this.stall = 0.3,
    this.writeBusyTimeout = HarborSdioController.defaultWriteBusyTimeout,
    this.burstBeats = 8,
    this.writeBatch = 4,
    this.sampleFall = false,
    this.errBase = admaErrBase,
  });

  int get busBytes => dataWidth ~/ 8;
  Logic get clk => sim.clk;
  Logic get irq => top.output('interrupt');

  Future<void> start() async {
    sdio = HarborSdioController(
      baseAddress: 0x60000000,
      fabricKind: kind,
      dmaDataWidth: dataWidth,
      config: HarborSdioConfig(sampleReadOnFall: sampleFall),
      dmaBurstBeats: burstBeats,
      dmaWriteBatch: writeBatch,
      dmaOutstanding: dmaOutstanding,
      writeBusyTimeout: writeBusyTimeout,
    );
    final cfg = HarborMemoryWaistConfig(
      addressWidth: 32,
      dataWidth: dataWidth,
      outstanding: dmaOutstanding,
    );
    top = AdmaSdioMemTop(sdio, kind, cfg);
    sim = Sim(top);
    top.input('sd_cmd_in').srcConnection! <= cmdIn;
    top.input('sd_dat_in').srcConnection! <= datIn;
    bus = RegBus.attach(top, sim.clk);
    for (final e in top.inputs.entries) {
      if (e.key == 'clk' || e.value.srcConnection != null) continue;
      e.value.srcConnection! <=
          Logic(name: 'tb_${e.key}', width: e.value.width);
    }
    mem = WaistMemory(
      sim,
      'mem',
      Random(7),
      outstanding: dmaOutstanding,
      busBytes: busBytes,
      errors: errors,
      errBase: errBase,
      stall: stall,
    );
    await sim.start();
    Simulator.setMaxSimTime(4000000);
    bus.idle();
    cmdIn.inject(1);
    datIn.inject(0xF);
    probe = AdmaProbe(sdio.dmaPort.waist, sim.clk, irq);
    await wr(admaClkDiv, 0);
    await wr(admaCtrl, 0x01 | (1 << 4)); // enable, 4-bit bus
    await wr(admaIntEnable, admaDataDone);
  }

  Future<void> settle() async {
    if (kind == HarborFabricKind.wishbone) await sim.clk.nextPosedge;
  }

  Future<void> wr(int addr, int data) async {
    await bus.write(addr, data);
    await settle();
  }

  Future<int> rd(int addr) async {
    final v = await bus.read(addr);
    await settle();
    return v;
  }

  int read32(int addr) {
    final lane = addr % busBytes;
    return (mem.mem.read(addr) >> (8 * lane)) & 0xFFFFFFFF;
  }

  void write32(int addr, int v) {
    final lane = addr % busBytes;
    mem.mem.write(addr, v << (8 * lane), 0xF << lane);
  }

  void descriptors(int at, List<(int, int)> runs) {
    for (var i = 0; i < runs.length; i++) {
      final (addr, len) = runs[i];
      write32(at + 8 * i, addr);
      write32(at + 8 * i + 4, len | (i == runs.length - 1 ? 0x80000000 : 0));
    }
  }

  /// Answers the command, then sends [words] as one 4-bit block. Returns
  /// when data-done raises the interrupt.
  Future<void> cardRead(List<int> words) async {
    final resp = admaResp48();
    final stream = admaFourBitBlock(words);
    final total = resp.length + stream.length;
    var sawDrive = false, idx = 0;
    var prevLow = top.output('sd_clk').value.toInt() == 0;
    for (var i = 0; i < 40000; i++) {
      await clk.nextPosedge;
      final sending = top.output('sd_cmd_oe').value.toInt() == 1;
      if (sending) sawDrive = true;
      final low = top.output('sd_clk').value.toInt() == 0;
      if (sawDrive && !sending && low && !prevLow && idx < total) {
        if (idx < resp.length) {
          cmdIn.inject(resp[idx]);
        } else {
          datIn.inject(stream[idx - resp.length]);
        }
        idx++;
      }
      if (idx == total && low && !prevLow) datIn.inject(0xF);
      prevLow = low;
      if (irq.value.toInt() == 1) {
        await clk.nextNegedge;
        return;
      }
    }
    fail('the card read never finished');
  }

  /// Answers the command, then sends each of [blocks] back to back.. Returns when the transfer ends.
  Future<void> cardReadBlocks(List<List<int>> blocks) async {
    final resp = admaResp48();
    final stream = <int>[for (final w in blocks) ...admaFourBitBlock(w)];
    final total = resp.length + stream.length;
    var sawDrive = false, idx = 0;
    var prevLow = top.output('sd_clk').value.toInt() == 0;
    for (var i = 0; i < 4000000; i++) {
      await clk.nextPosedge;
      final sending = top.output('sd_cmd_oe').value.toInt() == 1;
      if (sending) sawDrive = true;
      final low = top.output('sd_clk').value.toInt() == 0;
      var injected = false;
      if (sawDrive && !sending && low && !prevLow && idx < total) {
        injected = true;
        if (idx < resp.length) {
          cmdIn.inject(resp[idx]);
        } else {
          datIn.inject(stream[idx - resp.length]);
        }
        idx++;
      }
      if (idx == total && low && !prevLow && !injected) datIn.inject(0xF);
      prevLow = low;
      if (irq.value.toInt() == 1) {
        await clk.nextNegedge;
        return;
      }
    }
    fail('the card read never finished');
  }

  /// Answers the command, takes the block the controller sends, then sends
  /// [statusBusy] on DAT0: by default an accepted CRC status and a short
  /// busy. The last value stays on DAT0. Returns the DAT groups taken.
  Future<List<int>> cardWrite({
    List<int> statusBusy = const [0, 0, 1, 0, 1, 0, 1],
    int? requiredDataGroups,
  }) async {
    final resp = admaResp48();
    var sawCmd = false, sawDat = false, ri = 0, si = 0;
    final captured = <int>[];
    var endBitObserved = false;
    var prevClk = top.output('sd_clk').value.toInt();
    final maxCycles = requiredDataGroups == null ? 40000 : 200000;
    for (var i = 0; i < maxCycles; i++) {
      await clk.nextPosedge;
      final cmdSending = top.output('sd_cmd_oe').value.toInt() == 1;
      if (cmdSending) sawCmd = true;
      final datDriving = top.output('sd_dat_oe').value.toInt() == 1;
      if (datDriving) sawDat = true;
      final sdClk = top.output('sd_clk').value.toInt();
      if (sawCmd && !cmdSending && !sawDat && sdClk == 0 && ri < resp.length) {
        cmdIn.inject(resp[ri]);
        ri++;
      }
      if (prevClk == 0 && sdClk == 1 && datDriving) {
        final group = top.output('sd_dat_out').value.toInt() & 0xF;
        captured.add(group);
        if (requiredDataGroups != null &&
            captured.length == requiredDataGroups + 1 &&
            group == 0xF) {
          endBitObserved = true;
        }
      }
      prevClk = sdClk;
      if (sawDat &&
          !datDriving &&
          sdClk == 0 &&
          si < statusBusy.length &&
          (requiredDataGroups == null || endBitObserved)) {
        datIn.inject(0xE | statusBusy[si]);
        si++;
      }
      if (irq.value.toInt() == 1) {
        await clk.nextNegedge;
        return captured;
      }
    }
    fail('the card write never finished');
  }

  void checkShapes() {
    for (final b in [
      ...probe.writes,
      ...probe.reads,
      ...mem.writes,
      ...mem.reads,
    ]) {
      expect(
        illegalBurst(b, busBytes),
        isFalse,
        reason: '$b breaks AXI4 rules',
      );
    }
    for (final b in probe.writes) {
      expect(
        (b.addr & 0xFFF) + (b.len + 1) * (1 << b.size),
        lessThanOrEqualTo(4096),
      );
    }
    expect(probe.errors, isEmpty);
    expect(errors, isEmpty);
  }
}

/// Runs a direct DMA CMD18 read of [n] blocks of 512 bytes on the Delta
/// configuration (64-bit master, one request in flight, one beat bursts,
/// 4-bit bus, sample on fall) against a memory that idles [stall] of the
/// time. Checks every byte and the status bits.
Future<void> checkDirectCmd18(int n, double stall) async {
  final b = AdmaBench(
    HarborFabricKind.wishbone,
    64,
    dmaOutstanding: 1,
    stall: stall,
    burstBeats: 1,
    sampleFall: true,
    errBase: 0x1000000,
  );
  await b.start();
  Simulator.setMaxSimTime(400000000);
  final blocks = [
    for (var k = 0; k < n; k++)
      [for (var i = 0; i < 128; i++) (k << 20) + 0x10000 + i * 0x101],
  ];
  await b.wr(admaBlkSize, 512);
  await b.wr(0x58, n);
  await b.wr(admaAdmaAddr, 0x10000);
  await b.wr(admaCmd, 18 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10));
  await b.cardReadBlocks(blocks);
  var bad = 0;
  for (var k = 0; k < n; k++) {
    for (var i = 0; i < 128; i++) {
      if (b.read32(0x10000 + k * 512 + i * 4) != blocks[k][i]) bad++;
    }
  }
  final st = await b.rd(admaIntStatus);
  expect(bad, 0);
  expect(st & (admaDataDone | 0xF8), admaDataDone);
  await Simulator.endSimulation();
}

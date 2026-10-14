import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import '../util/reg_bus.dart';

const _ctrl = 0x00;
const _status = 0x08;
const _clkDiv = 0x10;
const _cmd = 0x18;
const _blkSize = 0x50;
const _intStatus = 0x60;
const _intEnable = 0x68;
const _admaAddr = 0x70;

const _dataDone = 0x02;
const _writeErr = 0x20;
const _admaErr = 0x80;
const _errBase = 0x8000;

const _cmdRead = 17 | (1 << 6) | (1 << 8) | (1 << 9) | (1 << 10);
const _cmdWrite = 24 | (1 << 6) | (1 << 8) | (1 << 10);
const _table = 1 << 11;

List<int> _bitsMsb(int value, int width) => [
  for (var i = width - 1; i >= 0; i--) (value >> i) & 1,
];

List<int> _resp48() => [
  0,
  0,
  ..._bitsMsb(0, 6),
  ..._bitsMsb(0, 32),
  ..._bitsMsb(0, 7),
  1,
];

List<int> _crc16(List<int> bits) {
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
List<int> _fourBitBlock(List<int> words) {
  final data = <int>[
    for (final w in words)
      for (var b = 0; b < 4; b++) ...[
        (w >> (8 * b + 4)) & 0xF,
        (w >> (8 * b)) & 0xF,
      ],
  ];
  final laneCrc = [
    for (var l = 0; l < 4; l++) _crc16([for (final g in data) (g >> l) & 1]),
  ];
  final crc = [
    for (var t = 0; t < 16; t++)
      [for (var l = 0; l < 4; l++) laneCrc[l][t] << l].reduce((a, b) => a | b),
  ];
  return [0, ...data, ...crc];
}

/// The SDIO controller with its ADMA master on a memory slave port of the same
/// kind. The slave waist is on ports `mem_*`, the register port on `bus_*`.
class _SdioMemTop extends BridgeModule {
  _SdioMemTop(
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
class _Probe {
  final List<Burst> writes = [];
  final List<Burst> reads = [];
  final List<String> errors = [];
  int cycle = 0;
  int lastResp = -1;
  int doneAt = -1;
  int _inflight = 0;

  _Probe(HarborMemoryWaist w, Logic clk, Logic irq) {
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

class _Bench {
  final HarborFabricKind kind;
  final int dataWidth;

  /// Requests the ADMA master can have in flight. 1 takes the Wishbone
  /// fast path when [kind] is wishbone.
  final int dmaOutstanding;

  /// How often the memory slave goes idle on its own channels, 0 to 1.
  final double stall;

  /// SD clocks the controller waits for the end of a card's busy.
  final int writeBusyTimeout;
  late final HarborSdioController sdio;
  late final _SdioMemTop top;
  late final Sim sim;
  late final RegBus bus;
  late final WaistMemory mem;
  late final _Probe probe;
  final List<String> errors = [];
  final Logic cmdIn = Logic(name: 'tb_cmd_in');
  final Logic datIn = Logic(name: 'tb_dat_in', width: 4);

  _Bench(
    this.kind,
    this.dataWidth, {
    this.dmaOutstanding = 4,
    this.stall = 0.3,
    this.writeBusyTimeout = HarborSdioController.defaultWriteBusyTimeout,
  });

  int get busBytes => dataWidth ~/ 8;
  Logic get clk => sim.clk;
  Logic get irq => top.output('interrupt');

  Future<void> start() async {
    sdio = HarborSdioController(
      baseAddress: 0x60000000,
      fabricKind: kind,
      dmaDataWidth: dataWidth,
      dmaBurstBeats: 8,
      dmaOutstanding: dmaOutstanding,
      writeBusyTimeout: writeBusyTimeout,
    );
    final cfg = HarborMemoryWaistConfig(
      addressWidth: 32,
      dataWidth: dataWidth,
      outstanding: dmaOutstanding,
    );
    top = _SdioMemTop(sdio, kind, cfg);
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
      errBase: _errBase,
      stall: stall,
    );
    await sim.start();
    Simulator.setMaxSimTime(4000000);
    bus.idle();
    cmdIn.inject(1);
    datIn.inject(0xF);
    probe = _Probe(sdio.dmaPort.waist, sim.clk, irq);
    await wr(_clkDiv, 0);
    await wr(_ctrl, 0x01 | (1 << 4)); // enable, 4-bit bus
    await wr(_intEnable, _dataDone);
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
    final resp = _resp48();
    final stream = _fourBitBlock(words);
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

  /// Answers the command, takes the block the controller sends, then sends
  /// [statusBusy] on DAT0: by default an accepted CRC status and a short
  /// busy. The last value stays on DAT0. Returns the DAT groups taken.
  Future<List<int>> cardWrite({
    List<int> statusBusy = const [0, 0, 1, 0, 0, 1],
  }) async {
    final resp = _resp48();
    var sawCmd = false, sawDat = false, ri = 0, si = 0;
    final captured = <int>[];
    var prevClk = top.output('sd_clk').value.toInt();
    for (var i = 0; i < 40000; i++) {
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
        captured.add(top.output('sd_dat_out').value.toInt() & 0xF);
      }
      prevClk = sdClk;
      if (sawDat && !datDriving && sdClk == 0 && si < statusBusy.length) {
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

void main() {
  tearDown(() async => Simulator.reset());

  for (final kind in HarborFabricKind.values) {
    for (final width in [32, 64]) {
      final tag = '${kind.name}, $width-bit';

      test('card read over a descriptor table ($tag)', () async {
        final b = _Bench(kind, width);
        await b.start();
        // An unaligned run across a 4 KB boundary, an odd tail, and an
        // unaligned odd run.
        const runs = [(0x0FE4, 40), (0x2000, 12), (0x3004, 12)];
        b.descriptors(0x100, runs);
        final before = {
          for (final a in [0x0FE0, 0x100C, 0x200C, 0x3000, 0x3010])
            a: b.read32(a),
        };
        final words = [
          for (var i = 0; i < 16; i++) 0x01020304 * (i + 1) ^ 0xA5000000,
        ];
        await b.wr(_blkSize, 64);
        await b.wr(_admaAddr, 0x100);
        await b.wr(_cmd, _cmdRead | _table);
        await b.cardRead(words);

        var n = 0;
        for (final (addr, len) in runs) {
          for (var o = 0; o < len; o += 4) {
            expect(
              b.read32(addr + o),
              words[n],
              reason: 'word $n at 0x${(addr + o).toRadixString(16)}',
            );
            n++;
          }
        }
        before.forEach(
          (a, v) => expect(
            b.read32(a),
            v,
            reason: 'touched 0x${a.toRadixString(16)}',
          ),
        );
        b.checkShapes();
        expect(
          b.probe.writes.any((w) => w.len > 0),
          isTrue,
          reason: 'no burst',
        );
        expect(
          b.probe.doneAt,
          greaterThan(b.probe.lastResp),
          reason: 'data-done before the last write response',
        );
        final st = await b.rd(_intStatus);
        expect(st & (_dataDone | _admaErr), _dataDone);
        expect((await b.rd(_status) >> 8) & 1, 0, reason: 'still busy');
        await Simulator.endSimulation();
      });

      test('card write over a descriptor table ($tag)', () async {
        final b = _Bench(kind, width);
        await b.start();
        const runs = [(0x0FF8, 16), (0x2004, 8)];
        b.descriptors(0x180, runs);
        final words = [
          for (var i = 0; i < 6; i++) 0x11111111 * (i + 1) ^ 0x5A0000C3,
        ];
        var n = 0;
        for (final (addr, len) in runs) {
          for (var o = 0; o < len; o += 4) {
            b.write32(addr + o, words[n++]);
          }
        }
        await b.wr(_blkSize, 24);
        await b.wr(_admaAddr, 0x180);
        await b.wr(_cmd, _cmdWrite | _table);
        final got = await b.cardWrite();
        final want = _fourBitBlock(words);
        expect(got.length, greaterThanOrEqualTo(want.length));
        expect(got.sublist(0, want.length), want);
        b.checkShapes();
        expect(b.probe.writes, isEmpty);
        expect(await b.rd(_intStatus) & (_dataDone | _admaErr), _dataDone);
        await Simulator.endSimulation();
      });

      test(
        'a write error ends a card read with the ADMA error bit ($tag)',
        () async {
          final b = _Bench(kind, width);
          await b.start();
          await b.wr(_blkSize, 32);
          await b.wr(_admaAddr, _errBase + 0x1000);
          await b.wr(_cmd, _cmdRead);
          await b.cardRead([for (var i = 0; i < 8; i++) i]);
          final st = await b.rd(_intStatus);
          expect(st & (_dataDone | _admaErr), _dataDone | _admaErr);
          expect((await b.rd(_status) >> 8) & 1, 0, reason: 'still busy');
          b.checkShapes();
          await b.wr(_intStatus, _admaErr);
          expect(await b.rd(_intStatus) & _admaErr, 0, reason: 'bit 7 is W1C');
          await Simulator.endSimulation();
        },
      );

      test(
        'a read error ends a card write with the ADMA error bit ($tag)',
        () async {
          final b = _Bench(kind, width);
          await b.start();
          await b.wr(_blkSize, 8);
          await b.wr(_admaAddr, _errBase + 0x1000);
          await b.wr(_cmd, _cmdWrite);
          final got = await b.cardWrite();
          expect(
            await b.rd(_intStatus) & (_dataDone | _admaErr),
            _dataDone | _admaErr,
          );
          // The card must reject the block: its CRC16 is wrong on every
          // lane.
          final data = got.sublist(1, 17);
          final crc = got.sublist(17, 33);
          for (var l = 0; l < 4; l++) {
            expect(
              [for (final g in crc) (g >> l) & 1],
              isNot(_crc16([for (final g in data) (g >> l) & 1])),
              reason: 'lane $l has a good CRC',
            );
          }
          expect((await b.rd(_status) >> 8) & 1, 0, reason: 'still busy');
          b.checkShapes();
          await Simulator.endSimulation();
        },
      );

      test('a descriptor fetch error ends a card read ($tag)', () async {
        final b = _Bench(kind, width);
        await b.start();
        await b.wr(_blkSize, 16);
        await b.wr(_admaAddr, _errBase + 0x200);
        await b.wr(_cmd, _cmdRead | _table);
        await b.cardRead([1, 2, 3, 4]);
        expect(
          await b.rd(_intStatus) & (_dataDone | _admaErr),
          _dataDone | _admaErr,
        );
        expect(b.probe.writes, isEmpty);
        b.checkShapes();
        await Simulator.endSimulation();
      });
    }
  }

  for (final (name, answer, addr) in [
    ('a rejected block with no busy', [0, 1, 0, 1, 1, 1, 1], _errBase),
    ('a busy that never ends', [0, 0, 1, 0, 1, 0], 0x1000),
  ]) {
    test('a card write ends after $name, and the next write works', () async {
      final b = _Bench(HarborFabricKind.wishbone, 32, writeBusyTimeout: 64);
      await b.start();
      await b.wr(_blkSize, 8);
      await b.wr(_admaAddr, addr);
      await b.wr(_cmd, _cmdWrite);
      await b.cardWrite(statusBusy: answer);
      expect(
        await b.rd(_intStatus) & (_dataDone | _writeErr),
        _dataDone | _writeErr,
      );
      expect((await b.rd(_status) >> 8) & 1, 0, reason: 'still busy');

      b.datIn.inject(0xF);
      await b.wr(_intStatus, 0xFF);
      const words = [0x12345678, 0x9ABCDEF0];
      b.write32(0x2000, words[0]);
      b.write32(0x2004, words[1]);
      await b.wr(_admaAddr, 0x2000);
      await b.wr(_cmd, _cmdWrite);
      final got = await b.cardWrite();
      final want = _fourBitBlock(words);
      expect(got.sublist(0, want.length), want);
      expect(
        await b.rd(_intStatus) & (_dataDone | _writeErr | _admaErr),
        _dataDone,
      );
      await Simulator.endSimulation();
    });
  }

  test('STATUS busy stays set while an ADMA access is in flight', () async {
    // The memory never takes a request, so the first ADMA read stays in
    // flight after the command times out.
    final b = _Bench(HarborFabricKind.wishbone, 32, stall: 1);
    await b.start();
    await b.wr(_blkSize, 8);
    await b.wr(_admaAddr, 0x1000);
    await b.wr(_cmd, _cmdWrite);
    var timedOut = false;
    for (var i = 0; i < 400 && !timedOut; i++) {
      timedOut = await b.rd(_intStatus) & 0x10 != 0;
    }
    expect(timedOut, isTrue, reason: 'no command timeout');
    expect((await b.rd(_status) >> 8) & 1, 1, reason: 'busy is clear');
    await Simulator.endSimulation();
  });

  // Replaces the deleted sdio_dma_throughput_sim_test: a card read drives
  // ADMA writes into memory through the Wishbone fast path (outstanding
  // 1), with the memory slave made slow and backpressuring so the test
  // proves ADMA writes neither stall forever nor drop data under it.
  test('card read keeps ADMA writes correct against a slow, backpressuring '
      'Wishbone memory slave, outstanding 1 fast path', () async {
    final b = _Bench(
      HarborFabricKind.wishbone,
      32,
      dmaOutstanding: 1,
      stall: 0.7,
    );
    await b.start();
    var cycles = 0;
    b.clk.posedge.listen((_) => cycles++);

    const blockWords = 128; // one 512-byte block
    final words = [for (var i = 0; i < blockWords; i++) 0x10000000 + i];
    await b.wr(_blkSize, blockWords * 4);
    await b.wr(_admaAddr, 0x1000);
    await b.wr(_cmd, _cmdRead);
    final before = cycles;
    await b.cardRead(words);
    final elapsed = cycles - before;

    for (var i = 0; i < blockWords; i++) {
      expect(b.read32(0x1000 + i * 4), words[i], reason: 'word $i');
    }
    b.checkShapes();
    expect(await b.rd(_intStatus) & (_dataDone | _admaErr), _dataDone);

    // SimpleClockGenerator(10) gives a 10 ns cycle, as the rest of this
    // suite assumes.
    final seconds = elapsed * 10e-9;
    final mbPerSec = (blockWords * 4) / seconds / 1e6;
    // ignore: avoid_print
    print(
      'SDIO ADMA card-read write throughput: '
      '${mbPerSec.toStringAsFixed(2)} MB/s over $elapsed cycles, '
      'stall 0.7',
    );
    await Simulator.endSimulation();
  });
}

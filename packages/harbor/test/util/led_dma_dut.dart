import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import 'led_wave.dart';
import 'reg_bus.dart';

const _ledBase = 0x10005000;
const _mem = 0x80000000;
const _irqStatus = 0x010;
const _irqEnable = 0x018;
int _reg(int ch, int off) => 0x100 + ch * 0x80 + off;
const _ctrl = 0x00;
const _status = 0x08;
const _t0h = 0x10;
const _t0l = 0x18;
const _t1h = 0x20;
const _t1l = 0x28;
const _resetGap = 0x30;
const _pixelCount = 0x38;
const _baseLo = 0x40;
const _baseHi = 0x48;
const _refresh = 0x50;

const _send = 3;

// The bytes of a frame in GRB order.
List<int> _grb(List<int> pixels) => [
  for (final p in pixels) ...[(p >> 8) & 0xFF, (p >> 16) & 0xFF, p & 0xFF],
];

// True when every low run between two bits has the length of its bit: 1 clock
// after a 1 and 2 clocks after a 0. The low after the last bit is the reset
// gap and is not checked. A fetch that starves holds a low and fails this.
bool _lowsExact(List<int> samples) {
  final bits = [for (final r in ledPulses(samples, 1)) r.length >= 2 ? 1 : 0];
  final lows = [for (final r in ledPulses(samples, 0)) r.length];
  if (lows.length != bits.length - 1) return false;
  for (var i = 0; i < lows.length; i++) {
    if (lows[i] != (bits[i] == 1 ? 1 : 2)) return false;
  }
  return true;
}

// Bytes from the high pulses of a fast frame: a pulse of 2 clocks is a 1.
List<int> _fastBytes(List<int> samples) {
  expect(_lowsExact(samples), isTrue, reason: 'a low run is stretched');
  final bits = [for (final r in ledPulses(samples, 1)) r.length >= 2 ? 1 : 0];
  expect(bits.length % 8, equals(0));
  return [
    for (var i = 0; i < bits.length; i += 8)
      bits.sublist(i, i + 8).fold(0, (v, b) => (v << 1) | b),
  ];
}

class _Cpu extends BridgeModule {
  _Cpu(HarborFabricKind kind) : super('LedDmaCpu_${kind.name}', name: 'cpu') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    final PairInterface intf = switch (kind) {
      HarborFabricKind.wishbone => WishboneInterface(
        const WishboneConfig(addressWidth: 32, dataWidth: 32, useErr: true),
      ),
      HarborFabricKind.axi4 => Axi4LiteInterface(
        addressWidth: 32,
        dataWidth: 32,
      ),
      HarborFabricKind.tilelink => TileLinkInterface(
        const TileLinkConfig(addressWidth: 32, dataWidth: 32),
      ),
    };
    final i = addInterface(
      intf,
      name: 'dataBus',
      role: PairRole.provider,
    ).internalInterface!;
    for (final e in i.getPorts([PairDirection.fromProvider]).entries) {
      final w = e.value.width;
      e.value <= addInput('p_${e.key}', Logic(width: w), width: w);
    }
    for (final e in i.getPorts([PairDirection.fromConsumer]).entries) {
      addOutput('p_${e.key}', width: e.value.width) <= e.value;
    }
  }

  void pullUp(HarborSoC soc) {
    for (final n in [...inputs.keys, ...outputs.keys]) {
      if (!n.startsWith('p_')) continue;
      soc.pullUpPort(port(n), newPortName: 'cpu_${n.substring(2)}');
    }
  }
}

// A master that reads one word of memory again and again while `hog_en`
// is high.
class _Hog extends BridgeModule {
  _Hog(HarborFabricKind kind) : super('LedDmaHog_${kind.name}', name: 'hog') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('hog_en', PortDirection.input);
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'hogbus',
      kind: kind,
      config: const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
      clk: input('clk'),
      reset: input('reset'),
    );
    final mem = port.waist;
    final sent = Logic(name: 'sent');
    mem.reqValid <= input('hog_en') & ~sent;
    mem.reqId <= Const(0, width: mem.config.idWidth);
    mem.reqWrite <= Const(0);
    mem.reqAddr <= Const(_mem + 0x800, width: 32);
    mem.reqLen <= Const(0, width: HarborMemoryWaistConfig.lenWidth);
    mem.reqSize <= Const(2, width: HarborMemoryWaistConfig.sizeWidth);
    mem.reqBurst <=
        Const(
          HarborMemoryBurst.incr.value,
          width: HarborMemoryWaistConfig.burstWidth,
        );
    mem.reqExclusive <= Const(0);
    mem.wdataValid <= Const(0);
    mem.wdataData <= Const(0, width: 32);
    mem.wdataStrb <= Const(0, width: 4);
    mem.wdataLast <= Const(0);
    mem.rdataReady <= sent;
    mem.wrespReady <= Const(0);
    Sequential(input('clk'), [
      If(
        input('reset'),
        then: [sent < 0],
        orElse: [
          If(mem.reqValid & mem.reqReady, then: [sent < 1]),
          If(mem.rdataValid & mem.rdataReady, then: [sent < 0]),
        ],
      ),
    ]);
  }
}

class _Dut {
  late HarborSoC soc;
  late Logic clk, reset;
  late RegBus bus;
  late LedWave wave;
  final hogEn = Logic(name: 'tb_hog_en');

  Future<void> setUp(
    HarborFabricKind kind, {
    int maxPixels = 16,
    int dmaAddressWidth = 32,
    int dmaDataWidth = 32,
    int memWidth = 32,
    int? cap = 16,
    int stallClocks = 65536,
  }) async {
    soc = HarborSoC(
      name: 'led_dma_${kind.name}',
      compatible: 'test,leddma',
      fabricKind: kind,
      target: const HarborSimTarget(frequency: 50000000),
    );
    final cpu = soc.addMaster(_Cpu(kind));
    final hog = _Hog(kind);
    final led = HarborLedEngine(
      baseAddress: _ledBase,
      stallClocks: stallClocks,
      maxPixels: maxPixels,
      pixelSource: HarborLedPixelSource.dma,
      fabricKind: kind,
      busAddressWidth: 32,
      dmaAddressWidth: dmaAddressWidth,
      dmaDataWidth: dmaDataWidth,
    );
    soc.addPeripheral(led);
    final range = const BusAddressRange(_mem, 0x1000);
    soc.addMaster(
      hog,
      busInterfaceName: 'hogbus',
      memory: true,
      outstanding: 1,
      targetRanges: [range],
    );
    soc.addMaster(
      led,
      busInterfaceName: 'dma',
      memory: true,
      outstanding: 1,
      targetRanges: [range],
      burstRanges: [range],
    );
    soc.addPeripheral(
      HarborSram(
        baseAddress: _mem,
        size: 0x1000,
        busAddressWidth: 32,
        dataWidth: memWidth,
        protocol: kind,
      ),
    );
    cpu.pullUp(soc);
    soc.exposePin(led, 'led_ch0', externalName: 'led_pin');
    soc.exposePin(led, 'led_status', externalName: 'led_status');
    soc.exposePin(led, 'interrupt', externalName: 'led_irq');
    soc.pullUpPort(hog.port('hog_en'), newPortName: 'hog_en');
    soc.buildFabric(
      maxGrantCycles: kind == HarborFabricKind.wishbone ? cap : null,
    );
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset')..inject(1);
    soc.input('clk').srcConnection! <= clk;
    soc.input('reset').srcConnection! <= reset;
    soc.input('hog_en').srcConnection! <= hogEn;
    bus = RegBus.attach(soc, clk, name: 'cpu', kind: kind);
    await soc.build();
    wave = LedWave(clk, soc.output('led_pin'));
    bus.idle();
    hogEn.inject(0);
    Simulator.setMaxSimTime(40000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
  }

  int get status => soc.output('led_status').value.toInt();

  Future<int> rd(int off) => bus.read(_ledBase + off);
  Future<void> wr(int off, int v) => bus.write(_ledBase + off, v);

  Future<void> putWords(int addr, List<int> words) async {
    for (var i = 0; i < words.length; i++) {
      await bus.write(addr + 4 * i, words[i]);
    }
  }

  // Fast timing: a 1 is 2 clocks high and a 0 is 1 clock high.
  Future<void> timing({int gap = 4}) async {
    await wr(_reg(0, _t0h), 1);
    await wr(_reg(0, _t0l), 2);
    await wr(_reg(0, _t1h), 2);
    await wr(_reg(0, _t1l), 1);
    await wr(_reg(0, _resetGap), gap);
  }

  Future<void> waitIdle() async {
    for (var i = 0; i < 600; i++) {
      if ((await rd(_reg(0, _status)) & 1) == 0) return;
    }
    fail('the frame did not end');
  }

  // Waits until [n] frames are done and the pin is idle.
  Future<void> waitFrames(int n) async {
    for (var i = 0; i < 400; i++) {
      final st = await rd(_reg(0, _status));
      if (st >> 16 >= n && st & 1 == 0) {
        await clk.nextPosedge;
        return;
      }
    }
    fail('frame $n did not end');
  }

  Future<void> runFrame(int base, int count) async {
    await wr(_reg(0, _baseLo), base);
    await wr(_reg(0, _pixelCount), count);
    await wr(_reg(0, _ctrl), _send);
    await waitIdle();
    await clk.nextPosedge;
  }
}

void registerLedDmaTests(HarborFabricKind kind) {
  group('HarborLedEngine dma (${kind.name})', () {
    final d = _Dut();
    tearDown(() async {
      await Simulator.reset();
    });

    test(
      'a first read slower than one bit is no stall and no underrun',
      () async {
        await d.setUp(kind);
        final pixels = [0x00A5C369, 0x00FF0001, 0x00123456];
        await d.putWords(_mem + 0x100, pixels);
        await d.timing();
        await d.wr(_reg(0, _baseLo), _mem + 0x100);
        await d.wr(_reg(0, _pixelCount), 3);
        final from = d.wave.samples.length;
        await d.wr(_reg(0, _ctrl), _send);
        await d.waitIdle();
        await d.clk.nextPosedge;
        final first = d.wave.samples.indexOf(1, from) - from;
        expect(first, greaterThan(3), reason: 'later than T0H plus T0L');
        final st = await d.rd(_reg(0, _status));
        expect(st & 0x1E, equals(0), reason: 'no UNDERRUN, error or STALL');
        expect(_fastBytes(d.wave.samples), equals(_grb(pixels)));
        await Simulator.endSimulation();
      },
    );

    test('3 pixels at BASE decode', () async {
      await d.setUp(kind);
      final pixels = [0x00A5C369, 0x00FF0001, 0x00123456];
      await d.putWords(_mem + 0x100, pixels);
      await d.timing();
      await d.wr(_reg(0, _baseLo), _mem + 0x100);
      expect(await d.rd(_reg(0, _baseLo)), equals(_mem + 0x100));
      expect(await d.rd(_reg(0, _baseHi)), equals(0));
      await d.wr(_reg(0, _pixelCount), 3);
      await d.wr(_reg(0, _ctrl), _send);
      await d.waitIdle();
      await d.clk.nextPosedge;
      expect(d.wave.samples.contains(-1), isFalse);
      expect(_fastBytes(d.wave.samples), equals(_grb(pixels)));
      final st = await d.rd(_reg(0, _status));
      expect(st & 0x1E, equals(0), reason: 'no underrun, error or pwm kind');
      expect(st >> 16, equals(1));
      expect(await d.rd(_irqStatus) & 1, equals(1));
      expect(d.status >> 16, equals(0));
      await Simulator.endSimulation();
    });

    test('an unaligned base and 7 pixels split into bursts', () async {
      await d.setUp(kind);
      final pixels = [for (var i = 0; i < 7; i++) 0x00010203 * (i + 1)];
      await d.putWords(_mem + 0x208, pixels);
      await d.timing();
      await d.runFrame(_mem + 0x208, 7);
      expect(_fastBytes(d.wave.samples), equals(_grb(pixels)));
      expect(await d.rd(_reg(0, _status)) & 0x1E, equals(0));
      await Simulator.endSimulation();
    });

    test('memory that changes between two REFRESH frames shows', () async {
      await d.setUp(kind);
      final a = [0x00112233, 0x00445566, 0x00778899];
      final b = [0x00AABBCC, 0x00DDEEFF, 0x00010203];
      await d.putWords(_mem + 0x40, a);
      await d.timing();
      await d.wr(_reg(0, _baseLo), _mem + 0x40);
      await d.wr(_reg(0, _pixelCount), 3);
      await d.wr(_reg(0, _ctrl), 2);
      await d.wr(_reg(0, _refresh), 400);
      await d.waitFrames(1);
      final split = d.wave.samples.length;
      await d.putWords(_mem + 0x40, b);
      await d.waitFrames(2);
      await d.wr(_reg(0, _refresh), 0);
      await d.waitIdle();
      await d.clk.nextPosedge;
      final first = d.wave.samples.sublist(0, split);
      final second = d.wave.samples.sublist(split);
      expect(_fastBytes(first), equals(_grb(a)));
      expect(_fastBytes(second), equals(_grb(b)));
      await Simulator.endSimulation();
    });

    test('a bus error aborts the frame and sets the error flags', () async {
      await d.setUp(kind);
      await d.timing();
      await d.wr(_irqEnable, 1);
      final pixels = [0x00A5C369, 0x00FF0001];
      await d.putWords(_mem + 0xFF8, pixels);
      // Words 0 and 1 are in memory, the burst for word 2 is not.
      await d.runFrame(_mem + 0xFF8, 4);
      final st = await d.rd(_reg(0, _status));
      expect(st & 1, equals(0), reason: 'not busy');
      expect(st & 4, equals(4), reason: 'DMA_ERR');
      expect(st >> 16, equals(0), reason: 'no completed frame');
      expect(d.status >> 24 & 1, equals(1));
      expect(await d.rd(_irqStatus) & 1, equals(1));
      expect(d.soc.output('led_irq').value.toInt(), equals(1));
      expect(d.wave.samples.contains(-1), isFalse);
      expect(d.wave.samples.last, equals(0));
      expect(d.wave.samples.length, greaterThan(20));
      for (var i = 0; i < 40; i++) {
        await d.clk.nextPosedge;
      }
      expect(d.soc.output('led_pin').value.toInt(), equals(0));

      // The next frame clears the error and runs.
      await d.wr(_irqStatus, 1);
      final good = [0x00010203, 0x00040506, 0x00070809];
      await d.putWords(_mem + 0x300, good);
      d.wave.samples.clear();
      await d.runFrame(_mem + 0x300, 3);
      expect(await d.rd(_reg(0, _status)) & 0x1F, equals(0));
      expect(d.status >> 24, equals(0));
      expect(_fastBytes(d.wave.samples), equals(_grb(good)));

      // A base outside memory fails on the first read.
      d.wave.samples.clear();
      await d.runFrame(0x90000000, 3);
      expect(await d.rd(_reg(0, _status)) & 5, equals(4));
      expect(d.wave.samples.every((s) => s == 0), isTrue);
      await Simulator.endSimulation();
    });

    test('PIXEL_COUNT 0 makes no read', () async {
      await d.setUp(kind);
      await d.timing();
      await d.runFrame(0x90000000, 0);
      final st = await d.rd(_reg(0, _status));
      expect(st & 0x1F, equals(0), reason: 'a read would be a bus error');
      expect(st >> 16, equals(1));
      expect(await d.rd(_irqStatus) & 1, equals(1));
      expect(d.wave.samples.every((s) => s == 0), isTrue);
      await Simulator.endSimulation();
    });

    test('the fetch runs while another master reads memory', () async {
      await d.setUp(kind);
      final pixels = [for (var i = 0; i < 6; i++) 0x00102030 + 0x010101 * i];
      await d.putWords(_mem + 0x1C, pixels);
      await d.timing();
      // The other master has priority and reads in bursts of 12 clocks.
      var hogging = true;
      unawaited(() async {
        while (hogging) {
          d.hogEn.inject(1);
          for (var i = 0; i < 12; i++) {
            await d.clk.nextPosedge;
          }
          d.hogEn.inject(0);
          for (var i = 0; i < 4; i++) {
            await d.clk.nextPosedge;
          }
        }
      }());
      await d.runFrame(_mem + 0x1C, 6);
      hogging = false;
      expect(_fastBytes(d.wave.samples), equals(_grb(pixels)));
      expect(await d.rd(_reg(0, _status)) & 0x1E, equals(0));
      await Simulator.endSimulation();
    });
  });
}

/// The starvation tests, which need the Wishbone fabric and take minutes.
void registerLedDmaStarveTests() {
  const kind = HarborFabricKind.wishbone;
  group('HarborLedEngine dma starvation (wishbone)', () {
    final d = _Dut();
    tearDown(() async {
      await Simulator.reset();
    });

    test('a fetch kept off the bus sets STALL and not UNDERRUN', () async {
      await d.setUp(kind, cap: null, stallClocks: 256);
      await d.putWords(_mem + 0x100, [0x00112233, 0x00445566, 0x00778899]);
      await d.timing();
      await d.wr(_reg(0, _baseLo), _mem + 0x100);
      await d.wr(_reg(0, _pixelCount), 3);
      await d.wr(_reg(0, _ctrl), _send);
      var st = 0;
      for (var i = 0; i < 150; i++) {
        st = await d.rd(_reg(0, _status));
      }
      expect(st & 1, equals(1), reason: 'BUSY, the fetch has no bus');
      expect(st & 0x10, equals(0x10), reason: 'STALL');
      expect(st & 2, equals(0), reason: 'no UNDERRUN');
      expect(d.status >> 32 & 1, equals(1));
      expect(d.status >> 16 & 1, equals(0));
      await d.wr(_reg(0, _ctrl), _send);
      expect(await d.rd(_reg(0, _status)) & 0x10, equals(0), reason: 'SEND');
      await Simulator.endSimulation();
    });

    test(
      'a fetch starved in the middle stretches a low and UNDERRUNs',
      () async {
        await d.setUp(kind, cap: null);
        final pixels = [for (var i = 0; i < 8; i++) 0x00102030 + 0x030507 * i];
        await d.putWords(_mem + 0x100, pixels);
        await d.timing();
        await d.wr(_reg(0, _baseLo), _mem + 0x100);
        await d.wr(_reg(0, _pixelCount), 8);
        await d.wr(_reg(0, _ctrl), _send);
        while (d.soc.output('led_pin').value.toInt() == 0) {
          await d.clk.nextPosedge;
        }
        for (var i = 0; i < 40; i++) {
          await d.clk.nextPosedge;
        }
        for (var i = 0; i < 300; i++) {
          await d.rd(_reg(0, _status));
        }
        for (var i = 0; i < 600; i++) {
          await d.clk.nextPosedge;
        }
        await d.waitIdle();
        await d.clk.nextPosedge;
        final st = await d.rd(_reg(0, _status));
        expect(st & 2, equals(2), reason: 'UNDERRUN');
        expect(st & 0x10, equals(0), reason: 'the first item was taken');
        expect(_lowsExact(d.wave.samples), isFalse);
        await Simulator.endSimulation();
      },
    );
  });
}

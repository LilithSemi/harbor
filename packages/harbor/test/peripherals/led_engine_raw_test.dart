import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/led_wave.dart';
import '../util/reg_bus.dart';

const _div = 0x008;
const _irqStatus = 0x010;
const _irqEnable = 0x018;
int _reg(int ch, int off) => 0x100 + ch * 0x80 + off;
const _ctrl = 0x00;
const _status = 0x08;
const _t0h = 0x10;
const _pixelCount = 0x38;
const _baseLo = 0x40;
const _baseHi = 0x48;
const _refresh = 0x50;
const _loop = 0x58;
const _itemStart = 0x60;
const _state = 0x68;
int _item(int i) => 0x400 + 4 * i;
int _pixel(int p) => 0x800 + 4 * p;
int _it(int level, int dur) => (level << 15) | dur;

void main() {
  group('HarborLedEngine construction', () {
    test('more than 6 channels is rejected', () {
      expect(
        () => HarborLedEngine(
          baseAddress: 0x1000,
          channels: List.filled(7, const HarborLedChannelConfig.serial()),
        ),
        throwsArgumentError,
      );
    });

    test('itemDepth above 256 is rejected', () {
      expect(
        () => HarborLedEngine(baseAddress: 0x1000, itemDepth: 512),
        throwsArgumentError,
      );
    });

    test('itemDepth that is not a power of 2 is rejected', () {
      expect(
        () => HarborLedEngine(baseAddress: 0x1000, itemDepth: 48),
        throwsArgumentError,
      );
    });

    test('itemDepth 1 is rejected', () {
      expect(
        () => HarborLedEngine(baseAddress: 0x1000, itemDepth: 1),
        throwsArgumentError,
      );
    });

    test('maxPixels 0 is rejected', () {
      expect(
        () => HarborLedEngine(baseAddress: 0x1000, maxPixels: 0),
        throwsArgumentError,
      );
    });

    test('an empty channel list is rejected', () {
      expect(
        () => HarborLedEngine(baseAddress: 0x1000, channels: const []),
        throwsArgumentError,
      );
    });

    test('options that are not built throw UnsupportedError', () {
      expect(
        () => HarborLedEngine(
          baseAddress: 0x1000,
          channels: const [
            HarborLedChannelConfig.pwm([HarborLedPin(0, HarborLedByte.b)]),
          ],
        ),
        throwsUnsupportedError,
      );
      expect(
        () => HarborLedEngine(
          baseAddress: 0x1000,
          pixelSource: HarborLedPixelSource.dma,
        ),
        throwsUnsupportedError,
      );
    });

    test('maxPixels above 512 is rejected', () {
      expect(
        () => HarborLedEngine(baseAddress: 0x1000, maxPixels: 513),
        throwsArgumentError,
      );
    });

    test('DT node', () {
      final led = HarborLedEngine(baseAddress: 0x10005000);
      final dt = led.dtNode;
      expect(dt.compatible, equals(['harbor,led-engine']));
      expect(dt.properties['channels'], equals(1));
      expect(dt.properties['harbor,kinds'], equals(['serial']));
      expect(dt.properties['harbor,pixel-count'], equals(16));
      expect(dt.properties['harbor,pixel-source'], equals('ram'));
      expect(dt.properties.containsKey('clock-frequency'), isFalse);
    });

    test('clockHz becomes clock-frequency in the DT and ACPI nodes', () {
      final led = HarborLedEngine(baseAddress: 0x10005000, clockHz: 25000000);
      expect(led.dtNode.properties['clock-frequency'], equals(25000000));
      expect(led.acpiDevice.properties['clock-frequency'], equals(25000000));
    });

    test('ACPI and SVD descriptors', () {
      final led = HarborLedEngine(
        baseAddress: 0x10005000,
        pixelSource: HarborLedPixelSource.none,
      );
      final acpi = led.acpiDevice;
      expect(acpi.hid, equals('PRP0001'));
      expect(acpi.memory.single.start, equals(0x10005000));
      expect(acpi.properties['compatible'], equals(['harbor,led-engine']));
      expect(acpi.properties['harbor,pixel-source'], equals('none'));
      expect(acpi.properties['harbor,pixel-count'], equals(0));
      final svd = led.svdPeripheral;
      expect(svd.name, equals('LED'));
      expect(svd.baseAddress, equals(0x10005000));
      expect(svd.size, equals(0x1000));
    });

    test('ports', () {
      final led = HarborLedEngine(
        baseAddress: 0x1000,
        channels: const [
          HarborLedChannelConfig.serial(),
          HarborLedChannelConfig.serial(),
        ],
      );
      expect(led.interrupt.width, equals(1));
      expect(led.frameTick.width, equals(2));
      expect(led.status.width, equals(32));
      expect(led.channelOut(1), hasLength(1));
      expect(led.dma, isNull);
    });
  });

  group('led_wave', () {
    List<int> frame(List<int> bits, {int gap = 5000}) {
      // 100 MHz: 10 ns per sample.
      final s = <int>[0, 0];
      for (final one in bits) {
        s.addAll(List.filled(one == 1 ? 80 : 40, 1));
        s.addAll(List.filled(one == 1 ? 45 : 85, 0));
      }
      s.addAll(List.filled(gap, 0));
      return s;
    }

    test('decodes a WS2812 byte from samples', () {
      final d = decodeWs2812(frame([1, 0, 1, 0, 0, 0, 0, 0]), 100000000);
      expect(d.single.bytes, equals([0xA0]));
      expect(d.single.resetNs, greaterThan(50000));
    });

    test('splits frames on a low over 9 us', () {
      final bits = [for (var i = 0; i < 8; i++) i == 0 ? 1 : 0];
      final d = decodeWs2812([
        ...frame(bits, gap: 1000),
        ...frame([1, 1, 1, 1, 1, 1, 1, 1], gap: 1000),
      ], 100000000);
      expect(
        d.map((f) => f.bytes),
        equals([
          [0x80],
          [0xFF],
        ]),
      );
    });

    test('throws on a partial byte', () {
      expect(() => decodeWs2812(frame([1, 0, 1]), 100000000), throwsStateError);
    });

    test('throws on an X sample', () {
      final s = frame([1, 0, 1, 0, 0, 0, 0, 0]);
      s[10] = -1;
      expect(() => decodeWs2812(s, 100000000), throwsStateError);
    });
  });

  for (final kind in HarborFabricKind.values) {
    registerTests(kind);
  }
}

void registerTests(HarborFabricKind kind) {
  group('HarborLedEngine (${kind.name})', () {
    late HarborLedEngine led;
    late Logic clk, reset;
    late RegBus bus;
    late LedWave wave;

    Future<void> setUpDut({
      List<HarborLedChannelConfig> channels = const [
        HarborLedChannelConfig.serial(),
      ],
      HarborLedPixelSource pixelSource = HarborLedPixelSource.ram,
      int itemDepth = 64,
    }) async {
      led = HarborLedEngine(
        baseAddress: 0x10005000,
        channels: channels,
        pixelSource: pixelSource,
        itemDepth: itemDepth,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      led.input('clk').srcConnection! <= clk;
      led.input('reset').srcConnection! <= reset;
      bus = RegBus.attach(led, clk);
      await led.build();
      wave = LedWave(clk, led.channelOut(0).first);

      reset.inject(1);
      bus.idle();
      Simulator.setMaxSimTime(2000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    tearDown(() async {
      await Simulator.reset();
    });

    Future<void> waitClk(int n) async {
      for (var i = 0; i < n; i++) {
        await clk.nextPosedge;
      }
    }

    Future<void> waitIdle() async {
      for (var i = 0; i < 400; i++) {
        if ((await bus.read(_reg(0, _status)) & 1) == 0) return;
        await waitClk(2);
      }
      fail('the train did not end');
    }

    Future<void> writeItems(List<int> items, {int at = 0}) async {
      for (var i = 0; i < items.length; i++) {
        await bus.write(_item(at + i), items[i]);
      }
    }

    test('reset values', () async {
      await setUpDut();
      // 1 channel, ram source, 64 items (log2 6), 16 pixels.
      expect(
        await bus.read(0x000),
        equals(1 | (1 << 4) | (6 << 8) | (16 << 16)),
      );
      expect(await bus.read(_div), equals(0));
      expect(await bus.read(_irqStatus), equals(0));
      expect(await bus.read(_irqEnable), equals(0));
      expect(await bus.read(_reg(0, _ctrl)), equals(0));
      expect(await bus.read(_reg(0, _status)), equals(0));
      await waitClk(4);
      expect(wave.samples.last, equals(0));
      expect(led.interrupt.value.toInt(), equals(0));
      await Simulator.endSimulation();
    });

    test('idle pin is IDLE xor POLARITY', () async {
      await setUpDut();
      await bus.write(_reg(0, _ctrl), 0x8);
      await waitClk(4);
      expect(wave.samples.last, equals(1));
      await bus.write(_reg(0, _ctrl), 0xC);
      await waitClk(4);
      expect(wave.samples.last, equals(0));
      await Simulator.endSimulation();
    });

    test('activeLow resets POLARITY and idles high', () async {
      led = HarborLedEngine(
        baseAddress: 0x10005000,
        channels: const [HarborLedChannelConfig.serial(activeLow: true)],
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      led.input('clk').srcConnection! <= clk;
      led.input('reset').srcConnection! <= reset;
      bus = RegBus.attach(led, clk);
      await led.build();
      reset.inject(1);
      bus.idle();
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
      expect(await bus.read(_reg(0, _ctrl)) & 4, equals(4));
      expect(led.channelOut(0).first.value.toInt(), equals(1));
      await Simulator.endSimulation();
    });

    test('a raw train gives the pulses of the items', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 3), _it(0, 2), _it(1, 1), 0]);
      await bus.write(_reg(0, _itemStart), 0);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(10);
      final high = wave.pulses(1);
      expect(high.map((r) => r.length), equals([6, 2]));
      expect(high[1].start - (high[0].start + high[0].length), equals(4));
      expect(wave.samples.last, equals(0));
      expect(await bus.read(_reg(0, _status)) & 2, equals(0));
      await Simulator.endSimulation();
    });

    test('ITEM_START selects the first item of the train', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 9), 0, _it(1, 2), 0], at: 0);
      await bus.write(_reg(0, _itemStart), 2);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(10);
      expect(wave.pulses(1).map((r) => r.length), equals([4]));
      await Simulator.endSimulation();
    });

    test('LOOP=2 repeats the train 3 times', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 2), _it(0, 1), 0]);
      await bus.write(_reg(0, _loop), 2);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(10);
      final high = wave.pulses(1);
      expect(high.map((r) => r.length), equals([4, 4, 4]));
      expect(high[1].start - high[0].start, equals(6));
      expect(high[2].start - high[1].start, equals(6));
      expect(await bus.read(_reg(0, _status)) >> 16, equals(1));
      await Simulator.endSimulation();
    });

    test('IRQ status, enable and write-1-to-clear', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 2), 0]);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      expect(await bus.read(_irqStatus), equals(0x101));
      await clk.nextNegedge;
      expect(led.interrupt.value.toInt(), equals(0));
      await bus.write(_irqEnable, 1);
      await waitClk(2);
      await clk.nextNegedge;
      expect(led.interrupt.value.toInt(), equals(1));
      await bus.write(_irqStatus, 0x101);
      expect(await bus.read(_irqStatus), equals(0));
      await clk.nextNegedge;
      expect(led.interrupt.value.toInt(), equals(0));
      await Simulator.endSimulation();
    });

    test('BUSY is high during the train', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 20), _it(0, 20), 0]);
      await bus.write(_reg(0, _ctrl), 1);
      expect((await bus.read(_reg(0, _status))) & 1, equals(1));
      await clk.nextNegedge;
      expect(led.status.value.toInt() & 1, equals(1));
      await waitIdle();
      expect(await bus.read(_reg(0, _status)) & 1, equals(0));
      await Simulator.endSimulation();
    });

    test('POLARITY inverts every level', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 3), _it(0, 2), _it(1, 1), 0]);
      await bus.write(_reg(0, _ctrl), 4);
      await waitClk(4);
      expect(wave.samples.last, equals(1));
      await bus.write(_reg(0, _ctrl), 5);
      await waitIdle();
      await waitClk(10);
      final low = wave.pulses(0);
      expect(low.map((r) => r.length), equals([6, 2]));
      expect(low[1].start - (low[0].start + low[0].length), equals(4));
      expect(wave.samples.last, equals(1));
      await Simulator.endSimulation();
    });

    test('a SEND while BUSY starts one more train when BUSY drops', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 20), _it(0, 5), 0]);
      await bus.write(_reg(0, _ctrl), 1);
      await waitClk(10);
      await bus.write(_reg(0, _ctrl), 1);
      await waitClk(10);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(200);
      final high = wave.pulses(1);
      expect(high.map((r) => r.length), equals([40, 40]));
      expect(await bus.read(_reg(0, _status)) >> 16, equals(2));
      await Simulator.endSimulation();
    });

    if (kind == HarborFabricKind.wishbone) {
      for (final n in [2, 3, 6]) {
        test('$n channels at the minimum: staggered starts keep the lowest '
            'priority channel exact', () async {
          await setUpDut(
            channels: List.filled(n, const HarborLedChannelConfig.serial()),
          );
          final last = LedWave(clk, led.channelOut(n - 1).first);
          final d = n + 1;
          await writeItems([
            for (var i = 0; i < 12; i++) _it((i + 1) & 1, d),
            0,
          ]);
          Future<void> idleAll() async {
            while (led.status.value.toInt() & ((1 << n) - 1) != 0) {
              await clk.nextPosedge;
            }
          }

          var runs = 0;
          for (final order in [0, 1]) {
            for (var delay = 0; delay < 2 * d + 2; delay++) {
              await idleAll();
              last.samples.clear();
              await bus.write(_reg(n - 1, _loop), 1);
              await bus.write(_reg(n - 1, _ctrl), 1);
              await waitClk(delay);
              if (order == 0) {
                for (var c = 0; c < n - 1; c++) {
                  await bus.write(_reg(c, _ctrl), 1);
                }
                await bus.read(_item(1));
                await bus.read(_item(2));
              } else {
                await bus.read(_item(1));
                for (var c = 0; c < n - 1; c++) {
                  await bus.write(_reg(c, _ctrl), 1);
                  await bus.read(_item(2));
                }
              }
              await idleAll();
              await waitClk(4);
              final msg = 'order $order delay $delay';
              expect(led.status.value.toInt() >> 16, equals(0), reason: msg);
              expect(
                last.pulses(1).map((r) => r.length),
                everyElement(d),
                reason: msg,
              );
              expect(last.pulses(1), hasLength(12), reason: msg);
              runs++;
            }
          }
          expect(runs, equals(2 * (2 * d + 2)));
          await Simulator.endSimulation();
        });
      }
    }

    test('the reserved RX space reads 0 and ignores writes', () async {
      await setUpDut();
      for (final a in [0x020, 0x038, 0x080, 0x0F8]) {
        await bus.write(a, 0xFFFFFFFF);
        expect(await bus.read(a), equals(0));
      }
      expect(await bus.read(_div), equals(0));
      expect(await bus.read(_irqEnable), equals(0));
      await Simulator.endSimulation();
    });

    test('later register slots and windows read back', () async {
      await setUpDut();
      final regs = {
        _reg(0, _t0h): 0x1234,
        _reg(0, _t0h + 8): 0x2345,
        _reg(0, _t0h + 16): 0x3456,
        _reg(0, _t0h + 24): 0x4567,
        _reg(0, 0x30): 0xABCDE,
        _reg(0, _pixelCount): 3,
        _reg(0, _refresh): 0x01020304,
        _reg(0, _loop): 7,
        _reg(0, _itemStart): 5,
        _div: 0xBEEF,
      };
      for (final e in regs.entries) {
        await bus.write(e.key, e.value);
      }
      for (final e in regs.entries) {
        expect(await bus.read(e.key), equals(e.value), reason: '${e.key}');
      }
      await bus.write(_reg(0, _baseLo), 0xDEADBEEF);
      await bus.write(_reg(0, _baseHi), 0x12);
      expect(await bus.read(_reg(0, _baseLo)), equals(0));
      expect(await bus.read(_reg(0, _baseHi)), equals(0));
      await bus.write(_reg(0, _ctrl), 0x51E);
      expect(await bus.read(_reg(0, _ctrl)), equals(0x51E));
      await bus.write(_item(3), 0x8123);
      await bus.write(_pixel(2), 0x80112233);
      await bus.write(_pixel(15), 0x00445566);
      expect(await bus.read(_item(3)), equals(0x8123));
      expect(await bus.read(_pixel(2)), equals(0x80112233));
      expect(await bus.read(_pixel(15)), equals(0x00445566));
      expect(await bus.read(_pixel(16)), equals(0));
      await Simulator.endSimulation();
    });

    test('two channels run their own trains', () async {
      await setUpDut(
        channels: const [
          HarborLedChannelConfig.serial(),
          HarborLedChannelConfig.serial(),
        ],
      );
      final wave1 = LedWave(clk, led.channelOut(1).first);
      await bus.write(_div, 1);
      await writeItems([_it(1, 4), _it(0, 2), 0], at: 0);
      await writeItems([_it(1, 6), _it(0, 3), 0], at: 8);
      await bus.write(_reg(1, _itemStart), 8);
      await bus.write(_reg(0, _ctrl), 1);
      await bus.write(_reg(1, _ctrl), 1);
      await waitClk(120);
      expect(wave.pulses(1).map((r) => r.length), equals([8]));
      expect(wave1.pulses(1).map((r) => r.length), equals([12]));
      expect(await bus.read(_irqStatus), equals(0x303));
      await Simulator.endSimulation();
    });

    test('DIV=0 gives exact pulses', () async {
      await setUpDut();
      await writeItems([_it(1, 3), _it(0, 2), _it(1, 1), 0]);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(10);
      final high = wave.pulses(1);
      expect(high.map((r) => r.length), equals([3, 1]));
      expect(high[1].start - (high[0].start + high[0].length), equals(2));
      await Simulator.endSimulation();
    });

    test('DIV=3 gives exact pulses', () async {
      await setUpDut();
      await bus.write(_div, 3);
      await writeItems([_it(1, 3), _it(0, 2), _it(1, 1), 0]);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(10);
      final high = wave.pulses(1);
      expect(high.map((r) => r.length), equals([12, 4]));
      expect(high[1].start - (high[0].start + high[0].length), equals(8));
      await Simulator.endSimulation();
    });

    test('LOOP at DIV=0 with a 1-tick last item has no gap', () async {
      await setUpDut();
      await writeItems([_it(1, 2), _it(0, 1), 0]);
      await bus.write(_reg(0, _loop), 2);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(10);
      final high = wave.pulses(1);
      expect(high.map((r) => r.length), equals([2, 2, 2]));
      expect(high[1].start - high[0].start, equals(3));
      expect(high[2].start - high[1].start, equals(3));
      expect(await bus.read(_reg(0, _status)) & 2, equals(0));
      await Simulator.endSimulation();
    });

    test('bus item reads during a train keep the pulses exact', () async {
      await setUpDut();
      await bus.write(_div, 1);
      final items = [
        for (var i = 0; i < 4; i++) ...[_it(1, 2), _it(0, 2)],
        0,
      ];
      await writeItems(items);
      await bus.write(_reg(0, _ctrl), 1);
      var reads = 0;
      while (led.status.value.toInt() & 1 == 1 || reads == 0) {
        final i = reads % 9;
        expect(await bus.read(_item(i)), equals(items[i]));
        reads++;
      }
      await waitClk(10);
      expect(reads, greaterThan(5));
      expect(wave.pulses(1).map((r) => r.length), equals([4, 4, 4, 4]));
      expect(await bus.read(_reg(0, _status)) & 2, equals(0));
      await Simulator.endSimulation();
    });

    test(
      'a bus item read gets through a channel that reads every clock',
      () async {
        await setUpDut();
        final items = [_it(1, 1), _it(0, 1), _it(1, 1), _it(0, 1), 0];
        await writeItems(items);
        await bus.write(_reg(0, _ctrl), 1);
        expect(await bus.read(_item(2)), equals(items[2]));
        await waitIdle();
        await Simulator.endSimulation();
      },
    );

    test(
      'many bus item reads in a long duration 2 train keep it exact',
      () async {
        await setUpDut();
        final items = [
          for (var i = 0; i < 30; i++) ...[_it(1, 2), _it(0, 2)],
          0,
        ];
        await writeItems(items);
        await bus.write(_reg(0, _ctrl), 1);
        var reads = 0;
        while (led.status.value.toInt() & 1 == 1 || reads == 0) {
          final i = (reads * 7) % items.length;
          expect(await bus.read(_item(i)), equals(items[i]));
          reads++;
        }
        await waitClk(10);
        expect(reads, greaterThan(20));
        final high = wave.pulses(1);
        expect(high.map((r) => r.length), everyElement(2));
        expect(high, hasLength(30));
        for (var i = 1; i < high.length; i++) {
          expect(high[i].start - high[i - 1].start, equals(4));
        }
        expect(await bus.read(_reg(0, _status)) & 2, equals(0));
        expect(led.status.value.toInt() >> 16, equals(0));
        await Simulator.endSimulation();
      },
    );

    test('6 channels at the minimum with bus item reads stay exact', () async {
      await setUpDut(
        channels: List.filled(6, const HarborLedChannelConfig.serial()),
      );
      final waves = [
        wave,
        for (var c = 1; c < 6; c++) LedWave(clk, led.channelOut(c).first),
      ];
      // 7 clocks per item is the minimum for 6 channels.
      final items = [
        for (var i = 0; i < 4; i++) ...[_it(1, 7), _it(0, 7)],
        0,
      ];
      await writeItems(items);
      for (var c = 0; c < 6; c++) {
        await bus.write(_reg(c, _loop), 1);
      }
      for (var c = 0; c < 6; c++) {
        await bus.write(_reg(c, _ctrl), 1);
      }
      var reads = 0;
      while (led.status.value.toInt() & 0x3F != 0 || reads == 0) {
        final i = reads % items.length;
        expect(await bus.read(_item(i)), equals(items[i]));
        reads++;
      }
      await waitClk(20);
      expect(reads, greaterThan(10));
      for (final w in waves) {
        final high = w.pulses(1);
        expect(high.map((r) => r.length), everyElement(7));
        expect(high, hasLength(8));
        expect(high[4].start - high[3].start, equals(14));
      }
      expect(led.status.value.toInt() >> 16, equals(0));
      await Simulator.endSimulation();
    });

    test('two channels with the same train give exact pulses', () async {
      await setUpDut(
        channels: const [
          HarborLedChannelConfig.serial(),
          HarborLedChannelConfig.serial(),
        ],
      );
      final wave1 = LedWave(clk, led.channelOut(1).first);
      await bus.write(_div, 1);
      await writeItems([
        for (var i = 0; i < 3; i++) ...[_it(1, 2), _it(0, 2)],
        0,
      ]);
      await bus.write(_reg(0, _ctrl), 1);
      await bus.write(_reg(1, _ctrl), 1);
      await waitClk(100);
      for (final w in [wave, wave1]) {
        final high = w.pulses(1);
        expect(high.map((r) => r.length), equals([4, 4, 4]));
        expect(high[1].start - high[0].start, equals(8));
      }
      expect(led.status.value.toInt() >> 16, equals(0));
      await Simulator.endSimulation();
    });

    test('UNDERRUN shows when a running channel loses its reads', () async {
      await setUpDut(
        channels: const [
          HarborLedChannelConfig.serial(),
          HarborLedChannelConfig.serial(),
        ],
      );
      final wave1 = LedWave(clk, led.channelOut(1).first);
      await writeItems([_it(1, 2), _it(0, 2), 0]);
      await writeItems([_it(1, 1), _it(0, 1), 0], at: 16);
      await bus.write(_reg(0, _loop), 8);
      await bus.write(_reg(1, _loop), 8);
      await bus.write(_reg(1, _itemStart), 16);
      await bus.write(_reg(0, _ctrl), 1);
      await bus.write(_reg(1, _ctrl), 1);
      await waitClk(100);
      expect(wave.pulses(1).map((r) => r.length), everyElement(2));
      expect(wave.pulses(1), hasLength(9));
      expect(wave1.pulses(1), isNotEmpty);
      expect(await bus.read(_reg(0, _status)) & 2, equals(0));
      expect(await bus.read(_reg(1, _status)) & 2, equals(2));
      expect(led.status.value.toInt() >> 16, equals(2));
      // A new SEND clears it.
      await bus.write(_reg(1, _ctrl), 1);
      await waitClk(2);
      expect(await bus.read(_reg(1, _status)) & 2, equals(0));
      await Simulator.endSimulation();
    });

    test('SEND does not start a second train by itself', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 2), 0]);
      await bus.write(_reg(0, _ctrl), 1);
      expect(await bus.read(_reg(0, _ctrl)), equals(0));
      await waitIdle();
      await waitClk(100);
      expect(wave.pulses(1), hasLength(1));
      expect(await bus.read(_reg(0, _status)) >> 16, equals(1));
      await Simulator.endSimulation();
    });

    test('SEND with MODE=1 in the same write starts a pixel frame', () async {
      await setUpDut();
      await writeItems([_it(1, 2), 0]);
      await bus.write(_reg(0, 0x30), 5);
      await bus.write(_reg(0, _ctrl), 3);
      await waitIdle();
      expect(await bus.read(_reg(0, _status)) >> 16, equals(1));
      expect(await bus.read(_reg(0, _ctrl)), equals(2));
      expect(wave.samples.every((v) => v == 0), isTrue);
      await Simulator.endSimulation();
    });

    test('SEND with MODE=1 and no pixel source starts nothing', () async {
      await setUpDut(pixelSource: HarborLedPixelSource.none);
      await writeItems([_it(1, 2), 0]);
      await bus.write(_reg(0, _ctrl), 3);
      await waitClk(20);
      expect(await bus.read(_reg(0, _status)), equals(0));
      expect(wave.samples.every((v) => v == 0), isTrue);
      await Simulator.endSimulation();
    });

    test('SEND with MODE=0 in the same write starts from MODE=1', () async {
      await setUpDut();
      await writeItems([_it(1, 2), 0]);
      await bus.write(_reg(0, _ctrl), 2);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(10);
      expect(wave.pulses(1).map((r) => r.length), equals([2]));
      expect(await bus.read(_reg(0, _ctrl)), equals(0));
      await Simulator.endSimulation();
    });

    test('byte lane stores touch only the bytes selected', () async {
      await setUpDut();
      await bus.write(_item(5), 0x1234);
      await bus.write(_item(5), 0xAB00, sel: 0x2);
      await bus.write(_item(5), 0x00AB, sel: 0x1);
      expect(await bus.read(_item(5)), equals(0x1234));
      await bus.write(_div, 0x1111);
      await bus.write(_div, 0x0300, sel: 0x2);
      expect(await bus.read(_div), equals(0x0311));
      await bus.write(_div, 0xFF0000, sel: 0x4);
      expect(await bus.read(_div), equals(0x0311));
      await bus.write(_irqEnable, 0x0100, sel: 0x2);
      expect(await bus.read(_irqEnable), equals(0x100));
      await bus.write(_irqEnable, 0x1, sel: 0x0);
      expect(await bus.read(_irqEnable), equals(0x100));
      await bus.write(_reg(0, _refresh), 0x11223344);
      await bus.write(_reg(0, _refresh), 0xAA000000, sel: 0x8);
      expect(await bus.read(_reg(0, _refresh)), equals(0xAA223344));
      await bus.write(_reg(0, _t0h), 0x1234);
      await bus.write(_reg(0, _t0h), 0xFF0000, sel: 0x4);
      expect(await bus.read(_reg(0, _t0h)), equals(0x1234));
      await Simulator.endSimulation();
    });

    test('BYTE_ORDER 6 and 7 read back as 0', () async {
      await setUpDut();
      await bus.write(_reg(0, _ctrl), 0x500);
      expect(await bus.read(_reg(0, _ctrl)), equals(0x500));
      await bus.write(_reg(0, _ctrl), 0x600);
      expect(await bus.read(_reg(0, _ctrl)), equals(0));
      await bus.write(_reg(0, _ctrl), 0x700);
      expect(await bus.read(_reg(0, _ctrl)), equals(0));
      await Simulator.endSimulation();
    });

    test('writing 0 to IRQ_STATUS keeps the bit', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 2), 0]);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await bus.write(_irqStatus, 0);
      expect(await bus.read(_irqStatus), equals(0x101));
      await bus.write(_irqStatus, 0x2);
      expect(await bus.read(_irqStatus), equals(0x101));
      await bus.write(_irqStatus, 0x100, sel: 0x2);
      expect(await bus.read(_irqStatus), equals(1));
      await bus.write(_irqStatus, 0x1, sel: 0x2);
      expect(await bus.read(_irqStatus), equals(1));
      await Simulator.endSimulation();
    });

    test('a set in the same cycle as a clear keeps the bit', () async {
      await setUpDut();
      await writeItems([_it(1, 2), 0]);
      for (var delay = 0; delay < 6; delay++) {
        await bus.write(_irqStatus, 1);
        await bus.write(_reg(0, _ctrl), 1);
        await waitClk(delay);
        while (led.status.value.toInt() & 1 == 1) {
          await bus.write(_irqStatus, 1);
        }
        await waitClk(8);
        expect(
          await bus.read(_irqStatus) & 1,
          equals(1),
          reason: 'delay $delay',
        );
      }
      await Simulator.endSimulation();
    });

    test('an empty train ends at once', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await bus.write(_reg(0, _loop), 3);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(10);
      expect(wave.samples.every((v) => v == 0), isTrue);
      expect(await bus.read(_irqStatus) & 1, equals(1));
      expect(await bus.read(_reg(0, _status)) >> 16, equals(1));
      await Simulator.endSimulation();
    });

    test('a train with no end item stops at the end of the RAM', () async {
      await setUpDut(itemDepth: 4);
      await bus.write(_div, 1);
      await writeItems([_it(1, 1), _it(0, 1), _it(1, 1), _it(0, 1)]);
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      await waitClk(10);
      expect(wave.pulses(1).map((r) => r.length), equals([2, 2]));
      expect(await bus.read(_reg(0, _status)) >> 16, equals(1));
      await Simulator.endSimulation();
    });

    test('STATE is the index of the item on the pin', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 20), _it(0, 20), _it(1, 20), 0]);
      await bus.write(_reg(0, _itemStart), 0);
      await bus.write(_reg(0, _ctrl), 1);
      await waitClk(12);
      expect(await bus.read(_reg(0, _state)), equals(0));
      await waitClk(40);
      expect(await bus.read(_reg(0, _state)), equals(1));
      await waitClk(40);
      expect(await bus.read(_reg(0, _state)), equals(2));
      await waitIdle();
      await Simulator.endSimulation();
    });

    test('ITEM_START is copied at SEND', () async {
      await setUpDut();
      await bus.write(_div, 1);
      await writeItems([_it(1, 6), 0, _it(1, 3), 0]);
      await bus.write(_reg(0, _itemStart), 2);
      await bus.write(_reg(0, _ctrl), 1);
      await bus.write(_reg(0, _itemStart), 0);
      await waitIdle();
      await waitClk(10);
      expect(wave.pulses(1).map((r) => r.length), equals([6]));
      await Simulator.endSimulation();
    });
  });
}

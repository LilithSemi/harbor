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
const _t0l = 0x18;
const _t1h = 0x20;
const _t1l = 0x28;
const _resetGap = 0x30;
const _pixelCount = 0x38;
const _refresh = 0x50;
int _pixel(int p) => 0x800 + 4 * p;

// Control value: pixel mode, BPP and byte order.
int _pixelCtrl({bool send = false, bool bpp32 = false, int order = 0}) =>
    (send ? 1 : 0) | 2 | (bpp32 ? 0x10 : 0) | (order << 8);

// The bytes of a frame in the order the pixel is sent.
List<int> _expected(List<int> pixels, {bool bpp32 = false, int order = 0}) {
  const names = [
    [1, 2, 0],
    [2, 1, 0],
    [0, 2, 1],
    [2, 0, 1],
    [1, 0, 2],
    [0, 1, 2],
  ];
  return [
    for (final p in pixels) ...[
      for (final src in names[order]) (p >> (8 * src)) & 0xFF,
      if (bpp32) (p >> 24) & 0xFF,
    ],
  ];
}

// Bytes from the high pulses of a fast frame: a pulse of 2 clocks is a 1.
List<int> _fastBytes(List<int> samples) {
  final bits = [for (final r in ledPulses(samples, 1)) r.length >= 2 ? 1 : 0];
  expect(bits.length % 8, equals(0));
  return [
    for (var i = 0; i < bits.length; i += 8)
      bits.sublist(i, i + 8).fold(0, (v, b) => (v << 1) | b),
  ];
}

class _Clock {
  final int mhz;
  final int div;
  const _Clock(this.mhz, this.div);

  // Ticks for a time in ns, with a tick of (div + 1) clocks.
  int ticks(double ns) => (ns * mhz * 1e-3 / (div + 1)).round();
}

void main() {
  for (final kind in HarborFabricKind.values) {
    registerTests(kind);
  }
  registerBram();
}

void registerBram() {
  group('HarborLedEngine block RAM pixels', () {
    late HarborLedEngine led;
    late Logic clk, reset;
    late RegBus bus;
    late LedWave wave;

    setUp(() async {
      led = HarborLedEngine(
        baseAddress: 0x10005000,
        maxPixels: 8,
        ramKind: HarborLedRamKind.bram,
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
    });

    tearDown(() async {
      await Simulator.reset();
    });

    Future<void> waitIdle() async {
      for (var i = 0; i < 2000; i++) {
        if ((await bus.read(_reg(0, _status)) & 1) == 0) return;
      }
      fail('the frame did not end');
    }

    test('a frame from block RAM pixels and reads during the frame', () async {
      final pixels = [0x00A5C369, 0x00FF0001, 0x00123456, 0x00FEDCBA];
      for (var p = 0; p < pixels.length; p++) {
        await bus.write(_pixel(p), pixels[p]);
      }
      expect(await bus.read(_pixel(2)), equals(pixels[2]));
      await bus.write(_reg(0, _t0h), 1);
      await bus.write(_reg(0, _t0l), 2);
      await bus.write(_reg(0, _t1h), 2);
      await bus.write(_reg(0, _t1l), 1);
      await bus.write(_reg(0, _resetGap), 4);
      await bus.write(_reg(0, _pixelCount), 4);
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      var reads = 0;
      while (led.status.value.toInt() & 1 == 1 || reads == 0) {
        final p = reads % pixels.length;
        expect(await bus.read(_pixel(p)), equals(pixels[p]));
        reads++;
      }
      await waitIdle();
      expect(reads, greaterThan(10));
      expect(_fastBytes(wave.samples), equals(_expected(pixels)));
      expect(led.status.value.toInt() >> 16, equals(0));
      await Simulator.endSimulation();
    });

    test('an unwritten pixel reads 0 and sends 0', () async {
      expect(await bus.read(_pixel(5)), equals(0));
      await bus.write(_reg(0, _t0h), 1);
      await bus.write(_reg(0, _t0l), 2);
      await bus.write(_reg(0, _t1h), 2);
      await bus.write(_reg(0, _t1l), 1);
      await bus.write(_reg(0, _resetGap), 4);
      await bus.write(_reg(0, _pixelCount), 2);
      await bus.write(_pixel(0), 0x00FFFFFF);
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      var n = 0;
      while (led.status.value.toInt() & 1 == 1 || n == 0) {
        await clk.nextPosedge;
        n++;
      }
      await clk.nextPosedge;
      expect(wave.samples.contains(-1), isFalse);
      expect(_fastBytes(wave.samples), equals([0xFF, 0xFF, 0xFF, 0, 0, 0]));
      await Simulator.endSimulation();
    });

    test('a store of less than 4 bytes does not write a pixel', () async {
      await bus.write(_pixel(1), 0x11223344);
      await bus.write(_pixel(1), 0xFFFFFFFF, sel: 0x3);
      expect(await bus.read(_pixel(1)), equals(0x11223344));
      await Simulator.endSimulation();
    });
  });
}

void registerTests(HarborFabricKind kind) {
  group('HarborLedEngine pixels (${kind.name})', () {
    late HarborLedEngine led;
    late Logic clk, reset;
    late RegBus bus;
    late LedWave wave;

    Future<void> setUpDut({
      int periodPs = 10,
      int maxPixels = 16,
      HarborLedPixelSource pixelSource = HarborLedPixelSource.ram,
    }) async {
      led = HarborLedEngine(
        baseAddress: 0x10005000,
        maxPixels: maxPixels,
        pixelSource: pixelSource,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(periodPs).clk;
      reset = Logic(name: 'reset');
      led.input('clk').srcConnection! <= clk;
      led.input('reset').srcConnection! <= reset;
      bus = RegBus.attach(led, clk);
      await led.build();
      wave = LedWave(clk, led.channelOut(0).first);
      reset.inject(1);
      bus.idle();
      Simulator.setMaxSimTime(20000000);
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

    Future<void> waitIdle({int ch = 0}) async {
      for (var i = 0; i < 4000; i++) {
        if ((await bus.read(_reg(ch, _status)) & 1) == 0) return;
        await waitClk(8);
      }
      fail('the frame did not end');
    }

    // Fast timings: a 1 is a 2 clock pulse, a 0 is a 1 clock pulse.
    Future<void> fastTimings({int gap = 4}) async {
      await bus.write(_reg(0, _t0h), 1);
      await bus.write(_reg(0, _t0l), 2);
      await bus.write(_reg(0, _t1h), 2);
      await bus.write(_reg(0, _t1l), 1);
      await bus.write(_reg(0, _resetGap), gap);
    }

    // WS2812B datasheet timings for a clock.
    Future<void> datasheetTimings(_Clock c, {int resetUs = 60}) async {
      await bus.write(_div, c.div);
      await bus.write(_reg(0, _t0h), c.ticks(400));
      await bus.write(_reg(0, _t0l), c.ticks(850));
      await bus.write(_reg(0, _t1h), c.ticks(800));
      await bus.write(_reg(0, _t1l), c.ticks(450));
      await bus.write(_reg(0, _resetGap), c.ticks(resetUs * 1000.0));
    }

    void checkWindows(Ws2812Frame f) {
      for (var i = 0; i < f.highNs.length; i++) {
        final one = f.highNs[i] > 600;
        final high = one ? 800 : 400;
        final low = one ? 450 : 850;
        expect(f.highNs[i], closeTo(high, 150), reason: 'high of bit $i');
        if (i < f.lowNs.length - 1) {
          expect(f.lowNs[i], closeTo(low, 150), reason: 'low of bit $i');
        }
      }
      expect(f.resetNs, greaterThanOrEqualTo(50000));
    }

    final clocks = kind == HarborFabricKind.wishbone
        ? [const _Clock(25, 0), const _Clock(50, 0), const _Clock(100, 1)]
        : <_Clock>[];
    for (final c in clocks) {
      test('3 pixels at ${c.mhz} MHz meet the WS2812B windows', () async {
        await setUpDut(periodPs: 1000 ~/ c.mhz);
        await datasheetTimings(c);
        await bus.write(_pixel(0), 0x00FF0000);
        await bus.write(_pixel(1), 0x0000FF00);
        await bus.write(_pixel(2), 0x000000FF);
        await bus.write(_reg(0, _pixelCount), 3);
        await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
        await waitIdle();
        await waitClk(4);
        final frames = decodeWs2812(wave.samples, c.mhz * 1000000);
        expect(frames, hasLength(1));
        expect(
          frames.single.bytes,
          equals([0x00, 0xFF, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF]),
        );
        checkWindows(frames.single);
        expect(await bus.read(_reg(0, _status)) >> 16, equals(1));
        await Simulator.endSimulation();
      });
    }

    if (kind == HarborFabricKind.wishbone) {
      for (final bpp32 in [false, true]) {
        test('every byte order, ${bpp32 ? '32' : '24'} bit', () async {
          await setUpDut();
          await fastTimings();
          const pixel = 0x44A5C369;
          await bus.write(_pixel(0), pixel);
          await bus.write(_reg(0, _pixelCount), 1);
          final all = <int>[];
          for (var order = 0; order < 6; order++) {
            wave.samples.clear();
            await bus.write(
              _reg(0, _ctrl),
              _pixelCtrl(send: true, bpp32: bpp32, order: order),
            );
            await waitIdle();
            await waitClk(4);
            final got = _fastBytes(wave.samples);
            expect(
              got,
              equals(_expected([pixel], bpp32: bpp32, order: order)),
              reason: 'order $order',
            );
            all.addAll(got);
          }
          expect(all, hasLength(6 * (bpp32 ? 4 : 3)));
          await Simulator.endSimulation();
        });
      }
    }

    test('STATE follows the mode of the frame and not the MODE bit', () async {
      await setUpDut();
      for (final (i, item) in [0x8003, 0x0002, 0x8001, 0x0000].indexed) {
        await bus.write(0x400 + 4 * i, item);
      }
      await bus.write(_reg(0, _ctrl), 1);
      await waitIdle();
      expect(await bus.read(_reg(0, 0x68)), equals(2));
      await bus.write(_reg(0, _ctrl), 2);
      expect(await bus.read(_reg(0, 0x68)), equals(2));
      await Simulator.endSimulation();
    });

    test('REFRESH starts frames at the period and ticks the frame', () async {
      await setUpDut();
      await fastTimings();
      await bus.write(_pixel(0), 0x00A5C369);
      await bus.write(_reg(0, _pixelCount), 1);
      await bus.write(_reg(0, _ctrl), _pixelCtrl());
      await bus.write(_irqEnable, 0x100);
      final ticks = <int>[];
      var now = 0;
      clk.negedge.listen((_) {
        if (led.frameTick.value.toInt() == 1) ticks.add(now);
        now++;
      });
      await bus.write(_reg(0, _refresh), 200);
      expect(led.interrupt.value.toInt(), equals(0));
      await waitClk(900);
      expect(ticks.length, inInclusiveRange(4, 5));
      for (var i = 1; i < ticks.length; i++) {
        expect(ticks[i] - ticks[i - 1], inInclusiveRange(199, 201));
      }
      expect(await bus.read(_irqStatus) & 0x100, equals(0x100));
      expect(led.interrupt.value.toInt(), equals(1));
      expect(
        await bus.read(_reg(0, _status)) >> 16,
        inInclusiveRange(ticks.length - 1, ticks.length),
      );
      // The frame tick pulse lasts one clock.
      expect(
        ticks.toSet().length,
        equals(ticks.length),
        reason: 'one sample per pulse',
      );
      // REFRESH 0 stops it.
      await bus.write(_reg(0, _refresh), 0);
      await waitIdle();
      await bus.write(_irqStatus, 0x100);
      expect(await bus.read(_irqStatus) & 0x100, equals(0));
      final stopped = ticks.length;
      await waitClk(600);
      expect(ticks.length, equals(stopped));
      await Simulator.endSimulation();
    });

    test(
      'a REFRESH shorter than the frame sends frames back to back',
      () async {
        await setUpDut();
        await fastTimings();
        await bus.write(_pixel(0), 0x00A5C369);
        await bus.write(_reg(0, _pixelCount), 1);
        await bus.write(_reg(0, _ctrl), _pixelCtrl());
        await bus.write(_reg(0, _refresh), 20);
        await waitClk(400);
        await bus.write(_reg(0, _refresh), 0);
        await waitIdle();
        await waitClk(4);
        final bytes = _fastBytes(wave.samples);
        expect(bytes.length, greaterThanOrEqualTo(9));
        expect(bytes.length % 3, equals(0));
        for (var i = 0; i < bytes.length; i += 3) {
          expect(bytes.sublist(i, i + 3), equals(_expected([0x00A5C369])));
        }
        await Simulator.endSimulation();
      },
    );

    if (kind == HarborFabricKind.wishbone) {
      for (final div in [0, 2]) {
        test('every high and low run of a frame is exact at DIV=$div', () async {
          await setUpDut();
          final pin = <int>[];
          final busy = <int>[];
          clk.negedge.listen((_) {
            pin.add(led.channelOut(0).first.value.toInt());
            busy.add(led.status.value.toInt() & 1);
          });
          const t = [3, 5, 4, 2];
          const gap = 11;
          await bus.write(_div, div);
          await bus.write(_reg(0, _t0h), t[0]);
          await bus.write(_reg(0, _t0l), t[1]);
          await bus.write(_reg(0, _t1h), t[2]);
          await bus.write(_reg(0, _t1l), t[3]);
          await bus.write(_reg(0, _resetGap), gap);
          await bus.write(_pixel(0), 0x00A5C369);
          await bus.write(_reg(0, _pixelCount), 1);
          pin.clear();
          busy.clear();
          await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
          await waitIdle();
          await waitClk(4);
          final bits = [
            for (final byte in _expected([0x00A5C369]))
              for (var k = 7; k >= 0; k--) (byte >> k) & 1,
          ];
          final k = div + 1;
          // Runs from the first high sample.
          var i = pin.indexOf(1);
          final highs = <int>[];
          final lows = <int>[];
          var lastHighEnd = 0;
          for (var b = 0; b < bits.length; b++) {
            var j = i;
            while (pin[j] == 1) {
              j++;
            }
            highs.add(j - i);
            lastHighEnd = j;
            i = j;
            if (b < bits.length - 1) {
              while (pin[j] == 0) {
                j++;
              }
              lows.add(j - i);
              i = j;
            }
          }
          expect(highs, equals([for (final x in bits) t[x == 1 ? 2 : 0] * k]));
          expect(
            lows,
            equals([
              for (var b = 0; b < bits.length - 1; b++)
                t[bits[b] == 1 ? 3 : 1] * k,
            ]),
          );
          // The last low ends when BUSY drops, one clock before the pin would.
          final fall =
              busy.indexOf(1) + busy.sublist(busy.indexOf(1)).indexOf(0);
          final finalLow = fall - lastHighEnd;
          expect(finalLow, equals((t[bits.last == 1 ? 3 : 1] + gap) * k - 1));
          await Simulator.endSimulation();
        });
      }
    }

    test('STATE shows the pixel index when MODE is 1', () async {
      await setUpDut();
      await fastTimings();
      for (var p = 0; p < 3; p++) {
        await bus.write(_pixel(p), 0x00010203);
      }
      await bus.write(_reg(0, _pixelCount), 3);
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      final seen = <int>{};
      while (led.status.value.toInt() & 1 == 1 || seen.isEmpty) {
        seen.add(await bus.read(_reg(0, 0x68)));
      }
      expect(seen, containsAll([0, 1, 2]));
      expect(seen.every((v) => v <= 2), isTrue);
      await Simulator.endSimulation();
    });

    test('a write to any byte lane of REFRESH restarts the count', () async {
      await setUpDut();
      await fastTimings();
      await bus.write(_pixel(0), 0x00A5C369);
      await bus.write(_reg(0, _pixelCount), 1);
      await bus.write(_reg(0, _ctrl), _pixelCtrl());
      await bus.write(_reg(0, _refresh), 300);
      await waitClk(200);
      await bus.write(_reg(0, _refresh) + 3, 0, sel: 0x8);
      await waitClk(150);
      expect(await bus.read(_reg(0, _status)) >> 16, equals(0));
      expect(ledPulses(wave.samples, 1), isEmpty);
      await waitClk(250);
      expect(ledPulses(wave.samples, 1), isNotEmpty);
      await Simulator.endSimulation();
    });

    test('PIXEL_COUNT 0 sends only the reset gap', () async {
      await setUpDut();
      await fastTimings(gap: 30);
      await bus.write(_reg(0, _pixelCount), 0);
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      var busy = 0;
      for (var i = 0; i < 60; i++) {
        busy += led.status.value.toInt() & 1;
        await clk.nextPosedge;
      }
      expect(busy, inInclusiveRange(28, 34));
      expect(ledPulses(wave.samples, 1), isEmpty);
      expect(wave.samples.every((v) => v == 0), isTrue);
      expect(await bus.read(_reg(0, _status)) >> 16, equals(1));
      await Simulator.endSimulation();
    });

    test('a fast 3 pixel frame', () async {
      await setUpDut();
      await fastTimings();
      final pixels = [0x00FF0000, 0x0000FF00, 0x000000FF];
      for (var p = 0; p < 3; p++) {
        await bus.write(_pixel(p), pixels[p]);
      }
      await bus.write(_reg(0, _pixelCount), 3);
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      await waitIdle();
      await waitClk(4);
      expect(_fastBytes(wave.samples), equals(_expected(pixels)));
      await Simulator.endSimulation();
    });

    if (kind == HarborFabricKind.wishbone) {
      test('a reset gap longer than 15 bits is sent whole', () async {
        await setUpDut();
        await fastTimings(gap: 32770);
        await bus.write(_reg(0, _pixelCount), 0);
        await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
        var busy = 0;
        while (true) {
          busy += led.status.value.toInt() & 1;
          await clk.nextPosedge;
          if (busy > 0 && led.status.value.toInt() & 1 == 0) break;
          if (busy > 40000) fail('the gap did not end');
        }
        expect(busy, inInclusiveRange(32765, 32775));
        await Simulator.endSimulation();
      });
    }

    test('a pixel written during a frame shows in the next frame', () async {
      await setUpDut();
      await fastTimings();
      final first = [0x00112233, 0x00445566, 0x00778899, 0x00AABBCC];
      for (var p = 0; p < 4; p++) {
        await bus.write(_pixel(p), first[p]);
      }
      await bus.write(_reg(0, _pixelCount), 4);
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      // Pixel 0 is out after about 75 clocks. The frame lasts about 300.
      await waitClk(110);
      expect(led.status.value.toInt() & 1, equals(1));
      await bus.write(_pixel(0), 0x00DDEEFF);
      await waitIdle();
      await waitClk(4);
      expect(_fastBytes(wave.samples), equals(_expected(first)));
      wave.samples.clear();
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      await waitIdle();
      await waitClk(4);
      expect(
        _fastBytes(wave.samples),
        equals(_expected([0x00DDEEFF, ...first.sublist(1)])),
      );
      await Simulator.endSimulation();
    });

    test('bus pixel reads and writes during a frame keep it exact', () async {
      await setUpDut();
      await fastTimings();
      final pixels = [0x00112233, 0x00445566, 0x00778899, 0x00AABBCC];
      for (var p = 0; p < 4; p++) {
        await bus.write(_pixel(p), pixels[p]);
      }
      await bus.write(_reg(0, _pixelCount), 4);
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      var n = 0;
      while (led.status.value.toInt() & 1 == 1 || n == 0) {
        // Rewrite the pixel with its own value, then read a pixel.
        final p = n % 4;
        await bus.write(_pixel(p + 8), pixels[p]);
        expect(await bus.read(_pixel(p)), equals(pixels[p]));
        n++;
      }
      await waitClk(4);
      expect(n, greaterThan(8));
      expect(_fastBytes(wave.samples), equals(_expected(pixels)));
      expect(led.status.value.toInt() >> 16, equals(0));
      await Simulator.endSimulation();
    });

    test('PIXEL_COUNT above maxPixels is clamped to maxPixels', () async {
      await setUpDut(maxPixels: 5);
      await fastTimings();
      final pixels = [
        0x00010203,
        0x00040506,
        0x00070809,
        0x000A0B0C,
        0x000D0E0F,
      ];
      for (var p = 0; p < 5; p++) {
        await bus.write(_pixel(p), pixels[p]);
      }
      // 3 bits wide: 7 is more than 5.
      await bus.write(_reg(0, _pixelCount), 7);
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      await waitIdle();
      await waitClk(4);
      expect(wave.samples.contains(-1), isFalse);
      expect(_fastBytes(wave.samples), equals(_expected(pixels)));
      await Simulator.endSimulation();
    });

    if (kind == HarborFabricKind.wishbone) {
      test('maxPixels 512 reaches the last pixel', () async {
        await setUpDut(maxPixels: 512);
        await bus.write(_pixel(511), 0x00ABCDEF);
        await bus.write(_pixel(0), 0x00123456);
        expect(await bus.read(_pixel(511)), equals(0x00ABCDEF));
        expect(await bus.read(_pixel(0)), equals(0x00123456));
        expect(await bus.read(0x000) >> 16 & 0xFFF, equals(512));
        await Simulator.endSimulation();
      });
    }

    test('PIXEL_COUNT is copied at SEND', () async {
      await setUpDut();
      await fastTimings();
      for (var p = 0; p < 3; p++) {
        await bus.write(_pixel(p), 0x00010101 * (p + 1));
      }
      await bus.write(_reg(0, _pixelCount), 2);
      await bus.write(_reg(0, _ctrl), _pixelCtrl(send: true));
      await waitClk(20);
      await bus.write(_reg(0, _pixelCount), 3);
      await waitIdle();
      await waitClk(4);
      expect(_fastBytes(wave.samples), hasLength(6));
      await Simulator.endSimulation();
    });
  });
}

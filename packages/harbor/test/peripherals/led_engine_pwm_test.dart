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
const _refresh = 0x50;
int _pixel(int p) => 0x800 + 4 * p;

const _pins = [
  HarborLedPin(0, HarborLedByte.b),
  HarborLedPin(1, HarborLedByte.b),
  HarborLedPin(2, HarborLedByte.r),
  HarborLedPin(2, HarborLedByte.g),
  HarborLedPin(2, HarborLedByte.b),
];

// The duty of every pin in [_pins] for the pixels written by [_writePixels].
const _duties = [0x80, 0xFF, 0x20, 0x00, 0x01];

void main() {
  for (final kind in HarborFabricKind.values) {
    registerTests(kind);
  }
  registerOther();
}

class _Dut {
  late HarborLedEngine led;
  late Logic clk, reset;
  late RegBus bus;
  late List<LedWave> waves;

  Future<void> setUp({
    required List<HarborLedChannelConfig> channels,
    HarborFabricKind kind = HarborFabricKind.wishbone,
    HarborLedRamKind ramKind = HarborLedRamKind.lut,
    int maxPixels = 8,
  }) async {
    led = HarborLedEngine(
      baseAddress: 0x10005000,
      channels: channels,
      maxPixels: maxPixels,
      ramKind: ramKind,
      fabricKind: kind,
    );
    clk = SimpleClockGenerator(10).clk;
    reset = Logic(name: 'reset');
    led.input('clk').srcConnection! <= clk;
    led.input('reset').srcConnection! <= reset;
    bus = RegBus.attach(led, clk);
    await led.build();
    waves = [
      for (var c = 0; c < channels.length; c++)
        for (final pin in led.channelOut(c)) LedWave(clk, pin),
    ];
    reset.inject(1);
    bus.idle();
    Simulator.setMaxSimTime(40000000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
  }

  Future<void> waitClk(int n) async {
    for (var i = 0; i < n; i++) {
      await clk.nextPosedge;
    }
  }

  Future<void> waitIdle({int ch = 0, int polls = 400}) async {
    for (var i = 0; i < polls; i++) {
      if ((await bus.read(_reg(ch, _status)) & 1) == 0) return;
    }
    fail('the frame did not end');
  }

  Future<void> writePixels() async {
    await bus.write(_pixel(0), 0x00000080);
    await bus.write(_pixel(1), 0xAA0000FF);
    await bus.write(_pixel(2), 0x00200001);
  }

  // The high clocks of every pin over [periods] whole PWM periods.
  Future<List<int>> highs({int div = 0, int periods = 1}) async {
    final n = 256 * (div + 1) * periods;
    for (final w in waves) {
      w.samples.clear();
    }
    await waitClk(n);
    return [
      for (final w in waves)
        w.samples.sublist(0, n).where((s) => s == 1).length,
    ];
  }
}

void registerTests(HarborFabricKind kind) {
  group('HarborLedEngine pwm (${kind.name})', () {
    final d = _Dut();

    tearDown(() async {
      await Simulator.reset();
    });

    test('the high time of every pin is the duty times the tick', () async {
      await d.setUp(
        channels: [const HarborLedChannelConfig.pwm(_pins)],
        kind: kind,
      );
      await d.bus.write(_div, 1);
      await d.writePixels();
      await d.bus.write(_reg(0, _ctrl), 1);
      await d.waitIdle();
      expect(await d.highs(div: 1), equals([for (final x in _duties) x * 2]));
      expect(await d.highs(div: 1, periods: 2), [
        for (final x in _duties) x * 4,
      ]);
      expect(d.led.status.value.toInt() >> 16, equals(0));
      await Simulator.endSimulation();
    });
  });
}

void registerOther() {
  group('HarborLedEngine pwm', () {
    final d = _Dut();

    tearDown(() async {
      await Simulator.reset();
    });

    test(
      'duty 0 stays low and duty 255 is high for 255 of 256 ticks',
      () async {
        await d.setUp(channels: [const HarborLedChannelConfig.pwm(_pins)]);
        await d.writePixels();
        await d.bus.write(_reg(0, _ctrl), 1);
        await d.waitIdle();
        final h = await d.highs();
        expect(h[3], equals(0));
        expect(h[1], equals(255));
        await Simulator.endSimulation();
      },
    );

    test('every duty from 0 to 255 is exact', () async {
      await d.setUp(
        channels: [
          const HarborLedChannelConfig.pwm([HarborLedPin(0, HarborLedByte.w)]),
        ],
      );
      for (var duty = 0; duty < 256; duty += 51) {
        await d.bus.write(_pixel(0), duty << 24);
        await d.bus.write(_reg(0, _ctrl), 1);
        await d.waitIdle();
        await d.waitClk(4);
        expect((await d.highs()).single, equals(duty), reason: 'duty $duty');
      }
      await Simulator.endSimulation();
    });

    test('active low inverts the output and POLARITY resets to 1', () async {
      await d.setUp(
        channels: [const HarborLedChannelConfig.pwm(_pins, activeLow: true)],
      );
      expect(await d.bus.read(_reg(0, _ctrl)) & 4, equals(4));
      await d.waitClk(4);
      for (final w in d.waves) {
        expect(w.samples.last, equals(1));
      }
      await d.writePixels();
      await d.bus.write(_reg(0, _ctrl), 1 | 4);
      await d.waitIdle();
      expect(await d.highs(), equals([for (final x in _duties) 256 - x]));
      await d.bus.write(_reg(0, _ctrl), 1);
      await d.waitIdle();
      expect(await d.highs(), equals(_duties));
      await Simulator.endSimulation();
    });

    test('new duties latch only at a frame', () async {
      await d.setUp(channels: [const HarborLedChannelConfig.pwm(_pins)]);
      await d.writePixels();
      await d.bus.write(_reg(0, _ctrl), 1);
      await d.waitIdle();
      await d.bus.write(_pixel(0), 0x00000010);
      await d.bus.write(_pixel(2), 0x00010203);
      expect(await d.highs(), equals(_duties));
      await d.bus.write(_reg(0, _ctrl), 1);
      await d.waitIdle();
      await d.waitClk(4);
      expect(await d.highs(), equals([0x10, 0xFF, 1, 2, 3]));
      await Simulator.endSimulation();
    });

    test('REFRESH latches the duties by itself', () async {
      await d.setUp(channels: [const HarborLedChannelConfig.pwm(_pins)]);
      await d.writePixels();
      await d.bus.write(_irqEnable, 0x100);
      await d.bus.write(_reg(0, _refresh), 300);
      await d.waitClk(360);
      expect(await d.highs(), equals(_duties));
      expect(d.led.interrupt.value.toInt(), equals(1));
      await d.bus.write(_irqStatus, 0x101);
      expect(d.led.interrupt.value.toInt(), equals(0));
      await d.bus.write(_pixel(1), 0x00000040);
      await d.waitClk(300);
      await d.waitClk(4);
      expect((await d.highs())[1], equals(0x40));
      expect(await d.bus.read(_reg(0, _status)) >> 16, greaterThanOrEqualTo(2));
      await Simulator.endSimulation();
    });

    test('a frame loads one pin per clock and reports done', () async {
      await d.setUp(channels: [const HarborLedChannelConfig.pwm(_pins)]);
      await d.writePixels();
      await d.bus.write(_irqEnable, 0x1);
      var busyClocks = 0;
      var ticks = 0;
      d.clk.negedge.listen((_) {
        if (d.led.status.value.toInt() & 1 == 1) busyClocks++;
        ticks += d.led.frameTick.value.toInt();
      });
      await d.bus.write(_reg(0, _ctrl), 1);
      await d.waitClk(20);
      expect(busyClocks, inInclusiveRange(_pins.length, _pins.length + 3));
      expect(ticks, equals(1));
      expect(d.led.interrupt.value.toInt(), equals(1));
      expect(await d.bus.read(_irqStatus) & 1, equals(1));
      expect(await d.bus.read(_reg(0, _status)), equals((1 << 16) | 8));
      await Simulator.endSimulation();
    });

    test('MODE reads 1 and raw mode is not available', () async {
      await d.setUp(channels: [const HarborLedChannelConfig.pwm(_pins)]);
      expect(await d.bus.read(_reg(0, _ctrl)) & 2, equals(2));
      await d.bus.write(_reg(0, _ctrl), 0);
      expect(await d.bus.read(_reg(0, _ctrl)) & 2, equals(2));
      await d.writePixels();
      await d.bus.write(_reg(0, _ctrl), 1);
      await d.waitIdle();
      expect(await d.highs(), equals(_duties));
      await Simulator.endSimulation();
    });

    test('block RAM pixels give the same duties', () async {
      await d.setUp(
        channels: [const HarborLedChannelConfig.pwm(_pins)],
        ramKind: HarborLedRamKind.bram,
      );
      await d.writePixels();
      await d.bus.write(_reg(0, _ctrl), 1);
      await d.waitIdle();
      await d.waitClk(4);
      expect(await d.highs(), equals(_duties));
      await Simulator.endSimulation();
    });

    test('a serial channel and a pwm channel run together', () async {
      await d.setUp(
        channels: [
          const HarborLedChannelConfig.serial(),
          const HarborLedChannelConfig.pwm(_pins),
        ],
      );
      expect(d.led.channelOut(0), hasLength(1));
      expect(d.led.channelOut(1), hasLength(5));
      expect(d.led.channelOut(1)[4].name, equals('led_ch1_4'));
      await d.writePixels();
      for (final k in [0, 1]) {
        await d.bus.write(_reg(0, 0x10 + 8 * k), 1 + k);
        await d.bus.write(_reg(0, 0x20 + 8 * k), 2 - k);
      }
      await d.bus.write(_reg(0, 0x30), 4);
      await d.bus.write(_reg(0, 0x38), 3);
      await d.bus.write(_reg(0, _ctrl), 2 | 1);
      await d.bus.write(_reg(1, _ctrl), 1);
      await d.waitIdle(ch: 0);
      await d.waitIdle(ch: 1);
      await d.waitClk(4);
      final bits = [
        for (final r in ledPulses(d.waves[0].samples, 1)) r.length >= 2 ? 1 : 0,
      ];
      expect(bits, hasLength(72));
      expect([
        for (var i = 0; i < 72; i += 8)
          bits.sublist(i, i + 8).fold(0, (v, b) => v << 1 | b),
      ], equals([0, 0, 0x80, 0, 0, 0xFF, 0, 0x20, 1]));
      expect((await d.highs()).sublist(1), equals(_duties));
      await Simulator.endSimulation();
    });

    test('STATUS KIND is 1 for a pwm channel and 0 for a serial one', () async {
      await d.setUp(
        channels: [
          const HarborLedChannelConfig.serial(),
          const HarborLedChannelConfig.pwm(_pins),
        ],
      );
      expect(await d.bus.read(_reg(0, _status)) & 8, equals(0));
      expect(await d.bus.read(_reg(1, _status)) & 8, equals(8));
      await Simulator.endSimulation();
    });

    test('without a serial channel the item window is empty', () async {
      await d.setUp(channels: [const HarborLedChannelConfig.pwm(_pins)]);
      expect((await d.bus.read(0x000) >> 8) & 0xFF, equals(0));
      await d.bus.write(0x400, 0x8005);
      expect(await d.bus.read(0x400), equals(0));
      await d.writePixels();
      await d.bus.write(_reg(0, _ctrl), 1);
      await d.waitIdle();
      expect(await d.highs(), equals(_duties));
      await Simulator.endSimulation();
      await Simulator.reset();
      await d.setUp(
        channels: [
          const HarborLedChannelConfig.serial(),
          const HarborLedChannelConfig.pwm(_pins),
        ],
      );
      expect((await d.bus.read(0x000) >> 8) & 0xFF, equals(6));
      await d.bus.write(0x400, 0x8005);
      expect(await d.bus.read(0x400), equals(0x8005));
      await Simulator.endSimulation();
    });

    test('pwm loads do not make a serial channel underrun', () async {
      final wide = [
        for (var i = 0; i < 16; i++) HarborLedPin(i, HarborLedByte.b),
      ];
      await d.setUp(
        channels: [
          HarborLedChannelConfig.pwm(wide),
          HarborLedChannelConfig.pwm(wide),
          const HarborLedChannelConfig.serial(),
        ],
        maxPixels: 16,
      );
      final pixels = [for (var i = 0; i < 16; i++) 0x00010203 * (i + 1)];
      for (var i = 0; i < 16; i++) {
        await d.bus.write(_pixel(i), pixels[i]);
      }
      await d.bus.write(_reg(0, _refresh), 40);
      await d.bus.write(_reg(1, _refresh), 41);
      await d.bus.write(_reg(2, 0x10), 1);
      await d.bus.write(_reg(2, 0x18), 2);
      await d.bus.write(_reg(2, 0x20), 2);
      await d.bus.write(_reg(2, 0x28), 1);
      await d.bus.write(_reg(2, 0x30), 4);
      await d.bus.write(_reg(2, 0x38), 16);
      final serial = d.waves.last;
      serial.samples.clear();
      await d.bus.write(_reg(2, _ctrl), 3);
      await d.waitIdle(ch: 2, polls: 3000);
      await d.waitClk(4);
      expect(
        await d.bus.read(_reg(2, _status)) & 2,
        equals(0),
        reason: 'UNDERRUN',
      );
      expect(d.led.status.value.toInt() >> 16, equals(0));
      final bits = [
        for (final r in ledPulses(serial.samples, 1)) r.length >= 2 ? 1 : 0,
      ];
      expect(bits, hasLength(16 * 24));
      expect(
        [
          for (var i = 0; i < bits.length; i += 8)
            bits.sublist(i, i + 8).fold(0, (v, b) => v << 1 | b),
        ],
        equals([
          for (final p in pixels) ...[
            (p >> 8) & 0xFF,
            (p >> 16) & 0xFF,
            p & 0xFF,
          ],
        ]),
      );
      expect(await d.bus.read(_reg(0, _status)) >> 16, greaterThan(8));
      await Simulator.endSimulation();
    });

    test('the DT node lists the pwm kind', () async {
      final led = HarborLedEngine(
        baseAddress: 0x10005000,
        channels: const [
          HarborLedChannelConfig.pwm(_pins),
          HarborLedChannelConfig.serial(),
        ],
      );
      expect(led.dtNode.properties['harbor,kinds'], equals(['pwm', 'serial']));
    });

    test('the constructor checks the pin map', () {
      expect(
        () => HarborLedEngine(
          baseAddress: 0,
          channels: const [HarborLedChannelConfig.pwm(_pins)],
          pixelSource: HarborLedPixelSource.none,
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborLedEngine(
          baseAddress: 0,
          channels: const [HarborLedChannelConfig.pwm([])],
        ),
        throwsArgumentError,
      );
      expect(
        () => HarborLedEngine(
          baseAddress: 0,
          maxPixels: 2,
          channels: const [HarborLedChannelConfig.pwm(_pins)],
        ),
        throwsArgumentError,
      );
    });
  });
}

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/led_wave.dart';
import '../util/reg_bus.dart';

const _ctrl = 0x00;
const _status = 0x08;
const _t0h = 0x10;
const _t0l = 0x18;
const _t1h = 0x20;
const _t1l = 0x28;
const _resetGap = 0x30;
const _pixelCount = 0x38;
int _reg(int ch, int off) => 0x100 + ch * 0x80 + off;
int _item(int i) => 0x400 + 4 * i;
int _pixel(int p) => 0x800 + 4 * p;

void main() {
  for (final kind in HarborFabricKind.values) {
    group('HarborLedEngine 64-bit bus (${kind.name})', () {
      late HarborLedEngine led;
      late Logic clk, reset;
      late RegBus bus;
      late LedWave wave;

      setUp(() async {
        led = HarborLedEngine(
          baseAddress: 0x10005000,
          fabricKind: kind,
          busDataWidth: 64,
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
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;
      });

      tearDown(() async {
        await Simulator.reset();
      });

      // A 32-bit access at byte address [addr] on the 64-bit bus: the data
      // and the byte lanes sit in the half that address bit 2 picks.
      Future<void> w32(int addr, int data) async {
        final half = (addr >> 2) & 1;
        await bus.accessWide(
          addr & ~7,
          data: BigInt.from(data) << (32 * half),
          sel: 0xF << (4 * half),
          write: true,
        );
      }

      Future<int> r32(int addr) async {
        final half = (addr >> 2) & 1;
        final r = await bus.accessWide(
          addr,
          sel: 0xF << (4 * half),
          write: false,
        );
        return ((r.data >> (32 * half)) & BigInt.from(0xFFFFFFFF)).toInt();
      }

      Future<void> waitClk(int n) async {
        for (var i = 0; i < n; i++) {
          await clk.nextPosedge;
        }
      }

      test('CTRL and STATUS read and write', () async {
        expect(bus.dataWidth, 64);
        expect(await r32(0x000), equals(1 | (1 << 4) | (6 << 8) | (16 << 16)));
        await w32(_reg(0, _ctrl), 0x8);
        expect(await r32(_reg(0, _ctrl)), equals(0x8));
        await w32(_reg(0, _ctrl), 0xC);
        expect(await r32(_reg(0, _ctrl)), equals(0xC));
        expect(await r32(_reg(0, _status)), equals(0));
        // A full 8-byte read returns the register in the low 32 bits.
        final full = await bus.accessWide(_reg(0, _ctrl), write: false);
        expect(full.data, equals(BigInt.from(0xC)));
        await Simulator.endSimulation();
      });

      test('an item at an odd index lives in the upper half', () async {
        await w32(_item(0), 0x1111);
        await w32(_item(1), 0x2222);
        await w32(_item(2), 0x3333);
        await w32(_item(3), 0x4444);
        expect(await r32(_item(0)), equals(0x1111));
        expect(await r32(_item(1)), equals(0x2222));
        expect(await r32(_item(2)), equals(0x3333));
        expect(await r32(_item(3)), equals(0x4444));
        await Simulator.endSimulation();
      });

      test('items written over the bus make a train', () async {
        await w32(0x008, 1);
        const it = [(1 << 15) | 3, 2, (1 << 15) | 1, 0];
        for (var i = 0; i < it.length; i++) {
          await w32(_item(i), it[i]);
        }
        await w32(_reg(0, 0x60), 0);
        await w32(_reg(0, _ctrl), 1);
        for (var i = 0; i < 400; i++) {
          if ((await r32(_reg(0, _status)) & 1) == 0) break;
          await waitClk(2);
        }
        await waitClk(10);
        final high = wave.pulses(1);
        expect(high.map((r) => r.length), equals([6, 2]));
        await Simulator.endSimulation();
      });

      test('a pixel at an odd index lives in the upper half', () async {
        await w32(_pixel(0), 0x00112233);
        await w32(_pixel(1), 0x00445566);
        await w32(_pixel(2), 0x00778899);
        await w32(_pixel(3), 0x00AABBCC);
        expect(await r32(_pixel(0)), equals(0x00112233));
        expect(await r32(_pixel(1)), equals(0x00445566));
        expect(await r32(_pixel(2)), equals(0x00778899));
        expect(await r32(_pixel(3)), equals(0x00AABBCC));
        // A store of two bytes merges into the pixel of its half.
        await bus.accessWide(
          _pixel(3) & ~7,
          data: BigInt.from(0xFFFFFFFF) << 32,
          sel: 0x30,
          write: true,
        );
        expect(await r32(_pixel(3)), equals(0x00AAFFFF));
        expect(await r32(_pixel(2)), equals(0x00778899));
        await Simulator.endSimulation();
      });

      test('a frame decodes from pixels written over the bus', () async {
        await w32(_reg(0, _t0h), 1);
        await w32(_reg(0, _t0l), 2);
        await w32(_reg(0, _t1h), 2);
        await w32(_reg(0, _t1l), 1);
        await w32(_reg(0, _resetGap), 4);
        final pixels = [0x00FF0000, 0x0000FF00, 0x000000FF];
        for (var p = 0; p < 3; p++) {
          await w32(_pixel(p), pixels[p]);
        }
        await w32(_reg(0, _pixelCount), 3);
        await w32(_reg(0, _ctrl), 3);
        for (var i = 0; i < 4000; i++) {
          if ((await r32(_reg(0, _status)) & 1) == 0) break;
          await waitClk(8);
        }
        await waitClk(4);
        final bits = [
          for (final r in ledPulses(wave.samples, 1)) r.length >= 2 ? 1 : 0,
        ];
        final bytes = [
          for (var i = 0; i < bits.length; i += 8)
            bits.sublist(i, i + 8).fold(0, (v, b) => (v << 1) | b),
        ];
        // Order 0 sends G, B, R of each pixel.
        expect(bytes, equals([0, 0xFF, 0, 0xFF, 0, 0, 0, 0, 0xFF]));
        await Simulator.endSimulation();
      });
    });
  }
}

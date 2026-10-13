import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// Register byte offsets: each register in its own 8-byte slot.
const _ctrl = 0x00;
const _fbBase = 0x10;
const _fbStride = 0x18;
const _hActive = 0x20;
const _hTiming = 0x28;
const _vActive = 0x30;
const _vTiming = 0x38;

void main() {
  group('HarborDisplayTiming', () {
    test('VGA 640x480 timing', () {
      const t = HarborDisplayTiming.vga640x480();
      expect(t.hActive, equals(640));
      expect(t.vActive, equals(480));
      expect(t.pixelClock, equals(25175000));
      expect(t.refreshRate, closeTo(59.94, 0.1));
      expect(t.resolution, equals('640x480'));
    });

    test('720p timing', () {
      const t = HarborDisplayTiming.hd720();
      expect(t.hActive, equals(1280));
      expect(t.vActive, equals(720));
      expect(t.refreshRate, closeTo(60.0, 0.1));
    });

    test('1080p timing', () {
      const t = HarborDisplayTiming.fhd1080();
      expect(t.hActive, equals(1920));
      expect(t.vActive, equals(1080));
      expect(t.refreshRate, closeTo(60.0, 0.1));
    });

    test('SVGA 800x600 timing', () {
      const t = HarborDisplayTiming.svga800x600();
      expect(t.hActive, equals(800));
      expect(t.vActive, equals(600));
      expect(t.pixelClock, equals(40000000));
      expect(t.hSyncPositive, isTrue);
      expect(t.vSyncPositive, isTrue);
      expect(t.hTotal, equals(1056));
      expect(t.vTotal, equals(628));
      expect(t.refreshRate, closeTo(60.0, 0.5));
    });

    test('hTotal and vTotal', () {
      const t = HarborDisplayTiming.vga640x480();
      expect(t.hTotal, equals(640 + 16 + 96 + 48)); // 800
      expect(t.vTotal, equals(480 + 10 + 2 + 33)); // 525
    });

    test('toPrettyString', () {
      const t = HarborDisplayTiming.hd720();
      expect(t.toPrettyString(), contains('1280x720'));
      expect(t.toPrettyString(), contains('60'));
    });
  });

  group('HarborDisplayConfig', () {
    test('basic config', () {
      const config = HarborDisplayConfig(
        interface_: HarborDisplayInterface.hdmi,
        timing: HarborDisplayTiming.fhd1080(),
      );
      expect(config.pixelFormat, equals(HarborPixelFormat.xrgb8888));
      expect(config.maxWidth, equals(1920));
    });

    test('toPrettyString', () {
      const config = HarborDisplayConfig(
        interface_: HarborDisplayInterface.vga,
        timing: HarborDisplayTiming.vga640x480(),
      );
      expect(config.toPrettyString(), contains('vga'));
      expect(config.toPrettyString(), contains('640x480'));
    });
  });

  group('HarborDisplayController', () {
    test('creates with VGA config', () {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.vga,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0x70000000,
      );
      expect(display.bus, isNotNull);
      expect(display.interrupt.width, equals(1));
    });

    test('has video output signals', () {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.hdmi,
          timing: HarborDisplayTiming.hd720(),
        ),
        baseAddress: 0x70000000,
      );
      expect(display.output('hsync').width, equals(1));
      expect(display.output('vsync').width, equals(1));
      expect(display.output('de').width, equals(1));
      expect(display.output('pixel_r').width, equals(8));
      expect(display.output('pixel_g').width, equals(8));
      expect(display.output('pixel_b').width, equals(8));
    });

    test('DT node', () {
      final display = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.hdmi,
          timing: HarborDisplayTiming.fhd1080(),
          maxWidth: 3840,
          maxHeight: 2160,
        ),
        baseAddress: 0x70000000,
      );
      final dt = display.dtNode;
      expect(dt.compatible.first, equals('harbor,display'));
      expect(dt.properties['output-interface'], equals('hdmi'));
      expect(dt.properties['max-width'], equals(3840));
    });

    test('two different parameter sets get different definition names', () {
      final a = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.vga,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0x70000000,
      );
      final b = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.hdmi,
          timing: HarborDisplayTiming.hd720(),
        ),
        baseAddress: 0x70000000,
      );
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  group('HarborPixelFormat', () {
    test('bits per pixel', () {
      expect(HarborPixelFormat.rgb565.bitsPerPixel, equals(16));
      expect(HarborPixelFormat.rgb888.bitsPerPixel, equals(24));
      expect(HarborPixelFormat.xrgb8888.bitsPerPixel, equals(32));
      expect(HarborPixelFormat.argb8888.bitsPerPixel, equals(32));
    });
  });

  for (final kind in HarborFabricKind.values) {
    _registerTests(kind);
  }
}

void _registerTests(HarborFabricKind kind) {
  group('HarborDisplayController register access (${kind.name})', () {
    late HarborDisplayController disp;
    late RegBus bus;
    late Logic clk;

    Future<void> setUpDut({Logic Function(Logic fbAddr)? fbDataOf}) async {
      disp = HarborDisplayController(
        config: const HarborDisplayConfig(
          interface_: HarborDisplayInterface.parallelRgb,
          timing: HarborDisplayTiming.vga640x480(),
        ),
        baseAddress: 0x70000000,
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');

      disp.input('clk').srcConnection! <= clk;
      disp.input('reset').srcConnection! <= reset;
      disp.input('pixel_clk').srcConnection! <= clk; // single domain for sim
      disp.input('fb_data').srcConnection! <=
          (fbDataOf?.call(disp.output('fb_addr')) ?? Const(0, width: 32));
      disp.input('fb_ack').srcConnection! <= disp.output('fb_stb');
      bus = RegBus.attach(disp, clk);

      await disp.build();
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

    test('streams framebuffer pixels during active video', () async {
      // Framebuffer model: a 2x2 image at base 0, stride 8 bytes.
      const fb = {0: 0x00112233, 4: 0x00445566, 8: 0x00778899, 12: 0x00AABBCC};
      await setUpDut(
        fbDataOf: (fbAddr) {
          Logic fbData = Const(0, width: 32);
          fb.forEach((a, v) {
            fbData = mux(
              fbAddr.eq(Const(a, width: 32)),
              Const(v, width: 32),
              fbData,
            );
          });
          return fbData;
        },
      );

      final de = disp.output('de');
      final vsync = disp.output('vsync');
      final pr = disp.output('pixel_r');
      final pg = disp.output('pixel_g');
      final pb = disp.output('pixel_b');

      // Shrink to a 2x2 frame with 1-pixel porches.
      await bus.write(_hActive, 2);
      await bus.write(_hTiming, 1 | (1 << 8) | (1 << 16));
      await bus.write(_vActive, 2);
      await bus.write(_vTiming, 1 | (1 << 8) | (1 << 16));
      await bus.write(_fbBase, 0);
      await bus.write(_fbStride, 8);
      await bus.write(_ctrl, 0x1); // enable

      // Align to a frame boundary: wait through one vsync pulse so the next
      // active region starts at pixel (0,0).
      var sawVsync = false;
      for (var i = 0; i < 200; i++) {
        await clk.nextPosedge;
        final v = vsync.value.toInt();
        if (v == 1) sawVsync = true;
        if (sawVsync && v == 0) break;
      }

      // Capture the next four active pixels (top-left of the frame, raster).
      final pixels = <int>[];
      for (var i = 0; i < 200 && pixels.length < 4; i++) {
        await clk.nextPosedge;
        if (de.value.toInt() == 1) {
          pixels.add(
            (pr.value.toInt() << 16) |
                (pg.value.toInt() << 8) |
                pb.value.toInt(),
          );
        }
      }

      expect(pixels, equals([0x112233, 0x445566, 0x778899, 0xAABBCC]));
      await Simulator.endSimulation();
    });

    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      await bus.write(_fbBase, 0x11223344);
      await bus.write(_fbStride, 0x0000ffff);
      await bus.write(_fbBase, 0xffffffff, sel: 0x0);
      await bus.write(_fbStride, 0xffffffff, sel: 0x0);
      expect(await bus.read(_fbBase), equals(0x11223344));
      expect(await bus.read(_fbStride), equals(0x0000ffff));
      await Simulator.endSimulation();
    });
  });
}

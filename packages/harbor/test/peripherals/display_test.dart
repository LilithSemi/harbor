import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Per format: yuv, bitDepth, hSub, vSub, planes (bytes, pixels, vSub),
// isPacked32.
typedef _Plane = (int bytes, int pixels, int vSub);

const _expected =
    <HarborPixelFormat, (bool, int, int, int, List<_Plane>, bool)>{
      HarborPixelFormat.rgb565: (false, 8, 1, 1, [(2, 1, 1)], false),
      HarborPixelFormat.rgb888: (false, 8, 1, 1, [(3, 1, 1)], false),
      HarborPixelFormat.xrgb8888: (false, 8, 1, 1, [(4, 1, 1)], true),
      HarborPixelFormat.argb8888: (false, 8, 1, 1, [(4, 1, 1)], true),
      HarborPixelFormat.yuyv: (true, 8, 2, 1, [(4, 2, 1)], false),
      HarborPixelFormat.uyvy: (true, 8, 2, 1, [(4, 2, 1)], false),
      HarborPixelFormat.nv12: (true, 8, 2, 2, [(1, 1, 1), (2, 2, 2)], false),
      HarborPixelFormat.p010: (true, 10, 2, 2, [(2, 1, 1), (4, 2, 2)], false),
      HarborPixelFormat.i420: (
        true,
        8,
        2,
        2,
        [(1, 1, 1), (1, 2, 2), (1, 2, 2)],
        false,
      ),
    };

// Hand computed bytes per line for widths 1920, 1919, 7 and 1, per plane.
const _widths = [1920, 1919, 7, 1];
const _lineBytes = <HarborPixelFormat, List<List<int>>>{
  HarborPixelFormat.rgb565: [
    [3840, 3838, 14, 2],
  ],
  HarborPixelFormat.rgb888: [
    [5760, 5757, 21, 3],
  ],
  HarborPixelFormat.xrgb8888: [
    [7680, 7676, 28, 4],
  ],
  HarborPixelFormat.argb8888: [
    [7680, 7676, 28, 4],
  ],
  HarborPixelFormat.yuyv: [
    [3840, 3840, 16, 4],
  ],
  HarborPixelFormat.uyvy: [
    [3840, 3840, 16, 4],
  ],
  HarborPixelFormat.nv12: [
    [1920, 1919, 7, 1],
    [1920, 1920, 8, 2],
  ],
  HarborPixelFormat.p010: [
    [3840, 3838, 14, 2],
    [3840, 3840, 16, 4],
  ],
  HarborPixelFormat.i420: [
    [1920, 1919, 7, 1],
    [960, 960, 4, 1],
    [960, 960, 4, 1],
  ],
};

HarborDualClockDisplay _buildDisplay(HarborPixelFormat format) =>
    HarborDualClockDisplay(
      target: const HarborSimTarget(),
      timing: const HarborDisplayTiming.vga640x480(),
      pixelClk: Logic(name: 'pixel_clk'),
      pixelReset: Logic(name: 'pixel_reset'),
      shiftClk: Logic(name: 'shift_clk'),
      shiftReset: Logic(name: 'shift_reset'),
      sysClk: Logic(name: 'sys_clk'),
      sysReset: Logic(name: 'sys_reset'),
      enable: Logic(name: 'enable'),
      fbBase: Logic(name: 'fb_base', width: 32),
      memory: HarborMemoryWaist(
        const HarborMemoryWaistConfig(addressWidth: 32, dataWidth: 32),
      ),
      pixelFormat: format,
    );

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

    test('XGA 1024x768 timing', () {
      const t = HarborDisplayTiming.xga1024x768();
      expect(t.hActive, equals(1024));
      expect(t.vActive, equals(768));
      expect(t.pixelClock, equals(65000000));
      expect(t.hSyncPositive, isFalse);
      expect(t.vSyncPositive, isFalse);
      expect(t.hTotal, equals(1344));
      expect(t.vTotal, equals(806));
      expect(t.refreshRate, closeTo(60.0, 0.01));
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
  group('HarborPixelFormat', () {
    test('declaration order', () {
      expect(HarborPixelFormat.values, [
        HarborPixelFormat.rgb565,
        HarborPixelFormat.rgb888,
        HarborPixelFormat.xrgb8888,
        HarborPixelFormat.argb8888,
        HarborPixelFormat.yuyv,
        HarborPixelFormat.uyvy,
        HarborPixelFormat.nv12,
        HarborPixelFormat.p010,
        HarborPixelFormat.i420,
      ]);
    });

    for (final e in _expected.entries) {
      final f = e.key;
      final (yuv, depth, hSub, vSub, planes, packed32) = e.value;
      test('${f.name} descriptor', () {
        expect(f.yuv, yuv);
        expect(f.bitDepth, depth);
        expect(f.hSub, hSub);
        expect(f.vSub, vSub);
        expect(f.isPacked32, packed32);
        expect(f.planes.length, planes.length);
        for (var i = 0; i < planes.length; i++) {
          expect(f.planes[i].bytesPerGroup, planes[i].$1, reason: 'plane $i');
          expect(f.planes[i].pixelsPerGroup, planes[i].$2, reason: 'plane $i');
          expect(f.planes[i].vSub, planes[i].$3, reason: 'plane $i');
        }
      });

      test('${f.name} lineBytes', () {
        final table = _lineBytes[f]!;
        expect(table.length, f.planes.length);
        for (var p = 0; p < table.length; p++) {
          for (var w = 0; w < _widths.length; w++) {
            expect(
              f.lineBytes(p, _widths[w]),
              table[p][w],
              reason: 'plane $p width ${_widths[w]}',
            );
          }
        }
      });

      test('${f.name} planeLines', () {
        for (var p = 0; p < planes.length; p++) {
          final sub = planes[p].$3;
          expect(f.planeLines(p, 1080), sub == 1 ? 1080 : 540);
          expect(f.planeLines(p, 1079), sub == 1 ? 1079 : 540);
        }
      });
    }

    test('bit order lists every value once in declaration order', () {
      expect(harborPixelFormatBitOrder, HarborPixelFormat.values);
      expect(
        harborPixelFormatBitOrder.toSet().length,
        HarborPixelFormat.values.length,
      );
    });

    test('dual clock display rejects rgb888, and planar formats without '
        'plane inputs', () {
      for (final f in [
        HarborPixelFormat.rgb888,
        HarborPixelFormat.nv12,
        HarborPixelFormat.p010,
        HarborPixelFormat.i420,
      ]) {
        expect(() => _buildDisplay(f), throwsArgumentError, reason: f.name);
      }
    });

    test('dual clock display takes the one plane yuv formats', () {
      final yuyv = _buildDisplay(HarborPixelFormat.yuyv);
      final uyvy = _buildDisplay(HarborPixelFormat.uyvy);
      expect(yuyv.definitionName, endsWith('_yuyv'));
      expect(uyvy.definitionName, endsWith('_uyvy'));
    });
  });
}

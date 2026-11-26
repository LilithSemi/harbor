// The adv7511 output of the fabric scanout display: the YCbCr bus for a known
// framebuffer.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'display_fabric_harness.dart';

void main() {
  tearDown(() async => Simulator.reset());

  for (final format in [HarborPixelFormat.xrgb8888, HarborPixelFormat.rgb565]) {
    test('${format.name} framebuffer reaches the pins as 4:2:2', () async {
      final c = FetchCase(
        kind: HarborFabricKind.axi4,
        format: format,
        hActive: 16,
        vActive: 4,
        adv7511: true,
      );
      final r = await startFetch(c);
      await r.write(HarborScanoutDisplay.fbBaseOffset, mem + c.fbOffset);
      await r.write(HarborScanoutDisplay.ctrlOffset, 1);
      await r.waitFrames(3);

      // The runs of DE are the lines.
      final lines = <List<int>>[];
      var inRun = false;
      for (final (de, d) in r.pins) {
        if (de == 1) {
          if (!inRun) lines.add([]);
          lines.last.add(d);
        }
        inRun = de == 1;
      }
      expect(lines.length, greaterThanOrEqualTo(2 * c.vActive));
      expect(lines.every((l) => l.length == c.hActive), isTrue);

      // The display starts a frame at the first run of DE.
      final frames = lines.length ~/ c.vActive;
      final base = (frames - 1) * c.vActive;
      for (var y = 0; y < c.vActive; y++) {
        for (var x = 0; x < c.hActive; x++) {
          final rgb = c.rgb(x, y);
          final yy = HarborBt709.y(rgb[0], rgb[1], rgb[2]);
          final even = c.rgb(x & ~1, y);
          final chroma = x.isEven
              ? HarborBt709.cb(rgb[0], rgb[1], rgb[2])
              : HarborBt709.cr(even[0], even[1], even[2]);
          expect(
            lines[base + y][x],
            (chroma << 8) | yy,
            reason: 'pixel $x,$y',
          );
        }
      }
      await Simulator.endSimulation();
    });
  }
}

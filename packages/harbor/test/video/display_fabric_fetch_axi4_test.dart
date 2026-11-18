// The scanout display as a real-time fabric master on a 64 bit AXI4 fabric,
// with its own pixel clock.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'display_fabric_harness.dart';

// The display reads a framebuffer through the fabric. The write of FB_BASE is
// one word off a 64 bit beat, and the display must read the aligned base.
Future<void> _pixels(FetchCase c) async {
  final r = await startFetch(c);
  await r.write(HarborScanoutDisplay.fbBaseOffset, mem + c.fbOffset + 4);
  await r.write(HarborScanoutDisplay.ctrlOffset, 1);
  if (c.hammer) r.hammerBursts(6);
  await r.waitFrames(2);
  for (final f in r.full.skip(r.full.length - 1)) {
    r.expectFrame(f);
  }
  expect(await r.reg(HarborScanoutDisplay.fbBaseOffset), mem + c.fbOffset);
  expect(await r.reg(HarborScanoutDisplay.underrunCountOffset), 0);
  expect(await r.reg(HarborScanoutDisplay.statusOffset) & 0x14, 0);
  expect(r.errors, isEmpty);
  await Simulator.endSimulation();
}

void main() {
  tearDown(() async => Simulator.reset());

  test('axi4 64 bit: rgb565 pixels', () async {
    await _pixels(const FetchCase(kind: HarborFabricKind.axi4));
  });

  test('axi4 64 bit: xrgb8888 lines across 4 KiB inside a burst, a master with '
      'long bursts on the bus', () async {
    await _pixels(
      const FetchCase(
        kind: HarborFabricKind.axi4,
        format: HarborPixelFormat.xrgb8888,
        hActive: 32,
        burstBeats: 8,
        fbOffset: 0xFE0,
        lineClocks: 80,
        hammer: true,
      ),
    );
  });
}

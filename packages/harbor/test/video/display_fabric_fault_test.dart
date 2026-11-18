// The scanout display as a fabric master under load and on faults: a forced
// underrun with the counter and the status bits, a bus error, and a disable
// and reconfigure in the middle of a frame.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'display_fabric_harness.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('a plain master behind long bursts underruns, and the count, STATUS '
      'and INT_STATUS show it', () async {
    final r = await startFetch(
      const FetchCase(
        kind: HarborFabricKind.axi4,
        realtime: false,
        hammer: true,
        lineClocks: 40,
      ),
    );
    await r.write(HarborScanoutDisplay.intEnableOffset, 2);
    await r.write(HarborScanoutDisplay.fbBaseOffset, mem);
    await r.write(HarborScanoutDisplay.ctrlOffset, 1);
    r.hammerBursts(12);
    await r.cycles(2500);
    final count = await r.reg(HarborScanoutDisplay.underrunCountOffset);
    expect(count, greaterThan(0), reason: 'late lines are counted');
    expect(
      await r.reg(HarborScanoutDisplay.statusOffset) & 0x4,
      0x4,
      reason: 'STATUS underrun',
    );
    expect(
      await r.reg(HarborScanoutDisplay.intStatusOffset) & 0x2,
      0x2,
      reason: 'INT_STATUS underrun',
    );
    expect(r.display.output('interrupt').value.toBool(), isTrue);
    // A write of 1 clears the bit and the count stays.
    await r.write(HarborScanoutDisplay.intStatusOffset, 2);
    expect(await r.reg(HarborScanoutDisplay.intStatusOffset) & 0x2, 0);
    expect(
      await r.reg(HarborScanoutDisplay.underrunCountOffset),
      greaterThanOrEqualTo(count),
    );
    await Simulator.endSimulation();
  });

  test('a framebuffer outside the memory is a bus error', () async {
    final r = await startFetch(
      const FetchCase(kind: HarborFabricKind.axi4),
      writeFrame: false,
    );
    await r.write(HarborScanoutDisplay.fbBaseOffset, 0x40000000);
    await r.write(HarborScanoutDisplay.ctrlOffset, 1);
    await r.cycles(1500);
    expect(await r.reg(HarborScanoutDisplay.intStatusOffset) & 0x4, 0x4);
    expect(await r.reg(HarborScanoutDisplay.statusOffset) & 0x10, 0x10);
    await r.write(HarborScanoutDisplay.intStatusOffset, 4);
    expect(await r.reg(HarborScanoutDisplay.intStatusOffset) & 0x4, 0);
    await Simulator.endSimulation();
  });

  test('a disable in the middle of a frame, then a new framebuffer', () async {
    const c = FetchCase(kind: HarborFabricKind.axi4);
    final r = await startFetch(c);
    await r.writePicture(0x800, 1);
    await r.write(HarborScanoutDisplay.fbBaseOffset, mem);
    await r.write(HarborScanoutDisplay.ctrlOffset, 1);
    await r.waitFrames(2);
    r.expectFrame(r.full.last);
    // Disable a few lines into the next frame.
    await r.cycles(300);
    await r.write(HarborScanoutDisplay.ctrlOffset, 0);
    await r.cycles(1200);
    expect(await r.reg(HarborScanoutDisplay.statusOffset) & 0x1, 0);
    await r.write(HarborScanoutDisplay.fbBaseOffset, mem + 0x800);
    await r.write(HarborScanoutDisplay.ctrlOffset, 1);
    await r.waitFrames(2);
    r.expectFrame(r.full.last, 1);
    await Simulator.endSimulation();
  });
}

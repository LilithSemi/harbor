import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final getStatus = dfuSetup(
    dirIn: true,
    bRequest: dfuReqGetStatus,
    wLength: 6,
  );

  group('UsbDfuRamSink with one reset alone', () {
    test('a lone bus_reset after an image and ABORT fakes no clear and '
        'replays nothing', () async {
      final (dut, host, busClk, busReset) =
          await buildRamSinkHarnessWithBusControl(regionBytes: 512, words: 128);
      await enumerateSinkDfu(host);
      var pulses = 0;
      dut.output('image_ready').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) pulses++;
      });

      final image = List.generate(90, (i) => (i + 3) & 0xFF);
      final st = await dfuDownload(host, 1, image);
      expect(st?[4], 2);
      final abort = dfuSetup(dirIn: false, bRequest: dfuReqAbort);
      expect(await host.controlNoData(1, abort), isTrue);
      await host.idle(500);

      var watching = false;
      final writes = countSinkWrites(dut, busClk, () => watching);
      watching = true;
      await pulseReset(busClk, busReset, 5);
      for (var i = 0; i < 3000; i++) {
        await busClk.nextPosedge;
      }
      watching = false;
      expect(writes[0], 0, reason: 'no stale FIFO entry is written');
      expect(pulses, 1, reason: 'no fake image_ready');

      final status = await host.controlRead(1, getStatus);
      expect(status?[0], 0, reason: 'bStatus OK');
      expect(status?[4], 2, reason: 'bState dfuIDLE');

      await Simulator.endSimulation();
    });
  });
}

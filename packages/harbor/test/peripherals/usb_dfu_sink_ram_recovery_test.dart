import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuRamSink recovery', () {
    test('overflow, CLRSTATUS, then a good download lands byte-exact and '
        'raises image_ready', () async {
      final (dut, host) = await buildRamSinkHarness(
        regionBytes: 256,
        words: 128,
      );
      await enumerateSinkDfu(host);

      final badImage = List.generate(300, (i) => i & 0xFF);
      final badStatus = await dfuDownload(host, 1, badImage);
      expect(badStatus, isNotNull);
      expect(badStatus![0], 0x08, reason: 'bStatus errADDRESS');
      expect(badStatus[4], 10, reason: 'bState dfuERROR');

      // Give the bus domain time to drain whatever the bad image left in
      // the FIFO before clearing: `clear` resets the write pointer and
      // the sticky error, not the FIFO itself.
      await host.idle(2000);

      final clrStatus = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);
      expect(await host.controlNoData(1, clrStatus), isTrue);
      final afterClear = await host.controlRead(
        1,
        dfuSetup(dirIn: true, bRequest: dfuReqGetStatus, wLength: 6),
      );
      expect(afterClear?[0], 0x00, reason: 'bStatus OK after CLRSTATUS');
      expect(afterClear?[4], 2, reason: 'bState dfuIDLE after CLRSTATUS');

      var imageReadyPulses = 0;
      final sub = dut.output('image_ready').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) imageReadyPulses++;
      });

      final goodImage = List.generate(80, (i) => (i + 1) & 0xFF);
      final goodStatus = await dfuDownload(host, 1, goodImage);
      await sub.cancel();

      expect(goodStatus, isNotNull);
      expect(goodStatus![0], 0x00, reason: 'bStatus OK');
      expect(goodStatus[4], 2, reason: 'bState dfuIDLE after manifest');
      expect(imageReadyPulses, 1, reason: 'image_ready pulsed once');
      expect(
        dut.output('bytes_written').value.toInt(),
        equals(goodImage.length),
        reason: 'write pointer restarted at 0 for the fresh image',
      );
      for (var i = 0; i < goodImage.length; i++) {
        expect(dut.mem.byteAt(i), equals(goodImage[i]), reason: 'byte[$i]');
      }

      await Simulator.endSimulation();
    });
  });
}

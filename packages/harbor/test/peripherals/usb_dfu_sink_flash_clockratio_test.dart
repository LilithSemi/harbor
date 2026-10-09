import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuFlashSink with the bus clock faster than the USB clock', () {
    test('a download still lands byte-exact and raises image_ready', () async {
      final (dut, host) = await buildFlashSinkHarness(
        flashBase: 0,
        eraseLatency: 30,
        programLatency: 30,
        usbClkPeriod: 20,
        busClkPeriod: 7,
      );
      await enumerateSinkDfu(host, altSetting: 1);

      var imageReadyPulses = 0;
      final sub = dut.output('image_ready').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) imageReadyPulses++;
      });

      final image = List.generate(70, (i) => (i + 7) & 0xFF);
      final status = await dfuDownload(host, 1, image);
      await sub.cancel();

      expect(status, isNotNull);
      expect(status![0], 0x00, reason: 'bStatus OK');
      expect(status[4], 2, reason: 'bState dfuIDLE after manifest');
      expect(imageReadyPulses, 1, reason: 'image_ready pulsed once');
      expect(dut.output('bytes_written').value.toInt(), equals(image.length));
      for (var i = 0; i < image.length; i++) {
        expect(dut.model.read(i), equals(image[i]), reason: 'byte[$i]');
      }

      await Simulator.endSimulation();
    });
  });
}

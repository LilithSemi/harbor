import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuFlashSink block sizes', () {
    test('48-byte blocks never program across a page', () async {
      final (dut, host) = await buildFlashSinkHarness(maxSimTime: 80000000);
      await enumerateSinkDfu(host, altSetting: 1);

      final image = List.generate(300, (i) => (i * 7 + 1) & 0xFF);
      final status = await dfuDownload(host, 1, image, blockSize: 48);
      expect(status, isNotNull);
      expect(status![0], 0x00, reason: 'bStatus OK');
      expect(status[4], 2, reason: 'bState dfuIDLE after manifest');
      expect(dut.model.rejectCount, 0, reason: 'no page-crossing program');
      expect(dut.output('bytes_written').value.toInt(), image.length);
      for (var i = 0; i < image.length; i++) {
        expect(dut.model.read(i), image[i], reason: 'flash byte[$i]');
      }

      await Simulator.endSimulation();
    });
  });
}

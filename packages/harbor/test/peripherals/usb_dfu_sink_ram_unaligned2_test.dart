import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuRamSink non-word-aligned length', () {
    test('303 bytes: a three-byte partial last word', () async {
      final (dut, host) = await buildRamSinkHarness(
        regionBytes: 512,
        words: 128,
      );
      await enumerateSinkDfu(host);

      const length = 303;
      final image = List.generate(length, (i) => i & 0xFF);
      final status = await dfuDownload(host, 1, image);

      expect(status, isNotNull);
      expect(status![4], 2, reason: 'bState dfuIDLE after manifest');
      expect(dut.output('bytes_written').value.toInt(), equals(length));

      for (var i = 0; i < length; i++) {
        expect(dut.mem.byteAt(i), equals(image[i]), reason: 'RAM byte[$i]');
      }
      // The lanes of the final word past the image, and every word after
      // it, were never selected: they keep the memory model's reset value.
      for (var i = length; i < length + 8; i++) {
        expect(dut.mem.byteAt(i), equals(0), reason: 'untouched byte[$i]');
      }

      await Simulator.endSimulation();
    });
  });
}

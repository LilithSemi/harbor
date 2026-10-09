import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuRamSink on the sink interface', () {
    test('a full 300-byte download lands byte-exact in RAM and raises done '
        'and image_ready', () async {
      final (dut, host) = await buildRamSinkHarness(
        regionBytes: 512,
        words: 128,
      );
      await enumerateSinkDfu(host);

      var imageReadyPulses = 0;
      final sub = dut.output('image_ready').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) imageReadyPulses++;
      });

      final image = List.generate(300, (i) => i & 0xFF);
      final status = await dfuDownload(host, 1, image);

      expect(status, isNotNull, reason: 'download completed');
      expect(status![0], 0x00, reason: 'bStatus OK');
      expect(status[4], 2, reason: 'bState dfuIDLE after manifest');
      expect(
        imageReadyPulses,
        1,
        reason: 'image_ready pulsed once (done fired the manifest)',
      );
      await sub.cancel();

      expect(
        dut.output('bytes_written').value.toInt(),
        equals(image.length),
        reason: 'bytes_written counts every byte',
      );
      for (var i = 0; i < image.length; i++) {
        expect(dut.mem.byteAt(i), equals(image[i]), reason: 'RAM byte[$i]');
      }

      await Simulator.endSimulation();
    });

    test(
      'a download past the region gives dfuERROR with bStatus 8 (errADDRESS)',
      () async {
        final (dut, host) = await buildRamSinkHarness(
          regionBytes: 256,
          words: 128,
        );
        await enumerateSinkDfu(host);

        final regionBytes = 256;
        final image = List.generate(300, (i) => i & 0xFF);
        final status = await dfuDownload(host, 1, image);

        expect(status, isNotNull);
        expect(status![0], 0x08, reason: 'bStatus errADDRESS');
        expect(status[4], 10, reason: 'bState dfuERROR');

        // The write pointer stopped at the region size: nothing past it
        // was ever attempted. Checked before CLRSTATUS, which resets the
        // write pointer for the next image.
        expect(
          dut.output('bytes_written').value.toInt(),
          equals(regionBytes),
          reason: 'bytes_written stopped at the region size',
        );
        for (var i = 0; i < regionBytes; i++) {
          expect(dut.mem.byteAt(i), equals(image[i]), reason: 'RAM byte[$i]');
        }
        for (var i = regionBytes; i < regionBytes + 8; i++) {
          expect(
            dut.mem.byteAt(i),
            equals(0),
            reason: 'byte[$i] past the region was never written',
          );
        }

        final clrStatus = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);
        expect(await host.controlNoData(1, clrStatus), isTrue);
        final afterClear = await host.controlRead(
          1,
          dfuSetup(dirIn: true, bRequest: dfuReqGetStatus, wLength: 6),
        );
        expect(afterClear?[0], 0x00, reason: 'bStatus OK after CLRSTATUS');
        expect(afterClear?[4], 2, reason: 'bState dfuIDLE after CLRSTATUS');

        await Simulator.endSimulation();
      },
    );
  });
}

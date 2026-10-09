import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuFlashSink recovery from a last-block error, bus clock faster '
      'than the USB clock', () {
    test(
      'image_ready never pulses early and the new image is byte-exact',
      (() async {
        final (dut, host) = await buildFlashSinkHarness(
          flashBase: 0,
          eraseLatency: 20,
          programLatency: 20,
          errorOnOp: 3,
          usbClkPeriod: 20,
          busClkPeriod: 7,
        );
        await enumerateSinkDfu(host, altSetting: 1);

        var imageReadyPulses = 0;
        final sub = dut.output('image_ready').changed.listen((e) {
          if (e.newValue.isValid && e.newValue.toBool()) {
            imageReadyPulses++;
          }
        });

        final badImage = List.generate(300, (i) => i & 0xFF);
        final badStatus = await dfuDownload(host, 1, badImage);
        expect(badStatus, isNotNull);
        expect(badStatus![0], 0x03, reason: 'bStatus errWRITE');
        expect(badStatus[4], 10, reason: 'bState dfuERROR');
        expect(imageReadyPulses, 0);

        final clrStatus = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);
        expect(await host.controlNoData(1, clrStatus), isTrue);
        final afterClear = await host.controlRead(
          1,
          dfuSetup(dirIn: true, bRequest: dfuReqGetStatus, wLength: 6),
        );
        expect(afterClear?[0], 0x00, reason: 'bStatus OK after CLRSTATUS');
        expect(afterClear?[4], 2, reason: 'bState dfuIDLE after CLRSTATUS');
        expect(imageReadyPulses, 0);

        final goodImage = List.generate(90, (i) => (i + 11) & 0xFF);
        final goodStatus = await dfuDownload(host, 1, goodImage);
        await sub.cancel();

        expect(goodStatus, isNotNull);
        expect(goodStatus![0], 0x00, reason: 'bStatus OK');
        expect(goodStatus[4], 2, reason: 'bState dfuIDLE after manifest');
        expect(imageReadyPulses, 1);
        expect(
          dut.output('bytes_written').value.toInt(),
          equals(goodImage.length),
        );
        for (var i = 0; i < goodImage.length; i++) {
          expect(dut.model.read(i), equals(goodImage[i]), reason: 'byte[$i]');
        }

        await Simulator.endSimulation();
      }),
    );
  });
}

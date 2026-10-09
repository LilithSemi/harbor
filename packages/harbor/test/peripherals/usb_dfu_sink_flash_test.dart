import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuFlashSink on the sink interface', () {
    test('the flash sink\'s busy shows up as dfuDNBUSY at the host while it '
        'erases and programs, then image_ready pulses', () async {
      final (dut, host) = await buildFlashSinkHarness(
        flashBase: 0,
        eraseLatency: 300,
        programLatency: 300,
      );
      await enumerateSinkDfu(host, altSetting: 1);

      var imageReadyPulses = 0;
      final readySub = dut.output('image_ready').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) imageReadyPulses++;
      });

      // dfuDownload's own GETSTATUS polling (waiting for not-busy between
      // blocks) is what drives dfuDNLOAD_SYNC into dfuDNBUSY, so watch
      // dfu_state for that value rather than polling separately: a
      // second, independent GETSTATUS before the real download would
      // desync the block numbering dfuDownload is about to use.
      var sawDnBusy = false;
      final stateSub = dut.output('dfu_state').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toInt() == 4) sawDnBusy = true;
      });

      final image = List.generate(300, (i) => i & 0xFF);
      final status = await dfuDownload(host, 1, image);
      await stateSub.cancel();

      expect(sawDnBusy, isTrue, reason: 'dfuDNBUSY while the sink writes');

      expect(status, isNotNull, reason: 'download completed');
      expect(status![0], 0x00, reason: 'bStatus OK');
      expect(status[4], 2, reason: 'bState dfuIDLE after manifest');
      expect(
        imageReadyPulses,
        1,
        reason: 'image_ready pulsed once after the whole image',
      );
      await readySub.cancel();

      expect(
        dut.output('bytes_written').value.toInt(),
        equals(image.length),
        reason: 'bytes_written counts every programmed byte',
      );
      for (var i = 0; i < image.length; i++) {
        expect(dut.model.read(i), equals(image[i]), reason: 'flash byte[$i]');
      }

      await Simulator.endSimulation();
    });

    test('wr_err gives bStatus 3 (errWRITE)', () async {
      final (dut, host) = await buildFlashSinkHarness(
        flashBase: 0,
        eraseLatency: 20,
        programLatency: 20,
        errorOnOp: 1, // the first op (the erase of the first page) fails
      );
      await enumerateSinkDfu(host, altSetting: 1);

      final image = List.generate(300, (i) => i & 0xFF);
      final status = await dfuDownload(host, 1, image);

      expect(status, isNotNull);
      expect(status![0], 0x03, reason: 'bStatus errWRITE');
      expect(status[4], 10, reason: 'bState dfuERROR');

      final clrStatus = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);
      expect(await host.controlNoData(1, clrStatus), isTrue);
      final afterClear = await host.controlRead(
        1,
        dfuSetup(dirIn: true, bRequest: dfuReqGetStatus, wLength: 6),
      );
      expect(afterClear?[0], 0x00, reason: 'bStatus OK after CLRSTATUS');
      expect(afterClear?[4], 2, reason: 'bState dfuIDLE after CLRSTATUS');

      await Simulator.endSimulation();
    });
  });
}

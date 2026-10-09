import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuRamSink clear watchdog', () {
    test('a sink that never acks clear (held in bus_reset) gives dfuERROR / '
        '0x0E on GETSTATUS, and CLRSTATUS plus a full download work once '
        'the sink is healthy again', () async {
      final (
        dut,
        host,
        busClk,
        busReset,
      ) = await buildRamSinkHarnessWithBusControl(
        regionBytes: 512,
        words: 128,
        clearWatchdogLimit: 300,
      );
      await enumerateSinkDfu(host);

      // Hold the sink's bus domain in reset for the rest of this
      // phase: equivalent to a stalled bus_clk, its FIFO can never be
      // drained and `clear` can never be acked. ABORT is accepted
      // straight from dfuIDLE (no DNLOAD data stage, so there is no
      // transfer left half-finished at the USB core level once it
      // completes) and raises `clear`.
      await setBusReset(busClk, busReset, 1);
      final abort = dfuSetup(dirIn: false, bRequest: dfuReqAbort);
      expect(await host.controlNoData(1, abort), isTrue);

      // The watchdog gives up and fails the device closed.
      final getStatus = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetStatus,
        wLength: 6,
      );
      List<int>? failedStatus;
      for (var i = 0; i < 500; i++) {
        final status = await host.controlRead(1, getStatus);
        if (status != null && status[4] == 10) {
          failedStatus = status;
          break;
        }
        await host.idle(50);
      }
      expect(failedStatus, isNotNull, reason: 'bState dfuERROR');
      expect(failedStatus![0], 0x0E, reason: 'bStatus errUNKNOWN');

      // The sink is healthy again.
      await setBusReset(busClk, busReset, 0);

      final clrStatus = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);
      expect(await host.controlNoData(1, clrStatus), isTrue);
      final afterClear = await host.controlRead(1, getStatus);
      expect(afterClear?[0], 0x00, reason: 'bStatus OK after CLRSTATUS');
      expect(afterClear?[4], 2, reason: 'bState dfuIDLE after CLRSTATUS');

      var imageReadyPulses = 0;
      final sub = dut.output('image_ready').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) imageReadyPulses++;
      });

      final goodImage = List.generate(90, (i) => (i + 4) & 0xFF);
      final goodStatus = await dfuDownload(host, 1, goodImage);
      await sub.cancel();

      expect(goodStatus, isNotNull);
      expect(goodStatus![0], 0x00, reason: 'bStatus OK');
      expect(goodStatus[4], 2, reason: 'bState dfuIDLE after manifest');
      expect(imageReadyPulses, 1, reason: 'image_ready pulsed once');
      expect(
        dut.output('bytes_written').value.toInt(),
        equals(goodImage.length),
      );
      for (var i = 0; i < goodImage.length; i++) {
        expect(dut.mem.byteAt(i), equals(goodImage[i]), reason: 'byte[$i]');
      }

      await Simulator.endSimulation();
    });
  });
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuRamSink recovery from bus_reset mid-clear', () {
    test('a bus_reset held through an in-flight clear does not ack it, the '
        'watchdog fails the device closed, and a fresh CLRSTATUS recovers '
        'a byte-exact download', () async {
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

      final block0 = List.generate(64, (i) => i & 0xFF);
      final setup = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: block0.length,
      );
      expect(await host.controlWrite(1, setup, block0), isTrue);

      // DFU 1.1 Table A.1: a GETSTATUS poll is needed to leave
      // dfuDNLOAD_SYNC for dfuDNLOAD_IDLE, where ABORT is accepted.
      final getStatus = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetStatus,
        wLength: 6,
      );
      final afterBlock = await host.controlRead(1, getStatus);
      expect(afterBlock?[4], 5, reason: 'bState dfuDNLOAD_IDLE');

      // Hold bus_reset from before ABORT raises `clear` until well past
      // the watchdog limit. The sink joins its two resets, so both of its
      // domains stay in reset and the clear is lost with no ack.
      await setBusReset(busClk, busReset, 1);
      final abort = dfuSetup(dirIn: false, bRequest: dfuReqAbort);
      expect(await host.controlNoData(1, abort), isTrue);

      // The dropped clear is never acked: the device's own watchdog
      // must give up and fail closed into dfuERROR with errUNKNOWN.
      List<int>? failedStatus;
      for (var i = 0; i < 500; i++) {
        final status = await host.controlRead(1, getStatus);
        if (status != null && status[4] == 10) {
          failedStatus = status;
          break;
        }
        await host.idle(50);
      }
      expect(
        failedStatus,
        isNotNull,
        reason: 'watchdog should fail the device closed into dfuERROR',
      );
      expect(failedStatus![0], 0x0E, reason: 'bStatus errUNKNOWN');

      // The sink is healthy again.
      await setBusReset(busClk, busReset, 0);

      // A fresh CLRSTATUS raises a fresh clear. The reset emptied both
      // sides of the sink's FIFO, so this clear acks quickly.
      final clrStatus = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);
      expect(await host.controlNoData(1, clrStatus), isTrue);
      final afterClear = await host.controlRead(1, getStatus);
      expect(afterClear?[0], 0x00, reason: 'bStatus OK after CLRSTATUS');
      expect(afterClear?[4], 2, reason: 'bState dfuIDLE after CLRSTATUS');

      var imageReadyPulses = 0;
      final sub = dut.output('image_ready').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) imageReadyPulses++;
      });

      final goodImage = List.generate(90, (i) => (i + 3) & 0xFF);
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

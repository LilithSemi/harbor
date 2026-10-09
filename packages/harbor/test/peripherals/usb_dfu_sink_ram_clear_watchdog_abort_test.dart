import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';
import 'usb_test_host.dart';

// Kept out of usb_dfu_sink_ram_clear_watchdog_test.dart, in its own
// process: this test and that file's own run a full download each, and
// chained in one isolate the second download runs far slower than either
// does alone.

/// Sends two OUT packets of a blocked DNLOAD data stage. The engine
/// buffers one packet, so the first may be ACKed. The second has no room
/// and is NAKed on every one of [tries].
Future<void> expectSecondPacketNaked(UsbTestHost host, int tries) async {
  await host.sendToken(1, 1, 0); // OUT
  await host.idle(2);
  await host.sendData(11, [10, 20, 30, 40]); // DATA1
  expect(
    (await host.waitPacket())?.pid,
    2,
    reason: 'the buffer was empty, so the first packet is kept',
  );
  await host.idle(50);

  for (var i = 0; i < tries; i++) {
    await host.sendToken(1, 1, 0); // OUT
    await host.idle(2);
    await host.sendData(3, [50, 60, 70, 80]); // DATA0
    expect(
      (await host.waitPacket())?.pid,
      10,
      reason: 'the buffer still holds the first packet, try $i',
    );
    await host.idle(50);
  }
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuRamSink clear watchdog', () {
    test('a DNLOAD blocked by a failed clear: the host gives up mid-block '
        'and sends GETSTATUS instead, and gets dfuERROR / 0x0E, then '
        'CLRSTATUS plus a full download work once the sink is healthy '
        'again', () async {
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

      // Hold the sink's bus domain in reset: a fresh download's first
      // block still raises `clear` (a new image starts at dfuIDLE),
      // but `clear` can never be acked, so the data stage never advances.
      await setBusReset(busClk, busReset, 1);
      final setup = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: 8,
      );
      await host.sendToken(13, 1, 0); // SETUP
      await host.idle(2);
      await host.sendData(3, setup); // DATA0
      await host.idle(100);
      expect(
        (await host.waitPacket())?.pid,
        2,
        reason: 'the SETUP itself is ACKed',
      );

      await expectSecondPacketNaked(host, 5);

      // The host gives up on this block and sends GETSTATUS instead
      // of finishing the OUT stage. USB 2.0 8.5.3/9.2.6.4: a new SETUP
      // is accepted and aborts the stage it interrupts. The sink's own
      // stuck clear is the root cause here, so GETSTATUS still reports
      // errUNKNOWN / 0x0E, not a different code for the abort itself.
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

      final goodImage = List.generate(90, (i) => (i + 5) & 0xFF);
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

    test('a DNLOAD blocked by a failed clear, aborted well before the '
        'watchdog could ever expire, still reports dfuERROR / 0x0E: the '
        'stuck sink is the root cause, not the abort', () async {
      final (
        _,
        host,
        busClk,
        busReset,
      ) = await buildRamSinkHarnessWithBusControl(
        regionBytes: 512,
        words: 128,
        clearWatchdogLimit: HarborUsbDfu.defaultClearWatchdogLimit,
      );
      await enumerateSinkDfu(host);

      await setBusReset(busClk, busReset, 1);
      final setup = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: 8,
      );
      await host.sendToken(13, 1, 0); // SETUP
      await host.idle(2);
      await host.sendData(3, setup); // DATA0
      await host.idle(100);
      expect(
        (await host.waitPacket())?.pid,
        2,
        reason: 'the SETUP itself is ACKed',
      );

      // The default watchdog cannot expire in this test, so GETSTATUS
      // below answers before the watchdog path could fire.
      await expectSecondPacketNaked(host, 2);

      // The host gives up immediately and polls GETSTATUS instead.
      final status = await host.controlRead(
        1,
        dfuSetup(dirIn: true, bRequest: dfuReqGetStatus, wLength: 6),
      );
      expect(status?[4], 10, reason: 'bState dfuERROR');
      expect(
        status?[0],
        0x0E,
        reason:
            'bStatus errUNKNOWN: the stuck sink is the root cause, '
            'the same failure the watchdog would eventually report on its '
            'own. An abort with no clear involved reports 0x0F instead '
            '(see usb_dfu_device_dnload_test.dart).',
      );

      await Simulator.endSimulation();
    });
  });
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';
import 'usb_test_host.dart';

Future<List<int>?> _pollNotBusy(UsbTestHost host, int addr) async {
  final getStatus = dfuSetup(
    dirIn: true,
    bRequest: dfuReqGetStatus,
    wLength: 6,
  );
  for (var i = 0; i < 2000; i++) {
    final status = await host.controlRead(addr, getStatus);
    if (status == null) return null;
    if (status[4] != 4 && status[4] != 7) return status;
    await host.idle(50);
  }
  return null;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('UsbDfuRamSink recovery from ABORT mid-drain', () {
    test('ABORT right after a block is sent, while the bus is stalled, then '
        'a new download is byte-exact with no old bytes', () async {
      // A slow bus (12 extra cycles per write ack) so a 64-byte block's
      // bytes are still queued in the CDC FIFO when ABORT lands right
      // behind it, with no idle in between.
      final (dut, host) = await buildRamSinkHarness(
        regionBytes: 512,
        words: 128,
        ackDelay: 12,
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

      // One GETSTATUS poll: DFU 1.1 Table A.1 needs it to leave
      // dfuDNLOAD_SYNC for dfuDNLOAD_IDLE, which is where ABORT is
      // accepted from. RAM's `busy` never reflects the bus domain's own
      // per-block drain, so this reports idle long before the block's
      // bytes have actually landed in RAM: exactly the race ABORT must
      // survive.
      final getStatus = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetStatus,
        wLength: 6,
      );
      final afterBlock = await host.controlRead(1, getStatus);
      expect(afterBlock?[4], 5, reason: 'bState dfuDNLOAD_IDLE');

      final abort = dfuSetup(dirIn: false, bRequest: dfuReqAbort);
      expect(await host.controlNoData(1, abort), isTrue);

      final afterAbort = await _pollNotBusy(host, 1);
      expect(afterAbort, isNotNull);
      expect(afterAbort![4], 2, reason: 'bState dfuIDLE after ABORT');

      var imageReadyPulses = 0;
      final sub = dut.output('image_ready').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) imageReadyPulses++;
      });

      final goodImage = List.generate(90, (i) => (i + 2) & 0xFF);
      final goodStatus = await dfuDownload(host, 1, goodImage);
      await sub.cancel();

      expect(goodStatus, isNotNull);
      expect(goodStatus![0], 0x00, reason: 'bStatus OK');
      expect(goodStatus[4], 2, reason: 'bState dfuIDLE after manifest');
      expect(imageReadyPulses, 1, reason: 'image_ready pulsed once');
      expect(
        dut.output('bytes_written').value.toInt(),
        equals(goodImage.length),
        reason: 'write pointer restarted at 0, no leftover old bytes',
      );
      for (var i = 0; i < goodImage.length; i++) {
        expect(dut.mem.byteAt(i), equals(goodImage[i]), reason: 'byte[$i]');
      }

      await Simulator.endSimulation();
    });
  });
}

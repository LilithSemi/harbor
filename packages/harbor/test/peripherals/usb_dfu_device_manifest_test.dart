import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_device_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbDfu manifest', () {
    test('a zero-length DNLOAD pulses end once; GETSTATUS reports the '
        'manifest states until the sink pulses done, then dfuIDLE', () async {
      final (dut, host, _, _, _) = await buildDfuHarness(
        busyCyclesAfterEnd: 3000,
      );
      await enumerateDfu(dut, host);

      // Watched from before the first block, so a false `end` pulse
      // during a data block would also be caught.
      final blockDone = watchPulses(dut, 'sink_block_done');
      final end = watchPulses(dut, 'sink_end');

      final data = List.generate(8, (i) => i & 0xFF);
      final dnload0 = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: data.length,
      );
      expect(await host.controlWrite(1, dnload0, data), isTrue);
      expect(
        blockDone.count.value,
        1,
        reason: 'block_done fires for the block',
      );
      expect(end.count.value, 0, reason: 'end never fires for a data block');

      final getStatus = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetStatus,
        wLength: 6,
      );
      // Drain the per-block busy window before ending the download.
      await host.idle(3200);
      final afterBlock = await host.controlRead(1, getStatus);
      expect(afterBlock?[4], 5, reason: 'dfuDNLOAD_IDLE before the end');

      final dnloadEnd = dfuSetup(dirIn: false, bRequest: dfuReqDnload);
      expect(await host.controlNoData(1, dnloadEnd), isTrue);
      expect(
        blockDone.count.value,
        1,
        reason: 'the zero-length DNLOAD is not a block',
      );
      expect(
        end.count.value,
        1,
        reason: 'end pulses exactly once, for the manifest trigger',
      );
      await blockDone.sub.cancel();
      await end.sub.cancel();

      final manifestStatus = await host.controlRead(1, getStatus);
      expect(
        manifestStatus?[4],
        anyOf(6, 7),
        reason: 'a manifest state while the sink is still busy',
      );

      await host.idle(3200);

      final finalStatus = await host.controlRead(1, getStatus);
      expect(finalStatus?[4], 2, reason: 'dfuIDLE once the sink is done');

      await Simulator.endSimulation();
    });
  });
}

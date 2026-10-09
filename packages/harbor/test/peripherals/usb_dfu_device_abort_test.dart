import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_device_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbDfu ABORT', () {
    test('ABORT in dfuIDLE is a no-op and stays dfuIDLE', () async {
      final (dut, host, _, _, _) = await buildDfuHarness();
      await enumerateDfu(dut, host);

      final abort = dfuSetup(dirIn: false, bRequest: dfuReqAbort);
      expect(await host.controlNoData(1, abort), isTrue);
      expect(dut.output('dfu_state').value.toInt(), 2);

      await Simulator.endSimulation();
    });

    test('ABORT in dfuDNLOAD_IDLE returns to dfuIDLE', () async {
      final (dut, host, _, _, _) = await buildDfuHarness();
      await enumerateDfu(dut, host);

      final data = List.generate(5, (i) => i & 0xFF);
      final dnload = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: data.length,
      );
      expect(await host.controlWrite(1, dnload, data), isTrue);

      final getStatus = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetStatus,
        wLength: 6,
      );
      final status = await host.controlRead(1, getStatus);
      expect(status?[4], 5, reason: 'dfuDNLOAD_IDLE before the abort');

      final abort = dfuSetup(dirIn: false, bRequest: dfuReqAbort);
      expect(await host.controlNoData(1, abort), isTrue);
      expect(dut.output('dfu_state').value.toInt(), 2);

      await Simulator.endSimulation();
    });

    test(
      'ABORT in dfuDNLOAD_SYNC is not a valid request: stalls into dfuERROR',
      () async {
        final (dut, host, _, _, _) = await buildDfuHarness();
        await enumerateDfu(dut, host);

        final data = List.generate(5, (i) => i & 0xFF);
        final dnload = dfuSetup(
          dirIn: false,
          bRequest: dfuReqDnload,
          wValue: 0,
          wLength: data.length,
        );
        expect(await host.controlWrite(1, dnload, data), isTrue);
        expect(
          dut.output('dfu_state').value.toInt(),
          3,
          reason: 'dfuDNLOAD_SYNC before any GETSTATUS poll',
        );

        final abort = dfuSetup(dirIn: false, bRequest: dfuReqAbort);
        expect(await host.controlNoData(1, abort), isFalse);
        expect(dut.output('dfu_state').value.toInt(), 10);
        expect(dut.output('dfu_status').value.toInt(), 0x0F);

        await Simulator.endSimulation();
      },
    );

    test(
      'ABORT in dfuERROR is not valid either: stays dfuERROR, needs CLRSTATUS',
      () async {
        final (dut, host, _, _, _) = await buildDfuHarness();
        await enumerateDfu(dut, host);

        // Reach dfuERROR the same way the state test does: a zero-length
        // DNLOAD from dfuIDLE.
        final badDnload = dfuSetup(dirIn: false, bRequest: dfuReqDnload);
        expect(await host.controlNoData(1, badDnload), isFalse);
        expect(dut.output('dfu_state').value.toInt(), 10);

        final abort = dfuSetup(dirIn: false, bRequest: dfuReqAbort);
        expect(await host.controlNoData(1, abort), isFalse);
        expect(dut.output('dfu_state').value.toInt(), 10);
        expect(dut.output('dfu_status').value.toInt(), 0x0F);

        await Simulator.endSimulation();
      },
    );
  });
}

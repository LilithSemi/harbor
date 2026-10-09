import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_core_harness.dart' show busResetHoldCycles;
import 'usb_dfu_device_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbDfu control requests', () {
    test('GETSTATE in dfuIDLE returns 2', () async {
      final (dut, host, _, _, _) = await buildDfuHarness();
      await enumerateDfu(dut, host);

      final getState = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetState,
        wLength: 1,
      );
      final state = await host.controlRead(1, getState);
      expect(state, [2]);

      await Simulator.endSimulation();
    });

    test(
      'a zero-length DNLOAD in dfuIDLE stalls and sets dfuERROR / errSTALLEDPKT',
      () async {
        final (dut, host, _, _, _) = await buildDfuHarness();
        await enumerateDfu(dut, host);

        final badDnload = dfuSetup(dirIn: false, bRequest: dfuReqDnload);
        expect(await host.controlNoData(1, badDnload), isFalse);
        expect(dut.output('dfu_state').value.toInt(), 10);
        expect(dut.output('dfu_status').value.toInt(), 0x0F);

        await Simulator.endSimulation();
      },
    );

    test('DFU_UPLOAD stalls', () async {
      final (dut, host, _, _, _) = await buildDfuHarness();
      await enumerateDfu(dut, host);

      final upload = dfuSetup(dirIn: true, bRequest: dfuReqUpload, wLength: 64);
      final resp = await host.controlRead(1, upload);
      expect(resp, isNull, reason: 'UPLOAD is unsupported and STALLs');

      await Simulator.endSimulation();
    });

    test('a bus reset during dfuDNLOAD_IDLE returns dfu_state to 2', () async {
      final (dut, host, clk, dp, dm) = await buildDfuHarness();
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
      expect(status?[4], 5, reason: 'dfuDNLOAD_IDLE before the reset');

      dp.inject(0);
      dm.inject(0);
      for (var i = 0; i < busResetHoldCycles; i++) {
        await clk.nextPosedge;
      }
      expect(dut.output('bus_reset').value.toInt(), 1);
      expect(dut.output('dfu_state').value.toInt(), 2);

      dp.inject(1);
      dm.inject(0);
      await host.idle(50);

      await Simulator.endSimulation();
    });
  });
}

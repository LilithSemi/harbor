import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_device_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbDfu sink error', () {
    test('a sink error during a block moves to dfuERROR with its status code; '
        'CLRSTATUS returns to dfuIDLE', () async {
      final (dut, host, _, _, _) = await buildDfuHarness(
        errorAtByteIndex: 3,
        errorCode: 0x03,
      );
      await enumerateDfu(dut, host);

      final data = List.generate(10, (i) => i & 0xFF);
      final dnload = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: data.length,
      );
      await host.controlWrite(1, dnload, data);

      final getStatus = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetStatus,
        wLength: 6,
      );
      final status = await host.controlRead(1, getStatus);
      expect(status?[0], 0x03, reason: 'bStatus errWRITE from the sink');
      expect(status?[4], 10, reason: 'bState dfuERROR');

      final clrStatus = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);
      expect(await host.controlNoData(1, clrStatus), isTrue);

      final afterClear = await host.controlRead(1, getStatus);
      expect(afterClear?[0], 0x00, reason: 'bStatus OK after CLRSTATUS');
      expect(afterClear?[4], 2, reason: 'bState dfuIDLE after CLRSTATUS');

      await Simulator.endSimulation();
    });
  });
}

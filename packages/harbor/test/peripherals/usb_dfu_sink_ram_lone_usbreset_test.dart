import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  final getStatus = dfuSetup(
    dirIn: true,
    bRequest: dfuReqGetStatus,
    wLength: 6,
  );

  group('UsbDfuRamSink with one reset alone', () {
    test('a lone usb_reset after an address error and CLRSTATUS fakes no '
        'error pulse', () async {
      final (dut, host, _, _) = await buildRamSinkHarnessWithBusControl(
        regionBytes: 32,
        words: 128,
      );
      await enumerateSinkDfu(host);

      final image = List.generate(64, (i) => i & 0xFF);
      final st = await dfuDownload(host, 1, image);
      expect(st?[0], 0x08, reason: 'bStatus errADDRESS');
      expect(st?[4], 10, reason: 'bState dfuERROR');

      final clr = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);
      expect(await host.controlNoData(1, clr), isTrue);
      final cleared = await host.controlRead(1, getStatus);
      expect(cleared?[0], 0);
      expect(cleared?[4], 2);

      await pulseReset(host.clk, host.reset, 10);
      await host.idle(300);
      expect(
        dut.output('dfu_status').value.toInt(),
        0,
        reason: 'no error pulse after the reset',
      );

      await enumerateSinkDfu(host);
      final status = await host.controlRead(1, getStatus);
      expect(status?[0], 0, reason: 'bStatus OK');
      expect(status?[4], 2, reason: 'bState dfuIDLE');

      await Simulator.endSimulation();
    });
  });
}

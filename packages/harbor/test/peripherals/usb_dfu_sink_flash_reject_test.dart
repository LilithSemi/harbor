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
  final clrStatus = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);

  group('UsbDfuFlashSink write rejects', () {
    test('a rejected request with no wr_busy fails to errWRITE, and '
        'CLRSTATUS recovers', () async {
      // Request 1 is the sector erase, request 2 the first page program.
      final (dut, host) = await buildFlashSinkHarness(
        rejectOnReq: 2,
        maxSimTime: 80000000,
      );
      await enumerateSinkDfu(host, altSetting: 1);

      final bad = List.generate(64, (i) => i & 0xFF);
      final status = await dfuDownload(host, 1, bad);
      expect(status, isNotNull);
      expect(status![0], 0x03, reason: 'bStatus errWRITE');
      expect(status[4], 10, reason: 'bState dfuERROR');

      expect(await host.controlNoData(1, clrStatus), isTrue);
      List<int>? cleared;
      for (var i = 0; i < 300; i++) {
        cleared = await host.controlRead(1, getStatus);
        if (cleared != null && cleared[4] != 4) break;
        await host.idle(50);
      }
      expect(cleared?[0], 0x00, reason: 'bStatus OK after CLRSTATUS');
      expect(cleared?[4], 2, reason: 'bState dfuIDLE after CLRSTATUS');

      final good = List.generate(128, (i) => (i + 5) & 0xFF);
      final st2 = await dfuDownload(host, 1, good);
      expect(st2?[0], 0x00);
      expect(st2?[4], 2);
      for (var i = 0; i < good.length; i++) {
        expect(dut.model.read(i), good[i], reason: 'flash byte[$i]');
      }

      await Simulator.endSimulation();
    });
  });
}

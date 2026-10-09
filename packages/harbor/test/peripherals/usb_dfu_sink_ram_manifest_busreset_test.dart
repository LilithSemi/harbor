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

  test('a lone bus_reset during dfuMANIFEST fails closed to errUNKNOWN, and '
      'CLRSTATUS recovers', () async {
    final (
      dut,
      host,
      busClk,
      busReset,
    ) = await buildRamSinkHarnessWithBusControl(
      regionBytes: 512,
      words: 128,
      ackDelay: 60,
      maxSimTime: 80000000,
    );
    await enumerateSinkDfu(host);

    final image = List.generate(90, (i) => (i + 3) & 0xFF);
    var block = 0;
    for (var off = 0; off < image.length; off += 64) {
      final end = (off + 64).clamp(0, image.length);
      final setup = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: block++,
        wLength: end - off,
      );
      expect(
        await host.controlWrite(1, setup, image.sublist(off, end)),
        isTrue,
      );
      expect((await host.controlRead(1, getStatus))?[4], 5);
    }
    final endSetup = dfuSetup(
      dirIn: false,
      bRequest: dfuReqDnload,
      wValue: block,
    );
    expect(await host.controlNoData(1, endSetup), isTrue);
    expect(
      (await host.controlRead(1, getStatus))?[4],
      7,
      reason: 'dfuMANIFEST while the slow RAM drains',
    );

    await pulseReset(busClk, busReset, 8);

    List<int>? s;
    for (var i = 0; i < 20; i++) {
      s = await host.controlRead(1, getStatus);
      if (s != null && s[4] != 7) break;
      await host.idle(200);
    }
    expect(s?[4], 10, reason: 'bState dfuERROR');
    expect(s?[0], 0x0E, reason: 'bStatus errUNKNOWN');

    final clr = dfuSetup(dirIn: false, bRequest: dfuReqClrStatus);
    expect(await host.controlNoData(1, clr), isTrue);
    final cleared = await host.controlRead(1, getStatus);
    expect(cleared?[0], 0);
    expect(cleared?[4], 2);

    await Simulator.endSimulation();
  });
}

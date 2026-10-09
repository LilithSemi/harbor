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

  test('a lone bus_reset during dfuDNBUSY fails closed to errUNKNOWN, and '
      'CLRSTATUS recovers', () async {
    final (
      dut,
      host,
      busClk,
      busReset,
    ) = await buildFlashSinkHarnessWithBusControl(
      eraseLatency: 3000,
      programLatency: 3000,
      maxSimTime: 80000000,
    );
    await enumerateSinkDfu(host, altSetting: 1);

    final data = List.generate(64, (i) => (i * 3) & 0xFF);
    final setup = dfuSetup(
      dirIn: false,
      bRequest: dfuReqDnload,
      wLength: data.length,
    );
    expect(await host.controlWrite(1, setup, data), isTrue);
    expect(
      (await host.controlRead(1, getStatus))?[4],
      4,
      reason: 'dfuDNBUSY while the flash erases',
    );

    await pulseReset(busClk, busReset, 8);

    List<int>? s;
    for (var i = 0; i < 20; i++) {
      s = await host.controlRead(1, getStatus);
      if (s != null && s[4] != 4) break;
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

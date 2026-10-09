import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_sink_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('a DNLOAD with wLength above wTransferSize STALLs and writes '
      'nothing', () async {
    final (dut, host) = await buildRamSinkHarness(regionBytes: 512, words: 128);
    await enumerateSinkDfu(host);

    final block = List.generate(300, (i) => (i + 9) & 0xFF);
    final setup = dfuSetup(
      dirIn: false,
      bRequest: dfuReqDnload,
      wLength: block.length,
    );
    expect(await host.controlWrite(1, setup, block), isFalse);

    final getStatus = dfuSetup(
      dirIn: true,
      bRequest: dfuReqGetStatus,
      wLength: 6,
    );
    final status = await host.controlRead(1, getStatus);
    expect(status?[0], 0x0F, reason: 'bStatus errSTALLEDPKT');
    expect(status?[4], 10, reason: 'bState dfuERROR');
    await host.idle(2000);
    expect(dut.output('bytes_written').value.toInt(), 0);

    await Simulator.endSimulation();
  });
}

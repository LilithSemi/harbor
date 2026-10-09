import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('a bus reset sets the bus reset interrupt, and W1C clears it', () async {
    final (dut, host, clk, dp, dm) = await buildUsbControllerHarness(
      maxSimTime: 4000000,
    );
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, intEnableAddr, 0x1);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    // HarborUsbFsResetDet trips after sustained SE0 past its threshold.
    dp.inject(0);
    dm.inject(0);
    for (var i = 0; i < 33000; i++) {
      await host.clk.nextPosedge;
    }
    await clk.nextPosedge;

    var status = await dut.read(clk, intStatusAddr);
    expect(status & 0x1, equals(1), reason: 'bus reset interrupt set');
    expect(dut.output('interrupt').value.toInt(), equals(1));

    dp.inject(1);
    dm.inject(0);
    for (var i = 0; i < 10; i++) {
      await host.clk.nextPosedge;
    }
    await clk.nextPosedge;

    await dut.write(clk, intStatusAddr, 0x1);
    status = await dut.read(clk, intStatusAddr);
    expect(status & 0x1, equals(0), reason: 'cleared by the write-1');

    await Simulator.endSimulation();
  });
}

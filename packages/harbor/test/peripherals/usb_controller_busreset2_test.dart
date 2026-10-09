import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

// Split from usb_controller_busreset_test.dart: each bus-reset test takes
// several minutes on its own, so chaining more than two in one file risks
// a very long single-file run.

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('IN bytes still queued behind a busy endpoint are discarded by a '
      'bus reset', () async {
    final (dut, host, clk, dp, dm) = await buildUsbControllerHarness(
      maxSimTime: 4000000,
    );
    await dut.write(clk, ctrlAddr, 0x3);

    // Arm EP2 and leave it unsent, so the endpoint is busy.
    for (final b in [1, 2, 3]) {
      await dut.write(clk, epAddr(2, inDataOff), b);
    }
    await dut.write(clk, epAddr(2, inCommitOff), 1);

    // These bytes queue behind the busy endpoint in the shared FIFO.
    for (final b in [0xA, 0xB, 0xC, 0xD, 0xE]) {
      await dut.write(clk, epAddr(2, inDataOff), b);
    }
    await dut.write(clk, intEnableAddr, 0x1);

    dp.inject(0);
    dm.inject(0);
    await dut.output('interrupt').nextPosedge;
    dp.inject(1);
    dm.inject(0);
    await host.idle(20);
    await dut.write(clk, intStatusAddr, 0x1);

    // Fresh data after the reset must not see the discarded bytes.
    for (final b in [7, 8]) {
      await dut.write(clk, epAddr(2, inDataOff), b);
    }
    await dut.write(clk, epAddr(2, inCommitOff), 1);

    await host.sendToken(9, 0, 2);
    final pkt = await host.waitPacket();
    expect(pkt?.pid, equals(3));
    expect(pkt!.payload, equals([7, 8]));

    await Simulator.endSimulation();
  });

  test('a bus reset clears every EP_CFG stall bit', () async {
    final (dut, host, clk, dp, dm) = await buildUsbControllerHarness(
      maxSimTime: 4000000,
    );
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(0, cfgOff), 0x19);
    await dut.write(clk, epAddr(1, cfgOff), 0x18);
    await dut.write(clk, intEnableAddr, 0x1);

    dp.inject(0);
    dm.inject(0);
    await dut.output('interrupt').nextPosedge;
    dp.inject(1);
    dm.inject(0);
    await host.idle(20);

    expect(await dut.read(clk, epAddr(0, cfgOff)) & 0x18, equals(0));
    expect(await dut.read(clk, epAddr(1, cfgOff)) & 0x18, equals(0));

    // The PE stall state must be clear too: EP1 IN NAKs and OUT ACKs.
    await host.sendToken(9, 0, 1);
    expect(
      (await host.waitPacket())?.pid,
      equals(10),
      reason: 'EP1 IN no longer stalls',
    );
    await host.idle(20);
    await host.sendToken(1, 0, 1);
    await host.idle(2);
    await host.sendData(3, [1]);
    expect(
      (await host.waitPacket())?.pid,
      equals(2),
      reason: 'EP1 OUT no longer stalls',
    );

    await Simulator.endSimulation();
  });
}

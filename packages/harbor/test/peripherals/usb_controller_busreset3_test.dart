import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('a toggle reset with a held packet, then a bus reset, leaves the '
      'endpoint clean', () async {
    final (dut, host, clk, dp, dm) = await buildUsbControllerHarness(
      maxSimTime: 4000000,
    );
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);

    await host.sendToken(1, 0, 1);
    await host.idle(2);
    await host.sendData(3, const [0x11]);
    expect((await host.waitPacket())?.pid, equals(2));
    await waitOutReady(dut, clk, 1);
    // Toggle reset OUT while A is held and never freed.
    await dut.write(clk, epAddr(1, cfgOff), 0x25);
    await dut.write(clk, intEnableAddr, 0x1);

    dp.inject(0);
    dm.inject(0);
    await dut.output('interrupt').nextPosedge;
    dp.inject(1);
    dm.inject(0);
    await host.idle(20);
    expect(await dut.read(clk, epAddr(1, outStatOff)) & 0x1, equals(0));

    // DATA0 lands, then DATA1: no toggle reset is left over.
    for (final (pid, b) in [(3, 0x22), (11, 0x33)]) {
      await host.sendToken(1, 0, 1);
      await host.idle(2);
      await host.sendData(pid, [b]);
      expect((await host.waitPacket())?.pid, equals(2));
      final st = await waitOutReady(dut, clk, 1);
      expect(await dut.read(clk, epAddr(1, outDataOff)), equals(b));
      await dut.write(clk, epAddr(1, outAckOff), st);
      await host.idle(20);
    }

    await Simulator.endSimulation();
  });
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'software pushes 18 bytes into EP0 IN_DATA, host IN reads them',
    () async {
      final (dut, host, clk, _, _) = await buildUsbControllerHarness();
      await dut.write(clk, ctrlAddr, 0x3);
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }

      final payload = List<int>.generate(18, (i) => i + 1);
      for (final b in payload) {
        await dut.write(clk, epAddr(0, inDataOff), b);
      }
      await dut.write(clk, epAddr(0, inCommitOff), 1);

      await host.sendToken(9, 0, 0);
      final pkt = await host.waitPacket();
      expect(pkt, isNotNull);
      expect(pkt!.pid, equals(3), reason: 'DATA0 for the first IN after reset');
      expect(pkt.payload, equals(payload));
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      final inStat = await dut.read(clk, epAddr(0, inStatOff));
      expect((inStat >> 1) & 0x1, equals(1), reason: 'last packet acked');

      await Simulator.endSimulation();
    },
  );

  test('zero-length IN_COMMIT gives a ZLP', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    await dut.write(clk, epAddr(0, inCommitOff), 1);

    await host.sendToken(9, 0, 0);
    final pkt = await host.waitPacket();
    expect(pkt, isNotNull);
    expect(pkt!.payload, isEmpty);
    expect(pkt.pid, equals(3), reason: 'DATA0 for the first IN after reset');

    await Simulator.endSimulation();
  });

  test('EP_CFG toggle reset gives DATA0 on the next IN', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    // First IN after reset starts at DATA0, and acking it flips the
    // engine's toggle to DATA1 for the next packet.
    await dut.write(clk, epAddr(0, inCommitOff), 1);
    await host.sendToken(9, 0, 0);
    var pkt = await host.waitPacket();
    expect(pkt, isNotNull);
    expect(pkt!.pid, equals(3));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(50);

    // Without a reset the next packet would be DATA1. Reset the IN
    // toggle for EP0 via EP_CFG bit 6 and confirm it goes back to DATA0.
    await dut.write(clk, epAddr(0, cfgOff), 0x40);

    await dut.write(clk, epAddr(0, inCommitOff), 1);
    await host.sendToken(9, 0, 0);
    pkt = await host.waitPacket();
    expect(pkt, isNotNull);
    expect(pkt!.pid, equals(3), reason: 'DATA0 after the toggle reset');

    await Simulator.endSimulation();
  });
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const getDescriptor = [0x80, 6, 0, 1, 0, 0, 18, 0];

  test('a SETUP clears an EP0 OUT+IN protocol stall and lands', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);

    // enable, stall OUT, stall IN.
    await dut.write(clk, epAddr(0, cfgOff), 0x19);

    await host.sendToken(9, 0, 0);
    final stalled = await host.waitPacket();
    expect(stalled?.pid, equals(14), reason: 'the stall is in effect');

    await host.idle(20);
    await host.sendToken(13, 0, 0);
    await host.idle(2);
    await host.sendData(3, getDescriptor);
    final ack = await host.waitPacket();
    expect(ack?.pid, equals(2), reason: 'the SETUP itself clears the stall');

    final status = await waitOutReady(dut, clk, 0);
    expect(status & 0x1, equals(1));
    expect((status >> 1) & 0x1, equals(1), reason: 'is SETUP');
    expect((status >> 8) & 0xFF, equals(8));
    final bytes = <int>[];
    for (var i = 0; i < 8; i++) {
      bytes.add(await dut.read(clk, epAddr(0, outDataOff)));
    }
    expect(bytes, equals(getDescriptor));
    await dut.write(clk, epAddr(0, outAckOff), status);

    await Simulator.endSimulation();
  });

  test(
    'a SETUP clears an EP0 IN-only stall for its own data stage IN',
    () async {
      final (dut, host, clk, _, _) = await buildUsbControllerHarness();
      await dut.write(clk, ctrlAddr, 0x3);

      // enable, stall IN only.
      await dut.write(clk, epAddr(0, cfgOff), 0x11);

      await host.sendToken(9, 0, 0);
      final stalled = await host.waitPacket();
      expect(stalled?.pid, equals(14), reason: 'the stall is in effect');

      await host.idle(20);
      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, getDescriptor);
      final setupAck = await host.waitPacket();
      expect(setupAck?.pid, equals(2));
      final status = await waitOutReady(dut, clk, 0);
      await dut.write(clk, epAddr(0, outAckOff), status);

      // Arm the response and poll with IN: it must not see the old stall.
      for (final b in [1, 2]) {
        await dut.write(clk, epAddr(0, inDataOff), b);
      }
      await dut.write(clk, epAddr(0, inCommitOff), 1);

      await host.idle(20);
      await host.sendToken(9, 0, 0);
      final data = await host.waitPacket();
      expect(data?.pid, equals(11), reason: 'DATA1, not a stale STALL');
      expect(data!.payload, equals([1, 2]));

      await Simulator.endSimulation();
    },
  );

  test('a SETUP-cleared stall also clears the EP_CFG register bits', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);

    await dut.write(clk, epAddr(0, cfgOff), 0x19);
    await host.sendToken(13, 0, 0);
    await host.idle(2);
    await host.sendData(3, getDescriptor);
    expect((await host.waitPacket())?.pid, equals(2));
    final status = await waitOutReady(dut, clk, 0);
    await dut.write(clk, epAddr(0, outAckOff), status);

    final cfg = await dut.read(clk, epAddr(0, cfgOff));
    expect(cfg & 0x08, equals(0), reason: 'stall OUT reads back clear');
    expect(cfg & 0x10, equals(0), reason: 'stall IN reads back clear');

    await Simulator.endSimulation();
  });

  test(
    'a new stall written after a clearing SETUP still takes effect',
    () async {
      final (dut, host, clk, _, _) = await buildUsbControllerHarness();
      await dut.write(clk, ctrlAddr, 0x3);

      await dut.write(clk, epAddr(0, cfgOff), 0x10);
      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, getDescriptor);
      expect((await host.waitPacket())?.pid, equals(2));
      final status = await waitOutReady(dut, clk, 0);
      await dut.write(clk, epAddr(0, outAckOff), status);

      // Give the auto-clear time to settle, then the driver stalls again.
      await host.idle(50);
      await dut.write(clk, epAddr(0, cfgOff), 0x11);

      await host.sendToken(9, 0, 0);
      final pkt = await host.waitPacket();
      expect(pkt?.pid, equals(14), reason: 'the newer write wins');

      await Simulator.endSimulation();
    },
  );
}

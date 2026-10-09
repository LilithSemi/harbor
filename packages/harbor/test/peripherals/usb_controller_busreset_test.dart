import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('a bus reset leaves every crossing aligned and raises only the '
      'reset event', () async {
    final (dut, host, clk, dp, dm) = await buildUsbControllerHarness(
      maxSimTime: 4000000,
    );
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, addrAddr, 0);

    // Leave state in every crossing: a part-read OUT packet, IN bytes
    // with no commit, and one SOF.
    await host.sendToken(1, 0, 0);
    await host.idle(2);
    await host.sendData(3, [1, 2, 3, 4]);
    expect((await host.waitPacket())?.pid, equals(2));
    await waitOutReady(dut, clk, 0);
    for (var i = 0; i < 3; i++) {
      await dut.read(clk, epAddr(0, outDataOff));
    }
    for (final b in [0xA1, 0xA2, 0xA3, 0xA4, 0xA5]) {
      await dut.write(clk, epAddr(1, inDataOff), b);
    }
    await host.sendToken(5, 0x23, 0x2);
    await host.idle(20);
    await dut.write(clk, intStatusAddr, 0xFFFFFFFF);
    await dut.write(clk, intEnableAddr, 0x1);

    dp.inject(0);
    dm.inject(0);
    await dut.output('interrupt').nextPosedge;

    // Action-channel accesses while the engine is held in reset complete.
    expect(await dut.read(clk, statusAddr) & 0x1, equals(1));
    await dut.write(clk, addrAddr, 9);
    expect(await dut.read(clk, epAddr(0, outDataOff)), equals(0));
    await dut.write(clk, epAddr(2, inCommitOff), 1);

    dp.inject(1);
    dm.inject(0);
    await host.idle(20);

    expect(
      await dut.read(clk, intStatusAddr),
      equals(0x1),
      reason: 'the bus reset is the only event',
    );
    expect(await dut.read(clk, statusAddr) & 0x1, equals(0));
    expect(await dut.read(clk, addrAddr), equals(0));
    expect(await dut.read(clk, epAddr(0, outStatOff)) & 0x1, equals(0));
    await dut.write(clk, intStatusAddr, 0x1);

    // A SETUP after the reset reads back unshifted.
    const setup = [0x80, 6, 0, 1, 0, 0, 18, 0];
    await host.sendToken(13, 0, 0);
    await host.idle(2);
    await host.sendData(3, setup);
    expect((await host.waitPacket())?.pid, equals(2));
    final stat = await waitOutReady(dut, clk, 0);
    expect((stat >> 8) & 0xFF, equals(8));
    final bytes = <int>[];
    for (var i = 0; i < 8; i++) {
      bytes.add(await dut.read(clk, epAddr(0, outDataOff)));
    }
    expect(bytes, equals(setup));
    await dut.write(clk, epAddr(0, outAckOff), stat);

    // EP1 sends only the bytes pushed after the reset.
    for (final b in [7, 8, 9]) {
      await dut.write(clk, epAddr(1, inDataOff), b);
    }
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    final pkt = await host.waitPacket();
    expect(pkt?.pid, equals(3));
    expect(pkt!.payload, equals([7, 8, 9]));
    await host.idle(2);
    await host.sendHandshake(2);

    // The IN_COMMIT written during the reset armed nothing.
    await host.idle(20);
    await host.sendToken(9, 0, 2);
    expect((await host.waitPacket())?.pid, equals(10));

    await Simulator.endSimulation();
  });

  test(
    'an OUT_ACK with a pre-reset tag after a bus reset is ignored',
    () async {
      final (dut, host, clk, dp, dm) = await buildUsbControllerHarness(
        maxSimTime: 4000000,
      );
      await dut.write(clk, ctrlAddr, 0x3);

      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(3, [1, 2, 3, 4]);
      expect((await host.waitPacket())?.pid, equals(2));
      final statA = await waitOutReady(dut, clk, 0);
      await dut.write(clk, intEnableAddr, 0x1);

      dp.inject(0);
      dm.inject(0);
      await dut.output('interrupt').nextPosedge;
      dp.inject(1);
      dm.inject(0);
      await host.idle(20);

      expect(await dut.read(clk, epAddr(0, outStatOff)) & 0x1, equals(0));
      await dut.write(clk, intStatusAddr, 0x1);

      // Hold a fresh packet, then send the stale OUT_ACK.
      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(3, [9, 9]);
      expect((await host.waitPacket())?.pid, equals(2));
      final statB = await waitOutReady(dut, clk, 0);
      expect(statB & 0x1, equals(1));
      await dut.write(clk, epAddr(0, outAckOff), statA);
      expect(
        await dut.read(clk, epAddr(0, outStatOff)),
        equals(statB),
        reason: 'the pre-reset OUT_ACK does not free the fresh packet',
      );
      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(11, [5]);
      expect(
        (await host.waitPacket())?.pid,
        equals(10),
        reason: 'the fresh packet is still held',
      );

      await dut.write(clk, epAddr(0, outAckOff), statB);
      expect(await dut.read(clk, epAddr(0, outStatOff)) & 0x1, equals(0));

      await Simulator.endSimulation();
    },
  );
}

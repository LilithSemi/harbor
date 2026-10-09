import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';
import 'usb_test_host.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<int?> sendOut(
    UsbTestHost host,
    int addr,
    int pid,
    List<int> data,
  ) async {
    await host.sendToken(1, addr, 0);
    await host.idle(2);
    await host.sendData(pid, data);
    final pkt = await host.waitPacket();
    return pkt?.pid;
  }

  test('a packet after a drained one waits for OUT_ACK', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);

    expect(await sendOut(host, 0, 3, [1, 2, 3, 4]), equals(2));
    final statA = await waitOutReady(dut, clk, 0);
    expect((statA >> 8) & 0xFF, equals(4));
    final bytes = <int>[];
    for (var i = 0; i < 4; i++) {
      bytes.add(await dut.read(clk, epAddr(0, outDataOff)));
    }
    expect(bytes, equals([1, 2, 3, 4]));

    // Every byte is read, but OUT_ACK is not written yet.
    expect(
      await sendOut(host, 0, 11, [5, 6, 7]),
      equals(10),
      reason: 'NAK while the drained packet is still held',
    );
    expect(
      await dut.read(clk, epAddr(0, outStatOff)),
      equals(statA),
      reason: 'the held packet is unchanged',
    );

    await dut.write(clk, epAddr(0, outAckOff), statA);
    expect(
      await dut.read(clk, epAddr(0, outStatOff)) & 0x1,
      equals(0),
      reason: 'ready clears before OUT_ACK completes',
    );

    expect(await sendOut(host, 0, 11, [5, 6, 7]), equals(2));
    final statB = await waitOutReady(dut, clk, 0);
    expect((statB >> 8) & 0xFF, equals(3));
    expect((statB >> 4) & 0xF, isNot(equals((statA >> 4) & 0xF)));
    final bytesB = <int>[];
    for (var i = 0; i < 3; i++) {
      bytesB.add(await dut.read(clk, epAddr(0, outDataOff)));
    }
    expect(bytesB, equals([5, 6, 7]));
    await dut.write(clk, epAddr(0, outAckOff), statB);

    await Simulator.endSimulation();
  });

  test('a packet after a ZLP waits for OUT_ACK', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);

    expect(await sendOut(host, 0, 3, const []), equals(2));
    final statZ = await waitOutReady(dut, clk, 0);
    expect((statZ >> 8) & 0xFF, equals(0));

    expect(await sendOut(host, 0, 11, [5, 6, 7]), equals(10));
    await dut.write(clk, epAddr(0, outAckOff), statZ);

    expect(await sendOut(host, 0, 11, [5, 6, 7]), equals(2));
    final statB = await waitOutReady(dut, clk, 0);
    expect((statB >> 8) & 0xFF, equals(3));
    await dut.write(clk, epAddr(0, outAckOff), statB);

    await Simulator.endSimulation();
  });

  test('a second OUT_ACK for the same packet is ignored', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);

    expect(await sendOut(host, 0, 3, [1, 2, 3, 4]), equals(2));
    final statA = await waitOutReady(dut, clk, 0);
    await dut.write(clk, epAddr(0, outAckOff), statA);
    expect(
      await dut.read(clk, epAddr(0, outStatOff)) & 0x1,
      equals(0),
      reason: 'the first OUT_ACK freed it',
    );

    // The next packet lands and is held with a new tag.
    expect(await sendOut(host, 0, 11, [5, 6, 7]), equals(2));
    final statB = await waitOutReady(dut, clk, 0);
    expect((statB >> 4) & 0xF, isNot(equals((statA >> 4) & 0xF)));

    // Repeating the old OUT_ACK does not touch the new packet.
    await dut.write(clk, epAddr(0, outAckOff), statA);
    expect(
      await dut.read(clk, epAddr(0, outStatOff)),
      equals(statB),
      reason: 'the duplicate OUT_ACK is ignored',
    );

    await dut.write(clk, epAddr(0, outAckOff), statB);

    await Simulator.endSimulation();
  });

  test('a stale OUT_ACK does not release the SETUP that preempted its '
      'packet', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);

    expect(await sendOut(host, 0, 3, [1, 2, 3, 4]), equals(2));
    final statA = await waitOutReady(dut, clk, 0);
    expect((statA >> 1) & 0x1, equals(0));

    // The SETUP token starts to overwrite the held packet.
    await host.sendToken(13, 0, 0);
    await host.idle(10);
    expect(
      await dut.read(clk, epAddr(0, outStatOff)) & 0x1,
      equals(0),
      reason: 'ready drops while the SETUP is received',
    );
    const setup = [0x00, 9, 1, 0, 0, 0, 0, 0];
    await host.sendData(3, setup);
    expect((await host.waitPacket())?.pid, equals(2));

    final statS = await waitOutReady(dut, clk, 0);
    expect((statS >> 1) & 0x1, equals(1));
    expect((statS >> 8) & 0xFF, equals(8));

    // The driver acknowledges the packet it saw before the SETUP.
    await dut.write(clk, epAddr(0, outAckOff), statA);
    expect(
      await dut.read(clk, epAddr(0, outStatOff)),
      equals(statS),
      reason: 'the stale OUT_ACK is ignored',
    );

    // An OUT token for the data stage is NAKed and leaves the flags alone.
    expect(await sendOut(host, 0, 11, [1]), equals(10));
    expect(
      await dut.read(clk, epAddr(0, outStatOff)),
      equals(statS),
      reason: 'still flagged as the SETUP',
    );

    final bytes = <int>[];
    for (var i = 0; i < 8; i++) {
      bytes.add(await dut.read(clk, epAddr(0, outDataOff)));
    }
    expect(bytes, equals(setup));
    await dut.write(clk, epAddr(0, outAckOff), statS);
    expect(await dut.read(clk, epAddr(0, outStatOff)) & 0x1, equals(0));

    await Simulator.endSimulation();
  });
}

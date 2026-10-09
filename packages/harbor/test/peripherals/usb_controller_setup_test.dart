import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('CTRL and ADDR registers read back what was written', () async {
    final (dut, _, clk, _, _) = await buildUsbControllerHarness();

    await dut.write(clk, ctrlAddr, 0x3);
    expect(await dut.read(clk, ctrlAddr), equals(0x3));

    await dut.write(clk, addrAddr, 42);
    expect(await dut.read(clk, addrAddr), equals(42));

    await Simulator.endSimulation();
  });

  test('CTRL enable/connect combinations gate usb_pullup', () async {
    final (dut, _, clk, _, _) = await buildUsbControllerHarness();

    await dut.write(clk, ctrlAddr, 0x0);
    expect(dut.output('usb_pullup').value.toInt(), equals(0));

    await dut.write(clk, ctrlAddr, 0x1); // enable only
    expect(dut.output('usb_pullup').value.toInt(), equals(0));

    await dut.write(clk, ctrlAddr, 0x2); // connect only
    expect(dut.output('usb_pullup').value.toInt(), equals(0));

    await dut.write(clk, ctrlAddr, 0x3); // both
    expect(dut.output('usb_pullup').value.toInt(), equals(1));

    await Simulator.endSimulation();
  });

  test('two ADDR writes back to back: the last one wins', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);

    await dut.write(clk, addrAddr, 5);
    await dut.write(clk, addrAddr, 7);
    expect(await dut.read(clk, addrAddr), equals(7));
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    await host.sendToken(13, 5, 0);
    await host.idle(2);
    await host.sendData(3, [0x80, 6, 0, 1, 0, 0, 18, 0]);
    expect(
      await host.waitPacket(maxCycles: 400),
      isNull,
      reason: 'address 5 does not answer',
    );
    expect(await dut.read(clk, epAddr(0, outStatOff)) & 0x1, equals(0));

    await host.idle(20);
    await host.sendToken(13, 7, 0);
    await host.idle(2);
    await host.sendData(3, [0x80, 6, 0, 1, 0, 0, 18, 0]);
    final ack = await host.waitPacket();
    expect(ack, isNotNull);
    expect(ack!.pid, equals(2), reason: 'address 7 answered');

    final status = await waitOutReady(dut, clk, 0);
    await dut.write(clk, epAddr(0, outAckOff), status);

    await Simulator.endSimulation();
  });

  test('a SETUP preempts an armed, unsent EP0 IN packet', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    // Arm a stale IN packet that is never sent.
    for (final b in [9, 9, 9]) {
      await dut.write(clk, epAddr(0, inDataOff), b);
    }
    await dut.write(clk, epAddr(0, inCommitOff), 1);

    // A SETUP preempts both the OUT and IN sides of EP0.
    await host.sendToken(13, 0, 0);
    await host.idle(2);
    await host.sendData(3, [0x80, 6, 0, 1, 0, 0, 18, 0]);
    final setupAck = await host.waitPacket();
    expect(setupAck, isNotNull);
    expect(setupAck!.pid, equals(2));

    var status = await dut.read(clk, epAddr(0, outStatOff));
    var guard = 0;
    while ((status & 0x1) == 0 && guard < 500) {
      await clk.nextPosedge;
      status = await dut.read(clk, epAddr(0, outStatOff));
      guard++;
    }
    expect((status >> 1) & 0x1, equals(1), reason: 'flags the SETUP');
    expect((status >> 8) & 0xFF, equals(8));
    await dut.write(clk, epAddr(0, outAckOff), status);

    // Nothing is armed yet: an IN token now gets a NAK, proving the
    // stale packet was dropped rather than still sendable.
    await host.sendToken(9, 0, 0);
    final nak = await host.waitPacket();
    expect(nak, isNotNull);
    expect(nak!.pid, equals(10), reason: 'NAK, the stale IN is gone');

    // Arm a fresh packet. The host's next IN gets the new data.
    for (final b in [1, 2, 3]) {
      await dut.write(clk, epAddr(0, inDataOff), b);
    }
    await dut.write(clk, epAddr(0, inCommitOff), 1);

    await host.sendToken(9, 0, 0);
    final pkt = await host.waitPacket();
    expect(pkt, isNotNull);
    expect(pkt!.payload, equals([1, 2, 3]), reason: 'the fresh data');

    await Simulator.endSimulation();
  });

  test('a host SETUP lands on EP0', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    final setupDone = host.sendToken(13, 0, 0);
    await setupDone;
    await host.sendData(3, [0x80, 6, 0, 1, 0, 0, 18, 0]);
    await host.idle(100);

    var status = await dut.read(clk, epAddr(0, outStatOff));
    var guard = 0;
    while ((status & 0x1) == 0 && guard < 500) {
      await clk.nextPosedge;
      status = await dut.read(clk, epAddr(0, outStatOff));
      guard++;
    }

    expect(status & 0x1, equals(1), reason: 'packet ready');
    expect((status >> 1) & 0x1, equals(1), reason: 'is SETUP');
    expect((status >> 8) & 0xFF, equals(8), reason: 'SETUP is always 8 bytes');

    final intStatus = await dut.read(clk, intStatusAddr);
    expect((intStatus >> 8) & 0x1, equals(1), reason: 'EP0 OUT ready');

    final bytes = <int>[];
    for (var i = 0; i < 8; i++) {
      bytes.add(await dut.read(clk, epAddr(0, outDataOff)));
    }
    expect(bytes, equals([0x80, 6, 0, 1, 0, 0, 18, 0]));

    await dut.write(clk, epAddr(0, outAckOff), status);

    await Simulator.endSimulation();
  });

  test('ADDR write changes the address the PE answers to', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, addrAddr, 5);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    // SETUP to the new address should land on EP0.
    await host.sendToken(13, 5, 0);
    await host.idle(2);
    await host.sendData(3, [0x80, 6, 0, 1, 0, 0, 18, 0]);
    await host.idle(100);

    var status = await dut.read(clk, epAddr(0, outStatOff));
    var guard = 0;
    while ((status & 0x1) == 0 && guard < 500) {
      await clk.nextPosedge;
      status = await dut.read(clk, epAddr(0, outStatOff));
      guard++;
    }
    expect(status & 0x1, equals(1));
    await dut.write(clk, epAddr(0, outAckOff), status);

    await Simulator.endSimulation();
  });

  test('a SETUP preempts a pending, unread EP0 OUT packet', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    // An OUT lands and is ACKed, but software never reads it.
    await host.sendToken(1, 0, 0);
    await host.idle(2);
    await host.sendData(3, [1, 2, 3, 4]);
    final outAck = await host.waitPacket();
    expect(outAck, isNotNull);
    expect(outAck!.pid, equals(2));

    var status = await dut.read(clk, epAddr(0, outStatOff));
    var guard = 0;
    while ((status & 0x1) == 0 && guard < 500) {
      await clk.nextPosedge;
      status = await dut.read(clk, epAddr(0, outStatOff));
      guard++;
    }
    expect(status & 0x1, equals(1));
    expect((status >> 1) & 0x1, equals(0), reason: 'a plain OUT, not SETUP');

    // Clear the OUT-ready interrupt so the SETUP's own re-raise is visible.
    await dut.write(clk, intStatusAddr, 0x100);
    expect(await dut.read(clk, intStatusAddr) & 0x100, equals(0));

    // A SETUP now preempts the unread OUT: the engine accepts it even
    // though software never drained or ACKed the earlier packet.
    await host.sendToken(13, 0, 0);
    await host.idle(2);
    await host.sendData(3, [0x80, 6, 0, 1, 0, 0, 18, 0]);
    final setupAck = await host.waitPacket();
    expect(setupAck, isNotNull);
    expect(setupAck!.pid, equals(2));

    status = await dut.read(clk, epAddr(0, outStatOff));
    guard = 0;
    while ((status & 0x1) == 0 && guard < 500) {
      await clk.nextPosedge;
      status = await dut.read(clk, epAddr(0, outStatOff));
      guard++;
    }
    expect(status & 0x1, equals(1), reason: 'packet ready');
    expect((status >> 1) & 0x1, equals(1), reason: 'the new SETUP, live');
    expect((status >> 8) & 0xFF, equals(8));

    final intStatus = await dut.read(clk, intStatusAddr);
    expect((intStatus >> 8) & 0x1, equals(1), reason: 'OUT ready raised again');

    final bytes = <int>[];
    for (var i = 0; i < 8; i++) {
      bytes.add(await dut.read(clk, epAddr(0, outDataOff)));
    }
    expect(
      bytes,
      equals([0x80, 6, 0, 1, 0, 0, 18, 0]),
      reason: 'the SETUP bytes, not the stale OUT',
    );

    await dut.write(clk, epAddr(0, outAckOff), status);

    await Simulator.endSimulation();
  });
}

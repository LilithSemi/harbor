import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('EP_CFG stall IN makes the host IN get a STALL', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    // bit4: stall IN.
    await dut.write(clk, epAddr(0, cfgOff), 0x10);

    await host.sendToken(9, 0, 0);
    final pkt = await host.waitPacket();
    expect(pkt, isNotNull);
    expect(pkt!.pid, equals(14), reason: 'STALL');

    await Simulator.endSimulation();
  });

  test('a second OUT before OUT_ACK is NAKed', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    await host.sendToken(1, 0, 0);
    await host.idle(2);
    await host.sendData(3, [1, 2, 3, 4]);
    final ack1 = await host.waitPacket();
    expect(ack1, isNotNull);
    expect(ack1!.pid, equals(2), reason: 'first OUT ACKed');

    // Software has not read OUT_DATA or written OUT_ACK: the engine's own
    // buffer for EP0 is still unread, so a second OUT must be NAKed.
    await host.sendToken(1, 0, 0);
    await host.idle(2);
    await host.sendData(11, [5, 6, 7, 8]);
    final nak = await host.waitPacket();
    expect(nak, isNotNull);
    expect(nak!.pid, equals(10), reason: 'NAK while the buffer is unread');

    final status = await dut.read(clk, epAddr(0, outStatOff));
    expect(status & 0x1, equals(1), reason: 'the first packet is still there');
    expect(
      (status >> 8) & 0xFF,
      equals(4),
      reason: 'the real length, up front',
    );

    final bytes = <int>[];
    for (var i = 0; i < 4; i++) {
      bytes.add(await dut.read(clk, epAddr(0, outDataOff)));
    }
    expect(bytes, equals([1, 2, 3, 4]), reason: 'still the first packet');

    await dut.write(clk, epAddr(0, outAckOff), status);

    await Simulator.endSimulation();
  });

  test('EP_CFG stall OUT makes the host OUT get a STALL', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    // bit3: stall OUT.
    await dut.write(clk, epAddr(0, cfgOff), 0x08);

    await host.sendToken(1, 0, 0);
    await host.idle(2);
    await host.sendData(3, [1, 2, 3, 4]);
    final pkt = await host.waitPacket();
    expect(pkt, isNotNull);
    expect(pkt!.pid, equals(14), reason: 'STALL');

    final status = await dut.read(clk, epAddr(0, outStatOff));
    expect(status & 0x1, equals(0), reason: 'a stalled OUT never lands');

    await Simulator.endSimulation();
  });

  test(
    'an OUT longer than 64 bytes gets no handshake and is dropped',
    () async {
      final (dut, host, clk, _, _) = await buildUsbControllerHarness();
      await dut.write(clk, ctrlAddr, 0x3);

      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(3, List<int>.generate(65, (i) => i));
      expect(await host.waitPacket(maxCycles: 400), isNull);
      expect(await dut.read(clk, epAddr(0, outStatOff)) & 0x1, equals(0));

      // The toggle did not advance, so the retry with DATA0 lands.
      await host.idle(20);
      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(3, [1, 2, 3, 4]);
      expect((await host.waitPacket())?.pid, equals(2));
      final status = await waitOutReady(dut, clk, 0);
      expect((status >> 8) & 0xFF, equals(4));
      await dut.write(clk, epAddr(0, outAckOff), status);

      await Simulator.endSimulation();
    },
  );
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

Logic _findSignal(Module m, String name) {
  for (final s in m.signals) {
    if (s.name == name) return s;
  }
  for (final sub in m.subModules) {
    try {
      return _findSignal(sub, name);
    } on StateError {
      continue;
    }
  }
  throw StateError('no signal $name');
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const getDescriptor = [0x80, 6, 0, 1, 0, 0, 18, 0];

  test('a stall written right after a SETUP is held always wins', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    final held = _findSignal(dut, 'out_ep_held');
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(0, cfgOff), 0x11);

    // Starts an EP_CFG write of 0x11 a set number of bus cycles after
    // EP0 holds the SETUP.
    var delay = 0;
    var count = -1;
    var writing = false;
    var written = false;
    var seen = false;
    host.clk.posedge.listen((_) {
      final h = held.value;
      if (h.isValid && h.toInt() & 1 == 1) seen = true;
    });
    clk.posedge.listen((_) {
      if (seen && count < 0 && !writing && !written) {
        seen = false;
        count = delay;
      }
      if (writing) {
        if (dut.ack.value.isValid && dut.ack.value.toInt() == 1) {
          dut.input('cyc').put(0);
          dut.input('stb').put(0);
          dut.input('we').put(0);
          writing = false;
          written = true;
        }
      } else if (count == 0) {
        count = -1;
        writing = true;
        dut.input('cyc').put(1);
        dut.input('stb').put(1);
        dut.input('we').put(1);
        dut.input('adr').put(epAddr(0, cfgOff));
        dut.input('dat_out').put(0x11);
        dut.input('sel').put(0xF);
      } else if (count > 0) {
        count--;
      }
    });

    for (delay = 0; delay < 6; delay++) {
      written = false;
      seen = false;
      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, getDescriptor);
      expect(
        (await host.waitPacket())?.pid,
        equals(2),
        reason: 'delay $delay: the SETUP is ACKed',
      );
      while (!written) {
        await clk.nextPosedge;
      }
      final status = await waitOutReady(dut, clk, 0);
      await dut.write(clk, epAddr(0, outAckOff), status);

      expect(
        await dut.read(clk, epAddr(0, cfgOff)),
        equals(0x11),
        reason: 'delay $delay: EP_CFG shows the new stall',
      );
      await host.idle(20);
      await host.sendToken(9, 0, 0);
      expect(
        (await host.waitPacket())?.pid,
        equals(14),
        reason: 'delay $delay: the data stage IN stalls',
      );
      await host.idle(20);
    }

    await Simulator.endSimulation();
  });

  test('a SETUP clears the stall of an endpoint typed control', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);

    // EP1: enable, type control, stall OUT and IN.
    await dut.write(clk, epAddr(1, cfgOff), 0x19);
    await host.sendToken(9, 0, 1);
    expect((await host.waitPacket())?.pid, equals(14));

    await host.idle(20);
    await host.sendToken(13, 0, 1);
    await host.idle(2);
    await host.sendData(3, getDescriptor);
    expect((await host.waitPacket())?.pid, equals(2));
    final status = await waitOutReady(dut, clk, 1);
    await dut.write(clk, epAddr(1, outAckOff), status);

    expect(await dut.read(clk, epAddr(1, cfgOff)), equals(0x01));
    await host.idle(20);
    await host.sendToken(9, 0, 1);
    expect((await host.waitPacket())?.pid, equals(10));

    await Simulator.endSimulation();
  });

  test('an EP_CFG stall clear frees the endpoint and resets the toggle '
      'to DATA0', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);

    // Move both toggles to DATA1 first.
    await dut.write(clk, epAddr(1, inDataOff), 0x11);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    expect((await host.waitPacket())?.pid, equals(3));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(20);
    await host.sendToken(1, 0, 1);
    await host.idle(2);
    await host.sendData(3, [1]);
    expect((await host.waitPacket())?.pid, equals(2));
    final stat = await waitOutReady(dut, clk, 1);
    await dut.write(clk, epAddr(1, outAckOff), stat);

    // Halt both directions, then clear with no toggle reset bits.
    await dut.write(clk, epAddr(1, cfgOff), 0x1D);
    await host.idle(20);
    await host.sendToken(9, 0, 1);
    expect((await host.waitPacket())?.pid, equals(14));
    await dut.write(clk, epAddr(1, cfgOff), 0x185);
    expect(await dut.read(clk, epAddr(1, cfgOff)), equals(0x05));

    await dut.write(clk, epAddr(1, inDataOff), 0x22);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.idle(20);
    await host.sendToken(9, 0, 1);
    final pkt = await host.waitPacket();
    expect(pkt?.pid, equals(3), reason: 'IN sends DATA0 after the clear');
    expect(pkt!.payload, equals([0x22]));
    await host.idle(2);
    await host.sendHandshake(2);

    await host.idle(20);
    await host.sendToken(1, 0, 1);
    await host.idle(2);
    await host.sendData(3, [2]);
    expect(
      (await host.waitPacket())?.pid,
      equals(2),
      reason: 'OUT DATA0 is ACKed after the clear',
    );
    final stat2 = await waitOutReady(dut, clk, 1);
    expect((stat2 >> 8) & 0xFF, equals(1), reason: 'the packet is kept');

    await Simulator.endSimulation();
  });
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

Logic _find(Module m, String name) {
  for (final s in m.signals) {
    if (s.name == name) return s;
  }
  for (final sub in m.subModules) {
    try {
      return _find(sub, name);
    } on StateError {
      continue;
    }
  }
  throw StateError('no signal $name');
}

bool _idle(Logic state) => state.value.isValid && state.value.toInt() == 0;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('a packet that does not end hits the IN wait ceiling', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    final xfr = _find(dut, 'in_xfr_state');
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);
    await dut.write(clk, epAddr(1, inDataOff), 0x51);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    expect((await host.waitPacket())?.pid, equals(3));

    // The host sends a long DATA0 in place of the handshake.
    var n = 0;
    var sent = false;
    final send = () async {
      await host.idle(2);
      await host.sendData(3, List.filled(64, 0x5A));
      sent = true;
    }();
    while (n < 4000 && !_idle(xfr)) {
      await host.clk.nextPosedge;
      n++;
    }
    expect(sent, isFalse, reason: 'the wait ends inside the packet');
    expect(n, inInclusiveRange(240, 270), reason: 'IN wait ceiling');
    await send;
    await host.idle(40);

    await host.sendToken(9, 0, 1);
    final retry = await host.waitPacket();
    expect(retry?.pid, equals(3), reason: 'the toggle is unchanged');
    expect(retry!.payload, equals([0x51]));

    await Simulator.endSimulation();
  });

  test('an OUT data packet that does not end hits the ceiling', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    final xfr = _find(dut, 'out_xfr_state');
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);

    await host.sendToken(1, 0, 1);
    var sent = false;
    final send = () async {
      await host.idle(2);
      await host.sendData(3, List.filled(120, 0xFF));
      sent = true;
    }();
    final n = await () async {
      for (var i = 0; i < 50 && _idle(xfr); i++) {
        await host.clk.nextPosedge;
      }
      var c = 0;
      while (c < 8000 && !_idle(xfr)) {
        await host.clk.nextPosedge;
        c++;
      }
      return c;
    }();
    expect(sent, isFalse, reason: 'the wait ends inside the packet');
    expect(n, inInclusiveRange(2640, 2660), reason: 'OUT wait ceiling');
    await send;
    expect(await host.waitPacket(maxCycles: 400), isNull);
    await host.idle(40);
    expect(await dut.read(clk, epAddr(1, outStatOff)) & 0x1, equals(0));

    final full = List.filled(64, 0xFF);
    await host.sendToken(1, 0, 1);
    await host.idle(2);
    await host.sendData(3, full);
    expect((await host.waitPacket())?.pid, equals(2), reason: '64 bytes fit');
    final st = await waitOutReady(dut, clk, 1);
    expect((st >> 8) & 0xFF, equals(64));

    await Simulator.endSimulation();
  });
}

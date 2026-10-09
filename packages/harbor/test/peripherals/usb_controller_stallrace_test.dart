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

bool _hi(Logic l) => l.value.isValid && l.value.toInt() != 0;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // EP1 bulk holds packet A. The driver resets the OUT toggle, then
  // OUT_ACKs A on the same usb cycle as the token of the host's DATA0.
  test('a toggle reset with a held packet does not lose the next packet '
      'when the release meets a token', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    final rel = _find(dut, 'out_release_1');
    final tok = _find(dut, 'out_token_received');
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);

    var cyc = 0;
    int? relAt;
    int? tokAt;
    var same = false;
    host.clk.negedge.listen((_) {
      cyc++;
      final r = _hi(rel);
      final t = _hi(tok);
      if (r) relAt ??= cyc;
      if (t) tokAt ??= cyc;
      if (r && t) same = true;
    });

    var off = 0;
    for (var iter = 0; iter < 16 && !same; iter++) {
      await dut.write(clk, epAddr(1, cfgOff), 0x25);
      await host.idle(20);
      await host.sendToken(1, 0, 1);
      await host.idle(2);
      await host.sendData(3, const [0x11]);
      expect((await host.waitPacket())?.pid, equals(2));
      await host.idle(40);
      final stA = await dut.read(clk, epAddr(1, outStatOff));
      expect(stA & 1, equals(1));
      await dut.write(clk, epAddr(1, cfgOff), 0x25);
      await host.idle(20 + (iter & 1));
      relAt = null;
      tokAt = null;
      final start = cyc;
      final w = () async {
        for (var i = 0; i < off; i++) {
          await host.clk.nextPosedge;
        }
        await dut.write(clk, epAddr(1, outAckOff), stA);
      }();
      await host.sendToken(1, 0, 1);
      await w;
      await host.idle(2);
      await host.sendData(3, const [0x22]);
      final hsB = (await host.waitPacket())?.pid;
      await host.idle(60);
      final stB = await dut.read(clk, epAddr(1, outStatOff));
      if (hsB == 2) {
        expect(stB & 1, equals(1), reason: 'off $off: B was ACKed, so held');
        expect(stB, isNot(equals(stA)), reason: 'off $off: a new tag');
        expect(await dut.read(clk, epAddr(1, outDataOff)), equals(0x22));
        await dut.write(clk, epAddr(1, outAckOff), stB);
      } else {
        expect(hsB, equals(10), reason: 'off $off: B is NAKed while held');
      }
      await host.idle(40);
      if (same) break;
      final d = (tokAt ?? start) - (relAt ?? start);
      off += d == 0 ? 1 : d;
      if (off < 0) off = 0;
    }
    expect(same, isTrue, reason: 'the release met the token cycle');

    await Simulator.endSimulation();
  });

  test('a SETUP to a halted bulk endpoint gets no handshake', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    // EP1: enable, type bulk, stall OUT and IN.
    await dut.write(clk, epAddr(1, cfgOff), 0x1D);

    await host.sendToken(13, 0, 1);
    await host.idle(2);
    await host.sendData(3, const [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(await host.waitPacket(maxCycles: 400), isNull);
    await host.idle(100);
    expect(await dut.read(clk, epAddr(1, outStatOff)) & 0x1, equals(0));
    expect(await dut.read(clk, intStatusAddr) & (1 << 9), equals(0));
    expect(await dut.read(clk, epAddr(1, cfgOff)), equals(0x1D));

    await host.sendToken(1, 0, 1);
    await host.idle(2);
    await host.sendData(3, const [9]);
    expect((await host.waitPacket())?.pid, equals(14));

    await Simulator.endSimulation();
  });

  test(
    'a SETUP to a bulk endpoint is ignored and the next OUT lands',
    () async {
      final (dut, host, clk, _, _) = await buildUsbControllerHarness();
      await dut.write(clk, ctrlAddr, 0x3);
      await dut.write(clk, epAddr(1, cfgOff), 0x05);

      await host.sendToken(13, 0, 1);
      await host.idle(2);
      await host.sendData(3, const [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(await host.waitPacket(maxCycles: 400), isNull);
      await host.idle(100);
      expect(await dut.read(clk, epAddr(1, outStatOff)) & 0x1, equals(0));

      // The toggle is untouched: DATA0 is still next.
      await host.sendToken(1, 0, 1);
      await host.idle(2);
      await host.sendData(3, const [9]);
      expect((await host.waitPacket())?.pid, equals(2));
      final st = await waitOutReady(dut, clk, 1);
      expect(st & 0x3, equals(0x1), reason: 'an OUT, not a SETUP');
      expect(await dut.read(clk, epAddr(1, outDataOff)), equals(9));

      await Simulator.endSimulation();
    },
  );

  test('a SETUP to EP1 right after reset gets no handshake', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    expect(
      await dut.read(clk, epAddr(1, cfgOff)),
      equals(0x04),
      reason: 'EP1 resets to type bulk',
    );
    expect(await dut.read(clk, epAddr(0, cfgOff)), equals(0x00));

    await host.sendToken(13, 0, 1);
    await host.idle(2);
    await host.sendData(3, const [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(await host.waitPacket(maxCycles: 400), isNull);
    await host.idle(100);
    expect(await dut.read(clk, epAddr(1, outStatOff)) & 0x1, equals(0));

    await Simulator.endSimulation();
  });
}

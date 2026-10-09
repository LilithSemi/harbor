import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';
import 'usb_test_host.dart';

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

bool _hi(Logic l) => l.value.isValid && l.value.toInt() & 1 == 1;

/// Records, in usb clock cycles, where an EP_CFG write is applied in the
/// usb domain and where [target] is high.
class _Align {
  final Logic target;
  final Logic opState;
  final Logic? xfrState;
  var cyc = 0;
  int? cfgAt;
  int? targetAt;
  int? xfrAtCfg;
  var same = false;

  _Align(UsbControllerHarness dut, Logic usbClk, String targetName)
    : target = _find(dut, targetName),
      opState = _find(dut, 'op_state_usb_q'),
      xfrState = _find(dut, 'out_xfr_state') {
    usbClk.negedge.listen((_) {
      cyc++;
      final t = _hi(target);
      final c = opState.value.isValid && opState.value.toInt() == 5;
      if (t) targetAt = cyc;
      if (c) {
        cfgAt = cyc;
        final x = xfrState!.value;
        xfrAtCfg = x.isValid ? x.toInt() : -1;
      }
      if (t && c) same = true;
    });
  }

  void clear() {
    cfgAt = null;
    targetAt = null;
    xfrAtCfg = null;
    same = false;
  }
}

const _getDescriptor = [0x80, 6, 0, 1, 0, 0, 18, 0];

/// Sends a SETUP to EP0 while an EP_CFG write of [value] starts [off] usb
/// cycles after the token starts. Returns the SETUP handshake PID.
Future<int?> _setupWithWrite(
  UsbControllerHarness dut,
  Logic clk,
  UsbTestHost host,
  int off,
  int value,
) async {
  final w = () async {
    for (var i = 0; i < off; i++) {
      await host.clk.nextPosedge;
    }
    await dut.write(clk, epAddr(0, cfgOff), value);
  }();
  await host.sendToken(13, 0, 0);
  await host.idle(2);
  await host.sendData(3, _getDescriptor);
  final hs = (await host.waitPacket())?.pid;
  await w;
  await host.idle(50);
  return hs;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test(
    'a stall written during a SETUP transaction does not stall it',
    () async {
      final (dut, host, clk, _, _) = await buildUsbControllerHarness();
      final tok = _find(dut, 'setup_token_received');
      await dut.write(clk, ctrlAddr, 0x3);
      await dut.write(clk, epAddr(0, cfgOff), 0x01);

      var seen = false;
      var fired = false;
      var done = false;
      host.clk.posedge.listen((_) {
        if (_hi(tok)) seen = true;
      });
      clk.posedge.listen((_) {
        if (seen && !fired) {
          fired = true;
          dut.input('cyc').put(1);
          dut.input('stb').put(1);
          dut.input('we').put(1);
          dut.input('adr').put(epAddr(0, cfgOff));
          dut.input('dat_out').put(0x19);
          dut.input('sel').put(0xF);
        } else if (fired && !done && _hi(dut.ack)) {
          done = true;
          dut.input('cyc').put(0);
          dut.input('stb').put(0);
          dut.input('we').put(0);
        }
      });

      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, _getDescriptor);
      expect((await host.waitPacket())?.pid, equals(2), reason: 'SETUP ACK');
      await host.idle(50);
      expect(done, isTrue);

      final st = await dut.read(clk, epAddr(0, outStatOff));
      expect(st & 0x3, equals(0x3), reason: 'the SETUP is held');
      expect(
        await dut.read(clk, epAddr(0, cfgOff)),
        equals(0x01),
        reason: 'a stall written before the SETUP is held is cleared',
      );
      await dut.write(clk, epAddr(0, outAckOff), st);

      await dut.write(clk, epAddr(0, inDataOff), 0x5A);
      await dut.write(clk, epAddr(0, inCommitOff), 1);
      await host.idle(20);
      await host.sendToken(9, 0, 0);
      expect((await host.waitPacket())?.pid, equals(11), reason: 'DATA1');

      await Simulator.endSimulation();
    },
  );

  test('a stall clear on the SETUP token cycle keeps the SETUP', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    final align = _Align(dut, host.clk, 'setup_token_received');
    await dut.write(clk, ctrlAddr, 0x3);

    var off = 130;
    for (var iter = 0; iter < 12 && !align.same; iter++) {
      await dut.write(clk, epAddr(0, cfgOff), 0x19);
      // An odd idle count flips the bus clock phase at the token.
      await host.idle(20 + (iter & 1));
      align.clear();
      final start = align.cyc;
      final hs = await _setupWithWrite(dut, clk, host, off, 0x181);
      final tag = 'off $off';
      expect(hs, equals(2), reason: '$tag: SETUP ACK');

      final st = await dut.read(clk, epAddr(0, outStatOff));
      expect(st & 0x3, equals(0x3), reason: '$tag: the SETUP is held');
      await dut.write(clk, epAddr(0, outAckOff), st);
      await dut.write(clk, epAddr(0, inDataOff), 0x5A);
      await dut.write(clk, epAddr(0, inCommitOff), 1);
      await host.idle(20);
      await host.sendToken(9, 0, 0);
      expect(
        (await host.waitPacket())?.pid,
        equals(11),
        reason: '$tag: the data stage is DATA1',
      );
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      if (align.same) break;
      final d = (align.targetAt ?? start) - (align.cfgAt ?? start);
      off += d == 0 ? 1 : d;
      if (off < 0) off = 0;
    }
    expect(align.same, isTrue, reason: 'the clear met the token cycle');

    await Simulator.endSimulation();
  });

  test('a stall set on the SETUP clear cycle loses to the SETUP', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    final align = _Align(dut, host.clk, 'setup_clear_0');
    await dut.write(clk, ctrlAddr, 0x3);

    var off = 530;
    for (var iter = 0; iter < 12 && !align.same; iter++) {
      await dut.write(clk, epAddr(0, cfgOff), 0x181);
      // An odd idle count flips the bus clock phase at the token.
      await host.idle(20 + (iter & 1));
      align.clear();
      final start = align.cyc;
      final hs = await _setupWithWrite(dut, clk, host, off, 0x19);
      final tag = 'off $off';
      expect(hs, equals(2), reason: '$tag: SETUP ACK');

      final cfg = await dut.read(clk, epAddr(0, cfgOff));
      final st = await dut.read(clk, epAddr(0, outStatOff));
      await host.idle(20);
      if (cfg & 0x18 == 0) {
        expect(st & 0x3, equals(0x3), reason: '$tag: the SETUP is held');
        await dut.write(clk, epAddr(0, outAckOff), st);
        await dut.write(clk, epAddr(0, inDataOff), 0x5A);
        await dut.write(clk, epAddr(0, inCommitOff), 1);
        await host.idle(20);
        await host.sendToken(9, 0, 0);
        expect((await host.waitPacket())?.pid, equals(11), reason: tag);
        await host.idle(2);
        await host.sendHandshake(2);
      } else {
        expect(cfg & 0x18, equals(0x18), reason: '$tag: no torn read');
        expect(align.same, isFalse, reason: '$tag: the SETUP wins a tie');
        await host.sendToken(9, 0, 0);
        expect((await host.waitPacket())?.pid, equals(14), reason: tag);
      }
      await host.idle(50);

      if (align.same) break;
      final d = (align.targetAt ?? start) - (align.cfgAt ?? start);
      off += d == 0 ? 1 : d;
      if (off < 0) off = 0;
    }
    expect(align.same, isTrue, reason: 'the set met the SETUP clear cycle');

    await Simulator.endSimulation();
  });

  test('a stall OUT and IN written after the SETUP is held applies', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(0, cfgOff), 0x01);

    await host.sendToken(13, 0, 0);
    await host.idle(2);
    await host.sendData(3, _getDescriptor);
    expect((await host.waitPacket())?.pid, equals(2));
    final st = await waitOutReady(dut, clk, 0);
    expect(st & 0x3, equals(0x3));

    await dut.write(clk, epAddr(0, cfgOff), 0x19);
    expect(await dut.read(clk, epAddr(0, cfgOff)), equals(0x19));
    expect(
      await dut.read(clk, epAddr(0, outStatOff)),
      equals(st),
      reason: 'a stall keeps the held packet',
    );
    await host.idle(20);
    await host.sendToken(9, 0, 0);
    expect((await host.waitPacket())?.pid, equals(14));
    await host.idle(20);
    await host.sendToken(1, 0, 0);
    await host.idle(2);
    await host.sendData(11, const []);
    expect((await host.waitPacket())?.pid, equals(14));
    await dut.write(clk, epAddr(0, outAckOff), st);

    await Simulator.endSimulation();
  });

  test('a toggle reset during an OUT keeps the ACKed packet', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    final align = _Align(dut, host.clk, 'out_token_received');
    final outTok = _find(dut, 'out_token_received');
    await dut.write(clk, ctrlAddr, 0x3);
    // EP1: enable, type bulk.
    await dut.write(clk, epAddr(1, cfgOff), 0x05);

    var value = 0;
    var seen = false;
    var fired = false;
    host.clk.posedge.listen((_) {
      if (_hi(outTok)) seen = true;
    });
    clk.posedge.listen((_) {
      if (seen && !fired) {
        fired = true;
        dut.input('cyc').put(1);
        dut.input('stb').put(1);
        dut.input('we').put(1);
        dut.input('adr').put(epAddr(1, cfgOff));
        dut.input('dat_out').put(value);
        dut.input('sel').put(0xF);
      } else if (fired && seen && _hi(dut.ack)) {
        seen = false;
        dut.input('cyc').put(0);
        dut.input('stb').put(0);
        dut.input('we').put(0);
      }
    });

    Future<int?> outWithWrite(int v, int pid, List<int> data) async {
      value = v;
      seen = false;
      fired = false;
      align.clear();
      await host.sendToken(1, 0, 1);
      await host.idle(2);
      await host.sendData(pid, data);
      final hs = (await host.waitPacket())?.pid;
      await host.idle(50);
      expect(fired, isTrue);
      expect(align.xfrAtCfg, isNot(0), reason: 'the write lands mid-OUT');
      return hs;
    }

    Future<void> expectHeld(List<int> data) async {
      final st = await dut.read(clk, epAddr(1, outStatOff));
      expect(st & 0x1, equals(1), reason: 'the ACKed packet is held');
      expect((st >> 8) & 0xFF, equals(data.length));
      final bytes = <int>[];
      for (var i = 0; i < data.length; i++) {
        bytes.add(await dut.read(clk, epAddr(1, outDataOff)));
      }
      expect(bytes, equals(data));
      await dut.write(clk, epAddr(1, outAckOff), st);
    }

    Future<void> plainOut(int pid, List<int> data) async {
      await host.sendToken(1, 0, 1);
      await host.idle(2);
      await host.sendData(pid, data);
      expect((await host.waitPacket())?.pid, equals(2));
      await host.idle(50);
      await expectHeld(data);
    }

    // An explicit toggle reset OUT lands while a DATA0 OUT is received.
    expect(await outWithWrite(0x25, 3, [1, 2, 3]), equals(2));
    await expectHeld([1, 2, 3]);
    // The reset then applies: DATA0 is the next expected PID.
    await plainOut(3, [4, 5]);

    // A stall clear lands while the host sends an OUT to the halted
    // endpoint. The host gets STALL or an ACK for a packet that is kept.
    await dut.write(clk, epAddr(1, cfgOff), 0x0D);
    await host.idle(20);
    final hs = await outWithWrite(0x85, 11, [6, 7]);
    if (hs == 2) {
      await expectHeld([6, 7]);
    } else {
      expect(hs, equals(14));
      expect(await dut.read(clk, epAddr(1, outStatOff)) & 0x1, equals(0));
    }
    expect(await dut.read(clk, epAddr(1, cfgOff)), equals(0x05));
    // The clear reset the toggle: DATA0 is next.
    await plainOut(3, [8, 9]);

    await Simulator.endSimulation();
  });
}

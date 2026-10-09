import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';
import 'usb_test_host.dart';

const _inFlushOff = 0x38;

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

/// Keeps the line idle and returns the usb cycles from when [state] leaves
/// 0 until it reads 0 again.
Future<int> _cyclesToIdle(UsbTestHost host, Logic state) async {
  for (var i = 0; i < 50 && _idle(state); i++) {
    await host.idle(1);
  }
  var n = 0;
  while (n < 2000 && !_idle(state)) {
    await host.idle(1);
    n++;
  }
  return n;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('an IN with no handshake times out and stays armed', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    final xfr = _find(dut, 'in_xfr_state');
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);
    await dut.write(clk, epAddr(1, inDataOff), 0x51);
    await dut.write(clk, epAddr(1, inDataOff), 0x52);
    await dut.write(clk, epAddr(1, inCommitOff), 1);

    await host.sendToken(9, 0, 1);
    final a = await host.waitPacket();
    expect(a?.pid, equals(3));
    expect(a!.payload, equals([0x51, 0x52]));

    final n = await _cyclesToIdle(host, xfr);
    expect(n, inInclusiveRange(90, 120), reason: 'turnaround timeout');
    await host.idle(200);
    expect(await dut.read(clk, epAddr(1, inStatOff)), equals(0));
    expect(await dut.read(clk, intStatusAddr) & (1 << 17), equals(0));

    await host.sendToken(9, 0, 1);
    final retry = await host.waitPacket();
    expect(retry?.pid, equals(3), reason: 'the toggle is unchanged');
    expect(retry!.payload, equals([0x51, 0x52]));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(60);
    expect(await dut.read(clk, intStatusAddr) & (1 << 17), isNot(0));
    await dut.write(clk, intStatusAddr, 1 << 17);

    await dut.write(clk, epAddr(1, inDataOff), 0x53);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    final b = await host.waitPacket();
    expect(b?.pid, equals(11));
    expect(b!.payload, equals([0x53]));

    await Simulator.endSimulation();
  });

  test('an IN_FLUSH during a missing handshake acks in bound', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);
    await dut.write(clk, epAddr(1, inDataOff), 0x61);
    await dut.write(clk, epAddr(1, inCommitOff), 1);

    await host.sendToken(9, 0, 1);
    final a = await host.waitPacket();
    expect(a?.pid, equals(3));

    // The host stays silent. The bound is the turnaround timeout (about
    // 54 bus cycles) plus the clock crossings.
    final idle = host.idle(400);
    await clk.nextPosedge;
    dut.input('cyc').put(1);
    dut.input('stb').put(1);
    dut.input('we').put(1);
    dut.input('adr').put(epAddr(1, _inFlushOff));
    dut.input('dat_out').put(1);
    var n = 0;
    while (n < 2000 && !(dut.ack.value.isValid && dut.ack.value.toInt() == 1)) {
      await clk.nextPosedge;
      n++;
    }
    dut.input('cyc').put(0);
    dut.input('stb').put(0);
    dut.input('we').put(0);
    expect(n, lessThan(150), reason: 'the flush acks after the timeout');
    await idle;

    await host.sendToken(9, 0, 1);
    expect((await host.waitPacket())?.pid, equals(10));
    expect(await dut.read(clk, epAddr(1, inStatOff)), equals(0x1));

    await dut.write(clk, epAddr(1, inDataOff), 0x62);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    final b = await host.waitPacket();
    expect(b?.pid, equals(3), reason: 'A was not ACKed, DATA0 again');
    expect(b!.payload, equals([0x62]));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(60);
    expect(await dut.read(clk, intStatusAddr) & (1 << 17), isNot(0));

    await Simulator.endSimulation();
  });

  test('an OUT token with no data packet times out', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    final xfr = _find(dut, 'out_xfr_state');
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);

    await host.sendToken(1, 0, 1);
    final n = await _cyclesToIdle(host, xfr);
    expect(n, inInclusiveRange(90, 120), reason: 'turnaround timeout');
    await host.idle(200);

    await host.sendToken(1, 0, 1);
    await host.idle(2);
    await host.sendData(3, const [9]);
    expect((await host.waitPacket())?.pid, equals(2));
    final st = await waitOutReady(dut, clk, 1);
    expect(st & 0x3, equals(0x1));
    expect(await dut.read(clk, epAddr(1, outDataOff)), equals(9));

    await Simulator.endSimulation();
  });
}

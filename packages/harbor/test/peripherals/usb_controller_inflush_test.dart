import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';
import 'usb_test_host.dart';

const _inFlushOff = 0x38;

Future<void> _push(
  UsbControllerHarness dut,
  Logic clk,
  int ep,
  List<int> bytes,
) async {
  for (final b in bytes) {
    await dut.write(clk, epAddr(ep, inDataOff), b);
  }
}

Future<int?> _in(UsbTestHost host, int ep) async {
  await host.sendToken(9, 0, ep);
  return (await host.waitPacket())?.pid;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('an IN flush drops an armed packet and keeps the toggle', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);

    // A flush with nothing armed acks and changes nothing.
    await dut.write(clk, epAddr(1, _inFlushOff), 1);

    await _push(dut, clk, 1, const [0x10]);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    var pkt = await host.waitPacket();
    expect(pkt?.pid, equals(3));
    expect(pkt!.payload, equals([0x10]));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(60);
    expect(await dut.read(clk, intStatusAddr) & (1 << 17), isNot(0));
    await dut.write(clk, intStatusAddr, 1 << 17);

    await _push(dut, clk, 1, const [0xA1, 0xA2]);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await dut.write(clk, epAddr(1, _inFlushOff), 1);
    await host.idle(20);
    expect(await _in(host, 1), equals(10), reason: 'the endpoint is unarmed');
    await host.idle(20);
    expect(await dut.read(clk, epAddr(1, inStatOff)), equals(0x1));

    await _push(dut, clk, 1, const [0xB1]);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    pkt = await host.waitPacket();
    expect(pkt?.pid, equals(11), reason: 'DATA1: the flush kept the toggle');
    expect(pkt!.payload, equals([0xB1]));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(60);
    expect(await dut.read(clk, intStatusAddr) & (1 << 17), isNot(0));

    await Simulator.endSimulation();
  });

  test('an IN flush drops bytes that were pushed but not committed', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);
    await dut.write(clk, epAddr(2, cfgOff), 0x05);

    // The bytes are in the engine buffer.
    await _push(dut, clk, 1, const [1, 2, 3]);
    await host.idle(20);
    await dut.write(clk, epAddr(1, _inFlushOff), 1);
    await _push(dut, clk, 1, const [4]);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    var pkt = await host.waitPacket();
    expect(pkt?.pid, equals(3));
    expect(pkt!.payload, equals([4]));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(40);

    // The bytes wait in the push FIFO behind an armed packet. Bytes for
    // EP2 behind them stay.
    await _push(dut, clk, 1, const [5]);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await _push(dut, clk, 1, const [6, 7]);
    await _push(dut, clk, 2, const [0x21]);
    await dut.write(clk, epAddr(1, _inFlushOff), 1);
    expect(await _in(host, 1), equals(10), reason: 'the endpoint is unarmed');
    await host.idle(20);

    await _push(dut, clk, 1, const [8]);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    pkt = await host.waitPacket();
    expect(pkt?.pid, equals(11));
    expect(pkt!.payload, equals([8]));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(40);

    await dut.write(clk, epAddr(2, inCommitOff), 1);
    await host.sendToken(9, 0, 2);
    pkt = await host.waitPacket();
    expect(pkt?.pid, equals(3));
    expect(pkt!.payload, equals([0x21]));

    await Simulator.endSimulation();
  });

  test('an IN flush clears a pending IN-done', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);

    await _push(dut, clk, 1, const [0x31]);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    expect((await host.waitPacket())?.pid, equals(3));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(60);
    expect(await dut.read(clk, intStatusAddr) & (1 << 17), isNot(0));
    expect(await dut.read(clk, epAddr(1, inStatOff)), equals(0x3));

    await dut.write(clk, epAddr(1, _inFlushOff), 1);
    expect(await dut.read(clk, intStatusAddr) & (1 << 17), equals(0));
    await host.idle(60);
    expect(await dut.read(clk, intStatusAddr) & (1 << 17), equals(0));
    expect(await dut.read(clk, epAddr(1, inStatOff)), equals(0x1));

    await Simulator.endSimulation();
  });

  test('an IN flush keeps the stall and the OUT side', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);

    await host.sendToken(1, 0, 1);
    await host.idle(2);
    await host.sendData(3, const [0x41]);
    expect((await host.waitPacket())?.pid, equals(2));
    final st = await waitOutReady(dut, clk, 1);

    await dut.write(clk, epAddr(1, cfgOff), 0x15);
    await _push(dut, clk, 1, const [0x42]);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await dut.write(clk, epAddr(1, _inFlushOff), 1);

    expect(await dut.read(clk, epAddr(1, cfgOff)), equals(0x15));
    expect(await _in(host, 1), equals(14), reason: 'the stall stays');
    await host.idle(20);
    expect(await dut.read(clk, epAddr(1, outStatOff)), equals(st));
    expect(await dut.read(clk, epAddr(1, outDataOff)), equals(0x41));

    // After the clear, nothing is armed. The clear resets the IN toggle.
    await dut.write(clk, epAddr(1, cfgOff), 0x105);
    expect(await _in(host, 1), equals(10));
    await host.idle(20);
    await _push(dut, clk, 1, const [0x43]);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    final pkt = await host.waitPacket();
    expect(pkt?.pid, equals(3));
    expect(pkt!.payload, equals([0x43]));

    await Simulator.endSimulation();
  });
}

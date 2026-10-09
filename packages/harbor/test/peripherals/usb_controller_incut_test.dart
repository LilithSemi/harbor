import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';
import 'usb_test_host.dart';

const _inFlushOff = 0x38;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  const k = [0, 1];
  const j = [1, 0];
  const se1 = [1, 1];
  final ackPid = usbEncode([usbPidByte(2)]);
  final cuts = {
    'SYNC and 3 PID bits, then J': (
      [k, j, k, j, k, j, k, k, j, j, k],
      j,
      false,
    ),
    'the full ACK PID, then J': (ackPid.sublist(0, ackPid.length - 3), j, true),
    'SYNC and 3 PID bits, then SE1': (
      [k, j, k, j, k, j, k, k, j, j, k],
      se1,
      false,
    ),
  };
  for (final MapEntry(key: name, value: (head, tail, checkToggle))
      in cuts.entries) {
    test('an IN_FLUSH after a cut handshake ($name) acks in bound', () async {
      await _cutFlush(head, tail, checkToggle: checkToggle);
    });
  }
}

/// Sends IN data, then [head] from the host and holds the line at [tail]
/// with no EOP. An IN_FLUSH must ack in bound. If [checkToggle], a new
/// packet is committed after the flush to confirm the toggle is still
/// DATA0: a wrongly accepted ACK would have flipped it to DATA1.
Future<void> _cutFlush(
  List<List<int>> head,
  List<int> tail, {
  bool checkToggle = false,
}) async {
  final (dut, host, clk, dp, dm) = await buildUsbControllerHarness();
  await dut.write(clk, ctrlAddr, 0x3);
  await dut.write(clk, epAddr(1, cfgOff), 0x05);
  await dut.write(clk, epAddr(1, inDataOff), 0x51);
  await dut.write(clk, epAddr(1, inCommitOff), 1);
  await host.sendToken(9, 0, 1);
  expect((await host.waitPacket())?.pid, equals(3));
  await host.idle(8);

  for (final s in head) {
    for (var t = 0; t < 4; t++) {
      dp.inject(s[0]);
      dm.inject(s[1]);
      await host.clk.nextPosedge;
    }
  }
  dp.inject(tail[0]);
  dm.inject(tail[1]);
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
  expect(n, lessThan(100), reason: 'the receiver ends the cut packet');
  for (var i = 0; i < 200; i++) {
    await host.clk.nextPosedge;
  }
  await host.idle(40);

  await host.sendToken(9, 0, 1);
  expect((await host.waitPacket())?.pid, equals(10));
  expect(await dut.read(clk, intStatusAddr) & (1 << 17), equals(0));

  if (checkToggle) {
    await dut.write(clk, epAddr(1, inDataOff), 0x52);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    final next = await host.waitPacket();
    expect(
      next?.pid,
      equals(3),
      reason: 'a wrongly accepted ACK would give DATA1',
    );
  }

  await Simulator.endSimulation();
}

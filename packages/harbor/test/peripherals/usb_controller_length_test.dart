import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('two back-to-back OUT packets of different lengths, and a ZLP, '
      'report the right lengths', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }

    Future<void> sendOutAndCheckLength(
      int pid,
      List<int> data,
      int expectedLength,
    ) async {
      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(pid, data);
      final ack = await host.waitPacket();
      expect(ack, isNotNull);
      expect(ack!.pid, equals(2));

      final status = await waitOutReady(dut, clk, 0);
      expect(status & 0x1, equals(1));
      expect((status >> 8) & 0xFF, equals(expectedLength));

      final bytes = <int>[];
      for (var i = 0; i < data.length; i++) {
        bytes.add(await dut.read(clk, epAddr(0, outDataOff)));
      }
      expect(bytes, equals(data));
      await dut.write(clk, epAddr(0, outAckOff), status);
    }

    final full = List<int>.generate(64, (i) => i & 0xFF);
    await sendOutAndCheckLength(3, full, 64);
    await sendOutAndCheckLength(11, List<int>.generate(13, (i) => i + 1), 13);
    await sendOutAndCheckLength(3, const [], 0);

    await Simulator.endSimulation();
  });

  test('FRAME reads the frame number of the last SOF', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await dut.write(clk, ctrlAddr, 0x3);

    // A SOF token carries the 11-bit frame number in the address and
    // endpoint fields.
    const frame = 0x5A3;
    await host.sendToken(5, frame & 0x7F, frame >> 7);
    await host.idle(20);
    expect(await dut.read(clk, frameAddr), equals(frame));
    expect((await dut.read(clk, intStatusAddr) >> 1) & 0x1, equals(1));

    // A later token to another address leaves FRAME alone.
    await host.sendToken(9, 0x11, 0);
    await host.idle(20);
    expect(await dut.read(clk, frameAddr), equals(frame));

    await Simulator.endSimulation();
  });
}

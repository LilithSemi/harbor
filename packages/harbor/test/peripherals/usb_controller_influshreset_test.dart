import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

const _inFlushOff = 0x38;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('an IN flush and a bus reset after a missing handshake', () async {
    final (dut, host, clk, dp, dm) = await buildUsbControllerHarness(
      maxSimTime: 4000000,
    );
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, epAddr(1, cfgOff), 0x05);
    await dut.write(clk, intEnableAddr, 0x1);

    await dut.write(clk, epAddr(1, inDataOff), 0x51);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await dut.write(clk, epAddr(1, inDataOff), 0x52);

    // The host takes the data, sends no handshake and starts a bus
    // reset. The flush acks at the turnaround timeout.
    await host.sendToken(9, 0, 1);
    final a = await host.waitPacket();
    expect(a?.pid, equals(3));
    expect(a!.payload, equals([0x51]));

    await clk.nextPosedge;
    dut.input('cyc').put(1);
    dut.input('stb').put(1);
    dut.input('we').put(1);
    dut.input('adr').put(epAddr(1, _inFlushOff));
    dut.input('dat_out').put(1);
    var acked = false;
    var resetSeen = false;
    for (var i = 0; i < 40000 && !acked; i++) {
      await clk.nextPosedge;
      acked = dut.ack.value.isValid && dut.ack.value.toInt() == 1;
      if (i == 0) {
        dp.inject(0);
        dm.inject(0);
      }
      if (_hi(dut.output('interrupt'))) resetSeen = true;
    }
    expect(acked, isTrue, reason: 'the flush acks');
    expect(resetSeen, isFalse, reason: 'the flush acks before the reset');
    dut.input('cyc').put(0);
    dut.input('stb').put(0);
    dut.input('we').put(0);

    if (!resetSeen) await dut.output('interrupt').nextPosedge;
    dp.inject(1);
    dm.inject(0);
    await host.idle(40);
    expect(await dut.read(clk, intStatusAddr), equals(0x1));
    await dut.write(clk, intStatusAddr, 0x1);

    await host.sendToken(9, 0, 1);
    expect((await host.waitPacket())?.pid, equals(10));
    await host.idle(20);
    await dut.write(clk, epAddr(1, inDataOff), 0x53);
    await dut.write(clk, epAddr(1, inCommitOff), 1);
    await host.sendToken(9, 0, 1);
    final b = await host.waitPacket();
    expect(b?.pid, equals(3), reason: 'a bus reset sets DATA0');
    expect(b!.payload, equals([0x53]));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(60);
    expect(await dut.read(clk, intStatusAddr), equals(1 << 17));

    await Simulator.endSimulation();
  });
}

bool _hi(Logic l) => l.value.isValid && l.value.toInt() != 0;

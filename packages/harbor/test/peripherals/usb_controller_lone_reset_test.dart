import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';
import 'usb_test_host.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<int?> sendOut(UsbTestHost host, int pid, List<int> data) async {
    await host.sendToken(1, 0, 0);
    await host.idle(2);
    await host.sendData(pid, data);
    final pkt = await host.waitPacket();
    return pkt?.pid;
  }

  Future<void> pulse(Logic clk, Logic reset, int cycles) async {
    await clk.nextNegedge;
    reset.put(1);
    for (var i = 0; i < cycles; i++) {
      await clk.nextPosedge;
    }
    await clk.nextNegedge;
    reset.put(0);
  }

  // One OUT packet and one IN packet on EP0, both completed, so every
  // crossing toggle and FIFO pointer has moved off its reset value.
  Future<void> exchange(
    UsbControllerHarness dut,
    UsbTestHost host,
    Logic clk,
  ) async {
    await dut.write(clk, ctrlAddr, 0x3);
    expect(await sendOut(host, 3, [1, 2, 3, 4]), equals(2));
    final stat = await waitOutReady(dut, clk, 0);
    for (var i = 0; i < 4; i++) {
      await dut.read(clk, epAddr(0, outDataOff));
    }
    await dut.write(clk, epAddr(0, outAckOff), stat);

    for (final b in [7, 8, 9]) {
      await dut.write(clk, epAddr(0, inDataOff), b);
    }
    await dut.write(clk, epAddr(0, inCommitOff), 1);
    await host.sendToken(9, 0, 0);
    final pkt = await host.waitPacket();
    expect(pkt?.payload, equals([7, 8, 9]));
    await host.idle(2);
    await host.sendHandshake(2);
    await host.idle(50);
  }

  // After the lone reset nothing may look like a new packet, and the next
  // IN packet must hold only the bytes pushed for it.
  Future<void> checkClean(
    UsbControllerHarness dut,
    UsbTestHost host,
    Logic clk,
  ) async {
    for (var i = 0; i < 400; i++) {
      await clk.nextPosedge;
    }
    await dut.write(clk, ctrlAddr, 0x3);
    for (var i = 0; i < 50; i++) {
      await clk.nextPosedge;
    }
    expect(
      await dut.read(clk, epAddr(0, outStatOff)) & 0x1,
      equals(0),
      reason: 'no fake OUT packet',
    );
    expect(
      await dut.read(clk, intStatusAddr) & 0xFFFF00,
      equals(0),
      reason: 'no fake endpoint interrupt',
    );

    for (final b in [0x55, 0x66]) {
      await dut.write(clk, epAddr(0, inDataOff), b);
    }
    await dut.write(clk, epAddr(0, inCommitOff), 1);
    await host.sendToken(9, 0, 0);
    final pkt = await host.waitPacket();
    expect(pkt, isNotNull);
    expect(pkt!.payload, equals([0x55, 0x66]), reason: 'no stale IN bytes');
  }

  test('a lone bus-side reset after an OUT and IN exchange', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness();
    await exchange(dut, host, clk);
    await pulse(clk, dut.input('reset').srcConnection!, 5);
    await checkClean(dut, host, clk);
    await Simulator.endSimulation();
  });

  test('a lone usb_reset after an OUT and IN exchange keeps the driver '
      'registers, detaches, and raises the local reset interrupt', () async {
    // 20 us at 48 MHz is 960 usb_clk cycles of detach.
    final (dut, host, clk, _, _) = await buildUsbControllerHarness(
      localResetDetachUs: 20,
    );
    await exchange(dut, host, clk);
    await dut.write(clk, intEnableAddr, 0x5);
    // EP1: enable, type bulk.
    await dut.write(clk, epAddr(1, cfgOff), 0x5);
    await dut.write(clk, addrAddr, 0x5);
    expect(await dut.read(clk, addrAddr), equals(0x5));
    expect(dut.output('usb_pullup').value.toInt(), equals(1));

    await pulse(host.clk, host.reset, 10);
    var lowCycles = 0;
    while (dut.output('usb_pullup').value.toInt() == 0 && lowCycles < 5000) {
      await host.clk.nextPosedge;
      lowCycles++;
    }
    expect(
      lowCycles,
      inInclusiveRange(960, 1060),
      reason: 'the pullup stays off for the detach time, then returns',
    );

    expect(await dut.read(clk, ctrlAddr), equals(0x3), reason: 'CTRL kept');
    expect(await dut.read(clk, intEnableAddr), equals(0x5));
    expect(
      await dut.read(clk, epAddr(1, cfgOff)) & 0x7,
      equals(0x5),
      reason: 'EP_CFG enable and type kept',
    );
    expect(
      await dut.read(clk, intStatusAddr),
      equals(0x5),
      reason: 'only the reset and local reset interrupts are set',
    );
    expect(dut.output('interrupt').value.toInt(), equals(1));
    expect(
      await dut.read(clk, addrAddr),
      equals(0),
      reason: 'ADDR clears, as on a bus reset',
    );

    await dut.write(clk, intStatusAddr, 0x5);
    expect(await dut.read(clk, intStatusAddr), equals(0));
    await checkClean(dut, host, clk);
    await Simulator.endSimulation();
  });
}

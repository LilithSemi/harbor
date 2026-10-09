import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

/// Starts one bus access and returns the bus cycles it took to ack, and
/// the data read.
Future<(int, int)> _access(
  UsbControllerHarness dut,
  Logic clk,
  int address, {
  int? data,
}) async {
  await clk.nextPosedge;
  dut.input('cyc').put(1);
  dut.input('stb').put(1);
  dut.input('we').put(data == null ? 0 : 1);
  dut.input('adr').put(address);
  dut.input('dat_out').put(data ?? 0);
  dut.input('sel').put(0xf);
  var cycles = 0;
  while (!(dut.ack.value.isValid && dut.ack.value.toInt() == 1)) {
    await clk.nextPosedge;
    if (++cycles > 2000)
      throw StateError('no ack at 0x${address.toRadixString(16)}');
  }
  final value = dut.datIn.value.isValid ? dut.datIn.value.toInt() : -1;
  dut.input('cyc').put(0);
  dut.input('stb').put(0);
  dut.input('we').put(0);
  await clk.nextPosedge;
  return (cycles, value);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('the bus side keeps answering through a long local reset', () async {
    final (dut, host, clk, _, _) = await buildUsbControllerHarness(
      localResetDetachUs: 20,
    );
    final usbReset = host.reset;
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, intEnableAddr, 0x5);
    for (var i = 0; i < 20; i++) {
      await clk.nextPosedge;
    }
    await dut.write(clk, intStatusAddr, 0xFFFFFFFF);

    // An IN_COMMIT in flight when the local reset starts.
    await clk.nextPosedge;
    dut.input('cyc').put(1);
    dut.input('stb').put(1);
    dut.input('we').put(1);
    dut.input('adr').put(epAddr(0, inCommitOff));
    dut.input('dat_out').put(1);
    await clk.nextPosedge;
    await host.clk.nextNegedge;
    usbReset.put(1);
    var waited = 0;
    var acks = 0;
    for (; waited < 20; waited++) {
      await clk.nextPosedge;
      if (dut.ack.value.isValid && dut.ack.value.toInt() == 1) {
        acks++;
        break;
      }
    }
    dut.input('cyc').put(0);
    dut.input('stb').put(0);
    dut.input('we').put(0);
    expect(acks, 1, reason: 'the in-flight access acks');
    for (var i = 0; i < 20; i++) {
      await clk.nextPosedge;
      expect(dut.ack.value.toInt(), 0, reason: 'and is not run again');
    }

    // Accesses during the reset all ack within a few cycles.
    const bound = 4;
    var (c, v) = await _access(dut, clk, ctrlAddr);
    expect(c, lessThanOrEqualTo(bound));
    expect(v, 0x3, reason: 'CTRL reads normally');
    (c, v) = await _access(dut, clk, statusAddr);
    expect(c, lessThanOrEqualTo(bound));
    expect(v, 0);
    (c, _) = await _access(dut, clk, epAddr(0, inDataOff), data: 0x77);
    expect(c, lessThanOrEqualTo(bound));
    (c, _) = await _access(dut, clk, epAddr(0, inCommitOff), data: 1);
    expect(c, lessThanOrEqualTo(bound), reason: 'IN_COMMIT acks, no effect');
    (c, v) = await _access(dut, clk, epAddr(0, outDataOff));
    expect(c, lessThanOrEqualTo(bound));
    expect(v, 0, reason: 'a read that needs the USB side reads 0');
    (c, _) = await _access(dut, clk, intEnableAddr, data: 0x7);
    expect(c, lessThanOrEqualTo(bound));
    (c, v) = await _access(dut, clk, intEnableAddr);
    expect(v, 0x7, reason: 'INT_ENABLE writes normally');
    (c, v) = await _access(dut, clk, intStatusAddr);
    expect(v & 0x5, 0, reason: 'INT_STATUS[0] waits for the release');
    expect(dut.output('usb_pullup').value.toInt(), 0);

    for (var i = 0; i < 2000; i++) {
      await host.clk.nextPosedge;
    }
    await host.clk.nextNegedge;
    usbReset.put(0);
    for (var i = 0; i < 20; i++) {
      await clk.nextPosedge;
    }
    expect((await _access(dut, clk, intStatusAddr)).$2, 0x5);
    await dut.write(clk, intStatusAddr, 0x5);

    // No packet was armed: the host gets NAK, not a zero-length packet.
    await host.sendToken(9, 0, 0);
    expect((await host.waitPacket())?.pid, 10, reason: 'NAK');

    // After the detach the host enumerates again from address 0.
    var guard = 0;
    while (dut.output('usb_pullup').value.toInt() == 0 && guard++ < 5000) {
      await host.clk.nextPosedge;
    }
    expect(dut.output('usb_pullup').value.toInt(), 1, reason: 'reconnected');
    final setAddr = <int>[0x00, 0x05, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00];
    await host.sendToken(13, 0, 0);
    await host.idle(2);
    await host.sendData(3, setAddr);
    expect((await host.waitPacket())?.pid, 2, reason: 'SETUP ACKed');
    final stat = await waitOutReady(dut, clk, 0);
    expect(stat & 0x3, 0x3, reason: 'a SETUP is held');
    expect((stat >> 8) & 0xFF, 8);
    final got = <int>[
      for (var i = 0; i < 8; i++) await dut.read(clk, epAddr(0, outDataOff)),
    ];
    expect(got, setAddr);

    await Simulator.endSimulation();
  });
}

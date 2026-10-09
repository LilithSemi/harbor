import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

/// Sends the host ACK so its first K lands [bits] bit times after the
/// device's SE0 to J edge. Returns the gap in bit times and whether the
/// IN-done for the packet is set. When the ACK is late, also checks that a
/// retry IN sends the same packet with the same toggle.
Future<(double, bool)> _ackAt(int bits) async {
  final (dut, host, clk, dp, dm) = await buildUsbControllerHarness();
  var cyc = 0;
  int? jCycle;
  int? kCycle;
  var prevSe0 = false;
  host.clk.posedge.listen((_) {
    cyc++;
    final oe = dut.output('oe').value;
    final dpo = dut.output('dp_out').value;
    final dmo = dut.output('dm_out').value;
    if (oe.isValid && oe.toInt() == 1 && dpo.isValid && dmo.isValid) {
      final se0 = dpo.toInt() == 0 && dmo.toInt() == 0;
      final j = dpo.toInt() == 1 && dmo.toInt() == 0;
      if (prevSe0 && j) jCycle = cyc;
      prevSe0 = se0;
    }
    if (jCycle != null && kCycle == null) {
      final a = dp.value;
      final b = dm.value;
      if (a.isValid && b.isValid && a.toInt() == 0 && b.toInt() == 1) {
        kCycle = cyc;
      }
    }
  });
  await dut.write(clk, ctrlAddr, 0x3);
  await dut.write(clk, epAddr(1, cfgOff), 0x05);
  await dut.write(clk, epAddr(1, inDataOff), 0x51);
  await dut.write(clk, epAddr(1, inCommitOff), 1);
  await host.sendToken(9, 0, 1);
  expect((await host.waitPacket())?.pid, equals(3));
  for (var g = 0; jCycle == null && g < 100; g++) {
    await host.idle(1);
  }
  final target = jCycle! + bits * 4;
  while (cyc < target - 1) {
    await host.idle(1);
  }
  await host.sendHandshake(2);
  await host.idle(80);
  final gap = (kCycle! - jCycle!) / 4;
  final got = (await dut.read(clk, intStatusAddr) & (1 << 17)) != 0;
  if (!got) {
    await host.sendToken(9, 0, 1);
    final retry = await host.waitPacket();
    expect(retry?.pid, equals(3), reason: 'the toggle is unchanged');
    expect(retry!.payload, equals([0x51]));
  }
  await Simulator.endSimulation();
  return (gap, got);
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  for (final (bits, accept) in [(16, true), (17, true), (18, false)]) {
    test('a host ACK at $bits bit times', () async {
      final (gap, got) = await _ackAt(bits);
      expect(gap, closeTo(bits, 0.5));
      expect(got, equals(accept));
    });
  }
}

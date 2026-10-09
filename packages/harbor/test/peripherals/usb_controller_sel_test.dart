import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('byte and halfword stores change only the selected bytes', () async {
    final (dut, _, clk, _, _) = await buildUsbControllerHarness(
      maxSimTime: 200000,
    );

    await dut.write(clk, intEnableAddr, 0x11223344);
    expect(await dut.read(clk, intEnableAddr), equals(0x11223344));

    await dut.write(clk, intEnableAddr, 0xAAAAAAAA, sel: 0x2);
    expect(await dut.read(clk, intEnableAddr), equals(0x1122AA44));

    await dut.write(clk, intEnableAddr, 0xBEEF0000, sel: 0xC);
    expect(await dut.read(clk, intEnableAddr), equals(0xBEEFAA44));

    // CTRL lives in byte 0, so a store to byte 1 does not change it.
    await dut.write(clk, ctrlAddr, 0x3);
    await dut.write(clk, ctrlAddr, 0x0, sel: 0x2);
    expect(await dut.read(clk, ctrlAddr), equals(0x3));

    await Simulator.endSimulation();
  });

  test('an in-window offset past the registers reads 0 and ignores '
      'writes', () async {
    final (dut, _, clk, _, _) = await buildUsbControllerHarness(
      maxSimTime: 200000,
    );

    await dut.write(clk, intEnableAddr, 0x12345678);

    // 0x030 is a hole in the global page, and 0x300 is EP4 on a 4-EP build.
    for (final addr in [0x030, 0x1F8, epAddr(4, cfgOff), 0x3F8]) {
      await dut.write(clk, addr, 0xFFFFFFFF);
      expect(
        await dut.read(clk, addr),
        equals(0),
        reason: 'read 0x${addr.toRadixString(16)}',
      );
    }
    expect(await dut.read(clk, intEnableAddr), equals(0x12345678));
    expect(await dut.read(clk, ctrlAddr), equals(0));

    await Simulator.endSimulation();
  });

  test('address bits above the window are ignored', () async {
    final (dut, _, clk, _, _) = await buildUsbControllerHarness(
      maxSimTime: 200000,
    );

    // An absolute-address fabric passes the base address bits through.
    await dut.write(clk, 0x10000000 | intEnableAddr, 0x0000BEEF);
    expect(await dut.read(clk, intEnableAddr), equals(0xBEEF));
    expect(await dut.read(clk, 0x10000000 | intEnableAddr), equals(0xBEEF));

    await Simulator.endSimulation();
  });
}

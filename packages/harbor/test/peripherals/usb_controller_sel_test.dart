import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_harness.dart';

void main() {
  for (final kind in HarborFabricKind.values) {
    _registerTests(kind);
  }
}

void _registerTests(HarborFabricKind kind) {
  group('UsbControllerHarness (${kind.name})', () {
    tearDown(() async {
      await Simulator.reset();
    });

    test('byte and halfword stores change only the selected bytes', () async {
      final (dut, _, clk, _, _) = await buildUsbControllerHarness(
        maxSimTime: 200000,
        kind: kind,
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
        kind: kind,
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
        kind: kind,
      );

      // An absolute-address fabric passes the base address bits through.
      await dut.write(clk, 0x10000000 | intEnableAddr, 0x0000BEEF);
      expect(await dut.read(clk, intEnableAddr), equals(0xBEEF));
      expect(await dut.read(clk, 0x10000000 | intEnableAddr), equals(0xBEEF));

      await Simulator.endSimulation();
    });

    test('a write with no byte selected changes nothing', () async {
      final (dut, _, clk, _, _) = await buildUsbControllerHarness(
        maxSimTime: 200000,
        kind: kind,
      );

      await dut.write(clk, intEnableAddr, 0x11223344);
      await dut.write(clk, ctrlAddr, 0x3);

      await dut.write(clk, intEnableAddr, 0xffffffff, sel: 0x0);
      await dut.write(clk, ctrlAddr, 0x0, sel: 0x0);

      expect(await dut.read(clk, intEnableAddr), equals(0x11223344));
      expect(await dut.read(clk, ctrlAddr), equals(0x3));

      await Simulator.endSimulation();
    });

    // OUT_DATA pops one byte on a read (see HarborUsbController), gated by
    // its own lane. On a 64-bit bus the upper 4 bytes of its 8-byte slot
    // are padding and a read of them must not pop a byte.
    test('a read of the padding lane of OUT_DATA does not pop a byte '
        '(64-bit bus)', () async {
      final (dut, host, clk, _, _) = await buildUsbControllerHarness(
        maxSimTime: 200000,
        kind: kind,
        busDataWidth: 64,
      );
      await dut.write(clk, ctrlAddr, 0x3);

      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(3, [0x11, 0x22, 0x33]);
      await host.waitPacket();

      final stat = await waitOutReady(dut, clk, 0);
      expect((stat >> 8) & 0xFF, equals(3));

      await dut.read(clk, epAddr(0, outDataOff), sel: 0xf0);
      expect(
        (await dut.read(clk, epAddr(0, outStatOff)) >> 8) & 0xFF,
        equals(3),
        reason: 'OUT_STAT length unchanged: no byte was popped',
      );

      final bytes = <int>[];
      for (var i = 0; i < 3; i++) {
        bytes.add(await dut.read(clk, epAddr(0, outDataOff), sel: 0x0f));
      }
      expect(bytes, equals([0x11, 0x22, 0x33]));

      await dut.write(clk, epAddr(0, outAckOff), stat);
      await Simulator.endSimulation();
    });
  });
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../peripherals/usb_controller_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('USB sim', () {
    test('write CTRL and read back', () async {
      final (dut, _, clk, _, _) = await buildUsbControllerHarness();

      await dut.write(clk, ctrlAddr, 0x01);
      final val = await dut.read(clk, ctrlAddr);
      expect(val & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('write INT_ENABLE and read back', () async {
      final (dut, _, clk, _, _) = await buildUsbControllerHarness();

      await dut.write(clk, intEnableAddr, 0xA5);
      final val = await dut.read(clk, intEnableAddr);
      expect(val, equals(0xA5));

      await Simulator.endSimulation();
    });

    test('read STATUS register', () async {
      final (dut, _, clk, _, _) = await buildUsbControllerHarness();

      final val = await dut.read(clk, statusAddr);
      // bus reset active should be 0 right after reset.
      expect(val & 0x01, equals(0));

      await Simulator.endSimulation();
    });

    test('write device address (ADDR) and read back', () async {
      final (dut, _, clk, _, _) = await buildUsbControllerHarness();

      await dut.write(clk, addrAddr, 42);
      final val = await dut.read(clk, addrAddr);
      expect(val & 0x7F, equals(42));

      await Simulator.endSimulation();
    });
  });
}

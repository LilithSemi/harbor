import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_device_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbDfu backpressure', () {
    test('a sink holding ready low for long stretches loses no byte', () async {
      final (dut, host, _, _, _) = await buildDfuHarness(
        readyOnCycles: 1,
        readyOffCycles: 20,
      );
      await enumerateDfu(dut, host);

      final watch = watchSink(dut);
      final data = List.generate(40, (i) => (i * 7) & 0xFF);
      final setup = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: data.length,
      );
      final ok = await host.controlWrite(1, setup, data);
      await watch.sub.cancel();

      expect(ok, isTrue);
      expect(watch.bytes, data, reason: 'every byte arrives, in order');

      await Simulator.endSimulation();
    });

    test(
      'an exact 64-byte block with a slow sink loses no byte, in order',
      () async {
        final (dut, host, _, _, _) = await buildDfuHarness(
          readyOnCycles: 1,
          readyOffCycles: 20,
        );
        await enumerateDfu(dut, host);

        final watch = watchSink(dut);
        final data = List.generate(64, (i) => (i * 3 + 1) & 0xFF);
        final setup = dfuSetup(
          dirIn: false,
          bRequest: dfuReqDnload,
          wValue: 0,
          wLength: data.length,
        );
        final ok = await host.controlWrite(1, setup, data);
        await watch.sub.cancel();

        expect(ok, isTrue);
        expect(
          watch.bytes,
          data,
          reason:
              'a full-size (64 byte, one packet) block loses no byte '
              'to a slow sink either',
        );

        await Simulator.endSimulation();
      },
    );
  });
}

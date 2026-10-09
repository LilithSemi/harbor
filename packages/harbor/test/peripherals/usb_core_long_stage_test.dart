import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_core_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbCore data stages past 255 bytes', () {
    test('class OUT with wLength 300 delivers all 300 bytes', () async {
      final (dut, host, _, _, _) = await buildCoreHarness();

      final data = List.generate(300, (i) => (i * 7 + 1) & 0xFF);
      final gotBytes = <int>[];
      var endPulses = 0;
      final validSub = dut.output('out_byte_valid').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) {
          final d = dut.output('out_byte_data').value;
          if (d.isValid) gotBytes.add(d.toInt());
        }
      });
      final endSub = dut.output('out_end_pulse').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) endPulses++;
      });

      final classOut = <int>[0x21, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x01];
      final ok = await host.controlWrite(0, classOut, data);
      await validSub.cancel();
      await endSub.cancel();
      expect(ok, isTrue, reason: 'status ZLP acked');
      expect(gotBytes, data, reason: 'all 300 bytes, in order');
      expect(endPulses, 1, reason: 'ep0_out_end pulses once, at the end');

      await Simulator.endSimulation();
    });

    test('class IN with wLength 200 stops at 200 bytes', () async {
      final (_, host, _, _, _) = await buildCoreHarness(inResponseLength: 255);

      final classIn = <int>[0xA1, 0x02, 0x00, 0x00, 0x00, 0x00, 200, 0x00];
      final got = await host.controlRead(0, classIn);
      expect(got, isNotNull);
      expect(got!.length, 200, reason: 'truncated to wLength');
      expect(got, List.generate(200, (i) => (i + 1) & 0xFF));

      await Simulator.endSimulation();
    });
  });
}

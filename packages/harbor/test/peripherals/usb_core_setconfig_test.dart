import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_core_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // USB 2.0 9.1.1.5: SET_CONFIGURATION puts every interface back to alt
  // setting 0 and clears every endpoint halt and data toggle.
  group('HarborUsbCore SET_CONFIGURATION', () {
    test('resets the alternate setting to 0', () async {
      final (_, host, _, _, _) = await buildCoreHarness();

      final setIntf = <int>[0x01, 0x0B, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
      expect(await host.controlNoData(0, setIntf), isTrue);
      final getIntf = <int>[0x81, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00];
      expect(await host.controlRead(0, getIntf), [1]);

      final setCfg = <int>[0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
      expect(await host.controlNoData(0, setCfg), isTrue);
      expect(await host.controlRead(0, getIntf), [0]);

      await Simulator.endSimulation();
    });

    test('clears a host-set endpoint halt', () async {
      final (_, host, _, _, _) = await buildEp1Harness();

      final setFeature = <int>[0x02, 0x03, 0x00, 0x00, 0x81, 0x00, 0x00, 0x00];
      expect(await host.controlNoData(0, setFeature), isTrue);
      final getStatus = <int>[0x82, 0x00, 0x00, 0x00, 0x81, 0x00, 0x02, 0x00];
      expect(await host.controlRead(0, getStatus), [1, 0]);

      final setCfg = <int>[0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
      expect(await host.controlNoData(0, setCfg), isTrue);
      expect(await host.controlRead(0, getStatus), [0, 0]);

      await host.sendToken(9, 0, 1);
      await host.idle(50);
      final pkt = await host.waitPacket();
      expect(pkt?.pid, 3, reason: 'EP1 IN answers with DATA0, not STALL');
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      await Simulator.endSimulation();
    });
  });
}

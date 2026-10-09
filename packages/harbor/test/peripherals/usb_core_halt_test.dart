import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_core_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbCore', () {
    test(
      'extra endpoints: EP1 moves one OUT packet and one IN packet',
      () async {
        final (dut, host, _, _, _) = await buildEp1Harness();

        final gotBytes = <int>[];
        final sub = dut.output('out_byte_valid').changed.listen((e) {
          if (e.newValue.isValid && e.newValue.toBool()) {
            final d = dut.output('out_byte_data').value;
            if (d.isValid) gotBytes.add(d.toInt());
          }
        });

        // OUT packet on EP1.
        await host.sendToken(1, 0, 1);
        await host.idle(2);
        await host.sendData(3, [0x11, 0x22]);
        await host.idle(100);
        expect(
          (await host.waitPacket())?.pid,
          2,
          reason: 'EP1 OUT packet ACKed',
        );
        await host.idle(50);
        await sub.cancel();
        expect(gotBytes, [
          0x11,
          0x22,
        ], reason: 'EP1 OUT bytes reached the func');

        // IN packet on EP1.
        await host.sendToken(9, 0, 1);
        await host.idle(50);
        final inPkt = await host.waitPacket();
        expect(inPkt?.pid, 3, reason: 'DATA0, the first EP1 IN packet');
        expect(inPkt?.payload, [0x42]);
        await host.idle(2);
        await host.sendHandshake(2);
        await host.idle(50);

        await Simulator.endSimulation();
      },
    );

    test(
      'SET_CONFIGURATION resets EP1 IN data toggle (USB 2.0 9.4.5)',
      () async {
        final (dut, host, _, _, _) = await buildEp1Harness();

        // One EP1 IN packet moves the toggle off its post-reset DATA0, so
        // an un-reset toggle would surface as DATA1 on the next packet
        // instead of the DATA0 that SET_CONFIGURATION requires.
        await host.sendToken(9, 0, 1);
        await host.idle(50);
        final first = await host.waitPacket();
        expect(first?.pid, 3, reason: 'DATA0, the first EP1 IN packet');
        await host.idle(2);
        await host.sendHandshake(2);
        await host.idle(50);

        final setCfg = <int>[0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
        expect(await host.controlNoData(0, setCfg), isTrue);

        await host.sendToken(9, 0, 1);
        await host.idle(50);
        final afterCfg = await host.waitPacket();
        expect(
          afterCfg?.pid,
          3,
          reason: 'SET_CONFIGURATION resets the toggle back to DATA0',
        );
        await host.idle(2);
        await host.sendHandshake(2);
        await host.idle(50);

        await Simulator.endSimulation();
      },
    );

    test('SET_INTERFACE resets EP1 IN data toggle (USB 2.0 9.4.5)', () async {
      final (dut, host, _, _, _) = await buildEp1Harness();

      await host.sendToken(9, 0, 1);
      await host.idle(50);
      final first = await host.waitPacket();
      expect(first?.pid, 3, reason: 'DATA0, the first EP1 IN packet');
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      final setIntf = <int>[0x01, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      expect(await host.controlNoData(0, setIntf), isTrue);

      await host.sendToken(9, 0, 1);
      await host.idle(50);
      final afterIntf = await host.waitPacket();
      expect(
        afterIntf?.pid,
        3,
        reason: 'SET_INTERFACE resets the toggle back to DATA0',
      );
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      await Simulator.endSimulation();
    });

    test('SET_FEATURE/CLEAR_FEATURE(ENDPOINT_HALT) stalls EP1 IN and resets '
        'its toggle', () async {
      final (dut, host, _, _, _) = await buildEp1Harness();

      // wIndex 0x0081 addresses EP1 IN (direction bit set, number 1).
      final setFeature = <int>[0x02, 0x03, 0x00, 0x00, 0x81, 0x00, 0x00, 0x00];
      expect(await host.controlNoData(0, setFeature), isTrue);

      await host.sendToken(9, 0, 1);
      await host.idle(50);
      expect(
        (await host.waitPacket())?.pid,
        14,
        reason: 'EP1 IN STALLs while the host-set halt is active',
      );

      final clearFeature = <int>[
        0x02,
        0x01,
        0x00,
        0x00,
        0x81,
        0x00,
        0x00,
        0x00,
      ];
      expect(await host.controlNoData(0, clearFeature), isTrue);

      await host.sendToken(9, 0, 1);
      await host.idle(50);
      final afterClear = await host.waitPacket();
      expect(
        afterClear?.pid,
        3,
        reason: 'CLEAR_FEATURE un-stalls and resets the toggle to DATA0',
      );
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      await Simulator.endSimulation();
    });

    test(
      'SET_FEATURE(ENDPOINT_HALT) on a nonexistent endpoint STALLs',
      () async {
        final (dut, host, _, _, _) = await buildEp1Harness();

        // wIndex 0x0082 addresses EP2 IN, which this harness never
        // claims (numInEps is 1): the request must STALL, not silently
        // ACK with no effect.
        final setFeature = <int>[
          0x02,
          0x03,
          0x00,
          0x00,
          0x82,
          0x00,
          0x00,
          0x00,
        ];
        expect(
          await host.controlNoData(0, setFeature),
          isFalse,
          reason: 'a halt on an endpoint nothing claims STALLs',
        );

        // The core is back at idle: EP1 IN still answers normally.
        await host.sendToken(9, 0, 1);
        await host.idle(50);
        final pkt = await host.waitPacket();
        expect(pkt?.pid, 3, reason: 'EP1 IN is unaffected, still DATA0');
        await host.idle(2);
        await host.sendHandshake(2);
        await host.idle(50);

        await Simulator.endSimulation();
      },
    );

    test('GET_STATUS(endpoint) reports a function-initiated stall', () async {
      final (dut, host, _, _, _) = await buildEp1Harness(selfStallIn: true);

      // bmRequestType 0x82, bRequest 0 (GET_STATUS), wIndex 0x0081
      // (EP1 IN). No SET_FEATURE is ever sent: the function itself
      // drives in_ep_stall, matching the "halts the endpoint on the
      // wire" behavior GET_STATUS must reflect.
      final getStatus = <int>[0x82, 0x00, 0x00, 0x00, 0x81, 0x00, 0x02, 0x00];
      final status = await host.controlRead(0, getStatus);
      expect(status, [
        1,
        0,
      ], reason: 'halt bit set for a function-initiated stall');

      await Simulator.endSimulation();
    });
  });
}

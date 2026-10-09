import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_core_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbCore', () {
    test('class IN request returns the function bytes', () async {
      final (dut, host, _, _, _) = await buildCoreHarness();

      final classIn = <int>[0xA1, 0x02, 0x00, 0x00, 0x00, 0x00, 64, 0x00];
      final result = await host.controlRead(0, classIn);
      expect(result, [1, 2, 3, 4, 5]);

      await Simulator.endSimulation();
    });

    test('unknown class request STALLs, next SETUP works', () async {
      final (dut, host, _, _, _) = await buildCoreHarness();

      final unknown = <int>[0x40, 0x55, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
      final ok = await host.controlNoData(0, unknown);
      expect(ok, isFalse, reason: 'unknown class request is STALLed');

      final getDevDesc = <int>[0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x40, 0x00];
      final dev = await host.controlRead(0, getDevDesc);
      expect(dev, devDesc, reason: 'the next SETUP works normally');

      await Simulator.endSimulation();
    });

    test('class IN: exact packet boundary sends a trailing ZLP', () async {
      final (dut, host, _, _, _) = await buildCoreHarness(inResponseLength: 64);

      final classIn = <int>[0xA1, 0x02, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00];
      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, classIn);
      await host.idle(100);
      expect((await host.waitPacket())?.pid, 2, reason: 'SETUP ACKed');

      // First IN: a full 64-byte packet.
      await host.sendToken(9, 0, 0);
      await host.idle(50);
      final pkt1 = await host.waitPacket();
      expect(pkt1?.pid, 11, reason: 'DATA1, 64 bytes');
      expect(pkt1?.payload, List.generate(64, (i) => (i + 1) & 0xFF));
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      // Second IN: the trailing ZLP, not a NAK.
      await host.sendToken(9, 0, 0);
      await host.idle(50);
      final pkt2 = await host.waitPacket();
      expect(pkt2?.pid, 3, reason: 'DATA0 ZLP, toggle flipped');
      expect(pkt2?.payload, isEmpty);
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      // Status stage: OUT ZLP.
      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(11, []);
      await host.idle(100);
      expect(
        (await host.waitPacket())?.pid,
        2,
        reason: 'status stage completes',
      );

      await Simulator.endSimulation();
    });

    test('class IN: exact wLength match sends no trailing ZLP', () async {
      final (dut, host, _, _, _) = await buildCoreHarness(inResponseLength: 64);

      final classIn = <int>[0xA1, 0x02, 0x00, 0x00, 0x00, 0x00, 64, 0x00];
      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, classIn);
      await host.idle(100);
      expect((await host.waitPacket())?.pid, 2, reason: 'SETUP ACKed');

      await host.sendToken(9, 0, 0);
      await host.idle(50);
      final pkt1 = await host.waitPacket();
      expect(pkt1?.pid, 11, reason: 'DATA1, 64 bytes');
      expect(pkt1?.payload, List.generate(64, (i) => (i + 1) & 0xFF));
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      // The status stage follows immediately, with no second IN poll:
      // wLength was reached exactly, so no ZLP is queued.
      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(11, []);
      await host.idle(100);
      expect(
        (await host.waitPacket())?.pid,
        2,
        reason: 'status stage completes without a second IN packet',
      );

      // The core is back at idle: a fresh descriptor read still works.
      final getDevDesc = <int>[0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x40, 0x00];
      final dev = await host.controlRead(0, getDevDesc);
      expect(dev, devDesc, reason: 'the device is idle, not stuck');

      await Simulator.endSimulation();
    });

    test('a SETUP in the middle of an IN data stage aborts it too', () async {
      final (dut, host, _, _, _) = await buildCoreHarness(inResponseLength: 64);

      // Same setup as the trailing-ZLP test above: a full 64-byte
      // packet, fully acked, leaves the core still owing a trailing
      // ZLP (needZlp), so it stays in the IN data stage.
      final classIn = <int>[0xA1, 0x02, 0x00, 0x00, 0x00, 0x00, 0xFF, 0x00];
      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, classIn);
      await host.idle(100);
      expect((await host.waitPacket())?.pid, 2, reason: 'SETUP ACKed');

      await host.sendToken(9, 0, 0);
      await host.idle(50);
      final pkt1 = await host.waitPacket();
      expect(pkt1?.pid, 11, reason: 'DATA1, 64 bytes');
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      // The host gives up on the trailing ZLP and the status stage,
      // and sends a new SETUP instead. USB 2.0 8.5.3/9.2.6.4: it must
      // be ACKed and answered, not ignored. Sequenced by hand rather
      // than through controlRead: its SETUP-ack wait is a fixed 500
      // cycles, tighter than this test needs right after the handshake
      // above.
      final getDevDesc = <int>[0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x40, 0x00];
      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, getDevDesc);
      await host.idle(100);
      expect((await host.waitPacket())?.pid, 2, reason: 'new SETUP ACKed');

      await host.sendToken(9, 0, 0);
      await host.idle(50);
      final descPkt = await host.waitPacket();
      expect(
        descPkt?.pid,
        11,
        reason:
            'DATA1: a SETUP always resets the toggle (USB 2.0 8.5.3), '
            'not the stale armed ZLP left over from the aborted stage',
      );
      expect(
        descPkt?.payload,
        devDesc,
        reason:
            'the new SETUP aborts the IN stage and is answered '
            'normally',
      );

      // Status stage: OUT ZLP, to leave the control endpoint idle.
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);
      await host.sendToken(1, 0, 0);
      await host.idle(2);
      await host.sendData(11, []);
      await host.idle(100);
      expect(
        (await host.waitPacket())?.pid,
        2,
        reason: 'status stage completes',
      );

      await Simulator.endSimulation();
    });
  });
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_core_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbCore', () {
    test('class OUT request delivers all bytes in order', () async {
      final (dut, host, _, _, _) = await buildCoreHarness();

      final data = List.generate(70, (i) => i & 0xFF);
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

      final classOut = <int>[0x21, 0x01, 0x00, 0x00, 0x00, 0x00, 70, 0x00];
      final ok = await host.controlWrite(0, classOut, data);
      await validSub.cancel();
      await endSub.cancel();
      expect(ok, isTrue, reason: 'status ZLP acked');
      expect(gotBytes, data, reason: 'all 70 bytes, in order');
      expect(endPulses, 1, reason: 'ep0_out_end pulses exactly once');

      await Simulator.endSimulation();
    });

    test(
      'class OUT: a slow function NAKs the second packet, loses no byte',
      () async {
        final (dut, host, _, _, _) = await buildCoreHarness(
          blockOutReadyCycles: 500,
        );

        final data = List.generate(70, (i) => (i * 3) & 0xFF);
        final gotBytes = <int>[];
        final validSub = dut.output('out_byte_valid').changed.listen((e) {
          if (e.newValue.isValid && e.newValue.toBool()) {
            final d = dut.output('out_byte_data').value;
            if (d.isValid) gotBytes.add(d.toInt());
          }
        });

        final classOut = <int>[0x21, 0x01, 0x00, 0x00, 0x00, 0x00, 70, 0x00];
        final ok = await host.controlWrite(0, classOut, data);
        await validSub.cancel();
        expect(ok, isTrue, reason: 'status ZLP acked once the function drains');
        expect(gotBytes, data, reason: 'no byte lost despite the NAK retries');

        await Simulator.endSimulation();
      },
    );

    test('a SETUP arriving while the function holds ep0_out_ready low aborts '
        'the OUT stage and is answered normally', () async {
      // ep0_out_ready stays low for the rest of the test (well past
      // anything it does): the first packet still lands in the engine's
      // buffer (that is not gated by the function at all), but the
      // function never drains it, so every packet after that is NAKed.
      final (dut, host, _, _, _) = await buildCoreHarness(
        blockOutReadyCycles: 50000,
      );

      var endPulses = 0;
      final endSub = dut.output('out_end_pulse').changed.listen((e) {
        if (e.newValue.isValid && e.newValue.toBool()) endPulses++;
      });

      final data = List.generate(70, (i) => i & 0xFF);
      final classOut = <int>[0x21, 0x01, 0x00, 0x00, 0x00, 0x00, 70, 0x00];
      await host.sendToken(13, 0, 0); // SETUP
      await host.idle(2);
      await host.sendData(3, classOut); // DATA0
      await host.idle(100);
      expect((await host.waitPacket())?.pid, 2, reason: 'SETUP ACKed');

      // The first packet (64 bytes) is accepted into the buffer. The
      // handshake follows quickly once the packet's CRC is checked, so
      // the wait before polling for it must stay short: a long idle
      // here would let `pkt_end` pulse and pass unseen before
      // waitPacket ever starts looking for it (idle() itself never
      // checks pkt_end, only waitPacket() does).
      await host.sendToken(1, 0, 0); // OUT
      await host.idle(2);
      await host.sendData(11, data.sublist(0, 64)); // DATA1
      await host.idle(100);
      expect(
        (await host.waitPacket())?.pid,
        2,
        reason: 'the first packet is ACKed into the buffer',
      );

      // The second packet (the remaining 6 bytes) is NAKed every time:
      // the function never drains the first one, so the buffer stays
      // busy.
      var anyAck = false;
      for (var i = 0; i < 5; i++) {
        await host.sendToken(1, 0, 0); // OUT
        await host.idle(2);
        await host.sendData(3, data.sublist(64)); // DATA0
        await host.idle(100);
        final resp = await host.waitPacket();
        if (resp != null && resp.pid == 2) anyAck = true;
        expect(resp?.pid, 10, reason: 'NAKed while ep0_out_ready is low');
        await host.idle(50);
      }
      expect(anyAck, isFalse, reason: 'the second packet never advances');

      // The host gives up and sends a new SETUP (GET_DESCRIPTOR)
      // instead of finishing the OUT stage. USB 2.0 8.5.3/9.2.6.4: it
      // must be ACKed and answered, not NAKed or ignored like the OUT
      // data above. Sequenced by hand, like the rest of this test,
      // rather than through controlRead: its SETUP-ack wait is a fixed
      // 500 cycles, tighter than this test needs after the retry loop
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
      await endSub.cancel();
      expect(
        descPkt?.payload,
        devDesc,
        reason:
            'the new SETUP aborts the OUT stage and is answered '
            'normally',
      );
      expect(
        endPulses,
        0,
        reason: 'the aborted OUT stage never reached ep0_out_end',
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

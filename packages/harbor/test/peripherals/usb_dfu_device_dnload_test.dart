import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_device_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbDfu DNLOAD', () {
    test('blocks of 64, 64, 17 bytes land on the sink in order, with their '
        'block number and target', () async {
      final (dut, host, _, _, _) = await buildDfuHarness();
      await enumerateDfu(dut, host);

      final watch = watchSink(dut);

      final block0 = List.generate(64, (i) => i & 0xFF);
      final block1 = List.generate(64, (i) => (i + 1) & 0xFF);
      final block2 = List.generate(17, (i) => (i + 2) & 0xFF);

      for (final (block, bytes) in [(0, block0), (1, block1), (2, block2)]) {
        final setup = dfuSetup(
          dirIn: false,
          bRequest: dfuReqDnload,
          wValue: block,
          wLength: bytes.length,
        );
        final ok = await host.controlWrite(1, setup, bytes);
        expect(ok, isTrue, reason: 'DNLOAD block $block status stage acked');

        // DFU 1.1 6.1.2: GETSTATUS is what advances dfuDNLOAD_SYNC to
        // dfuDNLOAD_IDLE, which is required before the next DNLOAD.
        final status = await host.controlRead(
          1,
          dfuSetup(dirIn: true, bRequest: dfuReqGetStatus, wLength: 6),
        );
        expect(status?[4], 5, reason: 'dfuDNLOAD_IDLE after block $block');
      }

      await watch.sub.cancel();
      expect(watch.bytes, [...block0, ...block1, ...block2]);
      expect(watch.blocks, [
        ...List.filled(64, 0),
        ...List.filled(64, 1),
        ...List.filled(17, 2),
      ]);
      expect(watch.targets, List.filled(145, 0));

      await Simulator.endSimulation();
    });

    test('a DNLOAD data stage aborted by a new SETUP (not a clear failure) '
        'goes to dfuERROR with bStatus 0x0F (errSTALLEDPKT)', () async {
      // The sink never takes a byte: ep0_out_ready stays low because
      // the sink itself is slow/unavailable, with no clear watchdog
      // involved at all (clear still acks immediately).
      final (dut, host, _, _, _) = await buildDfuHarness(
        readyOnCycles: 0,
        readyOffCycles: 1,
      );
      await enumerateDfu(dut, host);

      final watch = watchSink(dut);

      // Two packets: the first fills the empty endpoint buffer, so the
      // device may ACK it. The second has no room and must be NAKed. Each
      // is 32 bytes, so wLength stays at wTransferSize.
      final first = List.generate(32, (i) => i & 0xFF);
      final second = List.generate(32, (i) => (i + 32) & 0xFF);
      final dnload = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: first.length + second.length,
      );
      await host.sendToken(13, 1, 0); // SETUP
      await host.idle(2);
      await host.sendData(3, dnload); // DATA0
      expect((await host.waitPacket())?.pid, 2, reason: 'SETUP ACKed');
      await host.idle(50);

      await host.sendToken(1, 1, 0); // OUT
      await host.idle(2);
      await host.sendData(11, first); // DATA1
      expect(
        (await host.waitPacket())?.pid,
        2,
        reason: 'the buffer was empty, so the first packet is kept',
      );
      await host.idle(50);

      for (var i = 0; i < 5; i++) {
        await host.sendToken(1, 1, 0); // OUT
        await host.idle(2);
        await host.sendData(3, second); // DATA0
        expect(
          (await host.waitPacket())?.pid,
          10,
          reason: 'the buffer still holds the first packet, try $i',
        );
        await host.idle(50);
      }

      // The host gives up on this block and polls GETSTATUS instead
      // of finishing the data stage.
      final status = await host.controlRead(
        1,
        dfuSetup(dirIn: true, bRequest: dfuReqGetStatus, wLength: 6),
      );
      expect(status?[4], 10, reason: 'bState dfuERROR');
      expect(
        status?[0],
        0x0F,
        reason:
            'bStatus errSTALLEDPKT: an aborted DNLOAD, not a clear '
            'timeout (which would read 0x0E)',
      );
      await watch.sub.cancel();
      expect(watch.bytes, isEmpty, reason: 'the sink never takes a byte');

      await Simulator.endSimulation();
    });
  });
}

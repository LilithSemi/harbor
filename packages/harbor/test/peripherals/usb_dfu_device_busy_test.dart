import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_dfu_device_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbDfu busy polling', () {
    test('GETSTATUS reports dfuDNBUSY with a nonzero poll timeout while the '
        'sink is busy, then dfuDNLOAD_IDLE once it drops', () async {
      final (dut, host, _, _, _) = await buildDfuHarness(
        busyCyclesAfterEnd: 20000,
      );
      await enumerateDfu(dut, host);

      final blockDone = watchPulses(dut, 'sink_block_done');
      final end = watchPulses(dut, 'sink_end');

      final data = List.generate(10, (i) => i & 0xFF);
      final setup = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: data.length,
      );
      expect(await host.controlWrite(1, setup, data), isTrue);
      expect(
        blockDone.count.value,
        1,
        reason: 'block_done, not end, starts the busy window',
      );
      expect(
        end.count.value,
        0,
        reason: 'end only fires for the zero-length DNLOAD',
      );
      await blockDone.sub.cancel();
      await end.sub.cancel();

      final getStatus = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetStatus,
        wLength: 6,
      );
      final busyStatus = await host.controlRead(1, getStatus);
      expect(busyStatus?[4], 4, reason: 'dfuDNBUSY while the sink writes');
      final pollTimeout =
          (busyStatus![1]) | (busyStatus[2] << 8) | (busyStatus[3] << 16);
      expect(pollTimeout, greaterThan(0));

      await host.idle(20200);

      final idleStatus = await host.controlRead(1, getStatus);
      expect(idleStatus?[4], 5, reason: 'dfuDNLOAD_IDLE once the sink is done');
      final idlePoll =
          (idleStatus![1]) | (idleStatus[2] << 8) | (idleStatus[3] << 16);
      expect(idlePoll, 0);

      await Simulator.endSimulation();
    });

    test('dfuDNBUSY leaves to dfuDNLOAD_SYNC when the poll timeout ends, not '
        'straight to dfuDNLOAD_IDLE', () async {
      final (dut, host, _, _, _) = await buildDfuHarness(
        busyCyclesAfterEnd: 20000,
      );
      await enumerateDfu(dut, host);

      final data = List.generate(10, (i) => i & 0xFF);
      final setup = dfuSetup(
        dirIn: false,
        bRequest: dfuReqDnload,
        wValue: 0,
        wLength: data.length,
      );
      expect(await host.controlWrite(1, setup, data), isTrue);

      final getStatus = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetStatus,
        wLength: 6,
      );
      final busyStatus = await host.controlRead(1, getStatus);
      expect(busyStatus?[4], 4, reason: 'dfuDNBUSY while the sink writes');

      // Let the poll timeout end without issuing another GETSTATUS, so
      // the autonomous leave-DNBUSY transition is what GETSTATE reads.
      await host.idle(20200);

      final getState = dfuSetup(
        dirIn: true,
        bRequest: dfuReqGetState,
        wLength: 1,
      );
      final state = await host.controlRead(1, getState);
      expect(
        state,
        [3],
        reason:
            'DFU 1.1 Table A.1: dfuDNBUSY leaves to dfuDNLOAD_SYNC on its '
            'own; only a GETSTATUS from there decides dfuDNLOAD_IDLE',
      );

      final idleStatus = await host.controlRead(1, getStatus);
      expect(
        idleStatus?[4],
        5,
        reason: 'dfuDNLOAD_IDLE once GETSTATUS finds the sink not busy',
      );

      await Simulator.endSimulation();
    });
  });
}

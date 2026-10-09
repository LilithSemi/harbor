import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_core_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborUsbCore', () {
    test('GET_DESCRIPTOR device and config', () async {
      final (dut, host, _, _, _) = await buildCoreHarness();

      final getDevDesc = <int>[0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x40, 0x00];
      final dev = await host.controlRead(0, getDevDesc);
      expect(dev, devDesc, reason: 'device descriptor');

      final getCfgDesc = <int>[0x80, 0x06, 0x00, 0x02, 0x00, 0x00, 0x09, 0x00];
      final cfg = await host.controlRead(0, getCfgDesc);
      expect(cfg, cfgDescHeader, reason: 'config descriptor, wLength 9');

      await Simulator.endSimulation();
    });

    test('SET_ADDRESS applies only after the status stage', () async {
      final (dut, host, clk, dp, dm) = await buildCoreHarness();

      // Manual SETUP + DATA0 for SET_ADDRESS(5), so the status stage can
      // be inspected before it completes.
      final setAddr = <int>[0x00, 0x05, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00];
      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, setAddr);
      await host.idle(100);
      final setupAck = await host.waitPacket();
      expect(setupAck?.pid, 2, reason: 'device ACKs the SETUP data');

      expect(
        dut.output('dev_addr').value.toInt(),
        0,
        reason: 'address unchanged before the status stage completes',
      );

      await host.sendToken(9, 0, 0);
      await host.idle(50);
      final statusPkt = await host.waitPacket();
      expect(statusPkt?.pid, 11, reason: 'status stage ZLP is DATA1');
      expect(statusPkt?.payload, isEmpty);
      await host.idle(2);
      await host.sendHandshake(2);
      await host.idle(50);

      expect(
        dut.output('dev_addr').value.toInt(),
        5,
        reason: 'address applied after the status stage',
      );

      final getDevDesc = <int>[0x80, 0x06, 0x00, 0x01, 0x00, 0x00, 0x40, 0x00];
      final dev = await host.controlRead(5, getDevDesc);
      expect(dev, devDesc, reason: 'descriptor read works at address 5');

      dp.inject(1);
      dm.inject(0);
      await host.idle(10);
      await Simulator.endSimulation();
    });

    test('SET_CONFIGURATION and GET_CONFIGURATION', () async {
      final (dut, host, _, _, _) = await buildCoreHarness();

      final setCfg = <int>[0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
      final ok = await host.controlNoData(0, setCfg);
      expect(ok, isTrue, reason: 'SET_CONFIGURATION status stage completes');
      expect(dut.output('configured').value.toInt(), 1);

      final getCfg = <int>[0x80, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00];
      final cfgVal = await host.controlRead(0, getCfg);
      expect(cfgVal, [1], reason: 'GET_CONFIGURATION returns 1');

      await Simulator.endSimulation();
    });

    test('SET_INTERFACE applies, GET_INTERFACE reads it back', () async {
      final (dut, host, _, _, _) = await buildCoreHarness();

      final setIntf = <int>[0x01, 0x0B, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
      expect(await host.controlNoData(0, setIntf), isTrue);

      final getIntf = <int>[0x81, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00];
      final altSetting = await host.controlRead(0, getIntf);
      expect(altSetting, [1], reason: 'GET_INTERFACE reads the new setting');

      await Simulator.endSimulation();
    });

    test('SET_INTERFACE to an alt the config does not list STALLs', () async {
      final (_, host, _, _, _) = await buildCoreHarness();

      // Interface 0, alt 2: cfgDesc only declares alt 0 and alt 1.
      final setIntf = <int>[0x01, 0x0B, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00];
      await host.sendToken(13, 0, 0);
      await host.idle(2);
      await host.sendData(3, setIntf);
      await host.idle(100);
      final setupAck = await host.waitPacket();
      expect(setupAck?.pid, 2, reason: 'device ACKs the SETUP data');

      await host.sendToken(9, 0, 0);
      await host.idle(50);
      final status = await host.waitPacket();
      expect(status?.pid, 14, reason: 'unlisted alt setting STALLs');

      final getIntf = <int>[0x81, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00];
      final altSetting = await host.controlRead(0, getIntf);
      expect(altSetting, [0], reason: 'the stalled request never latched');

      await Simulator.endSimulation();
    });

    test('bus reset clears dev_addr and configured', () async {
      final (dut, host, clk, dp, dm) = await buildCoreHarness();

      final setAddr = <int>[0x00, 0x05, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00];
      expect(await host.controlNoData(0, setAddr), isTrue);
      final setCfg = <int>[0x00, 0x09, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00];
      expect(await host.controlNoData(5, setCfg), isTrue);
      expect(dut.output('dev_addr').value.toInt(), 5);
      expect(dut.output('configured').value.toInt(), 1);

      dp.inject(0);
      dm.inject(0);
      for (var i = 0; i < busResetHoldCycles; i++) {
        await clk.nextPosedge;
      }

      // bus_reset is a level, high only while the line stays at SE0
      // past the threshold, so it is read here, before the line goes
      // back to idle. dev_addr and configured stay cleared after.
      expect(dut.output('bus_reset').value.toInt(), 1);

      dp.inject(1);
      dm.inject(0);
      await host.idle(50);

      expect(dut.output('dev_addr').value.toInt(), 0);
      expect(dut.output('configured').value.toInt(), 0);

      await Simulator.endSimulation();
    });

    test(
      'GET_DESCRIPTOR at an exact packet boundary sends a trailing ZLP',
      () async {
        final (dut, host, _, _, _) = await buildCoreHarness();

        final getBoundaryDesc = <int>[
          0x80,
          0x06,
          0x09,
          0x03,
          0x00,
          0x00,
          0xFF,
          0x00,
        ];
        final desc = await host.controlRead(0, getBoundaryDesc);
        expect(
          desc,
          boundaryDesc64,
          reason: 'the ROM path shares the same trailing-ZLP fix',
        );

        await Simulator.endSimulation();
      },
    );
  });
}

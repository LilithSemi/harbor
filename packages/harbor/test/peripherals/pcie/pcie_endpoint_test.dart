import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../support/gtpe2_status_model.dart';
import '../../util/pcie_dma_bench.dart';

void main() {
  tearDown(() async => Simulator.reset());

  Logic bit() => Logic();

  HarborPcieEndpoint endpoint(
    HarborDeviceTarget target, {
    HarborPcieEndpointConfig config = const HarborPcieEndpointConfig(),
    int pipeStages = 1,
  }) => HarborPcieEndpoint(
    target: target,
    refClkP: bit(),
    refClkN: bit(),
    perstN: bit(),
    rxP: bit(),
    rxN: bit(),
    rxReady: bit(),
    txData: Logic(width: 64),
    txKeep: Logic(width: 8),
    txLast: bit(),
    txValid: bit(),
    config: config,
    pipeStages: pipeStages,
  );

  test('rejects targets without an Artix-7 PCIe hard block', () {
    expect(
      () => endpoint(
        const HarborFpgaTarget.ecp5(device: 'lfe5u-85f', package: 'CABGA381'),
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'AX7203 endpoint elaborates as native ROHD and primitive leaves',
    () async {
      final dut = endpoint(
        const HarborFpgaTarget.artix7(
          device: 'xc7a200t',
          package: 'fbg484',
          useOpenXc7: true,
        ),
      );
      await dut.build();
      final sv = dut.generateSynth();
      expect(sv, contains('PCIE_2_1'));
      expect(sv, contains('GTPE2_COMMON'));
      expect(sv, contains('GTPE2_CHANNEL'));
      expect(sv, contains('IBUFDS_GTE2'));
      expect(sv, isNot(contains('GTWESTREFCLK')));
      expect(sv, contains('HarborBram_68x2048'));
      expect(sv, contains('HarborGtpPciePhy_X1_Pipe1'));
      expect(dut.pipeStages, 1);
      expect(sv, contains('HarborBram_69x2048'));
      expect(sv, contains(".VC0_RX_RAM_LIMIT(13'h7FF)"));
      expect(dut.rxData.width, 64);
      expect(dut.rxUser.width, 22);
      expect(dut.completerId.width, 16);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'configures 1024-entry packet SRAM',
    () async {
      final dut = endpoint(
        const HarborFpgaTarget.artix7(
          device: 'xc7a200t',
          package: 'fbg484',
          useOpenXc7: true,
        ),
        config: const HarborPcieEndpointConfig(packetMemoryEntries: 1024),
      );
      await dut.build();
      final sv = dut.generateSynth();
      expect(sv, contains('HarborBram_68x1024'));
      expect(sv, contains('HarborBram_69x1024'));
      expect(sv, contains(".VC0_RX_RAM_LIMIT(13'h3FF)"));
      expect(sv, contains('.DEV_CAP_MAX_PAYLOAD_SUPPORTED(1)'));
      expect(sv, contains('.VC0_TX_LASTPACKET(28)'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'reset status comes from the GTP PHY',
    () async {
      final dut = endpoint(
        const HarborFpgaTarget.artix7(
          device: 'xc7a200t',
          package: 'fbg484',
          useOpenXc7: true,
        ),
      );
      await dut.build();
      // The simulated sequence for these outputs is in gtp_pcie_phy_test.
      // The GT primitives are black boxes, so this test follows the wires.
      List<Logic> path(Logic l) => [
        for (Logic? at = l; at != null; at = at.srcConnection) at,
      ];

      final widths = {
        'mmcm_lock': 1,
        'reset_state': 4,
        'reset_fail_state': 4,
        'reset_retries': 8,
        'link_retrains': 8,
      };
      for (final e in widths.entries) {
        final out = dut.output(e.key);
        expect(out.width, e.value, reason: e.key);
        final phyOut = path(
          out,
        ).where((l) => l.parentModule is HarborGtpPciePhy && l.isOutput);
        expect(phyOut.map((l) => l.name), [e.key], reason: e.key);
      }

      // The watchdog looks at the link up that the endpoint gives out.
      final linkIn = dut.subModules
          .expand((m) => m.subModules)
          .whereType<HarborGtpPciePhy>()
          .single
          .input('hard_link_up');
      expect(path(linkIn), contains(dut.linkUp.srcConnection));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'configures BAR2, MSI vectors and interrupt ports',
    () async {
      final dut = endpoint(
        const HarborFpgaTarget.artix7(
          device: 'xc7a200t',
          package: 'fbg484',
          useOpenXc7: true,
        ),
        config: const HarborPcieEndpointConfig(
          bar2Bytes: 16 << 20,
          msiVectors: 8,
        ),
      );
      await dut.build();
      final sv = dut.generateSynth();
      expect(sv, contains(".BAR2(32'hff00000c)"));
      expect(sv, contains(".BAR3(32'hffffffff)"));
      expect(sv, contains('.MSI_CAP_MULTIMSGCAP(3)'));
      expect(sv, contains('HarborPcieInterrupt'));
      expect(
        dut.definitionName,
        'HarborPcieEndpoint_Xilinx7_X1_Bar2x1000000_Msi8_Pipe1',
      );
      expect(dut.input('irq_pending').width, 8);
      expect(dut.maxPayload.width, 3);
      expect(dut.maxReadRequest.width, 3);
      expect(dut.rcb128.width, 1);
      expect(dut.busMasterEnable.width, 1);
      expect(dut.msiEnable.width, 1);
      expect(dut.msiVectorsGranted.width, 3);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('leaves BAR2 off by default', () async {
    final dut = endpoint(
      const HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
        useOpenXc7: true,
      ),
    );
    await dut.build();
    final sv = dut.generateSynth();
    expect(sv, contains(".BAR2(32'h00000000)"));
    expect(sv, contains(".BAR3(32'h00000000)"));
    expect(sv, contains('.MSI_CAP_MULTIMSGCAP(0)'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('rejects bad BAR2 sizes and MSI vector counts', () {
    const target = HarborFpgaTarget.artix7(
      device: 'xc7a200t',
      package: 'fbg484',
      useOpenXc7: true,
    );
    expect(
      () => endpoint(
        target,
        config: const HarborPcieEndpointConfig(bar2Bytes: 3000),
      ),
      throwsArgumentError,
    );
    expect(
      () => endpoint(
        target,
        config: const HarborPcieEndpointConfig(msiVectors: 3),
      ),
      throwsArgumentError,
    );
  });

  test('passes pipeStages to the PHY', () async {
    final dut = endpoint(
      const HarborFpgaTarget.artix7(
        device: 'xc7a200t',
        package: 'fbg484',
        useOpenXc7: true,
      ),
      pipeStages: 2,
    );
    await dut.build();
    final sv = dut.generateSynth();
    expect(dut.pipeStages, 2);
    expect(dut.definitionName, 'HarborPcieEndpoint_Xilinx7_X1_Pipe2');
    expect(sv, contains('HarborGtpPciePhy_X1_Pipe2'));
    expect(sv, contains('HarborGtpPcieLane_Pipe2'));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('rejects pipeStages other than 0, 1 and 2', () {
    const target = HarborFpgaTarget.artix7(
      device: 'xc7a200t',
      package: 'fbg484',
      useOpenXc7: true,
    );
    for (final n in [-1, 3]) {
      expect(
        () => endpoint(target, pipeStages: n),
        throwsArgumentError,
        reason: '$n',
      );
    }
  });

  test('rejects unsupported packet SRAM depths', () {
    expect(
      () => endpoint(
        const HarborFpgaTarget.artix7(
          device: 'xc7a200t',
          package: 'fbg484',
          useOpenXc7: true,
        ),
        config: const HarborPcieEndpointConfig(packetMemoryEntries: 512),
      ),
      throwsArgumentError,
    );
  });

  test(
    'a link retrain resets the DMA engine through the user reset',
    () async {
      // PCIE_2_1 is a black box. In the hard block, SYSRSTN low holds
      // USERRSTN low. Here the PHY ready drives the reset of the DMA engine
      // in the same way, on the same clock.
      const linkWait = 200;
      final b = await DmaBench.create(const DmaConfig());
      final perstN = Logic(name: 'perst_n')..put(0);
      final link = Logic(name: 'link')..put(0);
      final common = HarborGtpCommonPorts();
      final channels = [HarborGtpChannelPorts()];
      final pipe = HarborPciePipeLane();
      final model = Gtpe2StatusModel(b.clk, common, channels);
      final phy = HarborGtpPciePhy(
        perstN: perstN,
        hardLinkUp: link,
        common: common,
        channels: channels,
        pipes: [pipe],
        clocks: HarborPipeClocks(
          pclk: b.clk,
          userClk1: b.clk,
          userClk2: b.clk,
          mmcmLock: model.mmcmLock,
        ),
        timeouts: const HarborGtpPcieTimeouts(
          pllLock: 100,
          resetDone: 100,
          pmaResetDone: 50,
          mmcmLock: 100,
          txSync: 40,
          rate: 60,
          drp: 20,
          linkWait: linkWait,
        ),
      );
      await phy.build();
      for (final l in [
        pipe.txData,
        pipe.txDataK,
        pipe.txDetectRx,
        pipe.txCompliance,
        pipe.rxPolarity,
        pipe.powerDown,
        pipe.pipeRate,
        pipe.txMargin,
        pipe.txSwing,
        pipe.txDeemph,
      ]) {
        l.inject(0);
      }
      pipe.txElecIdle.inject(1);
      for (final l in phy.internalSignals) {
        if (l.name.startsWith('por_')) l.inject(0);
      }
      bool ready() => phy.phyReady.value.isValid && phy.phyReady.value.toBool();
      int retrains() => phy.linkRetrains!.value.toInt();

      await b.start();
      model.start();
      var running = true;
      var resets = 0;
      unawaited(() async {
        while (running) {
          await b.clk.nextNegedge;
          final r = !ready();
          if (r && b.reset.value.toInt() == 0) resets++;
          b.reset.inject(r ? 1 : 0);
        }
      }());
      await b.cycles(4);
      perstN.inject(1);
      await b.waitUntil(ready, timeout: 2000, what: 'PHY ready');
      link.inject(1);
      await b.cycles(10);

      // One descriptor in progress and one in the queue.
      b.seedHost(0x80000000, 0x1000);
      b.holdCompletions = true;
      await b.setupRing(dmaCplBase, 4);
      await b.enable();
      for (final local in [0x1000, 0x3000]) {
        await b.push(
          hostAddress: 0x80000000,
          localAddress: local,
          length: 0x800,
          deviceToHost: false,
        );
      }
      await b.waitUntil(() => b.reads.isNotEmpty, what: 'first read');
      final busy = await b.readReg(HarborPcieDma.registerStatus);
      expect(busy & HarborPcieDma.statusBusy, isNonZero);
      expect(busy >> HarborPcieDma.statusFreeShift, 63);
      expect(retrains(), 0);

      link.inject(0);
      await b.waitUntil(() => !ready(), timeout: linkWait + 10, what: 'drop');
      expect(retrains(), 1);
      await b.waitUntil(ready, timeout: 2000, what: 'PHY ready again');
      link.inject(1);
      await b.cycles(10);
      expect(resets, 2);
      expect(
        await b.readReg(HarborPcieDma.registerStatus),
        64 << HarborPcieDma.statusFreeShift,
      );
      expect(await b.readReg(HarborPcieDma.registerControl), 0);
      expect(retrains(), 1);
      expect(phy.resetRetries.value.toInt(), 0);
      running = false;
      model.stop();
      await b.finish();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  Logic bit() => Logic();

  HarborPcieEndpoint endpoint(
    HarborDeviceTarget target, {
    HarborPcieEndpointConfig config = const HarborPcieEndpointConfig(),
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
      };
      for (final e in widths.entries) {
        final out = dut.output(e.key);
        expect(out.width, e.value, reason: e.key);
        final phyOut = path(out).where(
          (l) => l.parentModule is HarborGtpPciePhy && l.isOutput,
        );
        expect(phyOut.map((l) => l.name), [e.key], reason: e.key);
      }
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
        'HarborPcieEndpoint_Xilinx7_X1_Bar2x1000000_Msi8',
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
}

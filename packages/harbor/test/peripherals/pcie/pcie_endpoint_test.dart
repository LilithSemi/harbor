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

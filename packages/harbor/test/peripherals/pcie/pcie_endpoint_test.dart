import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  Logic bit() => Logic();

  HarborPcieEndpoint endpoint(HarborDeviceTarget target) => HarborPcieEndpoint(
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
      expect(dut.rxData.width, 64);
      expect(dut.rxUser.width, 22);
      expect(dut.completerId.width, 16);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

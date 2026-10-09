import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_phy_ecp5_harness.dart';

/// [SdramPhyEcp5] against [SdramPinModel]: rising-edge capture (the default
/// config) at both ULX3S clock points, across the board-flight points the
/// corrected capture analysis (see the class doc) says should pass, with
/// the fpga's own tSU/tH margin applied ([sdramPhyCaptureOk]). Every one of
/// the 8 burst beats is checked, not just the first.
void main() {
  tearDown(() async => Simulator.reset());

  void positiveCase(int periodPs, int casLatency, double fpgaToSdramNs) {
    final mhz = periodPs == 8000 ? '125 MHz CL3' : '100 MHz CL2';
    test('$mhz passes at fpgaToSdramNs=$fpgaToSdramNs', () async {
      final tAcNs = casLatency == 3 ? 5.0 : 6.0;
      expect(
        sdramPhyCaptureOk(
          periodPs: periodPs,
          tAcNs: tAcNs,
          fpgaToSdramNs: fpgaToSdramNs,
          phy: const HarborSdramPhyConfig(),
        ),
        isTrue,
        reason: 'test point must itself be inside the margined window',
      );
      final r = await runSdramPhyEcp5Case(
        periodPs: periodPs,
        casLatency: casLatency,
        fpgaToSdramNs: fpgaToSdramNs,
      );
      expect(
        r.beats,
        equals([for (final e in r.expected) LogicValue.ofInt(e, 16)]),
      );
      expect(r.modelErrors, isEmpty);
    });
  }

  group('rising-edge capture, default config', () {
    for (final ns in [2.5, 3.5, 5.0]) {
      positiveCase(8000, 3, ns);
    }
    for (final ns in [4.0, 5.5, 7.0]) {
      positiveCase(10000, 2, ns);
    }
  });
}

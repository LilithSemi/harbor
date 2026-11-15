import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_phy_ecp5_harness.dart';

void main() {
  tearDown(Simulator.reset);

  const config = HarborSdramConfig.as4c16m16sb6();

  for (final edge in HarborSdramCaptureEdge.values) {
    test('40 ns clock, CL2, ${edge.name} capture: the library window check '
        'matches the pin model', () async {
      final phy = HarborSdramPhyConfig(captureEdge: edge);
      final r = await runSdramPhyEcp5Case(
        periodPs: 40000,
        casLatency: 2,
        fpgaToSdramNs: phy.fpgaToSdramNs,
        phy: phy,
      );
      final ok = phy.captureOk(
        clockHz: 25000000,
        config: config,
        casLatency: 2,
      );
      expect(ok, edge == HarborSdramCaptureEdge.falling);
      expect(r.allCorrect, ok, reason: '${r.beats} ${r.modelErrors}');
    });
  }
}

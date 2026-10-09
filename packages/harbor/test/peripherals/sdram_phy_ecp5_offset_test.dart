import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_phy_ecp5_harness.dart';

/// [SdramPhyEcp5] against [SdramPinModel]: `captureCycleOffset: 1` on
/// falling-edge capture, a fallback window for a board too slow for
/// `captureCycleOffset: 0`'s own, lower board-flight window (see the
/// class doc).
void main() {
  tearDown(() async => Simulator.reset());

  const phy = HarborSdramPhyConfig(
    captureEdge: HarborSdramCaptureEdge.falling,
    captureCycleOffset: 1,
  );

  group('falling-edge capture, captureCycleOffset: 1, 125 MHz CL3', () {
    // The chip's own tOH keeps a beat's data valid a whole extra sdram_clk
    // cycle past its own edge, before the next beat's own tAC makes its
    // own data valid, so sampling there instead still reads this beat
    // correctly, at a board flight too large for captureCycleOffset: 0.
    test('passes at fpgaToSdramNs=7.5', () async {
      expect(
        sdramPhyCaptureOk(
          periodPs: 8000,
          tAcNs: 5.0,
          fpgaToSdramNs: 7.5,
          phy: phy,
        ),
        isTrue,
      );
      final r = await runSdramPhyEcp5Case(
        periodPs: 8000,
        casLatency: 3,
        fpgaToSdramNs: 7.5,
        phy: phy,
      );
      expect(
        r.beats,
        equals([for (final e in r.expected) LogicValue.ofInt(e, 16)]),
      );
      expect(r.modelErrors, isEmpty);
    });

    test('fails at fpgaToSdramNs=4.0, below this window', () async {
      expect(
        sdramPhyCaptureOk(
          periodPs: 8000,
          tAcNs: 5.0,
          fpgaToSdramNs: 4.0,
          phy: phy,
        ),
        isFalse,
      );
      final r = await runSdramPhyEcp5Case(
        periodPs: 8000,
        casLatency: 3,
        fpgaToSdramNs: 4.0,
        phy: phy,
      );
      expect(r.allCorrect, isFalse);
    });
  });
}

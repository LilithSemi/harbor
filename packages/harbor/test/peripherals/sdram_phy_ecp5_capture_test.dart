import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_phy_ecp5_harness.dart';

/// [SdramPhyEcp5] against [SdramPinModel]: board flights too early or too
/// late for the capture window to land in (proving both sides of the
/// window check work, per [sdramPhyCaptureOk]), a readLatency off by one
/// cycle either way, and the falling-edge capture variant.
void main() {
  tearDown(() async => Simulator.reset());

  void expectUnreliable(
    String name, {
    required int periodPs,
    required int casLatency,
    required double fpgaToSdramNs,
    HarborSdramPhyConfig phy = const HarborSdramPhyConfig(),
    int sampleOffsetCycles = 0,
  }) {
    test(name, () async {
      final tAcNs = casLatency == 3 ? 5.0 : 6.0;
      if (sampleOffsetCycles == 0) {
        expect(
          sdramPhyCaptureOk(
            periodPs: periodPs,
            tAcNs: tAcNs,
            fpgaToSdramNs: fpgaToSdramNs,
            phy: phy,
          ),
          isFalse,
          reason: 'this point must itself be outside the margined window',
        );
      }
      final r = await runSdramPhyEcp5Case(
        periodPs: periodPs,
        casLatency: casLatency,
        fpgaToSdramNs: fpgaToSdramNs,
        phy: phy,
        sampleOffsetCycles: sampleOffsetCycles,
      );
      expect(r.allCorrect, isFalse);
    });
  }

  group('capture window miss, 125 MHz CL3 rising', () {
    expectUnreliable(
      'too early at fpgaToSdramNs=1.0',
      periodPs: 8000,
      casLatency: 3,
      fpgaToSdramNs: 1.0,
    );
    expectUnreliable(
      'too late at fpgaToSdramNs=7.0',
      periodPs: 8000,
      casLatency: 3,
      fpgaToSdramNs: 7.0,
    );
  });

  group('capture window miss, 100 MHz CL2 rising', () {
    expectUnreliable(
      'too early at fpgaToSdramNs=2.0',
      periodPs: 10000,
      casLatency: 2,
      fpgaToSdramNs: 2.0,
    );
    expectUnreliable(
      'too late at fpgaToSdramNs=9.0',
      periodPs: 10000,
      casLatency: 2,
      fpgaToSdramNs: 9.0,
    );
  });

  group(
    'readLatency off by one cycle, 125 MHz CL3 rising, fpgaToSdramNs=3.5',
    () {
      expectUnreliable(
        'readLatency - 1 fails',
        periodPs: 8000,
        casLatency: 3,
        fpgaToSdramNs: 3.5,
        sampleOffsetCycles: -1,
      );
      expectUnreliable(
        'readLatency + 1 fails',
        periodPs: 8000,
        casLatency: 3,
        fpgaToSdramNs: 3.5,
        sampleOffsetCycles: 1,
      );
    },
  );

  test('falling-edge capture passes at 100 MHz, fpgaToSdramNs=2.5', () async {
    const phy = HarborSdramPhyConfig(
      captureEdge: HarborSdramCaptureEdge.falling,
    );
    expect(
      sdramPhyCaptureOk(
        periodPs: 10000,
        tAcNs: 6.0,
        fpgaToSdramNs: 2.5,
        phy: phy,
      ),
      isTrue,
    );
    final r = await runSdramPhyEcp5Case(
      periodPs: 10000,
      casLatency: 2,
      fpgaToSdramNs: 2.5,
      phy: phy,
    );
    expect(
      r.beats,
      equals([for (final e in r.expected) LogicValue.ofInt(e, 16)]),
    );
    expect(r.modelErrors, isEmpty);
  });
}

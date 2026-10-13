import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_scanout_waist_harness.dart';

// One file per clock: a design built earlier in an isolate slows every later
// simulation in it.
void main() {
  tearDown(Simulator.reset);

  test(
    '125 MHz: 640-pixel lines never underrun while an axi4 port keeps 8 '
    'bursts in flight, and both arbiter ports stay inside their bounds',
    () async {
      final r = await runWaistScanout(
        kind: HarborFabricKind.axi4,
        outstanding: 8,
        memPeriodPs: 8000,
      );
      print(
        '125 MHz: ${r.frames} frames, ${r.underrunFrames} underrun, '
        '${r.bursts} bursts, bus wait ${r.busWait} '
        '(bound ${r.busWaitBound}), scanout wait ${r.scanWait} '
        '(bound ${r.scanWaitBound})',
      );
      expect(r.errors, isEmpty);
      expect(r.underrunFrames, isZero);
      expect(r.busWait, lessThanOrEqualTo(r.busWaitBound));
      expect(r.scanWait, lessThanOrEqualTo(r.scanWaitBound));
    },
    timeout: const Timeout(Duration(hours: 2)),
  );
}

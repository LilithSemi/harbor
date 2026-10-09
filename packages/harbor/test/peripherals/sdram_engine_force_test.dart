import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// Back-to-back traffic with no idle gaps, so refresh happens only when
/// the credit forces it. One postponed refresh is the limit here, and
/// k + p = 14 keeps the schedule inside tREFI.
void main() {
  tearDown(() async => Simulator.reset());

  test('125 MHz: forced refresh under saturating traffic', () async {
    final s = await sdramRandomRun(
      125000000,
      seed: 135,
      requests: 400,
      maxPostponed: 1,
      maxPulledIn: 13,
      gaps: false,
    );
    expect(s.errors, isEmpty);
    // The queue never runs dry, so every refresh past the pull-ins after
    // init needs the credit to force it.
    expect(s.forceEdges, greaterThanOrEqualTo(3));
    expect(s.model.refreshTimesPs.length, greaterThanOrEqualTo(s.forceEdges));
  });
}

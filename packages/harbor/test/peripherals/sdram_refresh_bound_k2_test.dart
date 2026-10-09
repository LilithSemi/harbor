import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_refresh_bound_test.dart' show sdramSaturateRefresh;

void main() {
  tearDown(() async => Simulator.reset());

  test(
    '125 MHz: saturating traffic keeps refresh_owed <= k (k=2, p=12)',
    () async {
      // k + p must stay large enough that 8192 + k + p refreshes still
      // fit tighter than tRefi (HarborSdramCycles enforces this). k=2
      // alone, keeping k small, needs p this large to stay valid.
      await sdramSaturateRefresh(
        125000000,
        30000,
        seed: 202,
        maxPostponed: 2,
        maxPulledIn: 12,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_refresh_bound_test.dart' show sdramSaturateRefresh;

void main() {
  tearDown(() async => Simulator.reset());

  test(
    '100 MHz: saturating traffic keeps refresh_owed <= k',
    () async {
      await sdramSaturateRefresh(100000000, 30000, seed: 203);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

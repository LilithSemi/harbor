import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_refresh_bound_test.dart' show sdramSaturateRefresh;

void main() {
  tearDown(() async => Simulator.reset());

  test(
    '125 MHz: saturating traffic keeps refresh_owed <= k (k=8, p=8)',
    () async {
      await sdramSaturateRefresh(125000000, 30000, seed: 201);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

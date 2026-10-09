import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_thrash_test.dart' show sdramThrashRun;

void main() {
  tearDown(() async => Simulator.reset());

  test('row hits survive 5-cycle gaps and refreshes still run', () async {
    await sdramThrashRun(5);
  });
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_arbiter_test.dart' show sdramTwoPortRun;

void main() {
  tearDown(() async => Simulator.reset());

  test(
    '125 MHz: 2 ports on the same banks, each waits one grant at most',
    () async {
      await sdramTwoPortRun(sharedBanks: true, seed: 401);
    },
  );
}

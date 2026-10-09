import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_wb_fail_cases.dart';
import 'sdram_wb_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('sync: cyc held across ack', () async {
    final s = SdramWbStack(
      sysClockHz: 125000000,
      memClockHz: 125000000,
      busClockSync: true,
    );
    await s.start();
    await heldCycCase(s);
    await s.stop();
    expect(s.errors, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 120)));
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_wb_fail_cases.dart';
import 'sdram_wb_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'async: a memory reset mid-read ends the bus cycle',
    () async {
      final s = SdramWbStack(sysClockHz: 50000000, memClockHz: 125000000);
      await s.start();
      await memResetCase(s);
      await s.stop();
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

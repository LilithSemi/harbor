import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_wb_fail_cases.dart';
import 'sdram_wb_stack.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'async posted: a bus reset after a write keeps every taken word',
    () async {
      final s = SdramWbStack(
        sysClockHz: 50000000,
        memClockHz: 125000000,
        postedWrites: true,
      );
      await s.start();
      await committedWriteCase(s);
      await s.stop();
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 600)),
  );
}

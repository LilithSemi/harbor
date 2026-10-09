import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

// The second half of the 125 MHz random run.
void main() {
  tearDown(() async => Simulator.reset());

  test(
    '1000 random requests at 125 MHz CL3, bankRowCol',
    () async {
      final s = await sdramRandomRun(
        125000000,
        seed: 2,
        requests: 1000,
        map: HarborSdramAddressMap.bankRowCol,
      );
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

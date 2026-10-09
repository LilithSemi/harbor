import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

// Half of the 125 MHz random run. sdram_engine_random_b_test.dart has the
// other 1000 requests, so each file stays near a minute.
void main() {
  tearDown(() async => Simulator.reset());

  test(
    '1000 random requests at 125 MHz CL3, rowBankCol',
    () async {
      final s = await sdramRandomRun(
        125000000,
        seed: 1,
        requests: 1000,
        map: HarborSdramAddressMap.rowBankCol,
      );
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

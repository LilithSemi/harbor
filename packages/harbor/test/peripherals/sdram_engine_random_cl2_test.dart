import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

// Half of the 100 MHz random run. sdram_engine_random_cl2_b_test.dart has
// the other 1000 requests.
void main() {
  tearDown(() async => Simulator.reset());

  test(
    '1000 random requests at 100 MHz CL2, rowBankCol',
    () async {
      final s = await sdramRandomRun(
        100000000,
        seed: 3,
        requests: 1000,
        map: HarborSdramAddressMap.rowBankCol,
      );
      expect(s.errors, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

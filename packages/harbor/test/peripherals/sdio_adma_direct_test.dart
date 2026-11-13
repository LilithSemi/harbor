import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdio_adma_bench.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'direct DMA CMD18 reads 16 blocks, memory stall 0.7',
    () => checkDirectCmd18(16, 0.7),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

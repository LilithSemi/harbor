import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdio_adma_bench.dart';

void main() {
  tearDown(() async => Simulator.reset());

  // 128 blocks of 512 bytes is 65536 bytes, which a 16-bit byte counter
  // wraps to 0.
  test(
    'direct DMA CMD18 reads 128 blocks',
    () => checkDirectCmd18(128, 0.0),
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_completer_bench.dart';

void main() {
  tearDown(() async => Simulator.reset());

  for (final (seed, config) in [
    (41, const CompleterConfig(width: 64, dataWidth: 32)),
    (42, const CompleterConfig(width: 64, dataWidth: 64, memoryOffset: 0x4004)),
    (
      43,
      const CompleterConfig(width: 128, dataWidth: 128, memoryOffset: 0x4008),
    ),
  ]) {
    test('mixed writes and reads, $config', () async {
      await runMixed(config, seed: seed, count: 60);
    });
  }

  test('mixed writes and reads with 4DW headers', () async {
    await runMixed(
      const CompleterConfig(width: 128, dataWidth: 128),
      seed: 31,
      count: 40,
      barBase: 0x200000000,
      rcb128: true,
    );
  });
}

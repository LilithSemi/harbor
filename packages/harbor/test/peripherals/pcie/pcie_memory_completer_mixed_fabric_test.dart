import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_completer_bench.dart';

void main() {
  tearDown(() async => Simulator.reset());

  for (final (seed, config) in [
    (
      44,
      const CompleterConfig(
        kind: HarborFabricKind.wishbone,
        memoryOffset: 0x400c,
      ),
    ),
    (
      45,
      const CompleterConfig(
        kind: HarborFabricKind.tilelink,
        memoryOffset: 0x400c,
      ),
    ),
    (
      46,
      const CompleterConfig(
        width: 128,
        dataWidth: 64,
        kind: HarborFabricKind.wishbone,
      ),
    ),
  ]) {
    test('mixed writes and reads, $config', () async {
      await runMixed(config, seed: seed, count: 60);
    });
  }
}

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_memory_port_bench.dart';

void main() {
  tearDown(() async {
    if (!Simulator.simulationHasEnded) await Simulator.endSimulation();
    await Simulator.reset();
  });

  test('axi4: a scanout read in the cycle after a WRESP sees the write, '
      'with bus reads filling the engine', () async {
    expect(await sdramScanReadAfterWresp(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 20)));
}

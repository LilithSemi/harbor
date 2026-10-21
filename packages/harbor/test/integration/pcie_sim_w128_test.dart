import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/pcie_gpu_bench.dart';

void main() {
  tearDown(Simulator.reset);

  test(
    'PCIe GPU W128: 1 MB each way from a host SG list, records, MSIs, '
    'BAR2 and ROM in parallel',
    () async => PcieGpuRun(await PcieGpuBench.create(128)).run(),
    timeout: const Timeout(Duration(hours: 5)),
  );
}

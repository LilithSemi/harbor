import 'package:harbor/harbor.dart';

import '../util/led_dma_dut.dart';

void main() {
  registerLedDmaTests(HarborFabricKind.axi4);
}

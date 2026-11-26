import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdio_adma_kind_cases.dart';

void main() {
  tearDown(() async => Simulator.reset());
  admaKindCases(HarborFabricKind.tilelink, widths: [32]);
}

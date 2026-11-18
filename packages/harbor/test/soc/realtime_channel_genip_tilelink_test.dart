// The genip shaped SoC on a TileLink fabric: the display read stays under the
// summed channel and converge bound.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'realtime_channel_genip_harness.dart';

void main() {
  tearDown(() async => Simulator.reset());
  test(
    'genip tilelink: the display read stays under the summed bound',
    () async {
      await runGenip(HarborFabricKind.tilelink);
    },
  );
}

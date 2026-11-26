// The genip shaped SoC on a Wishbone fabric: the display read stays under the
// summed channel and converge bound.

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'realtime_channel_genip_harness.dart';

void main() {
  tearDown(() async => Simulator.reset());
  test(
    'genip wishbone: the display read stays under the summed bound',
    () async {
      await runGenip(HarborFabricKind.wishbone);
    },
  );
  test('genip wishbone with register stages: the display read stays under the '
      'bound', () async {
    await runGenip(HarborFabricKind.wishbone, pipeline: true);
  });
}

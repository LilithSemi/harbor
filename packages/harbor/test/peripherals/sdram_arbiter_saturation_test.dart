import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_saturation_test.dart' show sdramSaturationRun;

void main() {
  tearDown(() async => Simulator.reset());

  test('125 MHz: the credit force wins with 2 ports saturating', () async {
    await sdramSaturationRun(2, rowAge: false);
  });

  test('125 MHz: the row-age force wins with 2 ports saturating', () async {
    await sdramSaturationRun(2, rowAge: true);
  });
}

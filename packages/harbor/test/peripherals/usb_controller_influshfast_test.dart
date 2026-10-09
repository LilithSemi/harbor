import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_influshrace_sweep.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  // The bus clock runs faster than the usb clock (period 7 against 10).
  test('an IN flush racing an ACKed IN with a fast bus clock', () async {
    await inFlushRaceSweep(ack: true, busPeriod: 7);
  });
}

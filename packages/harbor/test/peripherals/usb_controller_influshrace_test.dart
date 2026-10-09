import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'usb_controller_influshrace_sweep.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('an IN flush racing an IN that the host ACKs', () async {
    await inFlushRaceSweep(ack: true);
  });

  test('an IN flush racing an IN that the host does not ACK', () async {
    await inFlushRaceSweep(ack: false);
  });
}

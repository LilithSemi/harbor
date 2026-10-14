import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/eth_tx_check.dart';

// Split from ethernet_tx_payload_test.dart: run alone, since each of these
// costs several thousand cycles and dart test slows down as cases pile up
// in one process.
void main() {
  tearDown(() async => Simulator.reset());

  // Near the standard 1500-byte Ethernet MTU. The fetch (latency + 5
  // cycles) must stay under the 8 nibble times each word gets on the
  // wire for a frame this long to never underrun: true at latency 0 and
  // 1, not at 8 or 20 (see ethernet_tx_underrun_test.dart).
  for (final latency in [0, 1]) {
    test('TX payload is exact, len 1500, latency $latency', () async {
      await checkTxFrame(1500, latency);
    });
  }
}

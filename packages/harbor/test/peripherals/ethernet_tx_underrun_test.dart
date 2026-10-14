import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/eth_tx_check.dart';

// Latencies above the TX prefetch budget (see
// ethernet_tx_payload_test.dart): the frame must still finish with
// TX_EN continuous, but with a corrupted FCS and TX_UNDERRUN set,
// never with the stale word sent as if it were good.
void main() {
  tearDown(() async => Simulator.reset());

  for (final len in [16, 20]) {
    test('TX underrun corrupts the FCS, len $len, latency 8', () async {
      await checkTxUnderrun(len, 8);
    });
  }
  for (final len in [5, 8, 12, 16, 20]) {
    test('TX underrun corrupts the FCS, len $len, latency 20', () async {
      await checkTxUnderrun(len, 20);
    });
  }

  // The near-MTU frame also outruns the prefetch well under its own
  // latency budget, since every word after the first costs more to
  // fetch than it gets on the wire.
  test('TX underrun corrupts the FCS, len 1500, latency 8', () async {
    await checkTxUnderrun(1500, 8);
  });
}

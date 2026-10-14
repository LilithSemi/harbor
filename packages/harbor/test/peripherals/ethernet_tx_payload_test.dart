import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/eth_tx_check.dart';

// Lengths covered at each latency, measured against the default TX
// prefetch depth (see HarborEthernetConfig.txPrefetchDepth): the fetch
// round trip is latency + 5 cycles, against 8 nibble times per word on
// the wire, plus 16 bonus cycles from the preamble and SFD before the
// first prefetched word is needed. Past this, see
// ethernet_tx_underrun_test.dart.
final _lengthsByLatency = {
  0: [for (var len = 1; len <= 20; len++) len],
  1: [1, 4, 5, 8, 12, 16, 20],
  8: [1, 4, 5, 8, 12],
  20: [1, 4],
};

void main() {
  tearDown(() async => Simulator.reset());

  for (final entry in _lengthsByLatency.entries) {
    final latency = entry.key;
    for (final len in entry.value) {
      test('TX payload is exact, len $len, latency $latency', () async {
        await checkTxFrame(len, latency);
      });
    }
  }
}

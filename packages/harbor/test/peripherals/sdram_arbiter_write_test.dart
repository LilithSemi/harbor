import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_rw_test.dart' show sdramAddr;
import 'sdram_engine_stack.dart';

/// Two ports with multi-word writes queued at once. The engine takes the
/// words in the order it accepted the requests, so the arbiter must feed
/// each word from the port that owns that request, even when the next
/// request in line belongs to the other port.
void main() {
  tearDown(() async => Simulator.reset());

  test('125 MHz: write words follow request order across 2 ports', () async {
    final s = SdramEngineStack(clockHz: 125000000, ports: 2);
    await s.start();
    for (var i = 0; i < 24; i++) {
      for (var port = 0; port < 2; port++) {
        final a = sdramAddr(s, port, 30 + port, 16 * i);
        s.write(a, [
          for (var w = 0; w < 1 + (i + port) % 4; w++)
            (port << 12) | (i << 4) | w,
        ], port: port);
      }
    }
    for (var i = 0; i < 24; i++) {
      for (var port = 0; port < 2; port++) {
        s.read(sdramAddr(s, port, 30 + port, 16 * i), 4, port: port);
      }
    }
    await s.drain();
    await s.idle(20);
    await s.stop();
    expect(s.errors, isEmpty);
  });
}

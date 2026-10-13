import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_rw_test.dart' show sdramAddr;
import 'sdram_engine_stack.dart';

/// Random reads and multi-word writes on a best effort port behind a
/// slice, next to a realtime port without one, as in [HarborSdram].
/// Returns the cycles the run took.
Future<int> _run({required bool slice, required int seed}) async {
  final s = SdramEngineStack(
    clockHz: 125000000,
    ports: 2,
    portRealtime: const [false, true],
    portSlice: [slice, false],
  );
  await s.start();
  final rng = Random(seed);
  final start = s.cycle;
  for (var i = 0; i < 120; i++) {
    final port = rng.nextInt(4) == 0 ? 1 : 0;
    final words = 1 + rng.nextInt(8);
    final a = sdramAddr(s, rng.nextInt(4), 40 + port, 8 * rng.nextInt(64));
    if (port == 0 && rng.nextBool()) {
      s.write(a, [
        for (var w = 0; w < words; w++) rng.nextInt(1 << 16),
      ], port: port);
    } else {
      s.read(a, words, port: port);
    }
  }
  await s.drain();
  final cycles = s.cycle - start;
  await s.idle(20);
  await s.stop();
  expect(s.errors, isEmpty);
  return cycles;
}

void main() {
  tearDown(() async => Simulator.reset());

  test('125 MHz: a sliced port keeps its data and order and most of its '
      'rate next to a realtime port', () async {
    final sliced = await _run(slice: true, seed: 3);
    await Simulator.reset();
    final plain = await _run(slice: false, seed: 3);
    print('sliced $sliced cycles, plain $plain cycles');
    // One more cycle per request at most, never one per word.
    expect(sliced, lessThanOrEqualTo(plain + 120));
  });
}

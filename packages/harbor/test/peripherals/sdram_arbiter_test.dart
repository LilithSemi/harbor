import 'dart:math';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// Two ports queue random traffic at once, each with its own scoreboard.
/// With [sharedBanks] both ports use the same banks and rows, so their
/// requests also fight over rows. Otherwise each port has its own pair of
/// banks, so a data mismatch can only come from routing.
Future<void> sdramTwoPortRun({
  required bool sharedBanks,
  required int seed,
}) async {
  final s = SdramEngineStack(clockHz: 125000000, maxGrantWords: 16, ports: 2);
  await s.start();

  final rngs = [Random(seed), Random(seed + 1)];
  final c = s.config;
  final shared = [for (var i = 0; i < 3; i++) rngs[0].nextInt(1 << c.rowWidth)];
  final rows = [
    if (sharedBanks) ...[
      shared,
      shared,
    ] else ...[
      [for (var i = 0; i < 2; i++) rngs[0].nextInt(1 << c.rowWidth)],
      [for (var i = 0; i < 2; i++) rngs[1].nextInt(1 << c.rowWidth)],
    ],
  ];
  const perPort = 250;
  for (var i = 0; i < perPort; i++) {
    for (var port = 0; port < 2; port++) {
      final rng = rngs[port];
      final words = 1 + rng.nextInt(4);
      // With shared banks, each port keeps to its own columns, so the two
      // scoreboards never see each other's writes.
      final half = (1 << c.colWidth) ~/ 2;
      final col = sharedBanks
          ? port * half + rng.nextInt(half - words + 1)
          : rng.nextInt((1 << c.colWidth) - words + 1);
      final bank = sharedBanks
          ? rng.nextInt(c.banks)
          : (port == 0 ? rng.nextInt(2) : 2 + rng.nextInt(2));
      final row = rows[port][rng.nextInt(rows[port].length)];
      final addr = (((row << c.bankBits) | bank) << c.colWidth) | col;
      if (rng.nextBool()) {
        s.write(
          addr,
          [for (var w = 0; w < words; w++) rng.nextInt(1 << 16)],
          masks: [for (var w = 0; w < words; w++) rng.nextInt(4)],
          port: port,
        );
      } else {
        s.read(addr, words, port: port);
      }
    }
  }

  await s.drain();
  await s.idle(50);
  await s.stop();

  expect(s.errors, isEmpty);
  // Round robin: while a port waits, the other port gets at most one
  // grant, so the wait is the other port's largest request plus the one
  // already in flight.
  expect(s.maxOtherGrants, equals(1));
}

/// [SdramArbiter] in front of [SdramEngine]: one port is a pure
/// passthrough, and two ports on separate banks share the engine fairly.
void main() {
  tearDown(() async => Simulator.reset());

  test(
    '125 MHz: a one-port arbiter passes the random run unchanged',
    () async {
      final s = await sdramRandomRun(125000000, seed: 1, requests: 300);
      expect(s.errors, isEmpty);
    },
  );

  test(
    '125 MHz: 2 ports on separate banks, each waits one grant at most',
    () async {
      await sdramTwoPortRun(sharedBanks: false, seed: 301);
    },
  );
}

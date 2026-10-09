import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_rw_test.dart' show sdramAddr;
import 'sdram_engine_stack.dart';

/// Back-to-back 1 and 2 word row hits on [ports] ports, topped up so no
/// queue runs dry. Every request starts with a column command, so a
/// force must keep the next request from starting or it never gets a
/// cycle. With [rowAge], a 3 us tRAS max makes the row-age force fire
/// often. Without it, k = 1 makes the credit force fire every period.
Future<void> sdramSaturationRun(int ports, {required bool rowAge}) async {
  final s = SdramEngineStack(
    clockHz: 125000000,
    ports: ports,
    maxPostponed: rowAge ? 8 : 1,
    maxPulledIn: rowAge ? 8 : 13,
    tRasMaxNs: rowAge ? 3000 : null,
  );
  await s.start();
  final c0 = s.cycle;
  var i = 0;
  while (s.cycle - c0 < 4000) {
    for (; s.pending < 60; i++) {
      final port = i % ports;
      final addr = sdramAddr(s, port, 7, (i % 64) * 2);
      if (i % 3 == 0) {
        s.write(addr, [i & 0xFFFF, (i + 1) & 0xFFFF], port: port);
      } else {
        s.read(addr, 1 + i % 2, port: port);
      }
    }
    await s.idle(10);
  }
  await s.drain();
  await s.idle(20);
  await s.stop();
  expect(s.errors, isEmpty);
  if (rowAge) {
    expect(s.rowAgeEdges, greaterThanOrEqualTo(5));
  } else {
    expect(s.forceEdges, greaterThanOrEqualTo(3));
  }
}

void main() {
  tearDown(() async => Simulator.reset());

  test(
    '125 MHz: the credit force wins against back-to-back row hits',
    () async {
      await sdramSaturationRun(1, rowAge: false);
    },
  );

  test(
    '125 MHz: the row-age force wins against back-to-back row hits',
    () async {
      await sdramSaturationRun(1, rowAge: true);
    },
  );
}

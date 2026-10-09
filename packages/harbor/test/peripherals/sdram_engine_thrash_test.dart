import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

/// One-word writes to one open row with [gap] idle cycles after each. The
/// gaps are shorter than the pull-in idle time, so the row stays open and
/// is closed only for an owed refresh. With one pulled-in refresh at
/// most, those owed refreshes start early in the run.
Future<void> sdramThrashRun(int gap) async {
  final s = SdramEngineStack(
    clockHz: 125000000,
    maxPostponed: 13,
    maxPulledIn: 1,
  );
  await s.start();
  await s.idle(200);
  final start = s.model.log.length;
  final c0 = s.cycle;
  // About 3.5 refresh periods.
  var writes = 0;
  while (s.cycle - c0 < 3400) {
    s.write(writes % 256, [writes]);
    writes++;
    await s.drain();
    await s.idle(gap);
  }
  await s.idle(20);
  final log = s.model.log.sublist(start);
  int count(String kind) => log.where((c) => c.kind == kind).length;
  final refs = count('refresh');
  expect(count('write'), writes);
  expect(refs, greaterThanOrEqualTo(2));
  // One activate to start, then one after each refresh.
  expect(count('activate'), lessThanOrEqualTo(refs + 1));
  await s.stop();
  expect(s.errors, isEmpty);
}

void main() {
  tearDown(() async => Simulator.reset());

  test('row hits survive 2-cycle gaps and refreshes still run', () async {
    await sdramThrashRun(2);
  });
}

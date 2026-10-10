import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

int _addr(HarborSdramConfig c, int bank, int row, int col) =>
    c.addressMap == HarborSdramAddressMap.rowBankCol
    ? (((row << c.bankBits) | bank) << c.colWidth) | col
    : (((bank << c.rowWidth) | row) << c.colWidth) | col;

/// A fresh engine's first ever access: a 2-word read starting at column 7,
/// so it crosses the 8-word block boundary (the old read_more path).
Future<void> _runColumn7Case(SdramEngineStack s) async {
  s.read(_addr(s.config, 0, 5, 7), 2);
  await s.drain();
  await s.idle(10);
}

/// Standard init sequence, identical in every golden trace test in this
/// suite: precharge-all, mrs, 8 init refreshes, then one more refresh
/// whose address is don't care and shows la's row (the first real
/// request, already enqueued by the time this refresh is picked).
const _initPrefix = [
  (0, 'precharge', 0, 1024),
  (4, 'mrs', 0, 563),
  (7, 'refresh', 0, 0),
  (16, 'refresh', 0, 0),
  (25, 'refresh', 0, 0),
  (34, 'refresh', 0, 0),
  (43, 'refresh', 0, 0),
  (52, 'refresh', 0, 0),
  (61, 'refresh', 0, 0),
  (70, 'refresh', 0, 0),
  (81, 'refresh', 0, 5),
];

/// Expected trace for [_runColumn7Case], reasoned from the command rules
/// in sdram_engine_golden_trace_test.dart and the round 4 report, not
/// copied from a run.
const _expectedColumn7 = [
  ..._initPrefix,
  // rfc from the last init refresh's pick (80): picked 88, issued 89.
  (89, 'activate', 0, 5),
  // rcd (3) from the activate's pick (88): picked 91, issued 92. The
  // request does not fit the 8-word block from column 7 (room is 1
  // word), so the engine clamps beats to 1 and marks it not finished.
  (92, 'read', 0, 7),
  // read_more: colMore is set (beats == 1 and rem == 2 after the first
  // column), so the engine picks the continuation the very next cycle,
  // no bank command needed and no extra read-to-read spacing applies
  // since a 1-beat read's spacing span is 0. Picked 92, issued 93.
  (93, 'read', 0, 8),
];

/// A fresh engine's first access is an 8-beat read (column 0, so it does
/// not cross a block boundary), with a short tRasMax so the row-age guard
/// forces a precharge-all right after.
Future<void> _runForcedPrechargeCase(SdramEngineStack s) async {
  s.read(_addr(s.config, 0, 5, 0), 8);
  await s.drain();
  await s.idle(300);
}

/// Expected trace for [_runForcedPrechargeCase]. Reasoned, then checked
/// against the RTL: see the note below the list for where reasoning and
/// RTL disagreed.
///
/// The bank timers hold a precharge to a bank until an active read's own
/// "wanted burst has run its course" (`readBeatsTimer`, `spanOf(cmdBeats)`
/// in sdram_bank_timers.dart): an 8-beat read's span is 6, on top of the
/// base tRAS-min/tWR clearance. `wantPreAllNext` also folds into
/// `holdNext`, so once the row-age guard wants a close, `curGo` drops and
/// nothing new can be picked for cur, but the forced precharge-all itself
/// still waits out that same span. The two effects land together: the
/// precharge-all is picked only once the read's own beats have fully
/// cleared, not mid-command and not mid-data.
const _expectedForcedPrecharge = [
  ..._initPrefix,
  (89, 'activate', 0, 5),
  // rcd (3) from the activate's pick (88): picked 91, issued 92.
  (92, 'read', 0, 0),
  // Forced precharge-all, picked once readBeatsZero (an 8-beat read's
  // extra span is 6 cycles past the read's pick) and the row-age guard's
  // own want (tRasMaxNs: 200 keeps a comfortable margin over the fixed
  // register pipeline from rowAgeForce to the pick) are both ready.
  (113, 'precharge', 0, 1024),
  // rp (3) from the forced precharge's pick (112), then rfc (8) each.
  (116, 'refresh', 0, 5),
  (124, 'refresh', 0, 5),
  (132, 'refresh', 0, 5),
  (140, 'refresh', 0, 5),
  (148, 'refresh', 0, 5),
  (156, 'refresh', 0, 5),
  (164, 'refresh', 0, 5),
];

void main() {
  tearDown(() async => Simulator.reset());

  test('golden trace extra: 2-word read starting at column 7, '
      'the old read_more path', () async {
    final s = SdramEngineStack(clockHz: 125000000, maxGrantWords: 16);
    await s.start();
    await _runColumn7Case(s);
    await s.stop();

    expect(s.errors, isEmpty);
    final t0 = s.engineCommandLog.first.$1;
    final actual = [
      for (final e in s.engineCommandLog)
        ((e.$1 - t0) ~/ s.periodPs, e.$2, e.$3, e.$4),
    ];
    expect(actual, equals(_expectedColumn7));
  });

  // This is not a mid-burst truncation: see the disagreement note above
  // _expectedForcedPrecharge. The bank timers hold the forced
  // precharge-all off until the read has fully drained, so this shows
  // the earliest the RTL ever allows it to land after a forced close is
  // wanted, not a cut mid-command or mid-data.
  test('golden trace extra: a row-age forced precharge-all lands as soon '
      'as the active read drains, not mid-burst', () async {
    final s = SdramEngineStack(
      clockHz: 125000000,
      maxGrantWords: 16,
      tRasMaxNs: 200,
    );
    await s.start();
    await _runForcedPrechargeCase(s);
    await s.stop();

    expect(s.errors, isEmpty);
    final t0 = s.engineCommandLog.first.$1;
    final actual = [
      for (final e in s.engineCommandLog)
        ((e.$1 - t0) ~/ s.periodPs, e.$2, e.$3, e.$4),
    ];
    expect(actual, equals(_expectedForcedPrecharge));
  });
}

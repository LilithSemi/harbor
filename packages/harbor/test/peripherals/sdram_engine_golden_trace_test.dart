import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sdram_engine_stack.dart';

int _addr(HarborSdramConfig c, int bank, int row, int col) =>
    c.addressMap == HarborSdramAddressMap.rowBankCol
    ? (((row << c.bankBits) | bank) << c.colWidth) | col
    : (((bank << c.rowWidth) | row) << c.colWidth) | col;

/// Reads, writes, a row miss on each bank, then an idle long enough that
/// the row-age guard forces a precharge-all and commits to a refresh,
/// then a couple more accesses once the bank reopens.
Future<void> _runWorkload(SdramEngineStack s) async {
  final c = s.config;
  s.write(_addr(c, 0, 5, 0), [0x1111, 0x2222, 0x3333, 0x4444]);
  s.read(_addr(c, 1, 9, 0), 4);
  s.write(_addr(c, 0, 5, 4), [0x5555, 0x6666]);
  s.read(_addr(c, 1, 9, 4), 4);
  // Row miss: back to bank 0 with a different row.
  s.read(_addr(c, 0, 12, 0), 4);
  s.write(_addr(c, 1, 20, 0), [0xAAAA, 0xBBBB]);
  await s.drain();

  // Hold bank 0 row 12 open with nothing else happening, long enough
  // that the row-age guard forces a precharge-all and commits to the
  // next refresh.
  s.read(_addr(c, 0, 12, 0), 1);
  await s.drain();
  await s.idle(400);

  // A few more accesses after the forced close, to show the bank
  // reopens cleanly.
  s.read(_addr(c, 0, 12, 2), 2);
  s.write(_addr(c, 1, 20, 2), [0xCCCC]);
  await s.drain();
  await s.idle(20);
}

/// (cycle relative to the first command, command, bank, address field)
/// for every command the pin model decoded.
///
/// Golden data from the pre-fix RTL at git HEAD 605296d (before the Fmax
/// fix), built and run in a scratch copy outside this worktree with the
/// same workload below. Unedited: [_expected] is worked out from it.
const _golden = [
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
  (80, 'refresh', 0, 0),
  (88, 'activate', 0, 5),
  (90, 'activate', 1, 9),
  (91, 'write', 0, 0),
  (92, 'write', 0, 1),
  (93, 'write', 0, 2),
  (94, 'write', 0, 3),
  (95, 'read', 1, 0),
  (104, 'write', 0, 4),
  (105, 'write', 0, 5),
  (106, 'read', 1, 4),
  (108, 'precharge', 0, 0),
  (110, 'precharge', 1, 0),
  (111, 'activate', 0, 12),
  (113, 'activate', 1, 20),
  (114, 'read', 0, 0),
  (123, 'write', 1, 0),
  (124, 'write', 1, 1),
  (129, 'read', 0, 0),
  (149, 'precharge', 0, 1024),
  (152, 'refresh', 0, 12),
  (160, 'refresh', 0, 12),
  (168, 'refresh', 0, 12),
  (176, 'refresh', 0, 12),
  (184, 'refresh', 0, 12),
  (192, 'refresh', 0, 12),
  (200, 'refresh', 0, 12),
  (540, 'activate', 0, 12),
  (542, 'activate', 1, 20),
  (543, 'read', 0, 2),
  (550, 'write', 1, 2),
];

/// The command timing of the engine with the registered select, worked
/// out from [_golden] and these rules, not copied from a run:
///
/// 1. The select picks a command at the cycle the old engine issued it and
///    the command leaves one cycle later. The timers count from the pick,
///    so every spacing rule is the same.
/// 2. An entry is not picked in the cycle after a pick for it, except the
///    next word of a write. Nothing is picked in the cycle after a
///    finishing column, a precharge all or a refresh.
/// 3. The init sequence does not use the select and does not move.
///
/// A drain ends on the last write word or read beat, so a change before a
/// drain moves every entry after it.
const _expected = [
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
  // Rule 1. The address bits of a refresh are don't care and come from
  // la, which holds the first request one cycle later.
  (81, 'refresh', 0, 5),
  // Rule 1: picked at 88 (rfc after the pick at 80) and 90 (rrd).
  (89, 'activate', 0, 5),
  (91, 'activate', 1, 9),
  // Rule 1: picked at 91 (rcd), the la activate on sel does not hold cur.
  (92, 'write', 0, 0),
  (93, 'write', 0, 1),
  (94, 'write', 0, 2),
  (95, 'write', 0, 3),
  // Rule 2: the last write word holds back the pick at 95, so the read
  // that moves up is picked at 96.
  (97, 'read', 1, 0),
  // Read to write turnaround of 9 from the pick at 96.
  (106, 'write', 0, 4),
  (107, 'write', 0, 5),
  // Rule 2 after the last write word (picked at 106): picked at 108.
  (109, 'read', 1, 4),
  // Rule 2 after the finishing read (picked at 108): picked at 110.
  (111, 'precharge', 0, 0),
  // la holds this write one cycle later than before (the read above
  // finishes one pick later), so it is picked at 112.
  (113, 'precharge', 1, 0),
  // rp from 110, and rrd and rp from 113 and 112.
  (114, 'activate', 0, 12),
  (116, 'activate', 1, 20),
  // rcd from 113.
  (117, 'read', 0, 0),
  // Turnaround of 9 from the read picked at 116.
  (126, 'write', 1, 0),
  (127, 'write', 1, 1),
  // The drain ends 3 cycles later (last write word), picked at 132.
  (133, 'read', 0, 0),
  // The entries empty 4 cycles later after the read above, so the idle
  // count and the refresh pull-in run 4 cycles later and the pick is at
  // 153, then rp and rfc as before.
  (154, 'precharge', 0, 1024),
  (157, 'refresh', 0, 12),
  (165, 'refresh', 0, 12),
  (173, 'refresh', 0, 12),
  (181, 'refresh', 0, 12),
  (189, 'refresh', 0, 12),
  (197, 'refresh', 0, 12),
  (205, 'refresh', 0, 12),
  // The drain before the idle ends on the read data of the read at 133, 4
  // cycles later, and rule 1 adds one more.
  (545, 'activate', 0, 12),
  (547, 'activate', 1, 20),
  (548, 'read', 0, 2),
  (555, 'write', 1, 2),
];

/// How many trailing [_expected] entries come after the workload's final
/// read drain (the `s.read(_addr(c, 0, 12, 2), 2)` in [_runWorkload]):
/// the workload waits for that read's data before issuing them, so they
/// move later with the PHY's read latency instead of staying fixed to
/// the command before them.
const _afterFinalDrain = 4;

/// The expected trace, with [shift] added to cycles from [_afterFinalDrain]
/// entries before the end onward.
List<(int, String, int, int)> _withShift(int shift) => [
  for (final (i, e) in _expected.indexed)
    i < _expected.length - _afterFinalDrain
        ? e
        : (e.$1 + shift, e.$2, e.$3, e.$4),
];

void main() {
  tearDown(() async => Simulator.reset());

  test('golden command trace: engine timing follows the registered select, '
      'pins shift together by the phy output delay', () async {
    final s = SdramEngineStack(
      clockHz: 125000000,
      maxGrantWords: 16,
      tRasMaxNs: 2000,
    );
    await s.start();
    await _runWorkload(s);
    await s.stop();

    expect(s.errors, isEmpty);
    expect(s.model.log, isNotEmpty);
    expect(s.engineCommandLog, isNotEmpty);
    final periodPs = s.periodPs;

    // The phy's fixed command-to-pin delay and the read-latency shift
    // that follows from it, both read off the phy and its config
    // instead of hard-coded, so they track a future phy change.
    final phy = s.top.phy;
    const phyConfig = HarborSdramPhyConfig();
    final fixedPhyOutputDelay =
        phy.readLatency -
        s.cycles.casLatency -
        phyConfig.captureCycleOffset -
        phyConfig.captureCycles;
    final shift = fixedPhyOutputDelay - 1;

    // 1. The engine's own command timing, decoded before the phy's
    // output stage, matches [_expected] (with the read-latency shift on
    // requests that waited on read data).
    final engineT0 = s.engineCommandLog.first.$1;
    final engineActual = [
      for (final e in s.engineCommandLog)
        ((e.$1 - engineT0) ~/ periodPs, e.$2, e.$3, e.$4),
    ];
    expect(engineActual, equals(_withShift(shift)));
    // The registered select changes when commands go, not which go.
    expect([
      for (final e in _expected) (e.$2, e.$3),
    ], equals([for (final e in _golden) (e.$2, e.$3)]));

    // 2. Every pin command lands exactly fixedPhyOutputDelay cycles
    // after the matching engine command: the phy delays every command
    // the same amount, none sits early or late.
    expect(s.model.log.length, s.engineCommandLog.length);
    for (var i = 0; i < s.model.log.length; i++) {
      final pin = s.model.log[i];
      final engine = s.engineCommandLog[i];
      expect(pin.kind, engine.$2, reason: 'command $i kind');
      expect(pin.bank, engine.$3, reason: 'command $i bank');
      expect(pin.a, engine.$4, reason: 'command $i address');
      expect(
        (pin.timePs - engine.$1) ~/ periodPs,
        fixedPhyOutputDelay,
        reason: 'command $i pin-vs-engine delay',
      );
    }
  });
}

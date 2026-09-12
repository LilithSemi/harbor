// A real simulation of [HarborCdcHandshake] across two asynchronous clocks.
//
// The only test this module had before was a construction test: it made the
// module and read the width of the ports. That test passed while the module
// was completely dead, because `ackSync0` was tied to a fresh signal that
// nothing drove. `src_ready` never came back, and no transfer ever finished.
// Only a simulation finds a fault of that kind, so every check in this file
// runs the crossing on two clocks and reads what comes out.
//
// The two clocks are NOT harmonic: neither period is a whole multiple of the
// other, so the edges of one domain walk through the period of the other and
// the crossing meets every phase relation.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Width of the crossing under test.
const int _width = 8;

/// Largest number of clocks a step of the handshake may take.
///
/// Four phases, two synchroniser stages each way, on two clocks of
/// different rates. This bound is far more than any of that needs, and
/// small enough that a stall fails the test instead of hanging it.
const int _stepBound = 40;

/// One sample of the destination side, taken at a destination clock edge.
typedef _DstSample = ({bool valid, LogicValue data});

/// The crossing with both clocks running and the reset released.
class _Bench {
  final HarborCdcHandshake cdc;
  final Logic srcClk;
  final Logic dstClk;
  final Logic srcData;
  final Logic srcValid;
  final Logic dstReady;

  /// Every destination clock since the reset released.
  final List<_DstSample> dstSamples = [];

  /// Every source clock since the reset released, as `src_ready`.
  final List<LogicValue> srcReadySamples = [];

  final List<StreamSubscription<void>> _subs = [];

  _Bench({
    required this.cdc,
    required this.srcClk,
    required this.dstClk,
    required this.srcData,
    required this.srcValid,
    required this.dstReady,
  });

  /// `src_ready` now.
  LogicValue get srcReady => cdc.output('src_ready').value;

  /// `dst_valid` now.
  LogicValue get dstValid => cdc.output('dst_valid').value;

  /// `dst_data` now.
  LogicValue get dstData => cdc.output('dst_data').value;

  /// Starts to record both domains. Each sample is taken AT the clock edge,
  /// which is the value the flops of that domain see on that clock.
  void watch() {
    _subs.add(
      dstClk.posedge.listen(
        (_) =>
            dstSamples.add((valid: dstValid == LogicValue.one, data: dstData)),
      ),
    );
    _subs.add(srcClk.posedge.listen((_) => srcReadySamples.add(srcReady)));
  }

  /// Stops the recording.
  Future<void> unwatch() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }
}

/// Builds the crossing, holds the reset over both domains and releases it.
///
/// [levelAck] ties `dst_ready` to `~dst_valid`, which is the four phase
/// contract: the acknowledge is a LEVEL that stands until the request
/// drops. A destination that ties `dst_ready` high instead makes the
/// acknowledge a square wave, and the crossing then delivers the same
/// value again and again while one request stands. Every check here but
/// the stall check runs with the level acknowledge. The stall check turns
/// [levelAck] off and holds `dst_ready` low from the test instead.
Future<_Bench> _setUp({
  required int srcPeriod,
  required int dstPeriod,
  bool levelAck = true,
}) async {
  final cdc = HarborCdcHandshake(dataWidth: _width, name: 'cdc_under_test');
  final srcClk = SimpleClockGenerator(srcPeriod).clk;
  final dstClk = SimpleClockGenerator(dstPeriod).clk;
  final reset = Logic(name: 'cdc_reset');
  final srcData = Logic(name: 'cdc_src_data', width: _width);
  final srcValid = Logic(name: 'cdc_src_valid');
  final dstReady = Logic(name: 'cdc_dst_ready');

  cdc.input('src_clk').srcConnection! <= srcClk;
  cdc.input('src_reset').srcConnection! <= reset;
  cdc.input('src_data').srcConnection! <= srcData;
  cdc.input('src_valid').srcConnection! <= srcValid;
  cdc.input('dst_clk').srcConnection! <= dstClk;
  cdc.input('dst_reset').srcConnection! <= reset;
  if (levelAck) {
    cdc.input('dst_ready').srcConnection! <= ~cdc.output('dst_valid');
  } else {
    cdc.input('dst_ready').srcConnection! <= dstReady;
  }
  await cdc.build();

  reset.inject(1);
  srcData.inject(0);
  srcValid.inject(0);
  dstReady.inject(0);
  Simulator.setMaxSimTime(500000);
  unawaited(Simulator.run());

  // Both domains hold their own registers, so both need edges under reset.
  final slower = srcPeriod > dstPeriod ? srcClk : dstClk;
  for (var i = 0; i < 4; i++) {
    await slower.nextPosedge;
  }
  reset.inject(0);
  await srcClk.nextPosedge;
  await dstClk.nextPosedge;

  return _Bench(
    cdc: cdc,
    srcClk: srcClk,
    dstClk: dstClk,
    srcData: srcData,
    srcValid: srcValid,
    dstReady: dstReady,
  );
}

/// Waits until `src_ready` is high, and fails if it never comes.
///
/// This wait alone catches the fault that this file was written for: with
/// the acknowledge path broken, `src_ready` goes low on the first transfer
/// and never returns.
Future<void> _awaitSrcReady(_Bench b, String what) async {
  for (var i = 0; i < _stepBound; i++) {
    if (b.srcReady == LogicValue.one) return;
    await b.srcClk.nextPosedge;
  }
  fail('src_ready did not come back within $_stepBound source clocks: $what');
}

/// Puts [value] on the source and waits until the crossing retires it.
Future<void> _send(_Bench b, int value) async {
  await _awaitSrcReady(b, 'before sending 0x${value.toRadixString(16)}');
  b.srcData.inject(value);
  b.srcValid.inject(1);
  // The source latches the value on the next edge, because `src_ready` says
  // the request window is open.
  await b.srcClk.nextPosedge;
  b.srcValid.inject(0);
  // The four phase retires when `src_ready` comes back, which needs the
  // acknowledge to arrive AND to go away again.
  await b.srcClk.nextPosedge;
  await _awaitSrcReady(b, 'after sending 0x${value.toRadixString(16)}');
}

/// The values the destination held, one entry per `dst_valid` window.
///
/// A window is a run of destination clocks with `dst_valid` high. The whole
/// window must hold ONE value, because the destination register may not
/// change under a standing valid.
List<int> _windows(List<_DstSample> samples) {
  final out = <int>[];
  var inWindow = false;
  for (final s in samples) {
    if (!s.valid) {
      inWindow = false;
      continue;
    }
    expect(s.data.isValid, isTrue, reason: 'dst_data is X under dst_valid');
    final value = s.data.toInt();
    if (!inWindow) {
      out.add(value);
      inWindow = true;
    } else {
      expect(
        value,
        equals(out.last),
        reason: 'dst_data changed inside one dst_valid window',
      );
    }
  }
  return out;
}

/// Runs the whole check list at one clock ratio.
Future<void> _crossingHolds({
  required int srcPeriod,
  required int dstPeriod,
}) async {
  final b = await _setUp(srcPeriod: srcPeriod, dstPeriod: dstPeriod);
  b.watch();

  // Distinct values, so a value that the crossing skips or repeats shows up
  // in the sequence and not only in a count.
  const sent = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66];
  for (final v in sent) {
    await _send(b, v);
  }
  // Let the last window close.
  for (var i = 0; i < 8; i++) {
    await b.dstClk.nextPosedge;
  }
  await b.unwatch();

  // 1. `src_ready` came back. It is high now, and it went low in between,
  //    so the crossing really took the requests.
  expect(
    b.srcReady,
    LogicValue.one,
    reason: 'the source must be ready again once the last transfer retired',
  );
  expect(
    b.srcReadySamples.map((v) => v.toInt()).toSet(),
    equals({0, 1}),
    reason: 'src_ready must drop while a transfer is in flight',
  );

  // 4. Nothing is X after the reset released, on any clock of either domain.
  for (var i = 0; i < b.srcReadySamples.length; i++) {
    expect(
      b.srcReadySamples[i].isValid,
      isTrue,
      reason: 'src_ready is X on source clock $i',
    );
  }
  for (var i = 0; i < b.dstSamples.length; i++) {
    expect(
      b.dstSamples[i].data.isValid,
      isTrue,
      reason: 'dst_data is X on destination clock $i',
    );
  }

  // 2. `dst_valid` both rises and falls, so the four phase retires and does
  //    not stand for ever.
  final validLevels = b.dstSamples.map((s) => s.valid).toSet();
  expect(
    validLevels,
    equals({true, false}),
    reason: 'dst_valid must rise AND fall',
  );

  // 3, 5 and 6. Every window holds one value, and the windows carry the
  // values that were sent, in order, with none skipped.
  expect(
    _windows(b.dstSamples),
    equals(sent),
    reason:
        'every value must arrive once, in order, and never change '
        'inside its own dst_valid window',
  );

  await Simulator.endSimulation();
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborCdcHandshake carries data across two asynchronous clocks', () {
    // 7. Both ratios. The periods are 5:13 and 13:5, so neither clock is a
    // whole multiple of the other in either direction.
    test('with the source faster than the destination', () async {
      await _crossingHolds(srcPeriod: 10, dstPeriod: 26);
    });

    test('with the destination faster than the source', () async {
      await _crossingHolds(srcPeriod: 26, dstPeriod: 10);
    });

    // 6, on its own. The source data changes on EVERY source clock while
    // one value is in flight. The destination register may not follow it.
    test('dst_data stands still while src_data moves under it', () async {
      final b = await _setUp(srcPeriod: 10, dstPeriod: 26);
      const inFlight = 0xA5;

      await _awaitSrcReady(b, 'before the transfer');
      b.srcData.inject(inFlight);
      b.srcValid.inject(1);
      await b.srcClk.nextPosedge;
      b.srcValid.inject(0);

      // Now churn the source input. `src_valid` is low, so nothing may
      // reach the destination register.
      final seen = <int>{};
      var windows = 0;
      var wasValid = false;
      for (var i = 0; i < 40; i++) {
        b.srcData.inject((0x5A + i) & 0xFF);
        await b.srcClk.nextPosedge;
        final valid = b.dstValid == LogicValue.one;
        if (valid) {
          expect(b.dstData.isValid, isTrue, reason: 'dst_data is X');
          seen.add(b.dstData.toInt());
          if (!wasValid) windows++;
        }
        wasValid = valid;
      }

      expect(windows, greaterThan(0), reason: 'the transfer must arrive');
      expect(
        seen,
        equals({inFlight}),
        reason: 'dst_data must hold the value that was latched, and no other',
      );
      await Simulator.endSimulation();
    });

    // 8. A destination that never takes the data stalls the crossing. The
    // acknowledge cannot retire, so the source cannot start another
    // transfer.
    test('dst_ready held low lets no transfer complete', () async {
      final b = await _setUp(srcPeriod: 10, dstPeriod: 26, levelAck: false);

      await _awaitSrcReady(b, 'before the stalled transfer');
      b.srcData.inject(0x3C);
      b.srcValid.inject(1);
      await b.srcClk.nextPosedge;
      b.srcValid.inject(0);

      // Give the crossing far longer than a transfer needs.
      for (var i = 0; i < _stepBound * 4; i++) {
        await b.srcClk.nextPosedge;
      }

      expect(
        b.srcReady,
        LogicValue.zero,
        reason: 'the source may not report ready while the transfer stands',
      );

      // A second value cannot get in behind the first one.
      b.srcData.inject(0x7E);
      b.srcValid.inject(1);
      for (var i = 0; i < _stepBound; i++) {
        await b.srcClk.nextPosedge;
        expect(
          b.srcReady,
          LogicValue.zero,
          reason: 'a stalled crossing may not accept a second value',
        );
      }
      expect(
        b.dstData.toInt(),
        equals(0x3C),
        reason: 'the stalled destination keeps the value it was given',
      );
      await Simulator.endSimulation();
    });
  });
}

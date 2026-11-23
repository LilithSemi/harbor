import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _collectDqs = 3;
const _analyzeDqs = 4;
const _calibrateDqs = 5;

/// One ANALYZE_DQS pass that found the burst start.
typedef _Pass = ({int collection, int index, int stored, int repeat, int next});

/// Runs DQS calibration with the burst start at [indexOf] of each DQS
/// collection, and records each ANALYZE_DQS pass that finds it, until the
/// controller leaves for CALIBRATE_DQS.
Future<List<_Pass>> _analyze(int Function(int collection) indexOf) async {
  final p = DdrParams(controllerClkPeriodPs: 800000, ddr3ClkPeriodPs: 200000);
  final clk = SimpleClockGenerator(10).clk;
  final rstN = Logic()..inject(0);
  final dqs = Logic(width: p.lanes * 8)..inject(0);
  final ctrl = Ddr3Controller(
    p,
    controllerClk: clk,
    rstN: rstN,
    wbCyc: Logic()..inject(0),
    wbStb: Logic()..inject(0),
    wbWe: Logic()..inject(0),
    wbAddr: Logic(width: p.wbAddrBits)..inject(0),
    wbData: Logic(width: p.wbDataBits)..inject(0),
    wbSel: Logic(width: p.wbSelBits)..inject(0),
    aux: Logic(width: Ddr3Controller.auxWidth)..inject(0),
    wb2Cyc: Logic()..inject(0),
    wb2Stb: Logic()..inject(0),
    wb2We: Logic()..inject(0),
    wb2Addr: Logic(width: Ddr3Controller.wb2AddrBits)..inject(0),
    wb2Sel: Logic(width: Ddr3Controller.wb2SelBits)..inject(0),
    wb2Data: Logic(width: Ddr3Controller.wb2DataBits)..inject(0),
    phyIserdesData: Logic(width: p.dqBits * p.lanes * 8)..inject(0),
    phyIserdesDqs: dqs,
    phyIserdesBitslipReference: Logic(width: p.lanes * 8)
      ..inject(BigInt.parse('78' * p.lanes, radix: 16)),
    phyIdelayctrlRdy: Logic()..inject(1),
  );
  await ctrl.build();
  Logic sig(String n) => ctrl.signals.firstWhere((s) => s.name == n);
  int state() => ctrl.debug1.value.getRange(0, 6).toInt();
  Simulator.setMaxSimTime(2000000);
  unawaited(Simulator.run());
  await clk.nextNegedge;
  await clk.nextNegedge;
  rstN.inject(1);
  final passes = <_Pass>[];
  var collection = -1;
  var previous = -1;
  for (var cycle = 0; cycle < 30000; cycle++) {
    await clk.nextNegedge;
    final now = state();
    if (now == _collectDqs && previous != _collectDqs) collection++;
    if (now == _collectDqs) {
      final count = sig('dqs_count_repeat').value.toInt();
      final sample = ((0x154 << indexOf(collection)) >> (count * 8)) & 255;
      dqs.inject(
        BigInt.from(sample) *
            ((BigInt.one << (p.lanes * 8)) - BigInt.one) ~/
            BigInt.from(255),
      );
    }
    final index = sig('dqs_start_index').value.toInt();
    if (now == _analyzeDqs && index == indexOf(collection)) {
      final stored = sig('dqs_start_index_stored').value.toInt();
      final repeat = sig('dqs_start_index_repeat').value.toInt();
      await clk.nextNegedge;
      final next = state();
      passes.add((
        collection: collection,
        index: index,
        stored: stored,
        repeat: repeat,
        next: next,
      ));
      if (next == _calibrateDqs) break;
    }
    previous = now;
  }
  await Simulator.endSimulation();
  return passes;
}

void main() {
  tearDown(() async => Simulator.reset());

  test('DQS stability accepts matching samples', () async {
    final passes = await _analyze((_) => 8);
    expect(passes.map((x) => x.next), [2, 2, _calibrateDqs]);
    expect(passes.last.stored, 8);
    expect(passes.last.repeat, 1);
  });

  test('DQS stability rejects a changed latest sample', () async {
    final passes = await _analyze((c) => c >= 2 ? 9 : 8);
    // The third pass sees 9 after two passes of 8. The counter holds a
    // match, but the newest sample does not match, so it does not advance.
    expect(passes[2].stored, 8);
    expect(passes[2].repeat, 1);
    expect(passes[2].next, 2);
  });

  test('DQS stability accepts stable samples after a change', () async {
    final passes = await _analyze((c) => c >= 2 ? 9 : 8);
    expect(passes.last.next, _calibrateDqs);
    expect(passes.last.index, 9);
    expect(passes.last.stored, 9);
    expect(passes.last.collection, 4);
  });

  // The stored index resets to 0, so a start at index 0 matches it on the
  // first pass. Calibration then continues after two passes, not three.
  // UberDDR3 has the same behaviour.
  test('DQS stability at index 0 counts the reset value as a match', () async {
    final passes = await _analyze((_) => 0);
    expect(passes.first.stored, 0);
    expect(passes.first.repeat, 0);
    expect(passes.map((x) => x.next), [2, _calibrateDqs]);
  });
}

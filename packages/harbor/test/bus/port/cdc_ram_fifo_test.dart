import 'dart:async';
import 'dart:math';

import 'package:harbor/src/bus/port/port_cdc.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _width = 40;

// Random pushes and pops across two clocks. Every pop must give the next
// pushed entry, and the head must never be X when the FIFO is not empty.
Future<void> _run(int seed, {required bool trust, int depth = 16}) async {
  final rng = Random(seed);
  final wrPeriod = 2 * (2 + rng.nextInt(20));
  final rdPeriod = 2 * (2 + rng.nextInt(20));
  final wrClk = SimpleClockGenerator(wrPeriod).clk;
  final rdClk = SimpleClockGenerator(rdPeriod).clk;
  final wrReset = Logic(name: 'wr_reset_in');
  final rdReset = Logic(name: 'rd_reset_in');
  final wrEn = Logic(name: 'wr_en_in');
  final wrData = Logic(name: 'wr_data_in', width: _width);
  final rdEn = Logic(name: 'rd_en_in');
  final fifo = HarborWaistCdcFifo(
    wrClk: wrClk,
    wrReset: wrReset,
    wrEn: wrEn,
    wrData: wrData,
    rdClk: rdClk,
    rdReset: rdReset,
    rdEn: rdEn,
    depth: depth,
    trustWrite: trust,
    trustRead: trust,
  );
  await fifo.build();

  const total = 600;
  final pushed = <int>[];
  final popped = <int>[];
  final errors = <String>[];
  Simulator.setMaxSimTime(4000000);
  unawaited(Simulator.run());
  wrReset.inject(1);
  rdReset.inject(1);
  wrEn.inject(0);
  rdEn.inject(0);
  wrData.inject(0);
  for (var i = 0; i < 4; i++) {
    await wrClk.nextPosedge;
    await rdClk.nextPosedge;
  }
  wrReset.inject(0);
  rdReset.inject(0);

  // Inputs change at the negative edge. The full and empty flags only
  // change at a positive edge, so the values seen here hold at the next one.
  final wrBurst = 0.2 + 0.8 * rng.nextDouble();
  final rdBurst = 0.2 + 0.8 * rng.nextDouble();
  var stop = false;
  Future<void> writer() async {
    while (pushed.length < total && !stop) {
      await wrClk.nextNegedge;
      final full = fifo.wrFull.value.toBool();
      final want = rng.nextDouble() < wrBurst;
      final value = rng.nextInt(1 << 32) * 256 + pushed.length % 256;
      final en = want && (!trust || !full);
      wrEn.inject(en ? 1 : 0);
      wrData.inject(value);
      if (en && !full) pushed.add(value);
    }
    await wrClk.nextNegedge;
    wrEn.inject(0);
  }

  Future<void> reader() async {
    while (popped.length < total) {
      await rdClk.nextNegedge;
      final empty = fifo.rdEmpty.value.toBool();
      final want = rng.nextDouble() < rdBurst;
      final en = want && (!trust || !empty);
      rdEn.inject(en ? 1 : 0);
      if (!empty) {
        final head = fifo.rdData.value;
        if (!head.isValid) {
          errors.add('head is X at pop ${popped.length}');
        } else if (en) {
          if (head.toInt() != pushed[popped.length]) {
            errors.add('pop ${popped.length} is wrong');
          }
          popped.add(head.toInt());
        }
        if (errors.isNotEmpty) {
          stop = true;
          break;
        }
      }
    }
    await rdClk.nextNegedge;
    rdEn.inject(0);
  }

  await Future.wait([writer(), reader()]);
  await Simulator.endSimulation();
  final reason = 'seed $seed, wr period $wrPeriod, rd period $rdPeriod';
  expect(errors, isEmpty, reason: reason);
  expect(popped, pushed.take(popped.length).toList(), reason: reason);
  expect(popped.length, total, reason: reason);
}

void main() {
  tearDown(Simulator.reset);

  for (var seed = 1; seed <= 6; seed++) {
    test('random clock ratio, seed $seed', () => _run(seed, trust: false));
  }
  for (var seed = 7; seed <= 9; seed++) {
    test(
      'random clock ratio with trusted enables, seed $seed',
      () => _run(seed, trust: true, depth: 4),
    );
  }

  test('entries are in a RAM with an asynchronous read', () async {
    final fifo = HarborWaistCdcFifo(
      wrClk: Logic(),
      wrReset: Logic(),
      wrEn: Logic(),
      wrData: Logic(width: 73),
      rdClk: Logic(),
      rdReset: Logic(),
      rdEn: Logic(),
      depth: 16,
    );
    await fifo.build();
    final sv = SynthBuilder(
      fifo,
      SystemVerilogSynthesizer(),
    ).getSynthFileContents().map((f) => f.contents).join();
    expect(sv, contains('module HarborWaistCdcRam_73x16'));
    expect(sv, contains('if (wr_en) mem[wr_addr] <= wr_data;'));
    expect(sv, contains('assign rd_data = mem[rd_addr];'));
    expect(sv, isNot(contains('mem_15')));
  });
}

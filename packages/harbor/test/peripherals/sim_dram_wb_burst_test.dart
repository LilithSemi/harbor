import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'sim_dram_ref_model.dart';

/// The registered-feedback burst timing [HarborSimDram]'s bus port carries
/// in its generated SystemVerilog, through [SimDramRefModel] (see that
/// file for why a plain-Dart twin stands in for the real leaf).
void main() {
  tearDown(() async => Simulator.reset());

  test('a burst acks the first beat at the configured latency, then one '
      'word a cycle until the beat tagged 111', () async {
    const readLatency = 4;
    final clk = SimpleClockGenerator(10000).clk;
    final reset = Logic(name: 'reset');
    final stb = Logic(name: 'stb');
    final we = Logic(name: 'we');
    final adr = Logic(name: 'adr', width: 32);
    final datW = Logic(name: 'dat_w', width: 32);
    final cti = Logic(name: 'cti', width: 3);
    final scanRqValid = Logic(name: 'scan_rq_valid');
    final scanRqAddr = Logic(name: 'scan_rq_addr', width: 16);
    final scanRqWords = Logic(name: 'scan_rq_words', width: 4);

    final dram = SimDramRefModel(
      clk: clk,
      reset: reset,
      stb: stb,
      we: we,
      adr: adr,
      datW: datW,
      sel: Const(0xf, width: 4),
      cti: cti,
      scanRqValid: scanRqValid,
      scanRqAddr: scanRqAddr,
      scanRqWords: scanRqWords,
      readLatency: readLatency,
      writeLatency: readLatency,
    );

    reset.inject(1);
    stb.inject(0);
    we.inject(0);
    adr.inject(0);
    datW.inject(0);
    cti.inject(0);
    scanRqValid.inject(0);
    scanRqAddr.inject(0);
    scanRqWords.inject(0);

    Simulator.setMaxSimTime(1 << 40);
    unawaited(Simulator.run());

    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.put(0);
    await clk.nextPosedge;

    // 4-beat read burst: 3 incrementing beats then one end-of-burst beat.
    // Ack stays high for the whole burst once it starts (Wishbone
    // registered feedback), so the first beat is timed by waiting for
    // it, and every later beat by a single clock edge with ack already
    // there: no wait state between beats.
    const beats = [0x2, 0x2, 0x2, 0x7];
    stb.inject(1);
    cti.inject(beats[0]);
    adr.inject(0);
    var n0 = 0;
    while (dram.ack.value != LogicValue.one) {
      await clk.nextPosedge;
      n0++;
      if (n0 > 1000) fail('no ack from the first beat after 1000 cycles');
    }
    expect(
      n0,
      equals(readLatency),
      reason: 'the first beat costs the configured latency',
    );

    for (var i = 1; i < beats.length; i++) {
      cti.inject(beats[i]);
      adr.inject(i * 4);
      await clk.nextPosedge;
      expect(
        dram.ack.value,
        equals(LogicValue.one),
        reason: 'beat $i acks one cycle after its own strobe',
      );
    }
    stb.inject(0);
    await clk.nextPosedge;
    expect(
      dram.ack.value,
      equals(LogicValue.zero),
      reason: 'the burst ended at the beat tagged 111',
    );

    // After the end-of-burst beat, a classic access pays the full
    // latency again instead of free-running.
    stb.inject(1);
    cti.inject(0);
    adr.inject(0x100);
    var afterBurst = 0;
    while (dram.ack.value != LogicValue.one) {
      await clk.nextPosedge;
      afterBurst++;
      if (afterBurst > 1000) {
        fail('no ack from the post-burst access after 1000 cycles');
      }
    }
    stb.inject(0);
    await clk.nextPosedge;
    expect(afterBurst, equals(readLatency));

    await Simulator.endSimulation();
  });

  test('a write burst writes every beat to its own address', () async {
    const latency = 2;
    final clk = SimpleClockGenerator(10000).clk;
    final reset = Logic(name: 'reset');
    final stb = Logic(name: 'stb');
    final we = Logic(name: 'we');
    final adr = Logic(name: 'adr', width: 32);
    final datW = Logic(name: 'dat_w', width: 32);
    final cti = Logic(name: 'cti', width: 3);
    final scanRqValid = Logic(name: 'scan_rq_valid');
    final scanRqAddr = Logic(name: 'scan_rq_addr', width: 16);
    final scanRqWords = Logic(name: 'scan_rq_words', width: 4);

    final dram = SimDramRefModel(
      clk: clk,
      reset: reset,
      stb: stb,
      we: we,
      adr: adr,
      datW: datW,
      sel: Const(0xf, width: 4),
      cti: cti,
      scanRqValid: scanRqValid,
      scanRqAddr: scanRqAddr,
      scanRqWords: scanRqWords,
      readLatency: latency,
      writeLatency: latency,
    );

    reset.inject(1);
    stb.inject(0);
    we.inject(1);
    adr.inject(0);
    datW.inject(0);
    cti.inject(0);
    scanRqValid.inject(0);
    scanRqAddr.inject(0);
    scanRqWords.inject(0);

    Simulator.setMaxSimTime(1 << 40);
    unawaited(Simulator.run());

    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.put(0);
    await clk.nextPosedge;

    const beats = [0x2, 0x2, 0x7];
    stb.inject(1);
    cti.inject(beats[0]);
    adr.inject(0);
    datW.inject(0x1000);
    var n = 0;
    while (dram.ack.value != LogicValue.one) {
      await clk.nextPosedge;
      n++;
      if (n > 1000) fail('no ack from the first write beat after 1000 cycles');
    }
    for (var i = 1; i < beats.length; i++) {
      cti.inject(beats[i]);
      adr.inject(i * 4);
      datW.inject(0x1000 + i);
      await clk.nextPosedge;
    }
    stb.inject(0);
    await clk.nextPosedge;

    for (var i = 0; i < beats.length; i++) {
      expect(dram.peek(i), equals(0x1000 + i), reason: 'beat $i');
    }

    await Simulator.endSimulation();
  });
}

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:harbor/src/peripherals/led_engine_stage.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _ledBase = 0x10005000;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('the dma source builds a master port and rejects pwm', () {
    final led = HarborLedEngine(
      baseAddress: _ledBase,
      pixelSource: HarborLedPixelSource.dma,
    );
    expect(led.dma, isNotNull);
    expect(
      () => HarborLedEngine(
        baseAddress: _ledBase,
        pixelSource: HarborLedPixelSource.dma,
        channels: const [
          HarborLedChannelConfig.pwm([HarborLedPin(0, HarborLedByte.b)]),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => HarborLedEngine(
        baseAddress: _ledBase,
        pixelSource: HarborLedPixelSource.dma,
        dmaDataWidth: 48,
      ),
      throwsArgumentError,
    );
  });

  registerFetch();
  registerFetchError();
}

void registerFetch() {
  test('the fetch takes the word of each beat on a 64 bit bus', () async {
    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final start = Logic(name: 'start');
    final accepted = Logic(name: 'accepted');
    final rvalid = Logic(name: 'rvalid');
    final rerr = Logic(name: 'rerr');
    final rlast = Logic(name: 'rlast');
    final popReq = Logic(name: 'pop_req');
    final total = Logic(name: 'total', width: 3);
    final base = Logic(name: 'base', width: 30);
    final rdata = Logic(name: 'rdata', width: 64);
    final f = HarborLedDmaFetch(
      clk: clk,
      reset: reset,
      start: start,
      total: total,
      base: base,
      accepted: accepted,
      rvalid: rvalid,
      rdata: rdata,
      rerr: rerr,
      rlast: rlast,
      popReq: popReq,
      addressWidth: 32,
      dataWidth: 64,
      maxPixels: 7,
    );
    await f.build();
    for (final l in [start, accepted, rvalid, rerr, rlast, popReq]) {
      l.inject(0);
    }
    total.inject(5);
    base.inject(0x20000001);
    rdata.inject(0);
    reset.inject(1);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    reset.inject(0);
    await clk.nextPosedge;
    start.inject(1);
    await clk.nextPosedge;
    start.inject(0);
    await clk.nextPosedge;
    await clk.nextNegedge;
    expect(f.req.value.toInt(), equals(1));
    expect(f.reqAddr.value.toInt(), equals(0x80000004));
    expect(
      f.reqLen.value.toInt(),
      equals(2),
      reason: '3 beats to the block end',
    );
    accepted.inject(1);
    await clk.nextPosedge;
    accepted.inject(0);
    final beats = [
      (0x1001 << 32) | 0x1000,
      (0x1003 << 32) | 0x1002,
      (0x1003 << 32) | 0x1002,
    ];
    for (var i = 0; i < beats.length; i++) {
      rdata.inject(beats[i]);
      rvalid.inject(1);
      rlast.inject(i == beats.length - 1 ? 1 : 0);
      await clk.nextPosedge;
    }
    rvalid.inject(0);
    rlast.inject(0);
    popReq.inject(1);
    final got = <int>[];
    for (var i = 0; i < 6; i++) {
      await clk.nextNegedge;
      if (f.grant.value.toInt() == 1) got.add(f.word.value.toInt());
    }
    expect(got, equals([0x1001, 0x1002, 0x1003]));
    await Simulator.endSimulation();
  });
}

// A fetch of 4 words with a beat that fails in the middle of its burst, then
// a good frame. The rest of the failed burst must not reach the good frame.
void registerFetchError() {
  for (final overlap in [false, true]) {
    test(
      'a failed beat in a 4 beat burst leaves no stale word '
      '(${overlap ? 'the next frame starts during the drain' : 'after the drain'})',
      () async {
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final start = Logic(name: 'start');
        final accepted = Logic(name: 'accepted');
        final rvalid = Logic(name: 'rvalid');
        final rerr = Logic(name: 'rerr');
        final rlast = Logic(name: 'rlast');
        final popReq = Logic(name: 'pop_req');
        final total = Logic(name: 'total', width: 3);
        final base = Logic(name: 'base', width: 30);
        final rdata = Logic(name: 'rdata', width: 32);
        final f = HarborLedDmaFetch(
          clk: clk,
          reset: reset,
          start: start,
          total: total,
          base: base,
          accepted: accepted,
          rvalid: rvalid,
          rdata: rdata,
          rerr: rerr,
          rlast: rlast,
          popReq: popReq,
          addressWidth: 32,
          dataWidth: 32,
          maxPixels: 7,
        );
        await f.build();
        for (final l in [start, accepted, rvalid, rerr, rlast, popReq]) {
          l.inject(0);
        }
        total.inject(4);
        base.inject(0x20000000);
        rdata.inject(0);
        reset.inject(1);
        Simulator.setMaxSimTime(100000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        Future<void> startFrame() async {
          start.inject(1);
          await clk.nextPosedge;
          start.inject(0);
          await clk.nextPosedge;
        }

        Future<void> accept() async {
          for (var i = 0; i < 6 && f.req.value.toInt() != 1; i++) {
            await clk.nextNegedge;
          }
          expect(f.req.value.toInt(), equals(1));
          expect(f.reqLen.value.toInt(), equals(3));
          accepted.inject(1);
          await clk.nextPosedge;
          accepted.inject(0);
        }

        // One beat. The check is at the falling edge, before the beat is taken.
        Future<void> beat(
          int data, {
          bool err = false,
          bool last = false,
          bool startNow = false,
        }) async {
          rdata.inject(data);
          rvalid.inject(1);
          rerr.inject(err ? 1 : 0);
          rlast.inject(last ? 1 : 0);
          start.inject(startNow ? 1 : 0);
          await clk.nextNegedge;
          if (err) expect(f.abort.value.toInt(), equals(1));
          await clk.nextPosedge;
          start.inject(0);
          rvalid.inject(0);
          rerr.inject(0);
          rlast.inject(0);
        }

        await startFrame();
        await accept();
        await beat(0xA0);
        await beat(0xBAD1, err: true);
        await beat(0xBAD2, startNow: overlap);
        await beat(0xBAD3, last: true);
        if (!overlap) await startFrame();
        await clk.nextNegedge;
        expect(f.abort.value.toInt(), equals(0));
        await accept();
        for (var i = 0; i < 4; i++) {
          await beat(0x100 + i, last: i == 3);
        }
        popReq.inject(1);
        final got = <int>[];
        for (var i = 0; i < 8; i++) {
          await clk.nextNegedge;
          if (f.grant.value.toInt() == 1) got.add(f.word.value.toInt());
        }
        expect(got, equals([0x100, 0x101, 0x102, 0x103]));
        await Simulator.endSimulation();
      },
    );
  }
}

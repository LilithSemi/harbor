import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_downsizer.dart';

/// Drives the downsizer's wide (64-bit) slave face and models a narrow (32-bit)
/// one-cycle Wishbone register slave on the master side, checking that a 64-bit
/// write lands as two 32-bit halves (low at adr, high at adr+4) and a 64-bit
/// read assembles `{high, low}` back into the original word.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('64-bit access splits into two 32-bit halves and reassembles', () async {
    const aw = 32;
    const wide = 64;
    const narrow = 32;
    final dut = HarborWishboneDownsizer(
      addressWidth: aw,
      wideWidth: wide,
      narrowWidth: narrow,
    );

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: wide);
    final sSel = Logic(name: 's_sel', width: wide ~/ 8);

    dut.input('clk').srcConnection! <= clk;
    dut.input('reset').srcConnection! <= reset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= sSel;

    // Narrow slave: two 32-bit cells at adr 0x40 (low) and 0x44 (high). ACK is
    // combinational on the master cycle, writes store on the edge.
    final memLo = Logic(name: 'mem_lo', width: narrow);
    final memHi = Logic(name: 'mem_hi', width: narrow);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final mWe = dut.output('m_we');
    final mAdr = dut.output('m_adr');
    final mDatW = dut.output('m_dat_w');
    final isHi = mAdr.eq(Const(0x44, width: aw));
    dut.input('m_ack').srcConnection! <= (mCyc & mStb);
    dut.input('m_err').srcConnection! <= Const(0);
    dut.input('m_dat_r').srcConnection! <= mux(isHi, memHi, memLo);
    Sequential(clk, reset: reset, [
      If(
        mCyc & mStb & mWe,
        then: [
          If(isHi, then: [memHi < mDatW], orElse: [memLo < mDatW]),
        ],
      ),
    ]);

    reset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    sSel.inject(0xff);

    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());

    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    Future<BigInt> doXfer({
      required bool we,
      int adr = 0x40,
      BigInt? data,
    }) async {
      sWe.inject(we ? 1 : 0);
      sAdr.inject(adr);
      sDatW.inject(data ?? BigInt.zero);
      sCyc.inject(1);
      sStb.inject(1);
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await clk.nextPosedge;
        if (++guard > 500) fail('timeout waiting for s_ack (we=$we)');
      }
      final rd = dut.output('s_dat_r').value.toBigInt();
      sCyc.inject(0);
      sStb.inject(0);
      await clk.nextPosedge;
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      return rd;
    }

    final word = BigInt.parse('1122334455667788', radix: 16);
    await doXfer(we: true, adr: 0x40, data: word);

    // Halves landed at the right narrow addresses.
    expect(
      memLo.value.toInt(),
      equals(0x55667788),
      reason: 'low half must write to adr 0x40',
    );
    expect(
      memHi.value.toInt(),
      equals(0x11223344),
      reason: 'high half must write to adr 0x44',
    );

    final rd = await doXfer(we: false, adr: 0x40);
    expect(
      rd,
      equals(word),
      reason: 'read must reassemble {high, low} into the original 64-bit word',
    );

    await Simulator.endSimulation();
  });

  // Liveness: a lost downstream completion (m_ack never comes) must NOT wedge the
  // downsizer forever: the watchdog re-issues each beat and, after the budget,
  // force-completes so the wide read still acks. This is the creek Ferrite hang:
  // one lost PHY read-valid had no recovery anywhere in the read chain.
  test('watchdog force-completes a lost narrow read (no hang)', () async {
    const aw = 32;
    const wide = 64;
    const narrow = 32;
    final dut = HarborWishboneDownsizer(
      addressWidth: aw,
      wideWidth: wide,
      narrowWidth: narrow,
      completionTimeout: 8, // small so the test is short
      maxReissues: 2,
    );

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: wide);
    final sSel = Logic(name: 's_sel', width: wide ~/ 8);

    dut.input('clk').srcConnection! <= clk;
    dut.input('reset').srcConnection! <= reset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= sSel;
    // Narrow slave that NEVER acks: models a permanently lost PHY read-valid.
    dut.input('m_ack').srcConnection! <= Const(0);
    dut.input('m_err').srcConnection! <= Const(0);
    dut.input('m_dat_r').srcConnection! <= Const(0xDEAD, width: narrow);

    reset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    sSel.inject(0xff);
    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    // Drive a 64-bit read and count how many times m_cyc is re-issued while it is
    // outstanding (a fall from 1 to 0 after having been driven).
    sWe.inject(0);
    sAdr.inject(0x40);
    sCyc.inject(1);
    sStb.inject(1);
    var reissues = 0;
    var prevMCyc = false;
    var terminated = false;
    for (var guard = 0; guard < 400; guard++) {
      await clk.nextPosedge;
      final mc = dut.output('m_cyc').value == LogicValue.one;
      if (prevMCyc && !mc) reissues++;
      prevMCyc = mc;
      if (dut.output('s_ack').value == LogicValue.one ||
          dut.output('s_err').value == LogicValue.one) {
        terminated = true;
        break;
      }
    }
    expect(
      terminated,
      isTrue,
      reason: 'watchdog must force-complete a lost read (no permanent hang)',
    );
    // A forced completion is reported as ERR, not a fake ACK with
    // poisoned data: the master must know the word was never verified.
    expect(
      dut.output('s_err').value,
      equals(LogicValue.one),
      reason: 'a watchdog-forced completion must report ERR, not ACK',
    );
    expect(dut.output('s_ack').value, equals(LogicValue.zero));
    // Each of the two beats re-issues maxReissues times, then force-completes
    // (its final drop also counts), so several re-issues are observed, the point
    // is only that it recovered rather than wedging.
    expect(
      reissues,
      greaterThan(0),
      reason: 'the beat should have been re-issued before force-completing',
    );
    await Simulator.endSimulation();
  });

  // Error response: the narrow slave terminates with ERR instead of ACK.
  // The downsizer must report ERR on the wide side (not fake an ACK with
  // garbage data) and must not issue the high half after a low-half error.
  test(
    'narrow ERR on the low half terminates with ERR, no high half',
    () async {
      const aw = 32;
      const wide = 64;
      const narrow = 32;
      final dut = HarborWishboneDownsizer(
        addressWidth: aw,
        wideWidth: wide,
        narrowWidth: narrow,
      );

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final sCyc = Logic(name: 's_cyc');
      final sStb = Logic(name: 's_stb');
      final sWe = Logic(name: 's_we');
      final sAdr = Logic(name: 's_adr', width: aw);
      final sDatW = Logic(name: 's_dat_w', width: wide);
      final sSel = Logic(name: 's_sel', width: wide ~/ 8);

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('s_cyc').srcConnection! <= sCyc;
      dut.input('s_stb').srcConnection! <= sStb;
      dut.input('s_we').srcConnection! <= sWe;
      dut.input('s_adr').srcConnection! <= sAdr;
      dut.input('s_dat_w').srcConnection! <= sDatW;
      dut.input('s_sel').srcConnection! <= sSel;

      final mCyc = dut.output('m_cyc');
      final mStb = dut.output('m_stb');
      var highIssued = false;
      dut.input('m_ack').srcConnection! <= Const(0);
      dut.input('m_err').srcConnection! <= (mCyc & mStb);
      dut.input('m_dat_r').srcConnection! <= Const(0xBAD, width: narrow);

      reset.inject(1);
      sCyc.inject(0);
      sStb.inject(0);
      sWe.inject(0);
      sAdr.inject(0);
      sDatW.inject(0);
      sSel.inject(0xff);
      Simulator.setMaxSimTime(20000);
      unawaited(Simulator.run());
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      await clk.nextPosedge;

      sWe.inject(0);
      sAdr.inject(0x40);
      sCyc.inject(1);
      sStb.inject(1);
      for (var guard = 0; guard < 200; guard++) {
        await clk.nextPosedge;
        if (dut.output('m_adr').value.toInt() == 0x44 &&
            dut.output('m_cyc').value == LogicValue.one) {
          highIssued = true;
        }
        if (dut.output('s_err').value == LogicValue.one ||
            dut.output('s_ack').value == LogicValue.one) {
          break;
        }
      }
      expect(dut.output('s_err').value, equals(LogicValue.one));
      expect(dut.output('s_ack').value, equals(LogicValue.zero));
      expect(
        highIssued,
        isFalse,
        reason: 'a low-half error must skip the high half entirely',
      );
      await Simulator.endSimulation();
    },
  );

  // Backpressure: the narrow slave can delay its ack by several cycles
  // (well under the watchdog) without the downsizer mis-firing or losing
  // the transaction.
  test('waits through a delayed narrow ack (backpressure)', () async {
    const aw = 32;
    const wide = 64;
    const narrow = 32;
    final dut = HarborWishboneDownsizer(
      addressWidth: aw,
      wideWidth: wide,
      narrowWidth: narrow,
    );

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: wide);
    final sSel = Logic(name: 's_sel', width: wide ~/ 8);

    dut.input('clk').srcConnection! <= clk;
    dut.input('reset').srcConnection! <= reset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= sSel;

    // Narrow slave that holds off its ack for a fixed number of cycles per
    // beat, well under the (default, large) watchdog budget.
    final delayCnt = Logic(name: 'delay_cnt', width: 8);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final mAdr = dut.output('m_adr');
    final isHi = mAdr.eq(Const(0x44, width: aw));
    const delayCycles = 5;
    final delayedAck =
        (mCyc & mStb) & delayCnt.gte(Const(delayCycles, width: 8));
    Sequential(clk, reset: reset, [
      If(
        ~(mCyc & mStb),
        then: [delayCnt < Const(0, width: 8)],
        orElse: [
          If(
            delayCnt.lt(Const(delayCycles, width: 8)),
            then: [delayCnt < delayCnt + 1],
          ),
        ],
      ),
    ]);
    dut.input('m_ack').srcConnection! <= delayedAck;
    dut.input('m_err').srcConnection! <= Const(0);
    dut.input('m_dat_r').srcConnection! <=
        mux(
          isHi,
          Const(0x22222222, width: narrow),
          Const(0x11111111, width: narrow),
        );

    reset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    sSel.inject(0xff);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    sWe.inject(0);
    sAdr.inject(0x40);
    sCyc.inject(1);
    sStb.inject(1);
    var guard = 0;
    while (dut.output('s_ack').value != LogicValue.one) {
      await clk.nextPosedge;
      if (++guard > 500) fail('timeout waiting for s_ack under backpressure');
    }
    expect(dut.output('s_err').value, equals(LogicValue.zero));
    expect(
      dut.output('s_dat_r').value.toBigInt(),
      equals(BigInt.parse('2222222211111111', radix: 16)),
      reason: 'data must assemble correctly despite the delayed acks',
    );
    await Simulator.endSimulation();
  });

  // Abort: the master drops CYC mid-split. The downsizer must tear down
  // without acking or erroring the aborted cycle, then accept a fresh
  // transaction cleanly afterwards.
  test(
    'abort mid-split: no stray ack/err, next transaction is clean',
    () async {
      const aw = 32;
      const wide = 64;
      const narrow = 32;
      final dut = HarborWishboneDownsizer(
        addressWidth: aw,
        wideWidth: wide,
        narrowWidth: narrow,
      );

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final sCyc = Logic(name: 's_cyc');
      final sStb = Logic(name: 's_stb');
      final sWe = Logic(name: 's_we');
      final sAdr = Logic(name: 's_adr', width: aw);
      final sDatW = Logic(name: 's_dat_w', width: wide);
      final sSel = Logic(name: 's_sel', width: wide ~/ 8);

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('s_cyc').srcConnection! <= sCyc;
      dut.input('s_stb').srcConnection! <= sStb;
      dut.input('s_we').srcConnection! <= sWe;
      dut.input('s_adr').srcConnection! <= sAdr;
      dut.input('s_dat_w').srcConnection! <= sDatW;
      dut.input('s_sel').srcConnection! <= sSel;

      // Narrow slave that never acks the aborted beat (models a slow slave the
      // master gives up on), then acks normally for the next transaction.
      final memLo = Logic(name: 'mem_lo', width: narrow);
      final memHi = Logic(name: 'mem_hi', width: narrow);
      final mCyc = dut.output('m_cyc');
      final mStb = dut.output('m_stb');
      final mWe = dut.output('m_we');
      final mAdr = dut.output('m_adr');
      final mDatW = dut.output('m_dat_w');
      final allowAck = Logic(name: 'allow_ack');
      final isHi = mAdr.eq(Const(0x44, width: aw));
      dut.input('m_ack').srcConnection! <= (mCyc & mStb & allowAck);
      dut.input('m_err').srcConnection! <= Const(0);
      dut.input('m_dat_r').srcConnection! <= mux(isHi, memHi, memLo);
      Sequential(clk, reset: reset, [
        If(
          mCyc & mStb & mWe & allowAck,
          then: [
            If(isHi, then: [memHi < mDatW], orElse: [memLo < mDatW]),
          ],
        ),
      ]);

      reset.inject(1);
      sCyc.inject(0);
      sStb.inject(0);
      sWe.inject(0);
      sAdr.inject(0);
      sDatW.inject(0);
      sSel.inject(0xff);
      allowAck.inject(0);
      Simulator.setMaxSimTime(20000);
      unawaited(Simulator.run());
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      await clk.nextPosedge;

      // Start a read, let the low half go outstanding, then abort.
      sWe.inject(0);
      sAdr.inject(0x40);
      sCyc.inject(1);
      sStb.inject(1);
      await clk.nextPosedge;
      await clk.nextPosedge;
      sCyc.inject(0);
      sStb.inject(0);

      // The aborted cycle must never produce a stray ack or err once dropped.
      for (var i = 0; i < 10; i++) {
        await clk.nextPosedge;
        expect(dut.output('s_ack').value, equals(LogicValue.zero));
        expect(dut.output('s_err').value, equals(LogicValue.zero));
      }

      // Now let the slave ack freely and run a clean write, confirming the
      // module is ready for fresh work (not wedged by the abort).
      allowAck.inject(1);
      final word = BigInt.parse('cafef00ddeadbeef', radix: 16);
      sWe.inject(1);
      sAdr.inject(0x40);
      sDatW.inject(word);
      sCyc.inject(1);
      sStb.inject(1);
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await clk.nextPosedge;
        if (++guard > 500) fail('timeout waiting for s_ack after abort');
      }
      sCyc.inject(0);
      sStb.inject(0);
      expect(memLo.value.toInt(), equals(0xdeadbeef));
      expect(memHi.value.toInt(), equals(0xcafef00d));

      await Simulator.endSimulation();
    },
  );
}

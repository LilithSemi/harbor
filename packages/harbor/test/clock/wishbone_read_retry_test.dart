import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_read_retry.dart';

/// Drives the read-retry filter's slave face and models a GLITCHY one-cycle
/// Wishbone register slave on the master side: the FIRST read of each
/// transaction returns garbage, every subsequent read returns the correct
/// stored word (the intermittent-but-re-reads-correct DDR read defect). The
/// filter must retry until two consecutive reads agree and return the correct
/// word. Writes must pass straight through.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('retries a glitchy read until two agree; write passes through', () async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneReadRetry(addressWidth: aw, dataWidth: dw);

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: dw);
    final sSel = Logic(name: 's_sel', width: dw ~/ 8);

    dut.input('clk').srcConnection! <= clk;
    dut.input('reset').srcConnection! <= reset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= sSel;

    // Glitchy master slave: one stored cell, combinational ack on the master
    // cycle. The first read since the last slave ack returns garbage, the rest
    // return the stored value. Writes store on the edge.
    final mem = Logic(name: 'mem', width: dw);
    final rdSinceAck = Logic(name: 'rd_since_ack', width: 4);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final mWe = dut.output('m_we');
    final mDatW = dut.output('m_dat_w');
    final mRead = mCyc & mStb & ~mWe;
    final mAck = mCyc & mStb;
    final glitch = mRead & rdSinceAck.eq(0);
    dut.input('m_ack').srcConnection! <= mAck;
    dut.input('m_err').srcConnection! <= Const(0);
    dut.input('m_dat_r').srcConnection! <=
        mux(glitch, Const(0xDEADBEEF, width: dw), mem);
    Sequential(clk, reset: reset, [
      If(
        reset | dut.output('s_ack'),
        then: [rdSinceAck < Const(0, width: 4)],
        orElse: [
          If(mRead & mAck, then: [rdSinceAck < rdSinceAck + 1]),
        ],
      ),
      If(mCyc & mStb & mWe, then: [mem < mDatW]),
    ]);

    reset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    sSel.inject(0xf);

    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    Future<int> doXfer({required bool we, int adr = 0x80, int data = 0}) async {
      sWe.inject(we ? 1 : 0);
      sAdr.inject(adr);
      sDatW.inject(data);
      sCyc.inject(1);
      sStb.inject(1);
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await clk.nextPosedge;
        if (++guard > 500) fail('timeout waiting for s_ack (we=$we)');
      }
      final rd = dut.output('s_dat_r').value.toInt();
      sCyc.inject(0);
      sStb.inject(0);
      await clk.nextPosedge;
      await clk.nextPosedge;
      return rd;
    }

    // Write passes through to the backing.
    await doXfer(we: true, adr: 0x80, data: 0x11223344);
    expect(
      mem.value.toInt(),
      equals(0x11223344),
      reason: 'write must pass through to the master',
    );

    // Read: the first master read glitches (0xDEADBEEF), retries converge on
    // the correct stored word.
    final rd = await doXfer(we: false, adr: 0x80);
    expect(
      rd,
      equals(0x11223344),
      reason: 'read-retry must return the correct word despite the glitch',
    );

    // A second read (again first-read-glitches) still returns correct.
    final rd2 = await doXfer(we: false, adr: 0x80);
    expect(rd2, equals(0x11223344), reason: 'read-retry must be repeatable');

    await Simulator.endSimulation();
  });

  // Error response: the master terminates with ERR instead of ACK. An
  // error is authoritative and must end the transaction immediately,
  // without being retried through the read-voting loop.
  test('master ERR terminates immediately with ERR, no retry', () async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneReadRetry(addressWidth: aw, dataWidth: dw);

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: dw);
    final sSel = Logic(name: 's_sel', width: dw ~/ 8);

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
    var reIssued = false;
    var mReadCycles = 0;
    dut.input('m_ack').srcConnection! <= Const(0);
    dut.input('m_err').srcConnection! <= (mCyc & mStb);
    dut.input('m_dat_r').srcConnection! <= Const(0xBAD, width: dw);

    reset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    sSel.inject(0xf);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    sWe.inject(0);
    sAdr.inject(0x80);
    sCyc.inject(1);
    sStb.inject(1);
    for (var guard = 0; guard < 200; guard++) {
      await clk.nextPosedge;
      if (mCyc.value == LogicValue.one && mStb.value == LogicValue.one) {
        mReadCycles++;
      }
      if (dut.output('s_err').value == LogicValue.one ||
          dut.output('s_ack').value == LogicValue.one) {
        break;
      }
    }
    // Only one master read should ever have been issued: an ERR is
    // authoritative and short-circuits the voting loop.
    reIssued = mReadCycles > 1;
    expect(dut.output('s_err').value, equals(LogicValue.one));
    expect(dut.output('s_ack').value, equals(LogicValue.zero));
    expect(
      reIssued,
      isFalse,
      reason: 'an ERR must not be retried through the voting loop',
    );
    await Simulator.endSimulation();
  });

  // Backpressure: the master can delay its ack across several cycles
  // without the filter mis-firing.
  test('waits through a delayed master ack (backpressure)', () async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneReadRetry(addressWidth: aw, dataWidth: dw);

    final clk = SimpleClockGenerator(10).clk;
    final reset = Logic(name: 'reset');
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: dw);
    final sSel = Logic(name: 's_sel', width: dw ~/ 8);

    dut.input('clk').srcConnection! <= clk;
    dut.input('reset').srcConnection! <= reset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= sSel;

    final mem = Logic(name: 'mem', width: dw);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final delayCnt = Logic(name: 'delay_cnt', width: 8);
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
    dut.input('m_dat_r').srcConnection! <= mem;

    reset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    sSel.inject(0xf);
    mem.inject(0x55667788);
    Simulator.setMaxSimTime(20000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    await clk.nextPosedge;

    sWe.inject(0);
    sAdr.inject(0x80);
    sCyc.inject(1);
    sStb.inject(1);
    var guard = 0;
    while (dut.output('s_ack').value != LogicValue.one) {
      await clk.nextPosedge;
      if (++guard > 500) fail('timeout waiting for s_ack under backpressure');
    }
    expect(dut.output('s_err').value, equals(LogicValue.zero));
    expect(dut.output('s_dat_r').value.toInt(), equals(0x55667788));
    await Simulator.endSimulation();
  });

  // Abort: the master drops CYC mid-retry. The filter must tear down
  // without acking or erroring the aborted cycle, then accept a fresh
  // transaction cleanly afterwards.
  test(
    'abort mid-retry: no stray ack/err, next transaction is clean',
    () async {
      const aw = 32;
      const dw = 32;
      final dut = HarborWishboneReadRetry(addressWidth: aw, dataWidth: dw);

      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final sCyc = Logic(name: 's_cyc');
      final sStb = Logic(name: 's_stb');
      final sWe = Logic(name: 's_we');
      final sAdr = Logic(name: 's_adr', width: aw);
      final sDatW = Logic(name: 's_dat_w', width: dw);
      final sSel = Logic(name: 's_sel', width: dw ~/ 8);

      dut.input('clk').srcConnection! <= clk;
      dut.input('reset').srcConnection! <= reset;
      dut.input('s_cyc').srcConnection! <= sCyc;
      dut.input('s_stb').srcConnection! <= sStb;
      dut.input('s_we').srcConnection! <= sWe;
      dut.input('s_adr').srcConnection! <= sAdr;
      dut.input('s_dat_w').srcConnection! <= sDatW;
      dut.input('s_sel').srcConnection! <= sSel;

      // A read that never settles (always glitches), so the module would
      // keep retrying forever if the abort never tore it down.
      final mCyc = dut.output('m_cyc');
      final mStb = dut.output('m_stb');
      final allowAck = Logic(name: 'allow_ack');
      final mem = Logic(name: 'mem', width: dw);
      final toggle = Logic(name: 'toggle', width: dw);
      dut.input('m_ack').srcConnection! <= (mCyc & mStb & allowAck);
      dut.input('m_err').srcConnection! <= Const(0);
      dut.input('m_dat_r').srcConnection! <= mux(allowAck, toggle, mem);
      Sequential(clk, reset: reset, [
        If(mCyc & mStb & allowAck, then: [toggle < ~toggle]),
      ]);

      reset.inject(1);
      sCyc.inject(0);
      sStb.inject(0);
      sWe.inject(0);
      sAdr.inject(0);
      sDatW.inject(0);
      sSel.inject(0xf);
      mem.inject(0x11223344);
      allowAck.inject(0);
      Simulator.setMaxSimTime(20000);
      unawaited(Simulator.run());
      for (var i = 0; i < 4; i++) {
        await clk.nextPosedge;
      }
      reset.inject(0);
      await clk.nextPosedge;

      // Start a read; the master never acks so it sits mid-flight, then abort.
      sWe.inject(0);
      sAdr.inject(0x80);
      sCyc.inject(1);
      sStb.inject(1);
      await clk.nextPosedge;
      await clk.nextPosedge;
      sCyc.inject(0);
      sStb.inject(0);

      for (var i = 0; i < 10; i++) {
        await clk.nextPosedge;
        expect(dut.output('s_ack').value, equals(LogicValue.zero));
        expect(dut.output('s_err').value, equals(LogicValue.zero));
      }

      // Now let the slave ack freely and run a clean read, confirming the
      // module is ready for fresh work (not wedged chasing the abort).
      allowAck.inject(1);
      sWe.inject(0);
      sAdr.inject(0x80);
      sCyc.inject(1);
      sStb.inject(1);
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await clk.nextPosedge;
        if (++guard > 500) fail('timeout waiting for s_ack after abort');
      }
      sCyc.inject(0);
      sStb.inject(0);
      await Simulator.endSimulation();
    },
  );
}

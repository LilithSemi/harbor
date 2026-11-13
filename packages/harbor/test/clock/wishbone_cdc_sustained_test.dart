import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// #136 repro: hammer the CDC bridge with SUSTAINED back-to-back accesses (no
/// drain between transactions), the pattern Weir's bss-clear does. On hardware
/// this wedges the single-outstanding bridge. A deterministic sim should expose
/// a structural handshake stall (as opposed to pure metastability) at some clock
/// ratio: if any transaction fails to ACK, the bridge has a back-to-back race.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Run [n] back-to-back transactions with NO inter-access drain. Returns the
  /// number that completed (== n on success, < n means a wedge/timeout).
  Future<int> hammer({
    required int sPeriod,
    required int mPeriod,
    required int n,
    required bool write,
    int mAckDelay = 1,
  }) async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneCdcBridge(addressWidth: aw, dataWidth: dw);

    final sClk = SimpleClockGenerator(sPeriod + (sPeriod & 1)).clk;
    final mClk = SimpleClockGenerator(mPeriod + (mPeriod & 1)).clk;
    final sReset = Logic(name: 's_reset');
    final mReset = Logic(name: 'm_reset');

    final sCyc = Logic(name: 's_cyc');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: dw);

    dut.input('s_clk').srcConnection! <= sClk;
    dut.input('s_reset').srcConnection! <= sReset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    // The DDR controller ties s_stb high and gates with s_cyc. Mirror that.
    dut.input('s_stb').srcConnection! <= Const(1);
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= Const(0xf, width: dw ~/ 8);
    dut.input('m_clk').srcConnection! <= mClk;
    dut.input('m_reset').srcConnection! <= mReset;

    // Fast-side slave: acks [mAckDelay] fast-cycles after the master cycle opens
    // (models the DDR sequencer's multi-cycle access), holds a single reg.
    final mem = Logic(name: 'mem', width: dw);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final mWe = dut.output('m_we');
    final mDatW = dut.output('m_dat_w');
    final ackCnt = Logic(name: 'ack_cnt', width: 8);
    final mAck = Logic(name: 'm_ack');
    // Count fast cycles the master cycle has been open. Ack when == mAckDelay.
    Sequential(mClk, reset: mReset, [
      If(
        mCyc & mStb,
        then: [
          If(ackCnt.lt(mAckDelay), then: [ackCnt < ackCnt + 1]),
        ],
        orElse: [ackCnt < 0],
      ),
      If(mCyc & mStb & mWe & ackCnt.eq(mAckDelay), then: [mem < mDatW]),
    ]);
    mAck <= (mCyc & mStb & ackCnt.eq(mAckDelay));
    dut.input('m_ack').srcConnection! <= mAck;
    dut.input('m_dat_r').srcConnection! <= mem;

    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);

    Simulator.setMaxSimTime(5000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    // CONTINUOUS cyc: never drop it (the true "no-pause store" burst). s_stb is
    // tied high, so the bridge free-runs one transaction per drained handshake.
    // Count ACK pulses. A wedge shows as a missing next pulse (timeout).
    sWe.inject(write ? 1 : 0);
    sAdr.inject(0x40);
    sDatW.inject(0x1000);
    sCyc.inject(1);
    var done = 0;
    for (var t = 0; t < n; t++) {
      var guard = 0;
      // Wait for this transaction's ack.
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 2000) return done; // wedged
      }
      done++;
      // Present the next store's payload the same cycle we saw ack (pipelined),
      // then wait for ack to fall so we can detect the following pulse.
      sAdr.inject(0x40 + (t + 1) * 4);
      sDatW.inject(0x1000 + t + 1);
      guard = 0;
      while (dut.output('s_ack').value == LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 2000) return done; // ack stuck high
      }
    }
    await Simulator.endSimulation();
    return done;
  }

  // A few phase relationships + ack delays, continuous-cyc (no-pause) burst.
  // FUNCTIONAL guard: every no-pause transaction must ACK. The bridge now
  // crosses through gray-pointer async FIFOs (HarborCdcFifo), so it is correct
  // by construction for ANY phase, which is what fixes the #144 HARDWARE wedge.
  // That wedge was a mesochronous effect (sys=CLKOS 24MHz vs sclk=CLKOP/2 24MHz,
  // same freq, fixed phase) that the OLD four-phase-handshake bridge could drop.
  // Ideal-timing sim cannot reproduce the metastability itself, but the s==m
  // rows below exercise the same-frequency (mesochronous) datapath the fix
  // targets. (Kept fast + few to avoid runner wall-clock flakiness.)
  for (final ratio in const [
    (s: 20, m: 6),
    (s: 10, m: 12),
    (s: 14, m: 6),
    (s: 10, m: 10), // mesochronous: identical frequency (the creek case)
    (s: 12, m: 12),
  ]) {
    for (final ackDelay in const [1, 3]) {
      test(
        'sustained no-pause writes s=${ratio.s} m=${ratio.m} ack=$ackDelay',
        () async {
          final done = await hammer(
            sPeriod: ratio.s,
            mPeriod: ratio.m,
            n: 24,
            write: true,
            mAckDelay: ackDelay,
          );
          expect(
            done,
            24,
            reason: 'all 24 no-pause writes must ACK; got $done',
          );
        },
      );
    }
  }
}

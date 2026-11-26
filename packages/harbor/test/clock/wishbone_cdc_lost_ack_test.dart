import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// #144 completion-path guard.
///
/// History: this file used to ENSHRINE a bridge watchdog that re-issued a
/// transaction when a completion pulse was "lost". That watchdog was removed:
/// the real defect was never the bridge dropping a completion, it was the DDR
/// PHY producing a droppable read-valid. On the live (static, non-trainable)
/// read path the PHY drives rd_valid from the sclk read-latency count (rdPipe),
/// so the completion is TIMED by construction and cannot be dropped at any DQS
/// vs sclk phase. A genuine lost completion is therefore impossible by
/// construction, not masked by a retry, so there is nothing for a watchdog to
/// recover, and a watchdog that re-issues can itself wedge the sequencer.
///
/// This test now asserts the positive contract: with a correctly TIMED
/// one-cycle completion pulse (exactly what the PHY's rdPipe-timed busDone
/// produces), the single-outstanding bridge completes every transaction across
/// a mesochronous crossing. There is no drop injection because the design does
/// not admit one.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Run [n] sustained transactions. The fast-side slave acks with a ONE-CYCLE
  /// pulse per master cycle (like the DDR sequencer's [busDone], timed off the
  /// PHY read-latency count). Returns the number completed.
  Future<int> run({required int n, int sPeriod = 10, int mPeriod = 8}) async {
    const aw = 32;
    const dw = 32;
    // syncStages 4 mirrors the real DDR instantiation.
    final dut = HarborWishboneCdcBridge(
      addressWidth: aw,
      dataWidth: dw,
      syncStages: 4,
    );

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
    dut.input('s_stb').srcConnection! <= Const(1);
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= Const(0xf, width: dw ~/ 8);
    dut.input('m_clk').srcConnection! <= mClk;
    dut.input('m_reset').srcConnection! <= mReset;

    final mem = Logic(name: 'mem', width: dw);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final mWe = dut.output('m_we');
    final mDatW = dut.output('m_dat_w');
    final ackCnt = Logic(name: 'ack_cnt', width: 8);
    final served = Logic(name: 'served'); // this master cycle already pulsed
    final mAck = Logic(name: 'm_ack');
    const mAckDelay = 2;
    // One-cycle completion pulse: fires the cycle ackCnt hits the delay, once per
    // master-cycle assertion (gated by ~served). This is the TIMED completion the
    // PHY produces off its rdPipe read-latency count. It is never withheld.
    final wantPulse = (mCyc & mStb & ~served & ackCnt.eq(mAckDelay)).named(
      'want',
    );
    Sequential(mClk, reset: mReset, [
      If(
        ~(mCyc & mStb),
        then: [ackCnt < 0, served < 0],
        orElse: [
          If(ackCnt.lt(mAckDelay), then: [ackCnt < ackCnt + 1]),
          If(
            wantPulse,
            then: [
              served < 1,
              If(mWe, then: [mem < mDatW]),
            ],
          ),
        ],
      ),
    ]);
    mAck <= wantPulse;
    dut.input('m_ack').srcConnection! <= mAck;
    dut.input('m_dat_r').srcConnection! <= mem;

    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sWe.inject(1);
    sAdr.inject(0);
    sDatW.inject(0);

    Simulator.setMaxSimTime(50000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    sAdr.inject(0x40);
    sDatW.inject(0x1000);
    sCyc.inject(1);
    var done = 0;
    for (var t = 0; t < n; t++) {
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 20000) return done; // wedged
      }
      done++;
      sAdr.inject(0x40 + (t + 1) * 4);
      sDatW.inject(0x1000 + t + 1);
      guard = 0;
      while (dut.output('s_ack').value == LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 20000) return done;
      }
    }
    await Simulator.endSimulation();
    return done;
  }

  test(
    'timed completion never drops: all transactions ACK',
    () async {
      // Every one-cycle completion is a timed pulse (the PHY rdPipe-timed busDone).
      // The single-outstanding bridge must complete all of them. No watchdog, no
      // re-issue: a lost completion is impossible by construction, so none is
      // injected.
      final done = await run(n: 12);
      expect(done, 12, reason: 'all 12 must ACK with a timed completion pulse');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

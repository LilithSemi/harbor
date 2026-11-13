import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// Creek DDR wedge repro attempt in IDEAL sim. The creek ddr_cdc runs
/// syncStages: 6 with the slave on sys (~25 MHz) and the master on ctrl (~83 MHz,
/// ~3.3x faster), continuous back-to-back reads (the dcache refill stream). If
/// this wedges in ideal sim it is a FUNCTIONAL bug (fixable + testable here). If
/// every transaction acks, the hardware wedge is a mesochronous/metastable phase
/// effect that ideal sim cannot show, and the fix must be a phase-robust crossing.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<int> hammer({
    required int sPeriod,
    required int mPeriod,
    required int syncStages,
    required int mAckDelay,
    required int n,
  }) async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneCdcBridge(
      addressWidth: aw,
      dataWidth: dw,
      syncStages: syncStages,
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

    // Fast-side slave: acks mAckDelay fast-cycles after the master cycle opens.
    final mem = Logic(name: 'mem', width: dw);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final mWe = dut.output('m_we');
    final mDatW = dut.output('m_dat_w');
    final ackCnt = Logic(name: 'ack_cnt', width: 8);
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
    dut.input('m_ack').srcConnection! <= (mCyc & mStb & ackCnt.eq(mAckDelay));
    dut.input('m_dat_r').srcConnection! <= mem;

    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 8; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    // Continuous cyc reads, count acks, a wedge = a missing next ack (timeout).
    sWe.inject(0);
    sAdr.inject(0x40);
    sCyc.inject(1);
    var done = 0;
    for (var t = 0; t < n; t++) {
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 3000) return done;
      }
      done++;
      sAdr.inject(0x40 + (t + 1) * 4);
      guard = 0;
      while (dut.output('s_ack').value == LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 3000) return done;
      }
    }
    await Simulator.endSimulation();
    return done;
  }

  // Creek: syncStages 6, slave slower than master (~3.3x), a few phase offsets.
  for (final ratio in const [
    (s: 40, m: 12), // 25 MHz : 83 MHz
    (s: 48, m: 14),
    (s: 40, m: 10), // integer 4:1 (mesochronous-like)
    (s: 34, m: 10),
  ]) {
    for (final ackDelay in const [1, 4, 8]) {
      test(
        'creek repro s=${ratio.s} m=${ratio.m} sync=6 ack=$ackDelay',
        () async {
          final done = await hammer(
            sPeriod: ratio.s,
            mPeriod: ratio.m,
            syncStages: 6,
            mAckDelay: ackDelay,
            n: 40,
          );
          expect(
            done,
            40,
            reason:
                'all 40 back-to-back reads must ACK at sync=6 '
                's=${ratio.s} m=${ratio.m} ack=$ackDelay (got $done) - a '
                'shortfall is a FUNCTIONAL wedge reproducible in ideal sim',
          );
        },
      );
    }
  }
}

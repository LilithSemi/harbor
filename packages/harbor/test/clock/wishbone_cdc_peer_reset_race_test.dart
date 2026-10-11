// Pulses the peer (master) reset throughout live slave traffic, scheduled
// to land at the exact same simulator timestamp as an s_clk edge. A joined
// reset that reaches handshake logic without a local resync can flip
// mid s_clk-cycle on exactly this kind of peer pulse, which this test would
// see as a missing or doubled ack.
import 'dart:async';

import 'package:harbor/src/clock/wishbone_cdc.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  test('gray bridge: a peer reset landing exactly on an s_clk edge during '
      'traffic never double-acks or drops a request', () async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneCdcBridge(addressWidth: aw, dataWidth: dw);

    const sPeriod = 33;
    const mPeriod = 10;
    final sClk = SimpleClockGenerator(sPeriod).clk;
    final mClk = SimpleClockGenerator(mPeriod).clk;
    final sReset = Logic(name: 's_reset');
    final mReset = Logic(name: 'm_reset');
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: dw);

    dut.input('s_clk').srcConnection! <= sClk;
    dut.input('s_reset').srcConnection! <= sReset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= Const(0xf, width: 4);
    dut.input('m_clk').srcConnection! <= mClk;
    dut.input('m_reset').srcConnection! <= mReset;

    // Fast-side model holds the master cycle open for a few m_clk cycles
    // before acking, so `busy` stays asserted on the slave side long
    // enough to actually overlap a peer reset pulse.
    const ackDelay = 5;
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final ackCnt = Logic(name: 'ack_cnt', width: 8);
    Sequential(
      mClk,
      [
        If(
          mCyc & mStb,
          then: [
            If(
              ackCnt.lt(Const(ackDelay, width: 8)),
              then: [ackCnt < ackCnt + 1],
            ),
          ],
          orElse: [ackCnt < Const(0, width: 8)],
        ),
      ],
      reset: mReset,
      resetValues: {ackCnt: Const(0, width: 8)},
    );
    dut.input('m_ack').srcConnection! <=
        (mCyc & mStb & ackCnt.eq(Const(ackDelay, width: 8)));
    // Echo the address back as read data.
    dut.input('m_dat_r').srcConnection! <= dut.output('m_adr');

    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);

    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());

    for (var i = 0; i < 4; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    var ackPulses = 0;
    sClk.posedge.listen((_) {
      final v = dut.output('s_ack').value;
      if (v.isValid && v.toInt() == 1) {
        ackPulses++;
      }
    });

    // SimpleClockGenerator starts low and toggles every period ~/ 2 time
    // units forever, so s_clk's posedges land at this fixed schedule.
    // Schedule a short m_reset pulse to start at the EXACT timestamp of
    // many future s_clk posedges: the race this bridge must survive is a
    // peer reset glitch landing in the very same simulator tick as the
    // local clock edge.
    final sHalf = sPeriod ~/ 2;
    final startTime = Simulator.time + 3 * sPeriod;
    for (var k = 0; k < 120; k++) {
      final edgeIndex = (startTime - sHalf) ~/ (2 * sHalf) + k * 3;
      final t = sHalf + 2 * sHalf * edgeIndex;
      Simulator.registerAction(t, () {
        mReset.put(1);
        Simulator.registerAction(t + (mPeriod ~/ 2), () {
          mReset.put(0);
        });
      });
    }

    var completed = 0;
    const requests = 150;
    for (var i = 0; i < requests; i++) {
      sWe.inject(0);
      sAdr.inject(0x40 + 4 * (i % 8));
      sCyc.inject(1);
      sStb.inject(1);
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 500) {
          fail('request $i never completed (ack or err)');
        }
      }
      completed++;
      sCyc.inject(0);
      sStb.inject(0);
      await sClk.nextPosedge;
    }

    expect(completed, requests);
    expect(
      ackPulses,
      requests,
      reason: 'exactly one ack per request, no extras',
    );

    await Simulator.endSimulation();
  });
}

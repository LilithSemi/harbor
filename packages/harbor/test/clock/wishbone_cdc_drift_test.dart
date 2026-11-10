import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// #144 phase-drift reproduction. On creek silicon the CDC bridge wedges after a
/// per-boot-variable number of sustained back-to-back transactions (~400k, ~800k,
/// or survives). That wide geometric spread is the signature of a phase-alignment
/// logic hole in the handshake: with two same-PLL clocks whose periods differ
/// slightly, the phase relationship DRIFTS, and the bridge wedges when it drifts
/// through a pathological alignment. An exact integer clock ratio cannot show
/// this (its phase pattern repeats, so it either wedges on cycle 1 or never), so
/// the existing sustained test with n=24 and exact ratios stays green while the
/// hardware wedges. This test DETUNES the periods (non-exact ratio) so the phase
/// sweeps all alignments over a long run, and varies the fast-side ack latency
/// the way DDR refresh stalls do. A wedge here is the deterministic in-sim
/// reproduction of the hardware bug.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Run [n] back-to-back transactions with a DRIFTING phase (detuned periods).
  /// [ackPattern] cycles the fast-side ack latency to mimic variable DDR timing.
  /// Returns (done, wedgeInfo). done == n on success.
  Future<(int, String)> drift({
    required int sPeriod,
    required int mPeriod,
    required int n,
    required List<int> ackPattern,
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
    dut.input('s_stb').srcConnection! <= Const(1);
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= Const(0xf, width: dw ~/ 8);
    dut.input('m_clk').srcConnection! <= mClk;
    dut.input('m_reset').srcConnection! <= mReset;

    // Fast-side slave with a RUNTIME-settable ack latency (mAckDelayReg), so the
    // testbench can vary it per transaction to mimic DDR refresh stalls.
    final mem = Logic(name: 'mem', width: dw);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final mWe = dut.output('m_we');
    final mDatW = dut.output('m_dat_w');
    final mAckDelayReg = Logic(name: 'm_ack_delay', width: 8);
    final ackCnt = Logic(name: 'ack_cnt', width: 8);
    final mAck = Logic(name: 'm_ack');
    Sequential(mClk, reset: mReset, [
      If(
        mCyc & mStb,
        then: [
          If(ackCnt.lt(mAckDelayReg), then: [ackCnt < ackCnt + 1]),
        ],
        orElse: [ackCnt < 0],
      ),
      If(mCyc & mStb & mWe & ackCnt.eq(mAckDelayReg), then: [mem < mDatW]),
    ]);
    mAck <= (mCyc & mStb & ackCnt.eq(mAckDelayReg));
    dut.input('m_ack').srcConnection! <= mAck;
    dut.input('m_dat_r').srcConnection! <= mem;

    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sWe.inject(1);
    sAdr.inject(0);
    sDatW.inject(0);
    mAckDelayReg.inject(ackPattern.first);

    Simulator.setMaxSimTime(1000000000);
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
      // Vary the fast-side ack latency per transaction (drift the timing too).
      mAckDelayReg.inject(ackPattern[t % ackPattern.length]);
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 5000) {
          final dbg = dut.output('dbg').value;
          return (done, 'wedge at txn $t, dbg=$dbg');
        }
      }
      done++;
      sAdr.inject(0x40 + (t + 1) * 4);
      sDatW.inject(0x1000 + t + 1);
      guard = 0;
      while (dut.output('s_ack').value == LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 5000) {
          final dbg = dut.output('dbg').value;
          return (done, 'ack stuck high at txn $t, dbg=$dbg');
        }
      }
    }
    await Simulator.endSimulation();
    return (done, 'ok');
  }

  // Detuned near-3:2 (creek: core 24MHz vs DDR-side 36MHz) and near-1:1
  // (mesochronous same-freq). Non-exact so the phase sweeps every alignment over
  // the run. Large n. Varying ack latency. Any wedge is the #144 repro.
  for (final ratio in const [
    (s: 300, m: 198, tag: 'near-3:2 detuned'),
    (s: 300, m: 202, tag: 'near-3:2 detuned+'),
    (s: 200, m: 198, tag: 'near-1:1 detuned (mesochronous)'),
    (s: 198, m: 200, tag: 'near-1:1 detuned- (mesochronous)'),
    (s: 402, m: 268, tag: 'near-3:2 detuned coprime'),
  ]) {
    test(
      'phase-drift sustained ${ratio.tag} s=${ratio.s} m=${ratio.m}',
      () async {
        final (done, info) = await drift(
          sPeriod: ratio.s,
          mPeriod: ratio.m,
          n: 3000,
          ackPattern: const [1, 2, 1, 4, 1, 3, 7, 1],
        );
        expect(done, 3000, reason: 'all 3000 must ACK; $info');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}

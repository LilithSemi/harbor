import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// #144 phase-sweep completion guard.
///
/// History: this file used to carry a deliberately-FAILING "fragile" bug repro
/// that modelled the DDR PHY dropping a one-cycle completion at a marginal
/// DQS-vs-sclk phase (a rising-edge-anchored DATAVALID capture miss), and relied
/// on a bridge watchdog to paper over it. Both are gone. The real cure is in the
/// PHY: on the live (static, non-trainable) read path rd_valid is driven from the
/// sclk read-latency count (rdPipe), so the completion is TIMED and cannot be
/// dropped at any phase. DATAVALID/BURSTDET are only a leveling oracle, never the
/// capture gate. With a timed completion there is no edge to miss, so the bridge
/// needs no watchdog.
///
/// This test keeps the valuable coverage: detuned mesochronous s/m clocks sweep
/// every phase relationship boot-to-boot, and with a TIMED (level-persistent)
/// completion the single-outstanding bridge must complete every transaction at
/// every phase alignment.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// Run [n] back-to-back reads with detuned clocks (phase sweeps all
  /// alignments). The fast-side slave drives a level-persistent mAck held for
  /// [ackHold] m_clk cycles once the access latency has elapsed (the timed-tail
  /// completion the PHY's rdPipe count produces): there is no single edge to miss
  /// at any phase. Returns (completedCount, diagnosticInfo).
  Future<(int, String)> run({
    required int n,
    int sPeriod = 300,
    int mPeriod = 198,
    int ackDelay = 3,
    int ackHold = 6,
    int guardCycles = 2000,
  }) async {
    const aw = 32;
    const dw = 32;

    final dut = HarborWishboneCdcBridge(
      addressWidth: aw,
      dataWidth: dw,
      syncStages: 2,
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
    final mAck = Logic(name: 'm_ack');
    final ackCnt = Logic(name: 'ack_cnt', width: 8);

    // TIMED-TAIL model: level-persistent mAck held from ackDelay onwards while
    // mCyc is asserted. The bridge sees mAck=1 on the very first cycle
    // ackCnt >= ackDelay and completes. There is no single edge to miss.
    Sequential(mClk, reset: mReset, [
      If(
        ~(mCyc & mStb),
        then: [ackCnt < 0],
        orElse: [
          If(ackCnt.lt(ackDelay + ackHold), then: [ackCnt < ackCnt + 1]),
          If(mWe & ackCnt.eq(ackDelay), then: [mem < mDatW]),
        ],
      ),
    ]);
    // Level mAck: high for all cycles where ackCnt >= ackDelay while mCyc.
    // ~ackCnt.lt(ackDelay) == ackCnt >= ackDelay.
    mAck <= mCyc & mStb & ~ackCnt.lt(ackDelay);

    dut.input('m_ack').srcConnection! <= mAck;
    dut.input('m_dat_r').srcConnection! <= mem;

    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sWe.inject(0); // reads (the DDR read path is the one this models)
    sAdr.inject(0);
    sDatW.inject(0);

    Simulator.setMaxSimTime(1000000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    sAdr.inject(0x40);
    sCyc.inject(1);

    var done = 0;
    String? hangInfo;
    for (var t = 0; t < n; t++) {
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > guardCycles) {
          final dbg = dut.output('dbg').value;
          hangInfo =
              'txn $t hung after $guard s_clk cycles; '
              'dbg=0x${dbg.toInt().toRadixString(16)}'
              ' (busy=${dbg[0]} serving=${dbg[2]} mCyc=${dbg[3]})';
          break;
        }
      }
      if (hangInfo != null) break;
      done++;
      sAdr.inject(0x40 + (t + 1) * 4);
      guard = 0;
      while (dut.output('s_ack').value == LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > guardCycles) {
          hangInfo = 'txn $t s_ack stuck high after $guard s_clk cycles';
          break;
        }
      }
      if (hangInfo != null) break;
    }
    await Simulator.endSimulation();
    return (done, hangInfo ?? 'ok');
  }

  test(
    'timed level-persistent mAck cannot be edge-missed, all transactions complete',
    () async {
      // ackHold=6 m_clk cycles: bridge sees mAck=1 on cycle ackDelay and
      // completes. No single edge to miss at any phase alignment.
      final (done, info) = await run(n: 20, ackHold: 6);
      expect(
        done,
        20,
        reason: 'timed level mAck must ACK all 20 transactions; $info',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

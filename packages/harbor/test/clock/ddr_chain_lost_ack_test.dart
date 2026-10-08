import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_downsizer.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// #144 composite chain-integrity guard, mirroring the real DDR path order:
///   wide bus -> HarborWishboneDownsizer (64->32) -> HarborWishboneCdcBridge
///   (clk -> seqClk) -> 32-bit multi-cycle "sequencer" memory.
///
/// History: this used to DROP one completion pulse and rely on a bridge watchdog
/// + downsizer master-abort to re-issue and recover. The watchdog is gone: the
/// real fix is that the DDR PHY drives its read-valid from the sclk read-latency
/// count (rdPipe) on the live static path, so a completion is TIMED and cannot be
/// dropped at any DQS-vs-sclk phase. A lost completion is impossible by
/// construction, so there is nothing to re-issue.
///
/// This test now proves the positive contract: with a TIMED sequencer completion
/// (one pulse per access, never withheld), the whole downsizer -> CDC -> memory
/// chain completes every beat and returns correct data across the mesochronous
/// crossing.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> runChain() async {
    const aw = 32;
    final ds = HarborWishboneDownsizer(
      addressWidth: aw,
      wideWidth: 64,
      narrowWidth: 32,
      name: 'ds',
    );
    final cdc = HarborWishboneCdcBridge(
      addressWidth: aw,
      dataWidth: 32,
      syncStages: 4,
      name: 'cdc',
    );

    final sClk = SimpleClockGenerator(20).clk;
    final mClk = SimpleClockGenerator(7).clk;
    final sReset = Logic(name: 's_reset');
    final mReset = Logic(name: 'm_reset');

    final wCyc = Logic(name: 'w_cyc');
    final wWe = Logic(name: 'w_we');
    final wAdr = Logic(name: 'w_adr', width: aw);
    final wDatW = Logic(name: 'w_dat_w', width: 64);

    ds.input('clk').srcConnection! <= sClk;
    ds.input('reset').srcConnection! <= sReset;
    ds.input('s_cyc').srcConnection! <= wCyc;
    ds.input('s_stb').srcConnection! <= Const(1);
    ds.input('s_we').srcConnection! <= wWe;
    ds.input('s_adr').srcConnection! <= wAdr;
    ds.input('s_dat_w').srcConnection! <= wDatW;
    ds.input('s_sel').srcConnection! <= Const(0xff, width: 8);

    cdc.input('s_clk').srcConnection! <= sClk;
    cdc.input('s_reset').srcConnection! <= sReset;
    cdc.input('s_cyc').srcConnection! <=
        ds.output('m_cyc') & ds.output('m_stb');
    cdc.input('s_stb').srcConnection! <= Const(1);
    cdc.input('s_we').srcConnection! <= ds.output('m_we');
    cdc.input('s_adr').srcConnection! <= ds.output('m_adr');
    cdc.input('s_dat_w').srcConnection! <= ds.output('m_dat_w');
    cdc.input('s_sel').srcConnection! <= ds.output('m_sel');
    ds.input('m_ack').srcConnection! <= cdc.output('s_ack');
    ds.input('m_dat_r').srcConnection! <= cdc.output('s_dat_r');
    ds.input('m_err').srcConnection! <= Const(0);

    cdc.input('m_clk').srcConnection! <= mClk;
    cdc.input('m_reset').srcConnection! <= mReset;
    final mCyc = cdc.output('m_cyc');
    final mStb = cdc.output('m_stb');
    final mWe = cdc.output('m_we');
    final mAdr = cdc.output('m_adr');
    final mDatW = cdc.output('m_dat_w');
    final idx = mAdr.getRange(2, 5);
    final cells = [
      for (var i = 0; i < 8; i++) Logic(name: 'cell_$i', width: 32),
    ];

    // Multi-cycle memory that pulses ack once per access (the TIMED sequencer
    // completion). No pulse is ever dropped.
    final mBusy = Logic(name: 'm_busy');
    final mCount = Logic(name: 'm_count', width: 6);
    final mAckR = Logic(name: 'm_ack_r');
    const latency = 10;
    var rd = cells[7];
    for (var i = 6; i >= 0; i--) {
      rd = mux(idx.eq(Const(i, width: 3)), cells[i], rd);
    }
    cdc.input('m_ack').srcConnection! <= mAckR;
    cdc.input('m_dat_r').srcConnection! <= rd;
    final complete = (mBusy & mCount.eq(Const(latency, width: 6))).named(
      'cmpl',
    );
    Sequential(mClk, reset: mReset, [
      mAckR < 0,
      If(
        ~mBusy & mCyc & mStb & ~mAckR,
        then: [mBusy < 1, mCount < 0],
        orElse: [
          If(
            mBusy,
            then: [
              mCount < mCount + 1,
              If(
                complete,
                then: [
                  for (var i = 0; i < 8; i++)
                    If(
                      mWe & idx.eq(Const(i, width: 3)),
                      then: [cells[i] < mDatW],
                    ),
                  mBusy < 0,
                  mAckR < 1,
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    sReset.inject(1);
    mReset.inject(1);
    wCyc.inject(0);
    wWe.inject(0);
    wAdr.inject(0);
    wDatW.inject(0);

    Simulator.setMaxSimTime(20000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    Future<BigInt> xfer({
      required bool we,
      required int adr,
      BigInt? data,
    }) async {
      wWe.inject(we ? 1 : 0);
      wAdr.inject(adr);
      wDatW.inject(data ?? BigInt.zero);
      wCyc.inject(1);
      var guard = 0;
      while (ds.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 5000) {
          fail('timeout s_ack (we=$we adr=0x${adr.toRadixString(16)})');
        }
      }
      final r = ds.output('s_dat_r').value.toBigInt();
      wCyc.inject(0);
      await sClk.nextPosedge;
      return r;
    }

    final vals = [
      BigInt.parse('1111111122222222', radix: 16),
      BigInt.parse('33333333aaaaaaaa', radix: 16),
      BigInt.parse('44444444bbbbbbbb', radix: 16),
      BigInt.parse('55555555cccccccc', radix: 16),
    ];
    final addrs = [0x00, 0x08, 0x10, 0x18];
    for (var i = 0; i < 4; i++) {
      await xfer(we: true, adr: addrs[i], data: vals[i]);
    }
    for (var i = 0; i < 4; i++) {
      final r = await xfer(we: false, adr: addrs[i]);
      expect(
        r,
        equals(vals[i]),
        reason: 'addr 0x${addrs[i].toRadixString(16)} wrong through chain',
      );
    }
    await Simulator.endSimulation();
  }

  test(
    'timed completion through downsizer+CDC chain returns correct data',
    () async {
      await runChain();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

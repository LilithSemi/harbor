import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_downsizer.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// Reproduces the real DDR bus path minus the analog PHY: a 64-bit master drives
/// a [HarborWishboneDownsizer] (64->32) whose narrow master feeds a
/// [HarborWishboneCdcBridge] (32-bit) crossing to a faster clock, where a simple
/// 32-bit Wishbone memory lives. This is exactly the chain a DDR bus path uses
/// (bus -> downsizer -> CDC -> 32-bit datapath), so a structural corruption in
/// the downsizer+CDC interaction under back-to-back 64-bit traffic shows here.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> runChain({
    required int sPeriod,
    required int mPeriod,
    int pace = 0,
  }) async {
    const aw = 32;

    final ds = HarborWishboneDownsizer(
      addressWidth: aw,
      wideWidth: 64,
      narrowWidth: 32,
      paceCycles: pace,
      name: 'ds',
    );
    final cdc = HarborWishboneCdcBridge(
      addressWidth: aw,
      dataWidth: 32,
      name: 'cdc',
    );

    final sClk = SimpleClockGenerator(sPeriod).clk; // slow (core) domain
    final mClk = SimpleClockGenerator(mPeriod).clk; // fast (DDR) domain
    final sReset = Logic(name: 's_reset');
    final mReset = Logic(name: 'm_reset');

    // Wide (64-bit) stimulus into the downsizer's slave face.
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

    // Downsizer narrow master -> CDC slave (both slow domain).
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

    // CDC fast master -> behavioral 32-bit WB memory (8 words at 0x00..0x1C).
    cdc.input('m_clk').srcConnection! <= mClk;
    cdc.input('m_reset').srcConnection! <= mReset;
    final mCyc = cdc.output('m_cyc');
    final mStb = cdc.output('m_stb');
    final mWe = cdc.output('m_we');
    final mAdr = cdc.output('m_adr');
    final mDatW = cdc.output('m_dat_w');
    final idx = mAdr.getRange(2, 5); // word index 0..7
    final cells = [
      for (var i = 0; i < 8; i++) Logic(name: 'cell_$i', width: 32),
    ];
    // Multi-cycle slave: model the real DDR sequencer latency (activate -> CAS
    // -> precharge is tens of cycles, ack pulses once at the end), instead of a
    // combinational ack. This is what stresses the downsizer<->CDC<->reqFSM
    // handshake the way the real controller does.
    final mBusy = Logic(name: 'm_busy');
    final mCount = Logic(name: 'm_count', width: 6);
    final mAckR = Logic(name: 'm_ack_r');
    const latency = 12;
    var rd = cells[7];
    for (var i = 6; i >= 0; i--) {
      rd = mux(idx.eq(Const(i, width: 3)), cells[i], rd);
    }
    cdc.input('m_ack').srcConnection! <= mAckR;
    cdc.input('m_dat_r').srcConnection! <= rd;
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
                mCount.eq(Const(latency, width: 6)),
                then: [
                  for (var i = 0; i < 8; i++)
                    If(
                      mWe & idx.eq(Const(i, width: 3)),
                      then: [cells[i] < mDatW],
                    ),
                  mAckR < 1,
                  mBusy < 0,
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

    Simulator.setMaxSimTime(2000000);
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
        if (++guard > 1000)
          fail('timeout s_ack (we=$we adr=0x${adr.toRadixString(16)})');
      }
      final r = ds.output('s_dat_r').value.toBigInt();
      wCyc.inject(0);
      // Minimal gap: drop cyc for one cycle only, to stress back-to-back.
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

    // Write all four 64-bit words back to back.
    for (var i = 0; i < 4; i++) {
      await xfer(we: true, adr: addrs[i], data: vals[i]);
    }
    // Read them back to back and verify each reassembled word.
    for (var i = 0; i < 4; i++) {
      final r = await xfer(we: false, adr: addrs[i]);
      expect(
        r,
        equals(vals[i]),
        reason:
            'addr 0x${addrs[i].toRadixString(16)} read back wrong '
            '(got 0x${r.toRadixString(16)}, want 0x${vals[i].toRadixString(16)})',
      );
    }

    await Simulator.endSimulation();
  }

  test(
    'back-to-back 64-bit traffic through downsizer+CDC (fast DDR)',
    () async {
      await runChain(sPeriod: 20, mPeriod: 6);
    },
  );

  test('back-to-back 64-bit traffic, near-equal clocks', () async {
    await runChain(sPeriod: 10, mPeriod: 11);
  });

  test('paced (paceCycles=32) back-to-back 64-bit traffic', () async {
    await runChain(sPeriod: 20, mPeriod: 6, pace: 32);
  });
}

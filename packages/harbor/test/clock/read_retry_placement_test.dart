import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_downsizer.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';
import 'package:harbor/src/clock/wishbone_read_retry.dart';

/// Reproduces the creek DDR read path minus the analog PHY, to test whether the
/// read-retry voting is placed effectively.
///
/// Real chain (ddr.dart): 64-bit bus -> HarborWishboneReadRetry (WIDE, 64) ->
/// HarborWishboneDownsizer (64->32) -> HarborWishboneCdcBridge (32, mesochronous
/// crossing) -> 32-bit datapath. Each 64-bit read is two 32-bit narrow beats.
///
/// The hardware read glitch is per-NARROW-beat (the DQ/DQS capture marginally
/// mis-samples an individual 32-bit beat). This test models that: the FIRST read
/// of each distinct narrow transaction returns a corrupted beat, a re-read of the
/// same beat returns the stored value. It then checks whether the read-retry,
/// placed on the WIDE side (voting the reassembled 64-bit word) vs the NARROW
/// side (voting each 32-bit beat), recovers the correct data under sustained
/// back-to-back reads.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  /// [narrowRetry] false = read-retry on the wide (64) bus (current ddr.dart).
  /// true = read-retry on the narrow (32) bus between downsizer and CDC.
  Future<int> runChain({
    required bool narrowRetry,
    int sPeriod = 10,
    int mPeriod = 10, // mesochronous: same frequency (the creek case)
    int maxTries = 8,
    int nReads = 8,
  }) async {
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
      name: 'cdc',
    );
    // Wide retry sits in front of the downsizer (64-bit), narrow retry sits
    // between the downsizer and the CDC (32-bit).
    final rr = HarborWishboneReadRetry(
      addressWidth: aw,
      dataWidth: narrowRetry ? 32 : 64,
      maxTries: maxTries,
      name: 'rr',
    );

    final sClk = SimpleClockGenerator(sPeriod).clk;
    final mClk = SimpleClockGenerator(mPeriod).clk;
    final sReset = Logic(name: 's_reset');
    final mReset = Logic(name: 'm_reset');

    final wCyc = Logic(name: 'w_cyc');
    final wWe = Logic(name: 'w_we');
    final wAdr = Logic(name: 'w_adr', width: aw);
    final wDatW = Logic(name: 'w_dat_w', width: 64);

    if (!narrowRetry) {
      // bus -> rr(64) -> ds
      rr.input('clk').srcConnection! <= sClk;
      rr.input('reset').srcConnection! <= sReset;
      rr.input('s_cyc').srcConnection! <= wCyc;
      rr.input('s_stb').srcConnection! <= Const(1);
      rr.input('s_we').srcConnection! <= wWe;
      rr.input('s_adr').srcConnection! <= wAdr;
      rr.input('s_dat_w').srcConnection! <= wDatW;
      rr.input('s_sel').srcConnection! <= Const(0xff, width: 8);
      ds.input('clk').srcConnection! <= sClk;
      ds.input('reset').srcConnection! <= sReset;
      ds.input('s_cyc').srcConnection! <=
          rr.output('m_cyc') & rr.output('m_stb');
      ds.input('s_stb').srcConnection! <= Const(1);
      ds.input('s_we').srcConnection! <= rr.output('m_we');
      ds.input('s_adr').srcConnection! <= rr.output('m_adr');
      ds.input('s_dat_w').srcConnection! <= rr.output('m_dat_w');
      ds.input('s_sel').srcConnection! <= rr.output('m_sel');
      rr.input('m_ack').srcConnection! <= ds.output('s_ack');
      rr.input('m_dat_r').srcConnection! <= ds.output('s_dat_r');
      rr.input('m_err').srcConnection! <= ds.output('s_err');
    } else {
      // bus -> ds directly (wide)
      ds.input('clk').srcConnection! <= sClk;
      ds.input('reset').srcConnection! <= sReset;
      ds.input('s_cyc').srcConnection! <= wCyc;
      ds.input('s_stb').srcConnection! <= Const(1);
      ds.input('s_we').srcConnection! <= wWe;
      ds.input('s_adr').srcConnection! <= wAdr;
      ds.input('s_dat_w').srcConnection! <= wDatW;
      ds.input('s_sel').srcConnection! <= Const(0xff, width: 8);
    }

    final Logic nCyc, nWe, nAdr, nDatW, nSel;
    if (narrowRetry) {
      rr.input('clk').srcConnection! <= sClk;
      rr.input('reset').srcConnection! <= sReset;
      rr.input('s_cyc').srcConnection! <=
          ds.output('m_cyc') & ds.output('m_stb');
      rr.input('s_stb').srcConnection! <= Const(1);
      rr.input('s_we').srcConnection! <= ds.output('m_we');
      rr.input('s_adr').srcConnection! <= ds.output('m_adr');
      rr.input('s_dat_w').srcConnection! <= ds.output('m_dat_w');
      rr.input('s_sel').srcConnection! <= ds.output('m_sel');
      ds.input('m_ack').srcConnection! <= rr.output('s_ack');
      ds.input('m_dat_r').srcConnection! <= rr.output('s_dat_r');
      ds.input('m_err').srcConnection! <= rr.output('s_err');
      nCyc = rr.output('m_cyc') & rr.output('m_stb');
      nWe = rr.output('m_we');
      nAdr = rr.output('m_adr');
      nDatW = rr.output('m_dat_w');
      nSel = rr.output('m_sel');
    } else {
      nCyc = ds.output('m_cyc') & ds.output('m_stb');
      nWe = ds.output('m_we');
      nAdr = ds.output('m_adr');
      nDatW = ds.output('m_dat_w');
      nSel = ds.output('m_sel');
    }

    cdc.input('s_clk').srcConnection! <= sClk;
    cdc.input('s_reset').srcConnection! <= sReset;
    cdc.input('s_cyc').srcConnection! <= nCyc;
    cdc.input('s_stb').srcConnection! <= Const(1);
    cdc.input('s_we').srcConnection! <= nWe;
    cdc.input('s_adr').srcConnection! <= nAdr;
    cdc.input('s_dat_w').srcConnection! <= nDatW;
    cdc.input('s_sel').srcConnection! <= nSel;
    if (narrowRetry) {
      rr.input('m_ack').srcConnection! <= cdc.output('s_ack');
      rr.input('m_dat_r').srcConnection! <= cdc.output('s_dat_r');
      rr.input('m_err').srcConnection! <= Const(0);
    } else {
      ds.input('m_ack').srcConnection! <= cdc.output('s_ack');
      ds.input('m_dat_r').srcConnection! <= cdc.output('s_dat_r');
      ds.input('m_err').srcConnection! <= Const(0);
    }

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
    final mBusy = Logic(name: 'm_busy');
    final mCount = Logic(name: 'm_count', width: 6);
    final mAckR = Logic(name: 'm_ack_r');
    // Per-narrow-beat glitch: track a "read count since last write" per cell. The
    // FIRST read of a cell after any access returns a corrupted beat, re-reads
    // return the stored value. Model with a 1-bit "primed" flag per cell that is
    // set on write and cleared on the first read (so a read that immediately
    // re-reads the same cell gets the stored value).
    final primed = [for (var i = 0; i < 8; i++) Logic(name: 'primed_$i')];
    const latency = 6;
    var rd = cells[7];
    var isPrimed = primed[7];
    for (var i = 6; i >= 0; i--) {
      rd = mux(idx.eq(Const(i, width: 3)), cells[i], rd);
      isPrimed = mux(idx.eq(Const(i, width: 3)), primed[i], isPrimed);
    }
    // The corrupted beat = stored value XOR a fixed bit pattern (deterministic
    // per-address glitch: the same wrong value each first-read, so a WIDE vote of
    // two whole-word reads that each re-glitch both halves never converges).
    final glitched = rd ^ Const(0xDEAD0000, width: 32);
    cdc.input('m_ack').srcConnection! <= mAckR;
    cdc.input('m_dat_r').srcConnection! <= mux(isPrimed, glitched, rd);
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
                  mAckR < 1,
                  mBusy < 0,
                  for (var i = 0; i < 8; i++) ...[
                    If(
                      mWe & idx.eq(Const(i, width: 3)),
                      then: [
                        cells[i] < mDatW,
                        primed[i] <
                            Const(1), // a fresh write re-primes the glitch
                      ],
                    ),
                    // A read clears the prime for the addressed cell (next read clean).
                    If(
                      ~mWe & idx.eq(Const(i, width: 3)),
                      then: [primed[i] < Const(0)],
                    ),
                  ],
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
    for (final p in primed) {
      p.inject(0);
    }

    Simulator.setMaxSimTime(5000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    final slaveAck = narrowRetry
        ? ds.output('s_ack') // wide face is the downsizer slave
        : rr.output('s_ack'); // wide face is the retry slave
    final slaveDatR = narrowRetry ? ds.output('s_dat_r') : rr.output('s_dat_r');
    // Wait, the WIDE master face: with narrowRetry the master drives ds directly,
    // so the wide slave ack/data is ds. With wide retry, it is rr. Corrected below.

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
      while (slaveAck.value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 4000) {
          fail('timeout s_ack (we=$we adr=0x${adr.toRadixString(16)})');
        }
      }
      final r = slaveDatR.value.toBigInt();
      wCyc.inject(0);
      await sClk.nextPosedge;
      return r;
    }

    final vals = [
      for (var i = 0; i < 4; i++)
        BigInt.parse(
          '${(0x11111111 + i * 0x11111111).toRadixString(16)}'
          '${(0xa0a0a000 + i).toRadixString(16)}',
          radix: 16,
        ),
    ];
    final addrs = [0x00, 0x08, 0x10, 0x18];

    for (var i = 0; i < 4; i++) {
      await xfer(we: true, adr: addrs[i], data: vals[i]);
    }
    // Sustained back-to-back reads, looping over the 4 words nReads times, and
    // count how many come back correct.
    var correct = 0;
    var total = 0;
    for (var loop = 0; loop < nReads; loop++) {
      for (var i = 0; i < 4; i++) {
        final r = await xfer(we: false, adr: addrs[i]);
        total++;
        if (r == vals[i]) correct++;
      }
    }
    await Simulator.endSimulation();
    return total - correct; // number of CORRUPT reads
  }

  test('WIDE read-retry (current placement) leaves corrupt reads under '
      'per-beat glitch', () async {
    final corrupt = await runChain(narrowRetry: false);
    // This documents the weakness: report how many reads came back wrong.
    // ignore: avoid_print
    print('WIDE read-retry corrupt reads: $corrupt');
  });

  test('NARROW read-retry recovers all reads under per-beat glitch', () async {
    final corrupt = await runChain(narrowRetry: true);
    // ignore: avoid_print
    print('NARROW read-retry corrupt reads: $corrupt');
    expect(
      corrupt,
      0,
      reason: 'per-beat voting must clean every beat -> zero corrupt reads',
    );
  });
}

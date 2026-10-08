import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_downsizer.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// Reproduce the creek streaming-store DROP at the layer the RiverDdrVerify probe
/// + the dcache-stream test pointed to: SUB-WORD (32-bit, partial byte-select)
/// writes streamed through the downsizer + CDC. This is exactly what a 32-bit
/// `sw` from the RV64 core becomes: a 64-bit-wide write with sel = 0x0F (low
/// word) or 0xF0 (high word), which the downsizer splits into a WRITE beat
/// (sel=0xF) and a MASKED beat (sel=0x0). The existing chain test only ever
/// drives full sel=0xFF (both halves), so this masked-beat path is untested.
///
/// The backing memory here HONORS the narrow byte-select (writes only when
/// m_sel != 0), like real DRAM. If sub-word streaming drops writes, cells go
/// stale.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> run({required int sPeriod, required int mPeriod}) async {
    const aw = 32;
    final ds = HarborWishboneDownsizer(
      addressWidth: aw,
      wideWidth: 64,
      narrowWidth: 32,
    );
    final cdc = HarborWishboneCdcBridge(addressWidth: aw, dataWidth: 32);

    final sClk = SimpleClockGenerator(sPeriod).clk;
    final mClk = SimpleClockGenerator(mPeriod).clk;
    final sReset = Logic(name: 's_reset');
    final mReset = Logic(name: 'm_reset');

    final wCyc = Logic(name: 'w_cyc');
    final wWe = Logic(name: 'w_we');
    final wAdr = Logic(name: 'w_adr', width: aw);
    final wDatW = Logic(name: 'w_dat_w', width: 64);
    final wSel = Logic(name: 'w_sel', width: 8);

    ds.input('clk').srcConnection! <= sClk;
    ds.input('reset').srcConnection! <= sReset;
    ds.input('s_cyc').srcConnection! <= wCyc;
    ds.input('s_stb').srcConnection! <= Const(1);
    ds.input('s_we').srcConnection! <= wWe;
    ds.input('s_adr').srcConnection! <= wAdr;
    ds.input('s_dat_w').srcConnection! <= wDatW;
    ds.input('s_sel').srcConnection! <= wSel;

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
    final mSel = cdc.output('m_sel');
    const nCells = 16;
    final idx = mAdr.getRange(2, 2 + 4); // word index 0..15
    final cells = [
      for (var i = 0; i < nCells; i++) Logic(name: 'cell_$i', width: 32),
    ];
    final mBusy = Logic(name: 'm_busy');
    final mCount = Logic(name: 'm_count', width: 6);
    final mAckR = Logic(name: 'm_ack_r');
    const latency = 12;
    var rd = cells[nCells - 1];
    for (var i = nCells - 2; i >= 0; i--) {
      rd = mux(idx.eq(Const(i, width: 4)), cells[i], rd);
    }
    // Honor the narrow byte-select: a masked beat (m_sel == 0) writes NOTHING.
    final selNonzero = mSel.or();
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
                  for (var i = 0; i < nCells; i++)
                    If(
                      mWe & selNonzero & idx.eq(Const(i, width: 4)),
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
    wSel.inject(0);
    for (var i = 0; i < nCells; i++) {
      cells[i].inject(0);
    }

    Simulator.setMaxSimTime(4000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 4; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    // One wide transfer: hold cyc until ack, minimal 1-cycle gap (back-to-back).
    Future<void> wxfer({
      required int adr,
      required BigInt data,
      required int sel,
    }) async {
      wWe.inject(1);
      wAdr.inject(adr);
      wDatW.inject(data);
      wSel.inject(sel);
      wCyc.inject(1);
      var guard = 0;
      while (ds.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 2000)
          fail('timeout s_ack adr=0x${adr.toRadixString(16)}');
      }
      wCyc.inject(0);
      await sClk.nextPosedge;
    }

    // Stream a distinct 32-bit value into EACH of the 16 words via partial-sel
    // sub-word writes. This mirrors what the dcache presents for a 32-bit `sw`:
    // an 8-byte-ALIGNED wide (64-bit) write whose LANE is chosen by sel, NOT by a
    // 4-byte address. word w -> line (w~/2) at byte adr line*8, even w = low half
    // (sel 0x0F), odd w = high half (sel 0xF0). All back-to-back.
    BigInt v(int w) => BigInt.from(0x0BAD0000 + w);
    for (var w = 0; w < nCells; w++) {
      final low = (w & 1) == 0;
      final data = low ? v(w) : (v(w) << 32);
      await wxfer(adr: (w ~/ 2) * 8, data: data, sel: low ? 0x0F : 0xF0);
    }
    for (var i = 0; i < 30; i++) {
      await sClk.nextPosedge;
    }
    // Capture every cell before ending the sim.
    final got = [for (var i = 0; i < nCells; i++) cells[i].value.toBigInt()];
    await Simulator.endSimulation();

    for (var w = 0; w < nCells; w++) {
      expect(
        got[w],
        equals(v(w)),
        reason:
            'SUB-WORD STREAM DROP: word $w = 0x${got[w].toRadixString(16)} '
            'want 0x${v(w).toRadixString(16)} (streamed sub-word write lost)',
      );
    }
  }

  test('sub-word streaming writes through downsizer+CDC (fast DDR)', () async {
    await run(sPeriod: 20, mPeriod: 6);
  });
  test('sub-word streaming writes, near-equal clocks', () async {
    await run(sPeriod: 10, mPeriod: 11);
  });
}

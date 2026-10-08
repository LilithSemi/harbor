import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_downsizer.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// Sub-word (partial-SEL) write correctness through the real creek write chain
/// minus the analog PHY: 64-bit master -> HarborWishboneDownsizer (64->32) ->
/// HarborWishboneCdcBridge -> a SEL-HONORING behavioral 32-bit memory.
///
/// The creek boot corruption is dropped/aliased 32-bit stores: the region sweep
/// showed ~40% of 32-bit writes land wrong, deterministically (transient=0). A
/// 32-bit sw on the 64-bit bus is a partial-SEL wide write (one half selected,
/// the other SEL=0). This test checks the LOGIC: does the downsizer emit the
/// right per-half SEL so that only the addressed 4 bytes change and the sibling
/// half is untouched? If this passes, the write LOGIC is correct and the hardware
/// drop is analog write margin. If it fails, the SEL split is the bug.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('partial-SEL (32-bit) writes touch only selected bytes; sibling intact', () async {
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

    final sClk = SimpleClockGenerator(10).clk;
    final mClk = SimpleClockGenerator(6).clk; // faster DDR domain (avoids the
    // ROHD identical-period Sequential race, write LOGIC is ratio-independent)
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
    final idx = mAdr.getRange(2, 5);
    final cells = [
      for (var i = 0; i < 8; i++) Logic(name: 'cell_$i', width: 32),
    ];
    final mBusy = Logic(name: 'm_busy');
    final mCount = Logic(name: 'm_count', width: 6);
    final mAckR = Logic(name: 'm_ack_r');
    const latency = 6;
    var rd = cells[7];
    for (var i = 6; i >= 0; i--) {
      rd = mux(idx.eq(Const(i, width: 3)), cells[i], rd);
    }
    cdc.input('m_ack').srcConnection! <= mAckR;
    cdc.input('m_dat_r').srcConnection! <= rd;
    // SEL-IGNORING memory (the PESSIMISTIC real-DDR model): on ANY write it
    // stores the full narrow word regardless of mSel. This is exactly the
    // silicon behavior that made sub-word stores corrupt their sibling: a
    // downsizer that issued the unselected half as a SEL=0 write would clobber
    // this cell. With the downsizer's zero-SEL-half SKIP fix, that write is never
    // issued, so a sub-word store leaves its sibling untouched even here. (This
    // is the regression guard that reproduces the creek boot corruption.)
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
                  for (var i = 0; i < 8; i++)
                    If(
                      mWe & idx.eq(Const(i, width: 3)),
                      then: [cells[i] < mDatW],
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    ]);

    sReset.inject(1);
    mReset.inject(1);
    for (final s in [wCyc, wWe, wAdr, wDatW]) {
      s.inject(0);
    }
    wSel.inject(0);
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
      int sel = 0xff,
    }) async {
      wWe.inject(we ? 1 : 0);
      wAdr.inject(adr);
      wDatW.inject(data ?? BigInt.zero);
      wSel.inject(sel);
      wCyc.inject(1);
      var guard = 0;
      while (ds.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 2000)
          fail('timeout s_ack adr=0x${adr.toRadixString(16)}');
      }
      final r = ds.output('s_dat_r').value.toBigInt();
      wCyc.inject(0);
      await sClk.nextPosedge;
      await sClk.nextPosedge;
      return r;
    }

    // Drive exactly as the MMU does: 8-byte-aligned bus address, SEL and data
    // shifted left by the byte offset (adr & 7). This is the faithful stimulus.
    Future<void> store32(int byteAddr, int value) async {
      final aligned = byteAddr & ~7;
      final off = byteAddr & 7;
      final sel = 0x0f << off;
      final data = BigInt.from(value & 0xffffffff) << (off * 8);
      await xfer(we: true, adr: aligned, data: data, sel: sel);
    }

    Future<int> load32(int byteAddr) async {
      final aligned = byteAddr & ~7;
      final off = byteAddr & 7;
      final r = await xfer(we: false, adr: aligned);
      return ((r >> (off * 8)) & BigInt.from(0xffffffff)).toInt();
    }

    // The bss-clear shape: 32-bit stores to CONSECUTIVE 4-byte addresses, both
    // even (bit2=0) and odd (bit2=1). Each must round-trip and NOT clobber its
    // 8-byte sibling.
    for (var i = 0; i < 8; i++) {
      await store32(i * 4, 0x1000 + i);
    }
    for (var i = 0; i < 8; i++) {
      final got = await load32(i * 4);
      expect(
        got,
        0x1000 + i,
        reason:
            'word $i @0x${(i * 4).toRadixString(16)} readback '
            '0x${got.toRadixString(16)} (sub-word store corrupted)',
      );
    }

    await Simulator.endSimulation();
  });
}

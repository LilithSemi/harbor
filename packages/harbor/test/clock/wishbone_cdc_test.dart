import 'dart:async';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'package:harbor/src/clock/wishbone_cdc.dart';

/// Drives the bridge's slave side from a slow clock and models a simple
/// one-cycle Wishbone register slave on the fast (master) side, then checks a
/// write followed by a read crosses both clock domains correctly.
void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  Future<void> runXfer({required int sPeriod, required int mPeriod}) async {
    const aw = 32;
    const dw = 32;
    final dut = HarborWishboneCdcBridge(addressWidth: aw, dataWidth: dw);

    final sClk = SimpleClockGenerator(sPeriod + (sPeriod & 1)).clk;
    final mClk = SimpleClockGenerator(mPeriod + (mPeriod & 1)).clk;
    final sReset = Logic(name: 's_reset');
    final mReset = Logic(name: 'm_reset');

    // Slave-side stimulus signals.
    final sCyc = Logic(name: 's_cyc');
    final sStb = Logic(name: 's_stb');
    final sWe = Logic(name: 's_we');
    final sAdr = Logic(name: 's_adr', width: aw);
    final sDatW = Logic(name: 's_dat_w', width: dw);
    final sSel = Logic(name: 's_sel', width: dw ~/ 8);

    dut.input('s_clk').srcConnection! <= sClk;
    dut.input('s_reset').srcConnection! <= sReset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= sSel;
    dut.input('m_clk').srcConnection! <= mClk;
    dut.input('m_reset').srcConnection! <= mReset;

    // Fast-side model: a single 32-bit register acting as a one-cycle WB slave.
    // ACK is combinational on the master cycle, a write stores on the fast edge.
    final mem = Logic(name: 'mem', width: dw);
    final mCyc = dut.output('m_cyc');
    final mStb = dut.output('m_stb');
    final mWe = dut.output('m_we');
    final mDatW = dut.output('m_dat_w');
    dut.input('m_ack').srcConnection! <= (mCyc & mStb);
    dut.input('m_dat_r').srcConnection! <= mem;
    Sequential(mClk, reset: mReset, [
      If(mCyc & mStb & mWe, then: [mem < mDatW]),
    ]);

    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    sSel.inject(0xf);

    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());

    for (var i = 0; i < 4; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;

    Future<int> doXfer({required bool we, int adr = 0x40, int data = 0}) async {
      sWe.inject(we ? 1 : 0);
      sAdr.inject(adr);
      sDatW.inject(data);
      sCyc.inject(1);
      sStb.inject(1);
      // Hold the request until ACK (Wishbone classic master behavior).
      var guard = 0;
      while (dut.output('s_ack').value != LogicValue.one) {
        await sClk.nextPosedge;
        if (++guard > 500) {
          fail('timeout waiting for s_ack (we=$we)');
        }
      }
      final rd = dut.output('s_dat_r').value.toInt();
      sCyc.inject(0);
      sStb.inject(0);
      await sClk.nextPosedge;
      // Let the handshake drain before the next transaction.
      for (var i = 0; i < 6; i++) {
        await sClk.nextPosedge;
      }
      return rd;
    }

    const magic = 0xC0DE1234;
    await doXfer(we: true, adr: 0x40, data: magic);
    final rd = await doXfer(we: false, adr: 0x40);
    expect(rd, equals(magic), reason: 'read-back must match the written value');

    await Simulator.endSimulation();
  }

  test('write then read crosses domains (slow slave, fast master)', () async {
    await runXfer(sPeriod: 20, mPeriod: 6);
  });

  test('also works when master is slower than slave', () async {
    await runXfer(sPeriod: 6, mPeriod: 20);
  });

  test('handles near-equal asynchronous clocks', () async {
    await runXfer(sPeriod: 10, mPeriod: 12);
  });
}

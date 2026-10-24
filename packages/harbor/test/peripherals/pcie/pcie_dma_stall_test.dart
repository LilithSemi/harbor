import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../util/pcie_dma_bench.dart';

/// Polls STATUS until the engine state is [state].
Future<int> _waitState(DmaBench b, int state) async {
  for (var i = 0; i < 200; i++) {
    final status = await b.readReg(HarborPcieDma.registerStatus);
    if (status >> HarborPcieDma.statusStateShift & 0xf == state) return status;
  }
  fail('engine state $state not seen');
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final free in [false, true]) {
    test('PERST# resets a stuck engine and the reset counts go up, '
        '${free ? 'free clock' : 'user clock'}', () async {
      final b = await DmaBench.create(const DmaConfig(resetStatus: true));
      final perstN = Logic(name: 'perst_n');
      final hotReset = Logic(name: 'hot_reset');
      final linkUp = Logic(name: 'link_up');
      final lock = Logic(name: 'mmcm_lock');
      final counters = HarborPcieResetCounters(
        clk: b.clk,
        mmcmLock: lock,
        freeClk: free ? SimpleClockGenerator(26).clk : null,
        perstN: perstN,
        userReset: b.reset,
        hotReset: hotReset,
        linkUp: linkUp,
        phyResetState: Const(9, width: 4),
        phyFailState: Const(2, width: 4),
        phyRetries: Const(3, width: 8),
      );
      await counters.build();
      b.resetStatus! <= counters.status;
      for (final (l, v) in [
        (perstN, 1),
        (hotReset, 0),
        (linkUp, 1),
        (lock, 1),
      ]) {
        l.inject(v);
      }
      await b.start();
      await b.cycles(2);
      expect(
        await b.readReg(HarborPcieDma.registerCaps) &
            HarborPcieDma.capsResetStatus,
        isNonZero,
      );
      // The bench reset at the start counts as the power-on user reset.
      expect(await b.readReg(HarborPcieDma.registerResetCounts), 1);
      expect(await b.readReg(HarborPcieDma.registerPhyStatus), 0x0329);

      // A fabric read that never ends, with one more descriptor queued.
      await b.setupRing(dmaCplBase, 4);
      await b.enable();
      b.memory.readLimit = 0;
      for (final i in [0, 1]) {
        await b.push(
          hostAddress: 0x80000000 + 0x1000 * i,
          localAddress: 0x1000 + 0x1000 * i,
          length: 0x100,
        );
      }
      final stuck = await _waitState(b, 5);
      expect(stuck >> HarborPcieDma.statusFreeShift, 63);

      // PERST# resets the MMCM and stops the link, and the hard block holds
      // the user reset. The bench clock does not stop, so the counts must
      // wait for the lock.
      perstN.inject(0);
      lock.inject(0);
      linkUp.inject(0);
      b.reset.inject(1);
      await b.cycles(20);
      expect(counters.status.value.toBigInt() >> 48 & BigInt.one, BigInt.one);
      // No count on the user clock changes before the lock.
      expect(counters.status.value.toInt() & 0xffff00ff, 1);
      perstN.inject(1);
      await b.cycles(10);
      lock.inject(1);
      await b.cycles(20);
      b.memory.readLimit = null;
      b.reset.inject(0);
      linkUp.inject(1);
      await b.cycles(4);
      expect(await b.readReg(HarborPcieDma.registerStatus), 64 << 16);
      expect(await b.readReg(HarborPcieDma.registerControl), 0);
      expect(await b.readRegs(HarborPcieDma.registerCplHead, 2), [0, 0]);
      expect(await b.readReg(HarborPcieDma.registerResetCounts), 0x01000102);
      expect(await b.readReg(HarborPcieDma.registerPhyStatus), 0x0329);

      hotReset.inject(1);
      await b.cycles(5);
      hotReset.inject(0);
      await b.cycles(5);
      expect(await b.readReg(HarborPcieDma.registerResetCounts), 0x01010102);
      await b.finish();
    });
  }

  test('STATUS shows the state while a fabric read waits', () async {
    final b = await DmaBench.create(const DmaConfig());
    await b.start();
    await b.setupRing(dmaCplBase, 4);
    await b.enable();
    b.memory.readLimit = 0;
    await b.push(hostAddress: 0x80000000, localAddress: 0x100, length: 0x40);
    final status = await _waitState(b, 5);
    expect(status & HarborPcieDma.statusBusy, 1);
    await b.finish();
  });
}

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
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

/// A module with a memory master port that crosses to a fabric clock, and
/// its debug outputs on `cdc_*`.
class _CdcTop extends BridgeModule {
  _CdcTop() : super('PcieDmaStallCdcTop', name: 'top') {
    for (final p in ['clk', 'reset', 'fclk', 'freset']) {
      createPort(p, PortDirection.input);
    }
    final port = HarborMemoryMasterPort.create(
      module: this,
      name: 'memory',
      kind: HarborFabricKind.axi4,
      config: const HarborMemoryWaistConfig(addressWidth: 16, dataWidth: 32),
      clk: input('clk'),
      reset: input('reset'),
      fabricClock: HarborFabricClock(
        clk: input('fclk'),
        reset: input('freset'),
      ),
    );
    port.addDebugOutputs(this, 'cdc');
    final w = port.waist;
    createPort('req_valid', PortDirection.input);
    w.reqValid <= input('req_valid');
    w.reqId <= Const(0, width: w.config.idWidth);
    w.reqWrite <= Const(0);
    w.reqAddr <= Const(0x100, width: 16);
    w.reqLen <= Const(0, width: HarborMemoryWaistConfig.lenWidth);
    w.reqSize <= Const(2, width: HarborMemoryWaistConfig.sizeWidth);
    w.reqBurst <= Const(1, width: HarborMemoryWaistConfig.burstWidth);
    w.reqExclusive <= Const(0);
    w.wdataValid <= Const(0);
    w.wdataData <= Const(0, width: 32);
    w.wdataStrb <= Const(0, width: 4);
    w.wdataLast <= Const(0);
    w.rdataReady <= Const(0);
    w.wrespReady <= Const(0);
  }
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

  test('STATUS and DEBUG show the state while a fabric read waits', () async {
    final b = await DmaBench.create(const DmaConfig());
    await b.start();
    await b.setupRing(dmaCplBase, 4);
    await b.enable();
    b.memory.readLimit = 0;
    await b.push(hostAddress: 0x80000000, localAddress: 0x100, length: 0x40);
    final status = await _waitState(b, 5);
    expect(status & HarborPcieDma.statusBusy, 1);
    final debug = await b.readReg(HarborPcieDma.registerDebug);
    expect(debug & 0xf, 5);
    expect(debug >> HarborPcieDma.debugDStateShift & 7, 0);
    expect(b.top.output('debug').value.toInt() & 0xff, debug & 0xff);
    await b.finish();
  });

  test('DEBUG shows the drain state while a fabric write waits', () async {
    final b = await DmaBench.create(const DmaConfig());
    await b.start();
    await b.setupRing(dmaCplBase, 4);
    await b.enable();
    b.memory.writeLimit = 0;
    b.seedHost(0x80000000, 0x40);
    await b.push(
      hostAddress: 0x80000000,
      localAddress: 0x100,
      length: 0x40,
      deviceToHost: false,
    );
    await _waitState(b, 10);
    var dState = 0;
    for (var i = 0; i < 200 && dState < 3; i++) {
      final debug = await b.readReg(HarborPcieDma.registerDebug);
      dState = debug >> HarborPcieDma.debugDStateShift & 7;
    }
    expect(dState, anyOf(3, 4));
    await b.finish();
  });

  test('a memory port crossing shows its debug outputs', () async {
    final top = _CdcTop();
    await top.build();
    final clk = SimpleClockGenerator(10).clk;
    final fclk = SimpleClockGenerator(14).clk;
    final reset = Logic();
    final reqValid = Logic();
    top.input('clk').srcConnection! <= clk;
    top.input('fclk').srcConnection! <= fclk;
    top.input('reset').srcConnection! <= reset;
    top.input('freset').srcConnection! <= reset;
    top.input('req_valid').srcConnection! <= reqValid;
    for (final p in top.inputs.keys.where((p) => p.startsWith('memory_'))) {
      final port = top.input(p);
      (port.srcConnection ?? port).inject(p.endsWith('ARREADY') ? 1 : 0);
    }
    reset.inject(1);
    reqValid.inject(0);
    Simulator.setMaxSimTime(100000);
    unawaited(Simulator.run());
    for (var i = 0; i < 6; i++) {
      await clk.nextPosedge;
    }
    reset.inject(0);
    for (var i = 0; i < 12; i++) {
      await clk.nextPosedge;
    }
    int out(String n) => top.output('cdc_$n').value.toInt();
    expect(out('reads'), 0);
    expect(out('writes'), 0);
    expect(out('recover'), 0);
    expect(out('empty'), 0xf);
    expect(out('full'), 0);
    reqValid.inject(1);
    await clk.nextPosedge;
    reqValid.inject(0);
    for (var i = 0; i < 12; i++) {
      await clk.nextPosedge;
    }
    expect(out('reads'), 1);
    expect(out('empty'), 0xf);
    await Simulator.endSimulation();
  });
}

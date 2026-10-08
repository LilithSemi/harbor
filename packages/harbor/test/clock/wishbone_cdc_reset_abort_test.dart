// Abort, one-sided reset and watchdog behavior of the Wishbone CDC bridges.
import 'dart:async';

import 'package:harbor/src/clock/wishbone_cdc.dart';
import 'package:harbor/src/clock/wishbone_cdc_fifo.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const tag = 0xD0000000;
const poison = 0xFFFFFFFF;

class Rig {
  final Module dut;
  final Logic sClk;
  final Logic mClk;
  final sReset = Logic(name: 's_reset');
  final mReset = Logic(name: 'm_reset');
  final sCyc = Logic(name: 's_cyc');
  final sStb = Logic(name: 's_stb');
  final sWe = Logic(name: 's_we');
  final sAdr = Logic(name: 's_adr', width: 32);
  final sDatW = Logic(name: 's_dat_w', width: 32);
  final ackEnable = Logic(name: 'ack_en');
  final mResets = <int>[];

  /// Every m-side completion: (adr, we, dat_w).
  final done = <(int, int, int)>[];

  /// Every m-side cycle start.
  final starts = <int>[];

  Rig(this.dut, {int sPeriod = 10, int mPeriod = 7})
    : sClk = SimpleClockGenerator(sPeriod).clk,
      mClk = SimpleClockGenerator(mPeriod).clk {
    dut.input('s_clk').srcConnection! <= sClk;
    dut.input('s_reset').srcConnection! <= sReset;
    dut.input('s_cyc').srcConnection! <= sCyc;
    dut.input('s_stb').srcConnection! <= sStb;
    dut.input('s_we').srcConnection! <= sWe;
    dut.input('s_adr').srcConnection! <= sAdr;
    dut.input('s_dat_w').srcConnection! <= sDatW;
    dut.input('s_sel').srcConnection! <= Const(0xf, width: 4);
    dut.input('m_clk').srcConnection! <= mClk;
    dut.input('m_reset').srcConnection! <= mReset;
    final mCyc = dut.output('m_cyc');
    dut.input('m_ack').srcConnection! <= mCyc & ackEnable;
    // read data tags the address so a stale reply is visible
    dut.input('m_dat_r').srcConnection! <=
        dut.output('m_adr') ^ Const(0xD0000000, width: 32);
  }

  Future<void> start() async {
    await dut.build();
    sReset.inject(1);
    mReset.inject(1);
    sCyc.inject(0);
    sStb.inject(0);
    sWe.inject(0);
    sAdr.inject(0);
    sDatW.inject(0);
    ackEnable.inject(1);
    var prevCyc = 0;
    int v(String n) {
      final x = dut.output(n).value;
      return x.isValid ? x.toInt() : -1;
    }

    mClk.negedge.listen((_) {
      final c = v('m_cyc');
      if (c == 1 && prevCyc != 1) starts.add(v('m_adr'));
      if (c == 1 && ackEnable.value.toInt() == 1) {
        done.add((v('m_adr'), v('m_we'), v('m_dat_w')));
      }
      prevCyc = c;
    });
    Simulator.setMaxSimTime(2000000);
    unawaited(Simulator.run());
    for (var i = 0; i < 6; i++) {
      await sClk.nextPosedge;
    }
    sReset.inject(0);
    mReset.inject(0);
    await sClk.nextPosedge;
  }

  /// Classic transfer; returns read data or -1 on timeout.
  Future<int> xfer(bool we, int adr, [int data = 0, int limit = 500]) async {
    sWe.inject(we ? 1 : 0);
    sAdr.inject(adr);
    sDatW.inject(data);
    sCyc.inject(1);
    sStb.inject(1);
    var g = 0;
    while (dut.output('s_ack').value != LogicValue.one) {
      await sClk.nextPosedge;
      if (++g > limit) {
        sCyc.inject(0);
        sStb.inject(0);
        return -1;
      }
    }
    final rdv = dut.output('s_dat_r').value;
    final rd = rdv.isValid ? rdv.toInt() : -2;
    sCyc.inject(0);
    sStb.inject(0);
    await sClk.nextPosedge;
    return rd;
  }

  Future<void> idle(int n) async {
    for (var i = 0; i < n; i++) {
      await sClk.nextPosedge;
    }
  }
}

Module fifo() => HarborWishboneCdcFifoBridge(addressWidth: 32, dataWidth: 32);
Module gray({int timeout = 0}) => HarborWishboneCdcBridge(
  addressWidth: 32,
  dataWidth: 32,
  completionTimeout: timeout,
);

void main() {
  tearDown(() async => Simulator.reset());

  for (final (name, make) in [('fifo', fifo), ('gray', gray)]) {
    test('$name bridge: aborted read response is dropped, next read gets '
        'its own data', () async {
      final r = Rig(make());
      await r.start();
      r.ackEnable.inject(0);
      r.sWe.inject(0);
      r.sAdr.inject(0x100);
      r.sCyc.inject(1);
      r.sStb.inject(1);
      await r.idle(5);
      r.sCyc.inject(0);
      r.sStb.inject(0);
      await r.idle(2);
      r.ackEnable.inject(1);
      final b = await r.xfer(false, 0x200);
      expect(b, 0x200 ^ tag);
      expect(r.starts, [0x100, 0x200]);
      final c = await r.xfer(false, 0x300);
      expect(c, 0x300 ^ tag);
      await Simulator.endSimulation();
    });

    for (final side in ['m', 's']) {
      test(
        '$name bridge: ${side}_reset alone after traffic replays nothing',
        () async {
          final r = Rig(make());
          await r.start();
          for (var i = 0; i < 3; i++) {
            await r.xfer(true, 0x40 + 4 * i, 0x1000 + i);
          }
          await r.idle(10);
          final before = r.done.length;
          final rst = side == 'm' ? r.mReset : r.sReset;
          rst.inject(1);
          await r.idle(4);
          rst.inject(0);
          await r.idle(40);
          expect(r.done.sublist(before), isEmpty);
          expect(await r.xfer(false, 0x80), 0x80 ^ tag);
          expect(await r.xfer(false, 0x84), 0x84 ^ tag);
          await r.xfer(true, 0x88, 0x55);
          expect(r.done.last, (0x88, 1, 0x55));
          await Simulator.endSimulation();
        },
      );
    }

    test(
      '$name bridge: m_reset during a waiting read ends it with poison',
      () async {
        final r = Rig(make());
        await r.start();
        expect(r.dut.output('s_bus_error').value, LogicValue.zero);
        r.ackEnable.inject(0);
        r.sWe.inject(0);
        r.sAdr.inject(0x100);
        r.sCyc.inject(1);
        r.sStb.inject(1);
        await r.idle(8);
        r.mReset.inject(1);
        var g = 0;
        while (r.dut.output('s_ack').value != LogicValue.one && g++ < 50) {
          await r.sClk.nextPosedge;
        }
        expect(r.dut.output('s_ack').value, LogicValue.one);
        expect(r.dut.output('s_dat_r').value.toInt(), poison);
        r.sCyc.inject(0);
        r.sStb.inject(0);
        await r.idle(4);
        r.mReset.inject(0);
        r.ackEnable.inject(1);
        await r.idle(10);
        expect(await r.xfer(false, 0x200), 0x200 ^ tag);
        // The poison ACK left a sticky error that the peer reset kept.
        expect(r.dut.output('s_bus_error').value, LogicValue.one);
        await Simulator.endSimulation();
      },
    );
  }

  test('gray bridge: after a watchdog ACK the next request waits, ADR holds '
      'and each write runs once', () async {
    final r = Rig(gray(timeout: 20));
    await r.start();
    final adrInCycle = <List<int>>[];
    var inCyc = false;
    r.mClk.negedge.listen((_) {
      final c = r.dut.output('m_cyc').value;
      final a = r.dut.output('m_adr').value;
      final d = r.dut.output('m_dat_w').value;
      if (!c.isValid || !a.isValid || !d.isValid) return;
      if (c.toInt() == 1) {
        if (!inCyc) adrInCycle.add([]);
        final v = (a.toInt() << 8) | d.toInt();
        if (!adrInCycle.last.contains(v)) adrInCycle.last.add(v);
      }
      inCyc = c.toInt() == 1;
    });
    r.ackEnable.inject(0);
    final w1 = await r.xfer(true, 0x10, 0x11, 200);
    expect(w1, poison);
    expect(r.dut.output('s_bus_error').value, LogicValue.one);
    r.sWe.inject(1);
    r.sAdr.inject(0x20);
    r.sDatW.inject(0x22);
    r.sCyc.inject(1);
    r.sStb.inject(1);
    await r.idle(3);
    r.ackEnable.inject(1);
    var g = 0;
    while (r.dut.output('s_ack').value != LogicValue.one && g++ < 200) {
      await r.sClk.nextPosedge;
    }
    r.sCyc.inject(0);
    r.sStb.inject(0);
    await r.idle(20);
    // Each entry is ADR and DAT seen while m_cyc stays high.
    expect(adrInCycle, [
      [0x1011],
      [0x2022],
    ]);
    await Simulator.endSimulation();
  });

  test(
    'gray bridge: more than four watchdog ACKs keep the bridge in step',
    () async {
      final r = Rig(gray(timeout: 10));
      await r.start();
      r.ackEnable.inject(0);
      for (var i = 0; i < 6; i++) {
        expect(await r.xfer(false, 0x10 + 4 * i, 0, 100), poison);
      }
      r.ackEnable.inject(1);
      await r.idle(20);
      // Only the first stalled read reached the master side.
      expect(r.starts, [0x10]);
      for (var i = 0; i < 3; i++) {
        expect(await r.xfer(false, 0x80 + 4 * i), (0x80 + 4 * i) ^ tag);
      }
      await Simulator.endSimulation();
    },
  );
}

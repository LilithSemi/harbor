import 'dart:async';
import 'dart:collection';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_dram_model.dart';
import 'package:harbor/src/peripherals/ddr3_mode_registers.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_phy_ecp5.dart';
import 'package:harbor/src/peripherals/ddr3_timing.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

class _Req {
  final bool we;
  final int bank, row, col;
  _Req(this.we, this.bank, this.row, this.col);
  @override
  String toString() => '${we ? 'WR' : 'RD'} b$bank r$row c$col';
}

/// DDR3 protocol checker on the command slots of the controller. Times are
/// in CK. It checks bank state, tRP, tWR, tRTP, refresh with all banks
/// closed and silence during tRFC. Each RD and WR must match the next
/// accepted request.
class _Ddr3Checker {
  final DdrParams p;
  final DdrTiming t;
  final errors = <String>[];
  final expected = Queue<_Req>();
  final List<int?> open;
  final List<int> lastPre, lastWr, lastRd;
  int lastRef = -1 << 40;
  bool armed = false;
  int refreshes = 0, reads = 0, writes = 0;

  _Ddr3Checker(this.p, this.t)
    : open = List.filled(1 << p.baBits, null),
      lastPre = List.filled(1 << p.baBits, -1 << 40),
      lastWr = List.filled(1 << p.baBits, -1 << 40),
      lastRd = List.filled(1 << p.baBits, -1 << 40);

  int get _cmdLen => 4 + 3 + p.baBits + p.rowBits;
  int get _tRp => t.nsToNck(DdrTiming.tRp);
  int get _tRfc => t.nsToNck(t.tRfc);
  int get _tWr => DdrTiming.cwlNck + 4 + t.nsToNck(DdrTiming.tWr);
  int get _tRtp => t.nsToNck(t.tRtp);

  void _err(int ck, String m) {
    if (armed && errors.length < 20) errors.add('ck $ck: $m');
  }

  void step(int cycle, LogicValue v) {
    if (!v.isValid) return;
    for (var s = 0; s < p.serdesRatio; s++) {
      final w = v.getRange(_cmdLen * s, _cmdLen * (s + 1));
      if (w[_cmdLen - 1].toInt() != 0) continue;
      final op = w.getRange(_cmdLen - 4, _cmdLen - 1).toInt();
      if (op == Ddr3Cmd.nop) continue;
      final ck = cycle * p.controllerClkRatio + s;
      final bank = w.getRange(p.rowBits, p.rowBits + p.baBits).toInt();
      final addr = w.getRange(0, p.rowBits).toInt();
      _slot(ck, op, bank, addr);
    }
  }

  void _slot(int ck, int op, int bank, int addr) {
    if (ck - lastRef < _tRfc) _err(ck, 'command $op during tRFC');
    switch (op) {
      case Ddr3Cmd.act:
        if (open[bank] != null) _err(ck, 'ACT to open bank $bank');
        if (ck - lastPre[bank] < _tRp) _err(ck, 'ACT to bank $bank in tRP');
        open[bank] = addr;
      case Ddr3Cmd.pre:
        final all = addr & (1 << 10) != 0;
        for (var b = 0; b < open.length; b++) {
          if (!all && b != bank) continue;
          if (open[b] != null) {
            if (ck - lastWr[b] < _tWr) _err(ck, 'PRE bank $b in tWR');
            if (ck - lastRd[b] < _tRtp) _err(ck, 'PRE bank $b in tRTP');
          }
          open[b] = null;
          lastPre[b] = ck;
        }
      case Ddr3Cmd.ref:
        if (open.any((r) => r != null)) _err(ck, 'REF with a bank open');
        if (lastPre.any((c) => ck - c < _tRp)) _err(ck, 'REF in tRP');
        lastRef = ck;
        if (armed) refreshes++;
      case Ddr3Cmd.rd || Ddr3Cmd.wr:
        final we = op == Ddr3Cmd.wr;
        final row = open[bank];
        if (row == null) _err(ck, '${we ? 'WR' : 'RD'} to closed bank $bank');
        if (we) {
          lastWr[bank] = ck;
        } else {
          lastRd[bank] = ck;
        }
        if (!armed) return;
        we ? writes++ : reads++;
        final col = addr & ((1 << p.colBits) - 1);
        final got = _Req(we, bank, row ?? -1, col);
        if (expected.isEmpty) {
          _err(ck, 'unexpected $got');
          return;
        }
        final want = expected.removeFirst();
        if (want.toString() != got.toString()) {
          _err(ck, 'issued $got, expected $want');
        }
    }
  }
}

int _clog2(int x) {
  var n = 0;
  for (var v = x - 1; v > 0; v >>= 1) {
    n++;
  }
  return n;
}

/// Runs the controller with [p] to DONE_CALIBRATE, then sends a write and
/// at once a different-row access to the same bank at each phase around
/// the refresh stall.
Future<_Ddr3Checker> _run(DdrParams p, {required bool selfTrain}) async {
  final clk = SimpleClockGenerator(10).clk;
  final rstN = Logic(name: 'rstn');
  final wbCyc = Logic(name: 'wb_cyc')..inject(0);
  final wbStb = Logic(name: 'wb_stb')..inject(0);
  final wbWe = Logic(name: 'wb_we')..inject(0);
  final wbAddr = Logic(name: 'wb_addr', width: p.wbAddrBits)..inject(0);
  final wbData = Logic(name: 'wb_data', width: p.wbDataBits)..inject(0);
  final wbSel = Logic(name: 'wb_sel', width: p.wbSelBits)..inject(0);
  final dq = p.dqBits * p.lanes;
  final phyData = Logic(name: 'phy_data', width: dq * 8);
  final phyDqs = Logic(name: 'phy_dqs', width: p.lanes * 8);
  final phyBsRef = Logic(name: 'phy_bsref', width: p.lanes * 8);
  final phyRdy = Logic(name: 'phy_rdy');
  final levelDone = Logic(name: 'level_done');

  final ctrl = Ddr3Controller(
    p,
    controllerClk: clk,
    rstN: rstN,
    wbCyc: wbCyc,
    wbStb: wbStb,
    wbWe: wbWe,
    wbAddr: wbAddr,
    wbData: wbData,
    wbSel: wbSel,
    aux: Logic(width: Ddr3Controller.auxWidth)..inject(1),
    wb2Cyc: Logic()..inject(0),
    wb2Stb: Logic()..inject(0),
    wb2We: Logic()..inject(0),
    wb2Addr: Logic(width: Ddr3Controller.wb2AddrBits)..inject(0),
    wb2Sel: Logic(width: Ddr3Controller.wb2SelBits)..inject(0),
    wb2Data: Logic(width: Ddr3Controller.wb2DataBits)..inject(0),
    phyIserdesData: phyData,
    phyIserdesDqs: phyDqs,
    phyIserdesBitslipReference: phyBsRef,
    phyIdelayctrlRdy: phyRdy,
    phySelfTrainsRead: selfTrain,
    phyReadPipeTicks: selfTrain ? Ddr3PhyEcp5.readPipeTicks : 0,
    phyReadLevelDone: selfTrain ? levelDone : null,
  );
  final model = Ddr3DramModel(
    p,
    controllerClk: clk,
    phyReset: ctrl.phyReset,
    cmd: ctrl.phyCmd,
    writeData: ctrl.output('o_phy_data'),
    bitslip: ctrl.output('o_phy_bitslip'),
    idelayDqsLd: ctrl.output('o_phy_idelay_dqs_ld'),
  );
  phyData <= model.iserdesData;
  phyRdy <= model.idelayctrlRdy;
  Ddr3Ecp5ReadLeveler? lev;
  if (selfTrain) {
    phyDqs <= Const(0, width: p.lanes * 8);
    phyBsRef <= Const(0, width: p.lanes * 8);
    lev = Ddr3Ecp5ReadLeveler(
      lanes: p.lanes,
      clk: clk,
      reset: ctrl.phyReset,
      start: ctrl.output('o_phy_read_level_start'),
      check: ctrl.output('o_phy_read_level_check'),
      pass: ctrl.output('o_phy_read_level_pass'),
      burstSeen: Const(3, width: 2),
      useBurstDet: false,
    );
    levelDone <= lev.done;
  } else {
    phyDqs <= model.iserdesDqs;
    phyBsRef <= model.iserdesBitslipReference;
  }

  await ctrl.build();
  await model.build();
  await lev?.build();

  final timing = DdrTiming.fromPs(
    ddr3ClkPeriodPs: p.ddr3ClkPeriodPs,
    serdesRatio: p.serdesRatio,
    controllerClkRatio: p.controllerClkRatio,
    density: p.density,
  );
  final chk = _Ddr3Checker(p, timing);
  final colLo = p.colBits - _clog2(p.serdesRatio * 2);
  int addrOf(int bank, int row, int colGroup) =>
      (row << (colLo + p.baBits)) | (bank << colLo) | colGroup;

  rstN.inject(0);
  Simulator.setMaxSimTime(1 << 40);
  unawaited(Simulator.run());
  await clk.nextPosedge;
  await clk.nextPosedge;
  rstN.inject(1);

  final pending = Queue<_Req>();
  var cycle = 0;
  var presenting = false;
  var lastStall = 1;
  var acks = 0;
  var accepted = 0;

  int state() {
    final v = ctrl.debug1.value;
    return v.isValid ? v.getRange(0, 6).toInt() : -1;
  }

  int romAddr() {
    final v = ctrl.debug1.value;
    return v.isValid ? v.getRange(8, 13).toInt() : -1;
  }

  // One controller cycle. Inputs change and outputs are sampled at the
  // negative edge, so each value is stable at the next positive edge.
  Future<void> tick() async {
    await clk.nextNegedge;
    cycle++;
    chk.step(cycle, ctrl.phyCmd.value);
    if (chk.armed && ctrl.output('o_wb_ack').value.toInt() == 1) acks++;
    if (presenting && lastStall == 0) {
      chk.expected.add(pending.removeFirst());
      accepted++;
    }
    presenting = pending.isNotEmpty;
    if (presenting) {
      final r = pending.first;
      wbCyc.inject(1);
      wbStb.inject(1);
      wbWe.inject(r.we ? 1 : 0);
      wbAddr.inject(addrOf(r.bank, r.row, r.col >> 3));
      wbData.inject(BigInt.from(r.row * 31 + r.col));
      wbSel.inject((BigInt.one << p.wbSelBits) - BigInt.one);
    } else {
      wbStb.inject(0);
    }
    lastStall = ctrl.output('o_wb_stall').value.toInt();
  }

  for (var i = 0; i < 400000 && state() != 23; i++) {
    await tick();
  }
  expect(state(), 23, reason: 'never reached DONE_CALIBRATE');
  wbCyc.inject(1);
  chk.armed = true;

  // Wait for the start of the refresh interval (tREFI timer loaded).
  Future<int> waitRom(int a) async {
    while (romAddr() == a) {
      await tick();
    }
    while (romAddr() != a) {
      await tick();
    }
    return cycle;
  }

  final t22 = await waitRom(22);
  final t19 = await waitRom(19);
  final lead = t19 - t22;

  final phases = [for (var d = -18; d <= 2; d++) d];
  var n = 0;
  for (var rep = 0; rep < 2; rep++) {
    for (final d in phases) {
      final start = await waitRom(22);
      while (cycle < start + lead + d) {
        await tick();
      }
      final bank = n % (1 << p.baBits);
      final row = 1 + 2 * (n % 50);
      final col = 8 * (n % 16);
      pending
        ..add(_Req(true, bank, row, col))
        ..add(_Req(rep == 0, bank, row + 1, col));
      n++;
    }
  }
  for (var i = 0; i < 60; i++) {
    await tick();
  }
  await waitRom(21);
  for (var i = 0; i < 4 * lead; i++) {
    await tick();
  }
  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  expect(pending, isEmpty, reason: 'requests left unaccepted');
  expect(accepted, 4 * phases.length);
  expect(chk.expected, isEmpty, reason: 'accepted requests never issued');
  expect(acks, accepted, reason: 'ack count');
  expect(chk.refreshes, greaterThanOrEqualTo(2 * phases.length));
  return chk;
}

void main() {
  tearDown(() async => Simulator.reset());

  for (final (name, p, selfTrain) in [
    ('Arty S7', DdrParams.artyS7(), false),
    ('OrangeCrab', DdrParams.orangeCrab(), true),
  ]) {
    test(
      '$name: a row miss behind a write at refresh keeps the DDR3 protocol',
      () async {
        final chk = await _run(p, selfTrain: selfTrain);
        expect(chk.errors, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 30)),
    );
  }
}

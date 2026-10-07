import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// wb2 register indices. Index 3 is knob@3 (BITSLIP, byte 0x18) and index 4
/// is CTL (byte 0x20), the same contract Weir's ddr_train.zig drives.
const int wIdelay = 2;
const int wBitslip = 3;
const int wCtl = 4;

class _Wb2 {
  final Logic cyc = Logic()..inject(0);
  final Logic stb = Logic()..inject(0);
  final Logic we = Logic()..inject(0);
  final Logic addr;
  final Logic sel;
  final Logic data;
  _Wb2()
    : addr = Logic(width: Ddr3Controller.wb2AddrBits)..inject(0),
      sel = Logic(width: Ddr3Controller.wb2SelBits)..inject(0),
      data = Logic(width: Ddr3Controller.wb2DataBits)..inject(0);
}

/// One wb2 write, held for a single controller cycle. Mirrors Weir's
/// applyKnob: a register write is one bus transaction.
Future<void> _wb2Write(_Wb2 wb2, Logic clk, int addr, int data) async {
  wb2.cyc.inject(1);
  wb2.stb.inject(1);
  wb2.we.inject(1);
  wb2.addr.inject(addr);
  wb2.data.inject(data);
  await clk.nextPosedge;
  wb2.cyc.inject(0);
  wb2.stb.inject(0);
  wb2.we.inject(0);
}

void main() {
  tearDown(() async => Simulator.reset());

  test('Weir one APPLY step on the bitslip knob commits exactly one '
      'ISERDESE2 slip on the Xilinx path (train=runtime)', () async {
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rstn');
    final wb2 = _Wb2();
    final p = DdrParams.artyS7(ckPeriodPs: 3000);

    final dut = Ddr3Controller(
      p,
      controllerClk: clk,
      rstN: rstN,
      wbCyc: Logic()..inject(0),
      wbStb: Logic()..inject(0),
      wbWe: Logic()..inject(0),
      wbAddr: Logic(width: p.wbAddrBits)..inject(0),
      wbData: Logic(width: p.wbDataBits)..inject(0),
      wbSel: Logic(width: p.wbSelBits)..inject(0),
      aux: Logic(width: Ddr3Controller.auxWidth)..inject(0),
      wb2Cyc: wb2.cyc,
      wb2Stb: wb2.stb,
      wb2We: wb2.we,
      wb2Addr: wb2.addr,
      wb2Sel: wb2.sel,
      wb2Data: wb2.data,
      phyIserdesData: Logic(width: p.dqBits * p.lanes * 8)..inject(0),
      phyIserdesDqs: Logic(width: p.lanes * 8)..inject(0),
      phyIserdesBitslipReference: Logic(width: p.lanes * 8)..inject(0),
      phyIdelayctrlRdy: Logic()..inject(0),
      runtimeTrainable: true,
    );
    await dut.build();

    // Count a slip the same way the ISERDESE2 sim model does (see
    // iserdese2_sim.dart: "If(bitslip, then: [bs <- bs +/- 1])" on every
    // CLKDIV edge) and the way UG471 documents the real primitive: one
    // slip for every clkdiv cycle BITSLIP reads high. One counter per lane,
    // so a lane-1 APPLY cannot hide as a lane-0 slip or vice versa.
    final slipCount0 = Logic(name: 'slip_probe_count_0', width: 32);
    final slipCount1 = Logic(name: 'slip_probe_count_1', width: 32);
    final bitslipLane0 = dut.output('o_phy_bitslip')[0];
    final bitslipLane1 = dut.output('o_phy_bitslip')[1];
    Sequential(clk, [
      If(
        ~rstN,
        then: [
          slipCount0 < Const(0, width: 32),
          slipCount1 < Const(0, width: 32),
        ],
        orElse: [
          If(bitslipLane0, then: [slipCount0 < slipCount0 + 1]),
          If(bitslipLane1, then: [slipCount1 < slipCount1 + 1]),
        ],
      ),
    ]);

    rstN.inject(0);
    Simulator.setMaxSimTime(200000);
    unawaited(Simulator.run());
    await clk.nextPosedge;
    await clk.nextPosedge;
    rstN.inject(1);
    await clk.nextPosedge;

    // Weir's advanceOne() for one bitslip sweep step: write BITSLIP=1,
    // CTL SET (lane 0), CTL LOAD/APPLY. ddr_train.zig issues exactly this
    // sequence on every count of the sweep, always with value 1. Its own
    // doc comment (ddr_train.zig:27-28) says the engine reaches a count of
    // N with N repeated APPLY pulses: one APPLY must mean one slip.
    await _wb2Write(wb2, clk, wBitslip, 1);
    await _wb2Write(wb2, clk, wCtl, 0x1); // SET, lane 0
    await _wb2Write(wb2, clk, wCtl, 0x2); // LOAD/APPLY

    // Let many clkdiv cycles pass with no further wb2 traffic: the state
    // an FSBL sweep loop leaves the bus in while it runs patternPasses()
    // between steps.
    const idleCycles = 40;
    for (var i = 0; i < idleCycles; i++) {
      await clk.nextPosedge;
    }

    expect(
      slipCount0.value.toInt(),
      1,
      reason:
          'one Weir APPLY on the bitslip knob should commit exactly one '
          'ISERDESE2 slip, then stay low. A held BITSLIP level would keep '
          'slipping every clkdiv cycle instead.',
    );

    // A second APPLY (Weir's next sweep step) should add exactly one more
    // slip, not resume continuous slipping.
    await _wb2Write(wb2, clk, wBitslip, 1);
    await _wb2Write(wb2, clk, wCtl, 0x1); // SET, lane 0
    await _wb2Write(wb2, clk, wCtl, 0x2); // LOAD/APPLY
    for (var i = 0; i < idleCycles; i++) {
      await clk.nextPosedge;
    }

    expect(
      slipCount0.value.toInt(),
      2,
      reason: 'a second APPLY should commit exactly one more slip (total 2)',
    );

    // Lane 1 (CTL[11:8] = 1, the lane selector, per the knob-ABI doc comment
    // in ddr_train.zig) must slip lane 1 only, not touch lane 0's count.
    await _wb2Write(wb2, clk, wBitslip, 1);
    await _wb2Write(wb2, clk, wCtl, 0x101); // SET, lane 1
    await _wb2Write(wb2, clk, wCtl, 0x102); // LOAD/APPLY, lane 1
    for (var i = 0; i < idleCycles; i++) {
      await clk.nextPosedge;
    }

    expect(
      slipCount1.value.toInt(),
      1,
      reason: 'a lane-1 APPLY should commit exactly one lane-1 slip',
    );
    expect(
      slipCount0.value.toInt(),
      2,
      reason: 'a lane-1 APPLY must not slip lane 0',
    );

    // An APPLY that commits a different knob (IDELAY), with no new BITSLIP
    // write since the last APPLY, must not add a slip on either lane: the
    // strobe is gated on the bitslip knob's own dirty flag.
    await _wb2Write(wb2, clk, wIdelay, 5);
    await _wb2Write(wb2, clk, wCtl, 0x1); // SET, lane 0
    await _wb2Write(wb2, clk, wCtl, 0x2); // LOAD/APPLY, lane 0 (IDELAY only)
    for (var i = 0; i < idleCycles; i++) {
      await clk.nextPosedge;
    }

    expect(
      slipCount0.value.toInt(),
      2,
      reason: 'an IDELAY APPLY must not add a bitslip strobe',
    );
    expect(
      slipCount1.value.toInt(),
      1,
      reason: 'an IDELAY APPLY on lane 0 must not touch lane 1 either',
    );

    await Simulator.endSimulation();
  });
}

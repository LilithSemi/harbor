import 'dart:async';

import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_mode_registers.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

Ddr3Controller _build(DdrParams p, {required Logic clk, required Logic rstN}) =>
    Ddr3Controller(
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
      wb2Cyc: Logic()..inject(0),
      wb2Stb: Logic()..inject(0),
      wb2We: Logic()..inject(0),
      wb2Addr: Logic(width: Ddr3Controller.wb2AddrBits)..inject(0),
      wb2Sel: Logic(width: Ddr3Controller.wb2SelBits)..inject(0),
      wb2Data: Logic(width: Ddr3Controller.wb2DataBits)..inject(0),
      // No PHY model attached: idelayctrl never asserts, so the reset walk
      // pauses at the read-calibration point (instruction 13).
      phyIserdesData: Logic(width: p.dqBits * p.lanes * 8)..inject(0),
      phyIserdesDqs: Logic(width: p.lanes * 8)..inject(0),
      phyIserdesBitslipReference: Logic(width: p.lanes * 8)..inject(0),
      phyIdelayctrlRdy: Logic()..inject(0),
    );

void main() {
  tearDown(() async => Simulator.reset());

  test(
    'Ddr3Controller elaborates and emits the full PHY/wishbone port set',
    () async {
      final dut = _build(
        DdrParams.artyS7(ckPeriodPs: 3000),
        clk: Logic(name: 'cclk'),
        rstN: Logic(name: 'rstn'),
      );
      await dut.build();
      final sv = dut.dumpSystemVerilog();
      for (final port in [
        'o_phy_cmd',
        'o_phy_reset',
        'o_phy_bitslip',
        'o_wb_stall',
        'o_wb_ack',
        'i_phy_iserdes_data',
        'o_debug2',
      ]) {
        expect(sv, contains(port), reason: 'missing port $port');
      }
    },
  );

  test('reset engine walks the ROM and pauses at the read-cal point', () async {
    final clk = SimpleClockGenerator(10).clk;
    final rstN = Logic(name: 'rstn');
    // A tiny CK period keeps ns_to_cycles small so the multi-microsecond resets
    // finish in a few thousand controller cycles (the ROM walk is what we check,
    // not the exact hardware dwell).
    final p = DdrParams(
      controllerClkPeriodPs: 800000, // 800 ns
      ddr3ClkPeriodPs: 200000, // 200 ns CK (4:1)
    );
    final dut = _build(p, clk: clk, rstN: rstN);
    await dut.build();

    rstN.inject(0);
    Simulator.setMaxSimTime(1000000);
    unawaited(Simulator.run());

    // Hold reset a couple of cycles, then release.
    await clk.nextPosedge;
    await clk.nextPosedge;
    // During reset the ROM address sits at 0. The reset-walk observables live in
    // o_debug1 (instruction_address [12:8], reset_done [6]); o_debug2 is the BIST
    // capture word, unreset-X until calibration, so slice debug1 bit fields
    // rather than toInt the whole (partly-X) word.
    expect(dut.debug1.value.getRange(8, 13).toInt(), 0);
    rstN.inject(1);

    var maxAddr = 0;
    var finalAddr = 0;
    for (var i = 0; i < 6000; i++) {
      await clk.nextPosedge;
      final d1 = dut.debug1.value;
      final addr = d1.getRange(8, 13).toInt();
      if (addr > maxAddr) maxAddr = addr;
      finalAddr = addr;
      // reset_done must NOT assert without calibration (RST_DONE is post-cal).
      expect(d1[6].toInt(), 0, reason: 'reset_done asserted before cal');
    }

    // Programs MR2/MR3/MR1/MR0, ZQC and precharge (through instruction 12) then
    // pauses at instruction 13 waiting for read calibration.
    expect(maxAddr, greaterThanOrEqualTo(12));
    expect(finalAddr, 13, reason: 'walk should hold at the read-cal pause');

    await Simulator.endSimulation();
  });

  test(
    'reset-phase o_phy_cmd puts each ROM command on the precharge slot',
    () async {
      final clk = SimpleClockGenerator(10).clk;
      final rstN = Logic(name: 'rstn');
      final p = DdrParams(
        controllerClkPeriodPs: 800000,
        ddr3ClkPeriodPs: 200000,
      );
      final dut = _build(p, clk: clk, rstN: rstN);
      await dut.build();
      final cmdLen = dut.cmdLen;

      rstN.inject(0);
      Simulator.setMaxSimTime(1000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      rstN.inject(1);

      final cmd3Seen = <int>{};
      var sawAssertedCs = false;
      for (var i = 0; i < 4000; i++) {
        await clk.nextPosedge;
        // The precharge slot is slot 0 = the low cmdLen bits; the {ras,cas,we}
        // field sits at [cmdLen-2 : cmdLen-4] and cs_n at [cmdLen-1].
        final slot = dut.phyCmd.value.getRange(0, cmdLen);
        if (slot.isValid) {
          cmd3Seen.add(slot.getRange(cmdLen - 4, cmdLen - 1).toInt());
          if (slot[cmdLen - 1].toInt() == 0) sawAssertedCs = true;
        }
      }

      // Through the read-cal pause (instruction 13) the ROM drives MRS(0),
      // PRE(2), ZQC(6) and NOP(7). REF(1) is post-calibration (instruction 20).
      expect(cmd3Seen, containsAll(<int>{0, 2, 6, 7}));
      // cs_n asserts (goes low) when a new instruction is issued.
      expect(sawAssertedCs, isTrue);

      await Simulator.endSimulation();
    },
  );

  test('the reset ROM the DUT drives matches Ddr3ModeRegisters', () {
    final p = DdrParams.artyS7(ckPeriodPs: 3000);
    final dut = _build(
      p,
      clk: Logic(name: 'c'),
      rstN: Logic(name: 'r'),
    );
    final mr = Ddr3ModeRegisters(dut.timing);
    expect(mr.mr0, 0x520);
    expect(Ddr3Instruction(mr.romWord(21)).rstDone, 1);
  });
}

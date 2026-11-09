import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_phy.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Ddr3Phy skeleton elaborates and emits the CK + IDELAYCTRL primitives',
    () async {
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      const cmdLen =
          4 + 3 + 3 + 14; // odt/cke/reset + cs/ras/cas/we-ish + BA + ROW
      final phy = Ddr3Phy(
        p,
        controllerClk: Logic(name: 'cclk'),
        ddr3Clk: Logic(name: 'dclk'),
        refClk: Logic(name: 'rclk'),
        ddr3Clk90: Logic(name: 'dclk90'),
        rstN: Logic(name: 'rstn'),
        controllerReset: Logic(name: 'creset'),
        cmd: Logic(name: 'cmd', width: cmdLen * p.serdesRatio),
        dqsTriControl: Logic(),
        dqTriControl: Logic(),
        toggleDqs: Logic(),
        data: Logic(width: p.wbDataBits),
        dm: Logic(width: p.wbSelBits),
        odelayDataCntValueIn: Logic(width: 5),
        odelayDqsCntValueIn: Logic(width: 5),
        idelayDataCntValueIn: Logic(width: 5),
        idelayDqsCntValueIn: Logic(width: 5),
        odelayDataLd: Logic(width: p.lanes),
        odelayDqsLd: Logic(width: p.lanes),
        idelayDataLd: Logic(width: p.lanes),
        idelayDqsLd: Logic(width: p.lanes),
        bitslip: Logic(width: p.lanes),
        writeLevelingCalib: Logic(),
        dqPad: LogicNet(width: p.dqBits * p.lanes),
        dqsPad: LogicNet(width: p.lanes),
        dqsNPad: LogicNet(width: p.lanes),
      );

      await phy.build();
      final sv = phy.dumpSystemVerilog();

      expect(sv, contains('IDELAYCTRL'));
      expect(sv, contains('OBUFDS'));
      expect(sv, contains('ODDR'));
      // Read-return port widths track the x16 geometry.
      expect(phy.iserdesData.width, p.dqBits * p.lanes * 8); // 128
      expect(phy.iserdesDqs.width, p.lanes * 8); // 16
      expect(phy.idelayctrlRdy.width, 1);
    },
  );

  test(
    'command/address SERDES emits one OSERDESE2 per cmd bit + all cmd pads',
    () async {
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      const cmdLen = 4 + 3 + 3 + 14; // cs/ras/cas/we + odt/cke/reset + BA + ROW
      final phy = Ddr3Phy(
        p,
        controllerClk: Logic(name: 'cclk'),
        ddr3Clk: Logic(name: 'dclk'),
        refClk: Logic(name: 'rclk'),
        ddr3Clk90: Logic(name: 'dclk90'),
        rstN: Logic(name: 'rstn'),
        controllerReset: Logic(name: 'creset'),
        cmd: Logic(name: 'cmd', width: cmdLen * p.serdesRatio),
        dqsTriControl: Logic(),
        dqTriControl: Logic(),
        toggleDqs: Logic(),
        data: Logic(width: p.wbDataBits),
        dm: Logic(width: p.wbSelBits),
        odelayDataCntValueIn: Logic(width: 5),
        odelayDqsCntValueIn: Logic(width: 5),
        idelayDataCntValueIn: Logic(width: 5),
        idelayDqsCntValueIn: Logic(width: 5),
        odelayDataLd: Logic(width: p.lanes),
        odelayDqsLd: Logic(width: p.lanes),
        idelayDataLd: Logic(width: p.lanes),
        idelayDqsLd: Logic(width: p.lanes),
        bitslip: Logic(width: p.lanes),
        writeLevelingCalib: Logic(),
        dqPad: LogicNet(width: p.dqBits * p.lanes),
        dqsPad: LogicNet(width: p.lanes),
        dqsNPad: LogicNet(width: p.lanes),
      );

      await phy.build();
      final sv = phy.dumpSystemVerilog();

      // One command SERDES per command-word bit.
      expect(RegExp('cmd_oserdes').allMatches(sv).length, cmdLen);
      // Every command pad is driven.
      for (final pad in [
        'o_ddr3_cs_n',
        'o_ddr3_ras_n',
        'o_ddr3_cas_n',
        'o_ddr3_we_n',
        'o_ddr3_odt',
        'o_ddr3_cke',
        'o_ddr3_reset_n',
        'o_ddr3_ba_addr',
        'o_ddr3_addr',
      ]) {
        expect(sv, contains(pad), reason: 'missing command pad $pad');
      }
    },
  );

  test(
    'DQ datapath: per-pin write OSERDESE2 + IOBUF and read IDELAY/ISERDES',
    () async {
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      const cmdLen = 4 + 3 + 3 + 14;
      final dq = p.dqBits * p.lanes; // 16
      final phy = Ddr3Phy(
        p,
        controllerClk: Logic(name: 'cclk'),
        ddr3Clk: Logic(name: 'dclk'),
        refClk: Logic(name: 'rclk'),
        ddr3Clk90: Logic(name: 'dclk90'),
        rstN: Logic(name: 'rstn'),
        controllerReset: Logic(name: 'creset'),
        cmd: Logic(name: 'cmd', width: cmdLen * p.serdesRatio),
        dqsTriControl: Logic(),
        dqTriControl: Logic(),
        toggleDqs: Logic(),
        data: Logic(width: p.wbDataBits),
        dm: Logic(width: p.wbSelBits),
        odelayDataCntValueIn: Logic(width: 5),
        odelayDqsCntValueIn: Logic(width: 5),
        idelayDataCntValueIn: Logic(width: 5),
        idelayDqsCntValueIn: Logic(width: 5),
        odelayDataLd: Logic(width: p.lanes),
        odelayDqsLd: Logic(width: p.lanes),
        idelayDataLd: Logic(width: p.lanes),
        idelayDqsLd: Logic(width: p.lanes),
        bitslip: Logic(width: p.lanes),
        writeLevelingCalib: Logic(),
        dqPad: LogicNet(width: dq),
        dqsPad: LogicNet(width: p.lanes),
        dqsNPad: LogicNet(width: p.lanes),
      );

      await phy.build();
      final sv = phy.dumpSystemVerilog();

      // One write serdes, IOBUF, read IDELAY and read ISERDES per DQ pin.
      expect(RegExp('dq_oserdes').allMatches(sv).length, dq);
      expect(RegExp('dq_iobuf').allMatches(sv).length, dq);
      expect(RegExp('dq_idelay').allMatches(sv).length, dq);
      expect(RegExp('dq_iserdes').allMatches(sv).length, dq);
      // The HR-bank Arty S7 has no write ODELAYE2 (odelaySupported == false).
      expect(RegExp('dq_odelay').allMatches(sv).length, 0);
      // The 128-bit deserialized read word is assembled and driven.
      expect(sv, contains('io_ddr3_dq'));
      expect(phy.iserdesData.width, dq * 8);
    },
  );

  test(
    'DM + DQS + bitslip-reference datapaths: per-lane strobe and train serdes',
    () async {
      final p = DdrParams.artyS7(ckPeriodPs: 3000);
      const cmdLen = 4 + 3 + 3 + 14;
      final phy = Ddr3Phy(
        p,
        controllerClk: Logic(name: 'cclk'),
        ddr3Clk: Logic(name: 'dclk'),
        refClk: Logic(name: 'rclk'),
        ddr3Clk90: Logic(name: 'dclk90'),
        rstN: Logic(name: 'rstn'),
        controllerReset: Logic(name: 'creset'),
        cmd: Logic(name: 'cmd', width: cmdLen * p.serdesRatio),
        dqsTriControl: Logic(),
        dqTriControl: Logic(),
        toggleDqs: Logic(),
        data: Logic(width: p.wbDataBits),
        dm: Logic(width: p.wbSelBits),
        odelayDataCntValueIn: Logic(width: 5),
        odelayDqsCntValueIn: Logic(width: 5),
        idelayDataCntValueIn: Logic(width: 5),
        idelayDqsCntValueIn: Logic(width: 5),
        odelayDataLd: Logic(width: p.lanes),
        odelayDqsLd: Logic(width: p.lanes),
        idelayDataLd: Logic(width: p.lanes),
        idelayDqsLd: Logic(width: p.lanes),
        bitslip: Logic(width: p.lanes),
        writeLevelingCalib: Logic(),
        dqPad: LogicNet(width: p.dqBits * p.lanes),
        dqsPad: LogicNet(width: p.lanes),
        dqsNPad: LogicNet(width: p.lanes),
      );

      await phy.build();
      final sv = phy.dumpSystemVerilog();

      // One DM serdes+OBUF per lane, differential DQS IOBUFDS per lane.
      expect(RegExp('dm_oserdes').allMatches(sv).length, p.lanes);
      expect(RegExp('dm_obuf').allMatches(sv).length, p.lanes);
      expect(RegExp('dqs_oserdes').allMatches(sv).length, p.lanes);
      expect(RegExp('dqs_iserdes').allMatches(sv).length, p.lanes);
      expect(sv, contains('IOBUFDS'));
      expect(sv, contains('o_ddr3_dm'));
      expect(sv, contains('io_ddr3_dqs'));
      expect(sv, contains('io_ddr3_dqs_n'));
      // The bitslip-reference train serdes: one OSERDES/ISERDES pair per lane, with
      // the OFB loopback (OFB_USED="TRUE").
      expect(RegExp('train_oserdes').allMatches(sv).length, p.lanes);
      expect(RegExp('train_iserdes').allMatches(sv).length, p.lanes);
      expect(sv, contains('.OFB_USED("TRUE")'));
      expect(phy.iserdesBitslipReference.width, p.lanes * 8);
      expect(phy.iserdesDqs.width, p.lanes * 8);
    },
  );
}

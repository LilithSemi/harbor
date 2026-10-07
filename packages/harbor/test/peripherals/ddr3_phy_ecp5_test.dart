import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_phy_ecp5.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

Ddr3Controller _controller(DdrParams p, {required bool runtimeTrainable}) =>
    Ddr3Controller(
      p,
      controllerClk: Logic(),
      rstN: Logic(),
      wbCyc: Logic(),
      wbStb: Logic(),
      wbWe: Logic(),
      wbAddr: Logic(width: p.wbAddrBits),
      wbData: Logic(width: p.wbDataBits),
      wbSel: Logic(width: p.wbSelBits),
      aux: Logic(width: Ddr3Controller.auxWidth),
      wb2Cyc: Logic(),
      wb2Stb: Logic(),
      wb2We: Logic(),
      wb2Addr: Logic(width: Ddr3Controller.wb2AddrBits),
      wb2Sel: Logic(width: Ddr3Controller.wb2SelBits),
      wb2Data: Logic(width: Ddr3Controller.wb2DataBits),
      phyIserdesData: Logic(width: p.dqBits * p.lanes * 8),
      phyIserdesDqs: Logic(width: p.lanes * 8),
      phyIserdesBitslipReference: Logic(width: p.lanes * 8),
      phyIdelayctrlRdy: Logic(),
      phyReadLevelDone: Logic(),
      phySelfTrainsRead: true,
      phyReadPipeTicks: Ddr3PhyEcp5.readPipeTicks,
      runtimeTrainable: runtimeTrainable,
    );

/// The ECP5 PHY wired straight to a self-training controller, as HarborDdr3
/// does at gearRatio 1.
Ddr3PhyEcp5 _phy(DdrParams p, Ddr3Controller c, {bool runtime = false}) =>
    Ddr3PhyEcp5(
      p,
      controllerClk: Logic(name: 'cclk'),
      ddr3Clk: Logic(name: 'dclk'),
      refClk: Logic(name: 'rclk'),
      ddr3Clk90: Logic(name: 'dclk90'),
      rstN: Logic(name: 'rstn'),
      controllerReset: c.output('o_phy_reset'),
      cmd: c.output('o_phy_cmd'),
      dqsTriControl: c.output('o_phy_dqs_tri_control'),
      dqTriControl: c.output('o_phy_dq_tri_control'),
      toggleDqs: c.output('o_phy_toggle_dqs'),
      data: c.output('o_phy_data'),
      dm: c.output('o_phy_dm'),
      odelayDataCntValueIn: c.output('o_phy_odelay_data_cntvaluein'),
      odelayDqsCntValueIn: c.output('o_phy_odelay_dqs_cntvaluein'),
      idelayDataCntValueIn: c.output('o_phy_idelay_data_cntvaluein'),
      idelayDqsCntValueIn: c.output('o_phy_idelay_dqs_cntvaluein'),
      odelayDataLd: c.output('o_phy_odelay_data_ld'),
      odelayDqsLd: c.output('o_phy_odelay_dqs_ld'),
      idelayDataLd: c.output('o_phy_idelay_data_ld'),
      idelayDqsLd: c.output('o_phy_idelay_dqs_ld'),
      bitslip: c.output('o_phy_bitslip'),
      writeLevelingCalib: c.output('o_phy_write_leveling_calib'),
      readLevelStart: c.output('o_phy_read_level_start'),
      readLevelCheck: c.output('o_phy_read_level_check'),
      readLevelPass: c.output('o_phy_read_level_pass'),
      readClkSel: runtime ? c.output('o_phy_read_clk_sel') : null,
      dqPad: LogicNet(width: p.dqBits * p.lanes),
      dqsPad: LogicNet(width: p.lanes),
      dqsNPad: LogicNet(width: p.lanes),
      runtimeTrainable: runtime,
    );

/// The body of one module in a generateSynth() dump.
String _moduleBody(String sv, String name) {
  final start = sv.indexOf(RegExp('module $name\\s*\\('));
  expect(start, greaterThanOrEqualTo(0), reason: 'no module $name');
  return sv.substring(start, sv.indexOf('endmodule', start));
}

int _count(String sv, String cell) =>
    RegExp('\\b$cell\\b').allMatches(sv).length;

/// Ports this PHY takes for contract compliance but has no ECP5 use for.
const _unusedInputs = {
  'i_ref_clk',
  'i_ddr3_clk_90',
  'i_controller_dqs_tri_control',
  'i_controller_dq_tri_control',
  'i_controller_toggle_dqs',
  'i_controller_odelay_data_cntvaluein',
  'i_controller_odelay_dqs_cntvaluein',
  'i_controller_idelay_dqs_cntvaluein',
  'i_controller_odelay_data_ld',
  'i_controller_odelay_dqs_ld',
  'i_controller_idelay_dqs_ld',
  'i_controller_write_leveling_calib',
};

void main() {
  tearDown(() async => Simulator.reset());

  for (final runtime in [false, true]) {
    final mode = runtime ? 'train=runtime' : 'train=hw';
    test('$mode: every controller PHY port meets a PHY port of the same width '
        '(OrangeCrab geometry)', () async {
      final p = DdrParams.orangeCrab();
      final c = _controller(p, runtimeTrainable: runtime);
      final phy = _phy(p, c, runtime: runtime);
      await phy.build();

      final ctrlOut = c.outputs.keys.where((n) => n.startsWith('o_phy_'));
      expect(ctrlOut, hasLength(runtime ? 21 : 20));
      for (final n in ctrlOut) {
        final phyIn = n == 'o_phy_reset'
            ? 'i_controller_reset'
            : n.replaceFirst('o_phy_', 'i_controller_');
        expect(phy.inputs, contains(phyIn), reason: '$n has no PHY input');
        expect(phy.input(phyIn).width, c.output(n).width, reason: phyIn);
      }
      final ctrlIn = c.inputs.keys.where((n) => n.startsWith('i_phy_'));
      expect(ctrlIn, hasLength(5));
      for (final n in ctrlIn) {
        final phyOut = n.replaceFirst('i_phy_', 'o_controller_');
        expect(phy.outputs, contains(phyOut), reason: '$n has no PHY output');
        expect(phy.output(phyOut).width, c.input(n).width, reason: phyOut);
      }
      expect(phy.selfTrainsRead, isTrue);
      expect(
        phy.readLevelDone,
        same(phy.output('o_controller_read_level_done')),
      );

      // Pads follow the MT41K64M16 x16 geometry.
      expect(phy.oDdr3Addr.width, 13);
      expect(phy.oDdr3BaAddr.width, 3);
      expect(phy.oDdr3Dm.width, 2);
      expect(phy.ioDdr3Dq.width, 16);
      expect(phy.ioDdr3Dqs.width, 2);
      expect(phy.ioDdr3DqsN.width, 2);
      for (final pad in [
        phy.oDdr3ClkP,
        phy.oDdr3ClkN,
        phy.oDdr3Cke,
        phy.oDdr3CsN,
        phy.oDdr3RasN,
        phy.oDdr3CasN,
        phy.oDdr3WeN,
        phy.oDdr3Odt,
        phy.oDdr3ResetN,
      ]) {
        expect(pad.width, 1);
      }
    });

    test(
      '$mode: the ECP5 x2 primitives are emitted, and no Xilinx ones',
      () async {
        final p = DdrParams.orangeCrab();
        final c = _controller(p, runtimeTrainable: runtime);
        final phy = _phy(p, c, runtime: runtime);
        await phy.build();
        final sv = phy.generateSynth();
        const cmdPads = 4 + 3 + 3 + 13;
        expect(_count(sv, 'DQSBUFM'), greaterThanOrEqualTo(2));
        expect(sv, contains('DDRDLLA'));
        expect(sv, contains('ECLKSYNCB'));
        expect(sv, contains('CLKDIVF'));
        final top = _moduleBody(sv, 'Ddr3PhyEcp5');
        expect(_count(top, 'DQSBUFM'), 2);
        expect(_count(top, 'IDDRX2DQA'), 16);
        expect(_count(top, 'ODDRX2DQA'), 16 + 2); // DQ + DM
        expect(_count(top, 'ODDRX2DQSB'), 2);
        expect(_count(top, 'TSHX2DQA'), 16);
        expect(_count(top, 'TSHX2DQSA'), 2);
        expect(_count(top, 'ODDRX2F'), cmdPads + 2); // + CK and CK#
        expect(_count(top, 'BB'), 16 + 2);
        expect(_count(top, 'DELAYF'), runtime ? 16 : 0);
        expect(_count(top, 'DELAYG'), cmdPads + 2 + (runtime ? 0 : 16));
        for (final x in ['OSERDESE2', 'ISERDESE2', 'IDELAYE2', 'IDELAYCTRL']) {
          expect(sv, isNot(contains(x)), reason: '$x leaked into the ECP5 PHY');
        }

        // Every input is used, except the documented no-ECP5-meaning ones.
        final unused = {
          for (final n in phy.inputs.keys)
            if (RegExp('\\b$n\\b').allMatches(top).length < 2) n,
        };
        expect(unused, {
          ..._unusedInputs,
          // train=hw levels in hardware: the knob ports have no load.
          if (!runtime) ...{
            'i_controller_bitslip',
            'i_controller_idelay_data_cntvaluein',
            'i_controller_idelay_data_ld',
          },
          // train=runtime: firmware levels, so the sweep handshake is unused.
          if (runtime) ...{
            'i_controller_read_level_start',
            'i_controller_read_level_check',
            'i_controller_read_level_pass',
          },
        });
      },
    );
  }

  test('the ECP5 PHY rejects a geared (CK/8) controller', () {
    final p = DdrParams.orangeCrab(controllerGearRatio: 2);
    final c = _controller(DdrParams.orangeCrab(), runtimeTrainable: false);
    expect(() => _phy(p, c), throwsArgumentError);
  });
}

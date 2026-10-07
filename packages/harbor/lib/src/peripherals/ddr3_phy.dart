import 'dart:math' as math;

import 'package:rohd/rohd.dart';

import '../blackbox/xilinx/xilinx.dart';
import 'ddr3_params.dart';
import 'ddr3_phy_base.dart';

/// Xilinx 7-series DDR3 PHY, a faithful ROHD translation of UberDDR3's
/// `ddr3_phy.v`. Family-generic (Artix/Kintex/Spartan/Zynq-7); the only
/// bank-specific choice is [DdrParams.odelaySupported] (HP-bank ODELAYE2 write
/// deskew vs HR-bank CK@90 launch).
///
/// The PHY is the structural layer: per-DQ IOBUF -> IDELAYE2 -> ISERDESE2 (read)
/// and OSERDESE2 -> IOBUF (write), the DQS strobe path, the command/address
/// SERDES, one IDELAYCTRL, and the CK OBUFDS. All read/write *timing* is found at
/// run time by the calibration engine in `Ddr3Controller` (which drives the
/// per-bit IDELAY loads and bitslip through the `i_controller_*` ports and reads
/// the deserialized data/DQS back through the `o_controller_iserdes_*` ports).
///
/// This is a translation-in-progress: the module contract, reset sequencing,
/// IDELAYCTRL and CK are in place; the DQ/DQS/command datapaths are being ported
/// datapath-by-datapath and verified against `ddr3_phy.v`.
class Ddr3Phy extends Ddr3PhyBase {
  final DdrParams params;

  int get lanes => params.lanes;
  int get dqBits => params.dqBits;
  int get dq => dqBits * lanes; // total DQ pins
  int get serdes => params.serdesRatio;

  /// IDELAYCTRL RDY (gated with DCI lock). The calibration engine waits on this
  /// before touching the delay taps.
  @override
  Logic get idelayctrlRdy => output('o_controller_idelayctrl_rdy');

  /// Deserialized read data (DQ_BITS*LANES*8 = one BL8 gather).
  @override
  Logic get iserdesData => output('o_controller_iserdes_data');

  /// Deserialized DQS strobe (LANES*8) - the phase reference the DQS-analyze
  /// calibration step reads to find where the read burst begins.
  @override
  Logic get iserdesDqs => output('o_controller_iserdes_dqs');

  /// Fabric model of the ISERDES bitslip barrel-shift (LANES*8).
  @override
  Logic get iserdesBitslipReference =>
      output('o_controller_iserdes_bitslip_reference');

  @override
  Logic get oDdr3ClkP => output('o_ddr3_clk_p');
  @override
  Logic get oDdr3ClkN => output('o_ddr3_clk_n');
  @override
  Logic get oDdr3Cke => output('o_ddr3_cke');
  @override
  Logic get oDdr3CsN => output('o_ddr3_cs_n');
  @override
  Logic get oDdr3RasN => output('o_ddr3_ras_n');
  @override
  Logic get oDdr3CasN => output('o_ddr3_cas_n');
  @override
  Logic get oDdr3WeN => output('o_ddr3_we_n');
  @override
  Logic get oDdr3Odt => output('o_ddr3_odt');
  @override
  Logic get oDdr3ResetN => output('o_ddr3_reset_n');
  @override
  Logic get oDdr3BaAddr => output('o_ddr3_ba_addr');
  @override
  Logic get oDdr3Addr => output('o_ddr3_addr');
  @override
  Logic get oDdr3Dm => output('o_ddr3_dm');
  @override
  Logic get ioDdr3Dq => inOut('io_ddr3_dq');
  @override
  Logic get ioDdr3Dqs => inOut('io_ddr3_dqs');
  @override
  Logic get ioDdr3DqsN => inOut('io_ddr3_dqs_n');

  Ddr3Phy(
    this.params, {
    required Logic controllerClk,
    required Logic ddr3Clk,
    required Logic refClk,
    required Logic ddr3Clk90,
    required Logic rstN,
    // Controller -> PHY control/write channel.
    required Logic controllerReset,
    required Logic cmd, // i_controller_cmd [cmd_len*serdes-1:0]
    required Logic dqsTriControl,
    required Logic dqTriControl,
    required Logic toggleDqs,
    required Logic data, // write data [wb_data_bits-1:0]
    required Logic dm, // data mask [wb_sel_bits-1:0]
    required Logic odelayDataCntValueIn, // [4:0]
    required Logic odelayDqsCntValueIn, // [4:0]
    required Logic idelayDataCntValueIn, // [4:0]
    required Logic idelayDqsCntValueIn, // [4:0]
    required Logic odelayDataLd, // [LANES-1:0]
    required Logic odelayDqsLd,
    required Logic idelayDataLd,
    required Logic idelayDqsLd,
    required Logic bitslip, // [LANES-1:0]
    required Logic writeLevelingCalib,
    // DDR3 DQ data pads (bidirectional, [dq] wide). The write OSERDESE2 owns each
    // pad IOBUF, so its in-site tristate (TQ) reaches the pad T pin directly and
    // the read datapath sources DQ from the same IOBUF's O output.
    required LogicNet dqPad,
    // DDR3 DQS strobe pads (differential, [lanes] wide each). P on [dqsPad], N on
    // [dqsNPad].
    required LogicNet dqsPad,
    required LogicNet dqsNPad,
    super.name = 'ddr3_phy',
  }) {
    // --- clocks/reset ---
    controllerClk = addInput('i_controller_clk', controllerClk);
    ddr3Clk = addInput('i_ddr3_clk', ddr3Clk);
    refClk = addInput('i_ref_clk', refClk);
    ddr3Clk90 = addInput('i_ddr3_clk_90', ddr3Clk90);
    rstN = addInput('i_rst_n', rstN);
    controllerReset = addInput('i_controller_reset', controllerReset);

    // --- controller control/write inputs ---
    final cmdLen = _cmdLen();
    cmd = addInput('i_controller_cmd', cmd, width: cmdLen * serdes);
    dqsTriControl = addInput('i_controller_dqs_tri_control', dqsTriControl);
    dqTriControl = addInput('i_controller_dq_tri_control', dqTriControl);
    toggleDqs = addInput('i_controller_toggle_dqs', toggleDqs);
    data = addInput('i_controller_data', data, width: params.wbDataBits);
    dm = addInput('i_controller_dm', dm, width: params.wbSelBits);
    odelayDataCntValueIn = addInput(
      'i_controller_odelay_data_cntvaluein',
      odelayDataCntValueIn,
      width: 5,
    );
    odelayDqsCntValueIn = addInput(
      'i_controller_odelay_dqs_cntvaluein',
      odelayDqsCntValueIn,
      width: 5,
    );
    idelayDataCntValueIn = addInput(
      'i_controller_idelay_data_cntvaluein',
      idelayDataCntValueIn,
      width: 5,
    );
    idelayDqsCntValueIn = addInput(
      'i_controller_idelay_dqs_cntvaluein',
      idelayDqsCntValueIn,
      width: 5,
    );
    odelayDataLd = addInput(
      'i_controller_odelay_data_ld',
      odelayDataLd,
      width: lanes,
    );
    odelayDqsLd = addInput(
      'i_controller_odelay_dqs_ld',
      odelayDqsLd,
      width: lanes,
    );
    idelayDataLd = addInput(
      'i_controller_idelay_data_ld',
      idelayDataLd,
      width: lanes,
    );
    idelayDqsLd = addInput(
      'i_controller_idelay_dqs_ld',
      idelayDqsLd,
      width: lanes,
    );
    bitslip = addInput('i_controller_bitslip', bitslip, width: lanes);
    writeLevelingCalib = addInput(
      'i_controller_write_leveling_calib',
      writeLevelingCalib,
    );
    final dqPadIo = addInOut('io_ddr3_dq', dqPad, width: dq);
    final dqsPadIo = addInOut('io_ddr3_dqs', dqsPad, width: lanes);
    final dqsNPadIo = addInOut('io_ddr3_dqs_n', dqsNPad, width: lanes);

    // --- read-return / status outputs ---
    addOutput('o_controller_iserdes_data', width: dq * 8);
    addOutput('o_controller_iserdes_dqs', width: lanes * 8);
    addOutput('o_controller_iserdes_bitslip_reference', width: lanes * 8);
    addOutput('o_controller_idelayctrl_rdy');

    // --- reset sequencing (>= 52 ns for IDELAYCTRL) ---
    // SYNC_RESET_DELAY = ceil(1000 ns / controller period). Held high that many
    // controller cycles after reset, then released. Faithful to ddr3_phy.v:70.
    final syncResetDelay = (1e6 / params.controllerClkPeriodPs)
        .ceil(); // 1000ns / periodNs
    final cntW = math.max(1, syncResetDelay.bitLength);
    final syncRst = Logic(name: 'sync_rst');
    final delayCnt = Logic(name: 'delay_before_release_reset', width: cntW);
    final rst = ~rstN | controllerReset;
    Sequential(controllerClk, [
      If(
        rst,
        then: [
          syncRst < Const(1),
          delayCnt < Const(syncResetDelay, width: cntW),
        ],
        orElse: [
          delayCnt < mux(delayCnt.eq(0), Const(0, width: cntW), delayCnt - 1),
          syncRst < ~delayCnt.eq(0),
        ],
      ),
    ]);

    // --- IDELAYCTRL (one per bank using IDELAYE2; REFCLK ~200 MHz) ---
    final idelayctrlRdyW = XilinxIdelayctrl(refclk: refClk, rst: syncRst).rdy;
    // DCI is not used on the HR bank; tie locked high (ddr3_phy.v:dci_locked=1).
    output('o_controller_idelayctrl_rdy') <= idelayctrlRdyW & Const(1);

    // --- CK / CK# differential output via OBUFDS off a CK-rate ODDR ---
    // CK is driven INVERTED (= !i_ddr3_clk), matching the ODELAY-less reference
    // (ddr3_phy.v OBUFDS .I(!i_ddr3_clk)). With write leveling skipped on the HR
    // bank, the DQS strobe (which rides !CK) must land edge-aligned to CK for
    // tDQSS; a non-inverted CK puts DQS 180 deg off and writes fail while
    // (self-training) reads still pass. d1=0/d2=1 makes Q follow !C.
    final ckOddr = XilinxOddr(
      c: ddr3Clk,
      d1: Const(0),
      d2: Const(1),
      r: syncRst,
      name: 'ck_oddr',
    );
    final ckDiff = XilinxObufds(i: ckOddr.q, name: 'ck_obufds');
    addOutput('o_ddr3_clk_p') <= ckDiff.o;
    addOutput('o_ddr3_clk_n') <= ckDiff.ob;

    // --- (a) command/address SERDES ---
    // Each of the cmd_len command bits is 4:1 SDR-serialized (D1..D4 = the four
    // command slots) at the CK rate, then oserdes_cmd is unpacked to the pads.
    // Faithful to ddr3_phy.v:138-197.
    final oserdesCmd = <Logic>[];
    for (var i = 0; i < cmdLen; i++) {
      final os = XilinxOserdese2(
        clk: ddr3Clk,
        clkdiv: controllerClk,
        d: [
          cmd[cmdLen * 0 + i],
          cmd[cmdLen * 1 + i],
          cmd[cmdLen * 2 + i],
          cmd[cmdLen * 3 + i],
        ],
        rst: syncRst,
        dataRateOq: 'SDR',
        dataWidth: 4,
        hasTristate: false,
        name: 'cmd_oserdes_$i',
      );
      oserdesCmd.add(os.oq);
    }
    // bit i of the word = oserdesCmd[i] (element 0 = LSB).
    final oserdesCmdW = oserdesCmd.rswizzle().named('oserdes_cmd');

    // CMD field layout (ddr3_phy.v:61-67): top 7 control bits, then BA, then ADDR.
    final cmdCsN = cmdLen - 1;
    final cmdRasN = cmdLen - 2;
    final cmdCasN = cmdLen - 3;
    final cmdWeN = cmdLen - 4;
    final cmdOdt = cmdLen - 5;
    final cmdCke = cmdLen - 6;
    final cmdResetN = cmdLen - 7;
    // ba = [rowBits+baBits-1 : rowBits], addr = [rowBits-1 : 0].
    addOutput('o_ddr3_cs_n') <= oserdesCmdW[cmdCsN];
    addOutput('o_ddr3_ras_n') <= oserdesCmdW[cmdRasN];
    addOutput('o_ddr3_cas_n') <= oserdesCmdW[cmdCasN];
    addOutput('o_ddr3_we_n') <= oserdesCmdW[cmdWeN];
    addOutput('o_ddr3_odt') <= oserdesCmdW[cmdOdt];
    addOutput('o_ddr3_cke') <= oserdesCmdW[cmdCke];
    addOutput('o_ddr3_reset_n') <= oserdesCmdW[cmdResetN];
    addOutput('o_ddr3_ba_addr', width: params.baBits) <=
        oserdesCmdW.getRange(params.rowBits, params.rowBits + params.baBits);
    addOutput('o_ddr3_addr', width: params.rowBits) <=
        oserdesCmdW.getRange(0, params.rowBits);

    // --- (b) DQ write + (c) DQ read, one datapath per DQ pin ---
    // Faithful to ddr3_phy.v:297-576 (the ODELAY_SUPPORTED=0 / HR-bank branch).
    // Write:  8:1 DDR OSERDESE2 (D1..D8 = the BL8 gather from i_controller_data,
    //         launched on CK@90 so DQ leads the CK-aligned DQS by 90 deg) -> pad
    //         IOBUF (in-site tristate TQ -> IOBUF.T).
    // Read:   pad IOBUF.O -> IDELAYE2 (VAR_LOAD, per-bit tap) -> ISERDESE2
    //         (DATA_WIDTH=8 DDR, IOBDELAY=IFD, free-running CK capture, bitslip).
    // odelaySupported adds an ODELAYE2 between the write OSERDESE2 and the IOBUF;
    // the Arty S7 HR bank does not have it (params.odelaySupported == false).
    final iserdesData = List<Logic?>.filled(dq * 8, null);
    for (var gi = 0; gi < dq; gi++) {
      final lane = gi ~/ params.dqBits;
      // WRITE: OSERDESE2 D1..D8 = i_controller_data[gi + dq*0 .. gi + dq*7].
      final os = XilinxOserdese2(
        clk: params.odelaySupported ? ddr3Clk : ddr3Clk90,
        clkdiv: controllerClk,
        d: [for (var b = 0; b < 8; b++) data[gi + dq * b]],
        t1: dqTriControl,
        rst: syncRst,
        name: 'dq_oserdes_$gi',
      );
      // Optional HP-bank output deskew.
      final writeData = params.odelaySupported
          ? XilinxOdelaye2(
              odatain: os.oq,
              c: controllerClk,
              odelayType: 'VAR_LOAD',
              cntValueIn: odelayDataCntValueIn,
              ld: odelayDataLd[lane],
              name: 'dq_odelay_$gi',
            ).dataout
          : os.oq;
      // Pad IOBUF (the write OSERDESE2 owns it; O is the read return).
      final iob = XilinxIobuf(
        i: writeData,
        t: os.tq,
        io: dqPadIo[gi],
        name: 'dq_iobuf_$gi',
      );
      // READ: IOBUF.O -> IDELAYE2 (per-bit VAR_LOAD tap) -> ISERDESE2.
      final idel = XilinxIdelaye2(
        idatain: iob.o,
        c: controllerClk,
        idelayType: 'VAR_LOAD',
        cntValueIn: idelayDataCntValueIn,
        ld: idelayDataLd[lane],
        name: 'dq_idelay_$gi',
      );
      final iser = XilinxIserdese2(
        clk: ddr3Clk, // free-running CK capture (NOT DQS-clocked)
        clkb: ddr3Clk, // CLKB inverted on-chip (IS_CLKB_INVERTED)
        clkdiv: controllerClk,
        ddly: idel.dataout,
        bitslip: bitslip[lane],
        rst: syncRst,
        dataWidth: 8,
        name: 'dq_iserdes_$gi',
      );
      // Q1..Q8 map to the BL8 gather MSB..LSB: Qn -> data[dq*(8-n) + gi].
      for (var n = 1; n <= 8; n++) {
        iserdesData[dq * (8 - n) + gi] = iser.output('Q$n');
      }
    }
    output('o_controller_iserdes_data') <=
        [for (final b in iserdesData) b!].rswizzle();

    // --- DM (data-mask) write, one OSERDESE2 per lane, no tristate -> OBUF ---
    // Faithful to ddr3_phy.v:672-731 (HR-bank branch). DM rides CK@90 like DQ.
    final dmOut = <Logic>[];
    for (var l = 0; l < lanes; l++) {
      final os = XilinxOserdese2(
        clk: params.odelaySupported ? ddr3Clk : ddr3Clk90,
        clkdiv: controllerClk,
        d: [for (var b = 0; b < 8; b++) dm[l + lanes * b]],
        rst: syncRst,
        hasTristate: false,
        name: 'dm_oserdes_$l',
      );
      dmOut.add(XilinxObuf(i: os.oq, name: 'dm_obuf_$l').o);
    }
    addOutput('o_ddr3_dm', width: lanes) <= dmOut.rswizzle();

    // --- toggle_dqs_q: registered i_controller_toggle_dqs (ddr3_phy.v:107,127) ---
    final toggleDqsQ = Logic(name: 'toggle_dqs_q');
    Sequential(controllerClk, [
      If(
        syncRst,
        then: [toggleDqsQ < Const(0)],
        orElse: [toggleDqsQ < toggleDqs],
      ),
    ]);
    // The DQS burst spans a beat past the toggle (last half-series on toggle_dqs_q).
    final toggleOr = toggleDqs | toggleDqsQ;
    final notWl = ~writeLevelingCalib;

    // --- (d) DQS strobe: OSERDESE2 -> IOBUFDS write + read IDELAY/ISERDES ---
    // Faithful to ddr3_phy.v:856-1015 (HR-bank branch). The DQS OSERDESE2 rides
    // !CK (clkInverted) so the strobe is CK-aligned for tDQSS while DQ leads it by
    // 90 deg. The write-leveling calib squelches the trailing DQS edges (D3/D5/D7).
    final iserdesDqs = List<Logic?>.filled(lanes * 8, null);
    for (var l = 0; l < lanes; l++) {
      final os = XilinxOserdese2(
        clk: ddr3Clk,
        clkInverted: true, // CLK = !CK, on the same CK net (in-site inversion)
        clkdiv: controllerClk,
        d: [
          toggleOr, // D1
          Const(0), // D2
          toggleOr & notWl, // D3
          Const(0), // D4
          toggleDqs & notWl, // D5
          Const(0), // D6
          toggleDqs & notWl, // D7
          Const(0), // D8
        ],
        t1: dqsTriControl,
        rst: syncRst,
        initOq: "1'b1",
        name: 'dqs_oserdes_$l',
      );
      final iob = XilinxIobufds(
        i: os.oq,
        t: os.tq,
        io: dqsPadIo[l],
        iob: dqsNPadIo[l],
        name: 'dqs_iobufds_$l',
      );
      final idel = XilinxIdelaye2(
        idatain: iob.o,
        c: controllerClk,
        idelayType: 'VAR_LOAD',
        cntValueIn: idelayDqsCntValueIn,
        ld: idelayDqsLd[l],
        signalPattern: 'CLOCK', // a strobe, not data
        name: 'dqs_idelay_$l',
      );
      final iser = XilinxIserdese2(
        clk: ddr3Clk,
        clkb: ddr3Clk,
        clkdiv: controllerClk,
        ddly: idel.dataout,
        bitslip: bitslip[l],
        rst: syncRst,
        dataWidth: 8,
        name: 'dqs_iserdes_$l',
      );
      for (var n = 1; n <= 8; n++) {
        iserdesDqs[8 * l + (8 - n)] = iser.output('Q$n');
      }
    }
    output('o_controller_iserdes_dqs') <=
        [for (final b in iserdesDqs) b!].rswizzle();

    // --- (e) bitslip-reference: OSERDESE2_train -> ISERDESE2_train (OFB loopback) ---
    // A pad-less fabric model of the ISERDES barrel-shift the calibration engine
    // reads to frame the read burst: a fixed 0000_1111 pattern serialized then
    // captured through the OLOGIC->ILOGIC OFB feedback, so BITSLIP walks the same
    // rotation the real read ISERDES sees. Faithful to ddr3_phy.v:1018-1135.
    final bitslipRef = List<Logic?>.filled(lanes * 8, null);
    for (var l = 0; l < lanes; l++) {
      final osTrain = XilinxOserdese2(
        clk: ddr3Clk,
        clkdiv: controllerClk,
        d: [
          Const(0), Const(0), Const(0), Const(0), //
          Const(1), Const(1), Const(1), Const(1),
        ],
        rst: syncRst,
        hasTristate: false,
        initOq: "1'b1",
        name: 'train_oserdes_$l',
      );
      final iserTrain = XilinxIserdese2(
        clk: ddr3Clk,
        clkb: ddr3Clk,
        clkdiv: controllerClk,
        ddly: null, // IOBDELAY=NONE: data arrives via OFB; DDLY must stay open
        bitslip: bitslip[l],
        rst: syncRst,
        dataWidth: 8,
        iobDelay: 'NONE',
        ofbUsed: true,
        ofb: osTrain.output('OFB'),
        name: 'train_iserdes_$l',
      );
      for (var n = 1; n <= 8; n++) {
        bitslipRef[8 * l + (8 - n)] = iserTrain.output('Q$n');
      }
    }
    output('o_controller_iserdes_bitslip_reference') <=
        [for (final b in bitslipRef) b!].rswizzle();
  }

  /// UberDDR3 command length = 4 (cs/ras/cas/we-ish) + 3 (odt/cke/reset) + BA +
  /// ROW + 2*DUAL_RANK. Matches ddr3_top.v localparam `cmd_len`.
  int _cmdLen() =>
      4 + 3 + params.baBits + params.rowBits + (params.dualRankDimm ? 2 : 0);
}

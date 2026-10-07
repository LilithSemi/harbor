import 'dart:math' as math;

import 'package:rohd/rohd.dart';

import 'ddr3_mode_registers.dart';
import 'ddr3_params.dart';
import 'ddr3_timing.dart';

/// DDR3 memory controller, a faithful ROHD translation of UberDDR3's
/// `ddr3_controller.v`. It pairs with [Ddr3Phy]: the controller drives the DRAM
/// command/address stream and the write datapath, runs the power-up reset
/// sequence and the read/write calibration engine, and presents a pipelined
/// wishbone bus to the SoC.
///
/// This is a translation-in-progress. The parameter/timing layer ([DdrTiming]),
/// the Mode-Register values and the reset/refresh ROM ([Ddr3ModeRegisters]) are
/// complete and separately tested. The stateful Module is being ported one
/// always-block at a time, each verified in simulation:
///   1. reset-sequence engine (this file, done) - walks the ROM, sequences
///      RESET#/CKE/MRS/ZQC and the refresh loop.
///   2. command-issue + bank-status pipeline (TODO).
///   3. the 24-state calibration FSM (TODO).
///   4. the pipelined main wishbone + wb2 register file (TODO).
class Ddr3Controller extends Module {
  final DdrParams params;
  final DdrTiming timing;
  final Ddr3ModeRegisters modeRegs;

  /// When true, the PHY calibration knobs are exposed through the wb2 register
  /// window so an external CPU/FSBL drives training at runtime (train=runtime).
  /// Defaults false, which keeps the internal calibration FSM in sole control
  /// and the RTL byte-identical to the silicon-proven train=hw boot path.
  final bool runtimeTrainable;

  /// The PHY levels its own read path ([Ddr3PhyBase.selfTrainsRead]). The
  /// calibration FSM then skips the sampled-DQS states, writes its test
  /// pattern, and reads it back once per PHY leveling point until the PHY
  /// reports done. Defaults false, which leaves the RTL unchanged.
  final bool phySelfTrainsRead;

  /// Controller ticks the PHY adds to the read return. They are added to the
  /// read capture pipe. Used only with [phySelfTrainsRead].
  final int phyReadPipeTicks;

  /// Calibration runs before a self-trained calibration gives up and reports
  /// [calFailed]. 1 to 8. Used only with [phySelfTrainsRead].
  final int maxCalAttempts;

  // --- runtime-trainable knob registers (built only when runtimeTrainable) ---
  List<Logic>? _rtOdelay; // per-lane 5-bit write odelay tap
  List<Logic>? _rtIdelay; // per-lane 5-bit read idelay tap
  List<Logic>? _rtBitslip; // per-lane 1-bit ISERDES bitslip level
  List<Logic>? _rtWlevel; // per-lane 1-bit write-leveling override
  List<Logic>? _rtOdelayLd; // per-lane write-odelay load pulse (on APPLY)
  List<Logic>? _rtIdelayLd; // per-lane read-idelay load pulse (on APPLY)
  Logic? _rtLaneSel; // active lane selector (from CTL[11:8])
  Logic? _rtActive; // override armed: set on the first CTL APPLY
  List<Logic>? _rtClkSel; // per-lane 3-bit read clock select (self-train PHY)
  List<Logic>? _rtBitslipStep; // per-lane bitslip step pulse, one per APPLY

  /// Runtime knob registers, exposed for simulation tests (null in train=hw).
  List<Logic>? get rtOdelayRegs => _rtOdelay;
  List<Logic>? get rtIdelayRegs => _rtIdelay;
  List<Logic>? get rtBitslipRegs => _rtBitslip;
  List<Logic>? get rtWlevelRegs => _rtWlevel;

  /// Calibration read-pipe depth, exposed for simulation tests: the lane
  /// max and each lane's own value.
  Logic get addedReadPipeMaxReg => _addedReadPipeMax;
  List<Logic> get addedReadPipeLaneRegs => _addedReadPipeLane;

  static const int auxWidth = 4;
  static const int wb2AddrBits = 7;
  static const int wb2DataBits = 32;
  static const int wb2SelBits = wb2DataBits ~/ 8;

  int get lanes => params.lanes;
  int get dq => params.dqBits * lanes;
  int get serdes => params.serdesRatio;
  int get cmdLen => 4 + 3 + params.baBits + params.rowBits;

  /// Reset-sequence progress (for observation / bring-up LEDs). Debug word 2
  /// carries the ROM address in [4:0] and reset_done in bit 8.
  Logic get debug2 => output('o_debug2');

  /// o_phy_reset: the synchronous controller reset handed to the PHY.
  Logic get phyReset => output('o_phy_reset');

  /// o_phy_cmd: the serialized command/address stream to the PHY.
  Logic get phyCmd => output('o_phy_cmd');

  Ddr3Controller(
    this.params, {
    required Logic controllerClk,
    required Logic rstN,
    // Main wishbone (SoC-facing, controller-clock domain).
    required Logic wbCyc,
    required Logic wbStb,
    required Logic wbWe,
    required Logic wbAddr,
    required Logic wbData,
    required Logic wbSel,
    required Logic aux,
    // Secondary wishbone (register / debug access).
    required Logic wb2Cyc,
    required Logic wb2Stb,
    required Logic wb2We,
    required Logic wb2Addr,
    required Logic wb2Sel,
    required Logic wb2Data,
    // PHY read-return / status inputs.
    required Logic phyIserdesData,
    required Logic phyIserdesDqs,
    required Logic phyIserdesBitslipReference,
    required Logic phyIdelayctrlRdy,
    Logic? phyReadLevelDone,
    this.runtimeTrainable = false,
    this.phySelfTrainsRead = false,
    this.phyReadPipeTicks = 0,
    this.maxCalAttempts = defaultMaxCalAttempts,
    super.name = 'ddr3_controller',
  }) : timing = DdrTiming.fromPs(
         ddr3ClkPeriodPs: params.ddr3ClkPeriodPs,
         serdesRatio: params.serdesRatio,
         controllerClkRatio: params.controllerClkRatio,
         density: params.density,
       ),
       modeRegs = Ddr3ModeRegisters(
         DdrTiming.fromPs(
           ddr3ClkPeriodPs: params.ddr3ClkPeriodPs,
           serdesRatio: params.serdesRatio,
           controllerClkRatio: params.controllerClkRatio,
           density: params.density,
         ),
       ) {
    // --- clocks/reset ---
    controllerClk = addInput('i_controller_clk', controllerClk);
    rstN = addInput('i_rst_n', rstN);

    // --- main wishbone ---
    wbCyc = addInput('i_wb_cyc', wbCyc);
    wbStb = addInput('i_wb_stb', wbStb);
    wbWe = addInput('i_wb_we', wbWe);
    wbAddr = addInput('i_wb_addr', wbAddr, width: params.wbAddrBits);
    wbData = addInput('i_wb_data', wbData, width: params.wbDataBits);
    wbSel = addInput('i_wb_sel', wbSel, width: params.wbSelBits);
    aux = addInput('i_aux', aux, width: auxWidth);
    addOutput('o_wb_stall');
    addOutput('o_wb_ack');
    addOutput('o_wb_data', width: params.wbDataBits);
    addOutput('o_aux', width: auxWidth);

    // --- secondary wishbone ---
    wb2Cyc = addInput('i_wb2_cyc', wb2Cyc);
    wb2Stb = addInput('i_wb2_stb', wb2Stb);
    wb2We = addInput('i_wb2_we', wb2We);
    wb2Addr = addInput('i_wb2_addr', wb2Addr, width: wb2AddrBits);
    wb2Sel = addInput('i_wb2_sel', wb2Sel, width: wb2SelBits);
    wb2Data = addInput('i_wb2_data', wb2Data, width: wb2DataBits);
    addOutput('o_wb2_stall');
    addOutput('o_wb2_ack');
    addOutput('o_wb2_data', width: wb2DataBits);

    // --- PHY interface ---
    phyIserdesData = addInput(
      'i_phy_iserdes_data',
      phyIserdesData,
      width: dq * 8,
    );
    phyIserdesDqs = addInput(
      'i_phy_iserdes_dqs',
      phyIserdesDqs,
      width: lanes * 8,
    );
    phyIserdesBitslipReference = addInput(
      'i_phy_iserdes_bitslip_reference',
      phyIserdesBitslipReference,
      width: lanes * 8,
    );
    phyIdelayctrlRdy = addInput('i_phy_idelayctrl_rdy', phyIdelayctrlRdy);
    addOutput('o_phy_cmd', width: cmdLen * serdes);
    addOutput('o_phy_dqs_tri_control');
    addOutput('o_phy_dq_tri_control');
    addOutput('o_phy_toggle_dqs');
    addOutput('o_phy_data', width: params.wbDataBits);
    addOutput('o_phy_dm', width: params.wbSelBits);
    addOutput('o_phy_odelay_data_cntvaluein', width: 5);
    addOutput('o_phy_odelay_dqs_cntvaluein', width: 5);
    addOutput('o_phy_idelay_data_cntvaluein', width: 5);
    addOutput('o_phy_idelay_dqs_cntvaluein', width: 5);
    addOutput('o_phy_odelay_data_ld', width: lanes);
    addOutput('o_phy_odelay_dqs_ld', width: lanes);
    addOutput('o_phy_idelay_data_ld', width: lanes);
    addOutput('o_phy_idelay_dqs_ld', width: lanes);
    addOutput('o_phy_bitslip', width: lanes);
    addOutput('o_phy_write_leveling_calib');
    addOutput('o_phy_reset');
    Logic? readLevelDone;
    if (phySelfTrainsRead) {
      if (phyReadLevelDone == null) {
        throw ArgumentError.notNull('phyReadLevelDone');
      }
      if (maxCalAttempts < 1 || maxCalAttempts > 8) {
        throw ArgumentError.value(maxCalAttempts, 'maxCalAttempts');
      }
      if (phyReadPipeTicks < 0 || phyReadPipeTicks > 15) {
        throw ArgumentError.value(phyReadPipeTicks, 'phyReadPipeTicks');
      }
      readLevelDone = addInput('i_phy_read_level_done', phyReadLevelDone);
      addOutput('o_phy_read_level_start');
      addOutput('o_phy_read_level_check');
      addOutput('o_phy_read_level_pass', width: lanes);
      if (runtimeTrainable) addOutput('o_phy_read_clk_sel', width: 3 * lanes);
      addOutput('o_cal_failed');
    }

    // --- debug ---
    addOutput('o_debug1', width: 32);
    addOutput('o_debug2', width: 32);
    addOutput('o_debug3', width: 32);

    _pauseCounter = Logic(name: 'pause_counter');
    _issueReadCommand = Logic(name: 'issue_read_command');
    _resetFromCalibrate = Logic(name: 'reset_from_calibrate');
    _writeCalibDqs = Logic(name: 'write_calib_dqs_o');
    _writeCalibDq = Logic(name: 'write_calib_dq_o');
    _calibStb = Logic(name: 'calib_stb_o');
    _calibWe = Logic(name: 'calib_we_o');
    _calibAux = Logic(name: 'calib_aux_o', width: auxWidth);
    _calibSel = Logic(name: 'calib_sel_o', width: params.wbSelBits);
    _calibAddr = Logic(name: 'calib_addr_o', width: params.wbAddrBits);
    _calibData = Logic(name: 'calib_data_o', width: params.wbDataBits);
    _oWbStallCalib = Logic(name: 'o_wb_stall_calib_o');
    _stateCalibrate = Logic(name: 'state_calibrate_o', width: 6);
    _writeDqsSched = Logic(name: 'write_dqs_sched_o');
    _oWbAckRead = Logic(name: 'o_wb_ack_read_o', width: auxWidth + 1);
    _oWbData = Logic(name: 'o_wb_data_o', width: params.wbDataBits);
    _addedReadPipeMax = Logic(name: 'added_read_pipe_max_o', width: 4);
    _addedReadPipeLane = [
      for (var l = 0; l < params.lanes; l++)
        Logic(name: 'added_read_pipe_lane_o_$l', width: 4),
    ];

    _buildResetSequence(controllerClk, rstN);
    if (runtimeTrainable) _buildWb2Knobs(controllerClk, rstN);
    _buildCalibration(
      controllerClk,
      phyIdelayctrlRdy,
      phyIserdesDqs,
      phyIserdesBitslipReference,
      readLevelDone,
    );
    _buildWriteStrobeDatapath(controllerClk);
    _buildWishbonePipeline(
      controllerClk,
      phyIserdesData,
      wbCyc,
      wbStb,
      wbWe,
      wbAddr,
      wbData,
      wbSel,
      aux,
    );
    _tieOffUnbuilt();
  }

  /// Write DQS/DQ strobe + tristate datapath (ddr3_controller.v:1180-1270). The
  /// write strobe request [_writeCalibDqs]/[_writeCalibDq] (from the calibration
  /// FSM today; the wishbone scheduler's stage2 write will OR in later) is held
  /// for three controller cycles and pushed through the CWL launch shift register
  /// so the DQS/DQ tristate opens (and the DQS toggle asserts) at the right beat.
  void _buildWriteStrobeDatapath(Logic clk) {
    final depth = _stage2DataDepth; // 2
    final writeDqsD = _writeCalibDqs | _writeDqsSched; // cal WL or stage2 write
    final writeDqD = _writeCalibDq | _writeDqsSched;

    Logic bit(String n) => Logic(name: n);
    final writeDqsQ = [bit('write_dqs_q0'), bit('write_dqs_q1')];
    final writeDqQ = [bit('write_dq_q0'), bit('write_dq_q1')];
    // write_dqs / write_dqs_val: depth+1 bits; write_dq: depth+2 bits.
    final writeDqs = [for (var i = 0; i <= depth; i++) bit('write_dqs_$i')];
    final writeDqsVal = [
      for (var i = 0; i <= depth; i++) bit('write_dqs_val_$i'),
    ];
    final writeDq = [for (var i = 0; i <= depth + 1; i++) bit('write_dq_$i')];

    final held3Dqs = writeDqsD | writeDqsQ[0] | writeDqsQ[1]; // high 3 cycles
    final held3Dq = writeDqD | writeDqQ[0] | writeDqQ[1];

    Sequential(clk, [
      If(
        _syncRst,
        then: [
          for (final b in [
            ...writeDqsQ,
            ...writeDqQ,
            ...writeDqs,
            ...writeDqsVal,
            ...writeDq,
          ])
            b < Const(0),
        ],
        orElse: [
          writeDqsQ[0] < writeDqsD,
          writeDqsQ[1] < writeDqsQ[0],
          writeDqQ[0] < writeDqD,
          writeDqQ[1] < writeDqQ[0],
          // HR bank (!ODELAY): the DQS-valid window opens a cycle earlier.
          writeDqsVal[0] < held3Dqs,
          writeDqs[0] < held3Dqs,
          writeDq[0] < held3Dq,
          for (var i = 0; i < depth; i++) ...[
            writeDqs[i + 1] < writeDqs[i],
            writeDqsVal[i + 1] < writeDqsVal[i],
          ],
          for (var i = 0; i < depth + 1; i++) writeDq[i + 1] < writeDq[i],
        ],
      ),
    ]);

    // Tristate is active-high = high-Z (read); the strobe pulls it low to write.
    output('o_phy_dqs_tri_control') <= ~writeDqs[depth];
    output('o_phy_dq_tri_control') <= ~writeDq[depth];
    // toggle_dqs at depth-2 (STAGE2_DATA_DEPTH >= 2) else write_dqs_d|write_dqs_q0.
    final toggleDqs = depth >= 2
        ? writeDqsVal[depth - 2]
        : (writeDqsD | writeDqsQ[0]);
    output('o_phy_toggle_dqs') <= toggleDqs;
  }

  /// One serdes-slot command word (MSB..LSB): cs_n, {ras,cas,we}, odt, cke,
  /// reset_n, bank, addr. Matches the PHY's cmd unpack.
  Logic _slotCmd({
    required Logic csN,
    required Logic cmd3,
    required Logic odt,
    required Logic cke,
    required Logic resetN,
    required Logic bank,
    required Logic addr,
  }) => [csN, cmd3, odt, cke, resetN, bank, addr].swizzle();

  /// Command-issue (ddr3_controller.v:911-1152), reset-phase default only for
  /// now. o_phy_cmd = {cmd_d[3],cmd_d[2],cmd_d[1],cmd_d[0]}: the current ROM
  /// instruction lands on the precharge slot (cs_n asserted for exactly the one
  /// cycle a new instruction starts), the other three slots hold a deselect NOP.
  /// The wishbone/bank-status command paths (stage2 read/write/activate/
  /// precharge) are not ported yet; until reset_done and a live bus request they
  /// would not fire anyway, so the reset default is also the correct idle output.

  /// The wishbone pipeline + bank scheduler + read-ack path
  /// (ddr3_controller.v:700-1270). Folds in the reset-phase command generation
  /// so calibration reads keep working; when a stage2 request is pending (from
  /// the calibration BIST master or the SoC bus) it overrides the command slots
  /// with the scheduled activate / precharge / read / write.
  void _buildWishbonePipeline(
    Logic clk,
    Logic iserdesData,
    Logic wbCyc,
    Logic wbStb,
    Logic wbWe,
    Logic wbAddr,
    Logic wbData,
    Logic wbSel,
    Logic aux,
  ) {
    final nBanks = 1 << params.baBits;
    final clog2sr2 = _clog2(serdes * 2); // 3
    final rowBits = params.rowBits, colBits = params.colBits;
    final baBits = params.baBits;
    // Anticipate margin in wb-word (column) units: how many columns before the
    // row end to start pre-precharge/pre-activate of the next row so it satisfies
    // tRP + tRCD (+ any leftover write-to-precharge). ddr3_controller.v:249.
    final marginBeforeAnticipate =
        timing.prechargeToActivateDelay +
        timing.activateToWriteDelay +
        timing.writeToPrechargeDelay;
    final colLo = colBits - clog2sr2;
    final wbDataBits = params.wbDataBits, wbSelBits = params.wbSelBits;
    final depth = _stage2DataDepth; // 2
    final readAckPipeWidth = _readDelay + 1 + 2 + 1 + 1; // 6
    const maxAckDelay = 16;
    // A failed self-trained calibration also opens the bus, so a CPU access
    // does not stall forever and firmware can read the failure flag.
    final done = phySelfTrainsRead
        ? (_stateCalibrate.eq(_stDoneCalibrate) |
              _stateCalibrate.eq(_stCalFailed))
        : _stateCalibrate.eq(_stDoneCalibrate);

    // --- registers ---
    Logic reg(String n, [int w = 1]) => Logic(name: n, width: w);
    final s1Pending = reg('s1_pending');
    final s1Aux = reg('s1_aux', auxWidth);
    final s1We = reg('s1_we');
    final s1Dm = reg('s1_dm', wbSelBits);
    final s1Col = reg('s1_col', colBits);
    final s1Bank = reg('s1_bank', baBits);
    final s1Row = reg('s1_row', rowBits);
    final s1NextBank = reg('s1_next_bank', baBits);
    final s1NextRow = reg('s1_next_row', rowBits);
    final s1Data = reg('s1_data', wbDataBits);
    final s2Pending = reg('s2_pending');
    final s2Aux = reg('s2_aux', auxWidth);
    final s2We = reg('s2_we');
    final s2Col = reg('s2_col', colBits);
    final s2Bank = reg('s2_bank', baBits);
    final s2Row = reg('s2_row', rowBits);
    final s2DataUnaligned = reg('s2_data_unaligned', wbDataBits);
    final s2DataUnalignedTemp = reg('s2_data_unaligned_temp', wbDataBits);
    final s2Data = [
      for (var i = 0; i < depth; i++) reg('s2_data_$i', wbDataBits),
    ];
    // Byte-mask (DM) pipeline. Mirrors the write-data pipeline exactly, but the
    // value is the INVERTED byte-select: DDR3 DM is active-high (1 masks a byte),
    // while Wishbone sel is active-high write-enable (1 writes a byte). A stage
    // whose data reaches o_phy_data has its mask reach o_phy_dm on the same beat.
    final s2DmUnaligned = reg('s2_dm_unaligned', wbSelBits);
    final s2DmUnalignedTemp = reg('s2_dm_unaligned_temp', wbSelBits);
    final s2Dm = [for (var i = 0; i < depth; i++) reg('s2_dm_$i', wbSelBits)];
    final cmdOdtQ = reg('cmd_odt_q');
    final oWbStall = reg('wb_stall_reg');
    final oWbStallQ = reg('wb_stall_q_reg');
    final oWbStallCalib = reg('wb_stall_calib_reg');
    final bankStatusQ = [
      for (var b = 0; b < nBanks; b++) reg('bank_status_q_$b'),
    ];
    final bankRowQ = [
      for (var b = 0; b < nBanks; b++) reg('bank_row_q_$b', rowBits),
    ];
    final dPreQ = [for (var b = 0; b < nBanks; b++) reg('d_pre_q_$b', 4)];
    final dActQ = [for (var b = 0; b < nBanks; b++) reg('d_act_q_$b', 4)];
    final dWrQ = [for (var b = 0; b < nBanks; b++) reg('d_wr_q_$b', 4)];
    final dRdQ = [for (var b = 0; b < nBanks; b++) reg('d_rd_q_$b', 4)];
    // read-ack pipe
    final shiftRegQ = [
      for (var i = 0; i < readAckPipeWidth; i++) reg('srp_q_$i', auxWidth + 1),
    ];
    final ackReadQ = [
      for (var i = 0; i < maxAckDelay; i++) reg('ack_q_$i', auxWidth + 1),
    ];
    final oWbDataQ = [
      reg('owb_data_q0', wbDataBits),
      reg('owb_data_q1', wbDataBits),
    ];
    final indexWbData = reg('index_wb_data');
    final delayReadPipe = [
      reg('delay_read_pipe0', 16),
      reg('delay_read_pipe1', 16),
    ];
    final indexReadPipe = reg('index_read_pipe');

    // --- combinational scheduler (_d) ---
    Logic wire(String n, [int w = 1]) => Logic(name: n, width: w);
    final cmdOdt = wire('cmd_odt');
    final cmdCkEn = wire('cmd_ck_en');
    final cmdResetN = wire('cmd_reset_n');
    final stage2Stall = wire('stage2_stall');
    final stage2Update = wire('stage2_update');
    final stage1Stall = wire('stage1_stall');
    final oWbStallD = wire('o_wb_stall_d');
    final prechargeBusy = wire('precharge_slot_busy');
    final activateBusy = wire('activate_slot_busy');
    final writeDqsSched = wire('write_dqs_sched');
    final cmdD = [for (var s = 0; s < 4; s++) wire('cmd_d_$s', cmdLen)];
    final bankStatusD = [
      for (var b = 0; b < nBanks; b++) wire('bank_status_d_$b'),
    ];
    final bankRowD = [
      for (var b = 0; b < nBanks; b++) wire('bank_row_d_$b', rowBits),
    ];
    final dPreD = [for (var b = 0; b < nBanks; b++) wire('d_pre_d_$b', 4)];
    final dActD = [for (var b = 0; b < nBanks; b++) wire('d_act_d_$b', 4)];
    final dWrD = [for (var b = 0; b < nBanks; b++) wire('d_wr_d_$b', 4)];
    final dRdD = [for (var b = 0; b < nBanks; b++) wire('d_rd_d_$b', 4)];
    final shiftRegD = [
      for (var i = 0; i < readAckPipeWidth; i++) wire('srp_d_$i', auxWidth + 1),
    ];

    // reset-phase command defaults (folded from the old command-issue block).
    final a10 = _instruction[25];
    final instrBank = _instruction.getRange(16, 16 + baBits);
    final instrAddr = [
      for (var i = 0; i < rowBits; i++) (i == 10 ? a10 : _instruction[i]),
    ].rswizzle();
    final zeroBank = Const(0, width: baBits);
    final zeroAddr = Const(0, width: rowBits);

    // constant delay values
    Logic dc(int v) => Const(v, width: 4);
    final t = timing;

    // Precompute the scheduler's FINAL ODT decision once, from registers only
    // (so it is glitch-free). The stage2 scheduler launches cmd_odt=1 for a
    // write and 0 for a read on the matched open bank/row, and otherwise leaves
    // the default (cmd_odt_q). Feeding this single value into every command-slot
    // build lets the plain Combinational stay legal: cmd_odt used to be read
    // into the reset-phase slots, then REASSIGNED in the scheduler, then reread
    // by an ODT fixup loop (a write-after-read ROHD forbids). Now it is written
    // once and the fixup loop is gone.
    Logic pickBank(List<Logic> regs) => cases(
      s2Bank,
      {for (var b = 0; b < nBanks; b++) Const(b, width: baBits): regs[b]},
      defaultValue: regs[0],
      conditionalType: ConditionalType.unique,
    );
    final s2RightRow =
        s2Pending & pickBank(bankStatusQ) & pickBank(bankRowQ).eq(s2Row);
    final s2LaunchWrite = s2RightRow & s2We & pickBank(dWrQ).eq(0);
    final s2LaunchRead = s2RightRow & ~s2We & pickBank(dRdQ).eq(0);
    final cmdOdtVal = mux(
      s2LaunchWrite,
      Const(1),
      mux(s2LaunchRead, Const(0), cmdOdtQ),
    );

    Combinational([
      cmdOdt < cmdOdtVal, // scheduler-final ODT (write=1 / read=0 / else _q)
      cmdCkEn < _instruction[24],
      cmdResetN < _instruction[23],
      stage1Stall < Const(0),
      stage2Stall < Const(0),
      stage2Update < Const(1),
      oWbStallD < Const(0),
      prechargeBusy < Const(0),
      activateBusy < Const(0),
      writeDqsSched < Const(0),
      // default bank / counter _d
      for (var b = 0; b < nBanks; b++) ...[
        bankStatusD[b] < bankStatusQ[b],
        bankRowD[b] < bankRowQ[b],
        dPreD[b] < mux(dPreQ[b].eq(0), dc(0), dPreQ[b] - 1),
        dActD[b] < mux(dActQ[b].eq(0), dc(0), dActQ[b] - 1),
        dWrD[b] < mux(dWrQ[b].eq(0), dc(0), dWrQ[b] - 1),
        dRdD[b] < mux(dRdQ[b].eq(0), dc(0), dRdQ[b] - 1),
      ],
      // read-ack shift pipe default (shift down, top cleared)
      for (var i = 0; i < readAckPipeWidth - 1; i++)
        shiftRegD[i] < shiftRegQ[i + 1],
      shiftRegD[readAckPipeWidth - 1] < Const(0, width: auxWidth + 1),
      // reset-phase command slots (precharge carries the instruction).
      cmdD[timing.prechargeSlot] <
          _slotCmd(
            csN: ~_delayCounterIsZero,
            cmd3: _instruction.getRange(19, 22),
            odt: cmdOdt,
            cke: cmdCkEn,
            resetN: cmdResetN,
            bank: instrBank,
            addr: instrAddr,
          ),
      cmdD[timing.readSlot] <
          _slotCmd(
            csN: ~_issueReadCommand,
            cmd3: Const(Ddr3Cmd.rd & 0x7, width: 3),
            odt: cmdOdt,
            cke: cmdCkEn,
            resetN: cmdResetN,
            bank: zeroBank,
            addr: zeroAddr,
          ),
      cmdD[timing.writeSlot] <
          _slotCmd(
            csN: Const(1),
            cmd3: Const(Ddr3Cmd.wr & 0x7, width: 3),
            odt: cmdOdt,
            cke: cmdCkEn,
            resetN: cmdResetN,
            bank: zeroBank,
            addr: zeroAddr,
          ),
      cmdD[timing.activateSlot] <
          _slotCmd(
            csN: Const(1),
            cmd3: Const(Ddr3Cmd.act & 0x7, width: 3),
            odt: cmdOdt,
            cke: cmdCkEn,
            resetN: cmdResetN,
            bank: zeroBank,
            addr: zeroAddr,
          ),
      // --- stage2 command scheduling (per-bank, guarded by s2Bank) ---
      // cmd_odt is already the scheduler-final value (cmdOdtVal), so every slot
      // below embeds it directly; no post-hoc ODT fixup / reassignment needed.
      If(
        s2Pending,
        then: [
          stage2Stall < Const(1),
          stage2Update < Const(0),
          for (var b = 0; b < nBanks; b++)
            If(
              s2Bank.eq(b) & bankStatusQ[b] & bankRowQ[b].eq(s2Row),
              then: [
                // right row active -> read or write
                If(
                  s2We & dWrQ[b].eq(0),
                  then: [
                    stage2Stall < Const(0),
                    stage2Update < Const(1),
                    shiftRegD[readAckPipeWidth - 1] <
                        [s2Aux, Const(1)].swizzle(),
                    If(
                      dPreQ[b].lte(dc(t.writeToPrechargeDelay)),
                      then: [dPreD[b] < dc(t.writeToPrechargeDelay)],
                    ),
                    for (var k = 0; k < nBanks; k++)
                      dRdD[k] < dc(t.writeToReadDelay + 1),
                    dWrD[b] < dc(t.writeToWriteDelay),
                    cmdD[timing.writeSlot] <
                        _rwCmd(
                          Ddr3Cmd.wr & 0x7,
                          s2Bank,
                          s2Col,
                          cmdOdt,
                          cmdCkEn,
                          cmdResetN,
                        ),
                    writeDqsSched < Const(1),
                  ],
                  orElse: [
                    If(
                      ~s2We & dRdQ[b].eq(0),
                      then: [
                        stage2Stall < Const(0),
                        stage2Update < Const(1),
                        If(
                          dPreQ[b].lte(dc(t.readToPrechargeDelay)),
                          then: [dPreD[b] < dc(t.readToPrechargeDelay)],
                        ),
                        dRdD[b] < dc(t.readToReadDelay),
                        for (var k = 0; k < nBanks; k++)
                          dWrD[k] < dc(t.writeToReadDelay + 1),
                        shiftRegD[readAckPipeWidth - 1] <
                            [s2Aux, Const(1)].swizzle(),
                        cmdD[timing.readSlot] <
                            _rwCmd(
                              Ddr3Cmd.rd & 0x7,
                              s2Bank,
                              s2Col,
                              cmdOdt,
                              cmdCkEn,
                              cmdResetN,
                            ),
                      ],
                    ),
                  ],
                ),
              ],
              orElse: [
                If(
                  s2Bank.eq(b) & ~bankStatusQ[b] & dActQ[b].eq(0),
                  then: [
                    // bank idle -> activate
                    activateBusy < Const(1),
                    dPreD[b] < dc(t.activateToPrechargeDelay),
                    If(
                      dRdQ[b].lte(dc(t.activateToReadDelay)),
                      then: [dRdD[b] < dc(t.activateToReadDelay)],
                    ),
                    If(
                      dWrQ[b].lte(dc(t.activateToWriteDelay)),
                      then: [dWrD[b] < dc(t.activateToWriteDelay)],
                    ),
                    cmdD[timing.activateSlot] <
                        _actCmd(s2Bank, s2Row, cmdOdt, cmdCkEn, cmdResetN),
                    bankStatusD[b] < Const(1),
                    bankRowD[b] < s2Row,
                  ],
                  orElse: [
                    If(
                      s2Bank.eq(b) &
                          bankStatusQ[b] &
                          ~bankRowQ[b].eq(s2Row) &
                          dPreQ[b].eq(0),
                      then: [
                        // wrong row -> precharge
                        prechargeBusy < Const(1),
                        dActD[b] < dc(t.prechargeToActivateDelay),
                        cmdD[timing.prechargeSlot] <
                            _preCmd(s2Bank, s2Row, cmdOdt, cmdCkEn, cmdResetN),
                        bankStatusD[b] < Const(0),
                      ],
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
      // --- stage1 anticipate (ddr3_controller.v:1069-1101) ---
      // While stage2 serves the current request, pre-precharge / pre-activate the
      // NEXT request's row (s1NextBank/s1NextRow) so it is open by the time it
      // reaches stage2. Skipped when the anticipated bank is the one stage2 is
      // using this cycle. Without this the on-demand path desyncs bank_row on a
      // row change and a read can land on the wrong open row.
      If(
        s1Pending & ~(s1NextBank.eq(s2Bank) & s2Pending),
        then: [
          for (var b = 0; b < nBanks; b++)
            If(
              s1NextBank.eq(b) &
                  bankStatusQ[b] &
                  ~bankRowQ[b].eq(s1NextRow) &
                  dPreQ[b].eq(0) &
                  ~prechargeBusy,
              then: [
                // wrong row open in the anticipated bank -> precharge it.
                dActD[b] < dc(t.prechargeToActivateDelay),
                cmdD[timing.prechargeSlot] <
                    _preCmd(s1NextBank, s1NextRow, cmdOdt, cmdCkEn, cmdResetN),
                bankStatusD[b] < Const(0),
              ],
              orElse: [
                If(
                  s1NextBank.eq(b) &
                      ~bankStatusQ[b] &
                      dActQ[b].eq(0) &
                      ~activateBusy,
                  then: [
                    // anticipated bank idle -> activate the next row early.
                    dPreD[b] < dc(t.activateToPrechargeDelay),
                    If(
                      dRdD[b].lte(dc(t.activateToReadDelay)),
                      then: [dRdD[b] < dc(t.activateToReadDelay)],
                    ),
                    If(
                      dWrD[b].lte(dc(t.activateToWriteDelay)),
                      then: [dWrD[b] < dc(t.activateToWriteDelay)],
                    ),
                    cmdD[timing.activateSlot] <
                        _actCmd(
                          s1NextBank,
                          s1NextRow,
                          cmdOdt,
                          cmdCkEn,
                          cmdResetN,
                        ),
                    bankStatusD[b] < Const(1),
                    bankRowD[b] < s1NextRow,
                  ],
                ),
              ],
            ),
        ],
      ),
      // --- stage1 stall (ddr3_controller.v:1104-1123) ---
      // Hold stage1 until its own bank/row is ready: bank idle, wrong row still
      // open, or the read/write timer for that bank has not elapsed.
      If(
        s1Pending,
        then: [
          for (var b = 0; b < nBanks; b++)
            If(
              s1Bank.eq(b),
              then: [
                If(
                  ~bankStatusD[b] |
                      (bankStatusD[b] & ~bankRowD[b].eq(s1Row)) |
                      (~s1We & ~dRdD[b].eq(0)) |
                      (s1We & ~dWrD[b].eq(0)),
                  then: [stage1Stall < Const(1)],
                ),
              ],
            ),
        ],
      ),
      // --- stall control ---
      If(
        s2Pending,
        then: [
          for (var b = 0; b < nBanks; b++)
            If(
              s2Bank.eq(b) & bankStatusD[b] & bankRowD[b].eq(s2Row),
              then: [
                If(s2We & dWrD[b].eq(0), then: [stage2Stall < Const(0)]),
                If(~s2We & dRdD[b].eq(0), then: [stage2Stall < Const(0)]),
              ],
            ),
        ],
      ),
      If(
        oWbStallQ,
        then: [oWbStallD < stage2Stall],
        orElse: [
          If(
            (~wbStb & done) | (~_calibStb & ~done),
            then: [oWbStallD < Const(0)],
            orElse: [
              If(
                ~s1Pending,
                then: [oWbStallD < stage2Stall],
                orElse: [oWbStallD < stage1Stall],
              ),
            ],
          ),
        ],
      ),
      If(~wbCyc & done, then: [oWbStallD < Const(0)]),
    ]);

    // --- sequential pipeline ---
    final acceptWb = wbCyc & ~oWbStall;
    final acceptCalib = ~done & ~oWbStallCalib;
    // Address field decode helper (wb or calib).
    Logic colOf(Logic a) => [
      a.getRange(0, colBits - clog2sr2),
      Const(0, width: clog2sr2),
    ].swizzle();
    Logic bankOf(Logic a) =>
        a.getRange(colBits - clog2sr2, baBits + colBits - clog2sr2);
    Logic rowOf(Logic a) => a.getRange(
      baBits + colBits - clog2sr2,
      rowBits + baBits + colBits - clog2sr2,
    );
    // Anticipated next {row,bank} = (addr + MARGIN) >> colLo, split into the
    // low baBits (bank) and the next rowBits (row). ddr3_controller.v:832/846.
    Logic _antic(Logic a) =>
        (a + Const(marginBeforeAnticipate, width: params.wbAddrBits)) >> colLo;
    Logic nextBankOf(Logic a) => _antic(a).getRange(0, baBits);
    Logic nextRowOf(Logic a) => _antic(a).getRange(baBits, baBits + rowBits);

    Sequential(clk, [
      If(
        _syncRst,
        then: [
          oWbStall < Const(1),
          oWbStallQ < Const(1),
          oWbStallCalib < Const(1),
          s1Pending < Const(0),
          s2Pending < Const(0),
          cmdOdtQ < Const(0),
          indexWbData < Const(0),
          indexReadPipe < Const(0),
          delayReadPipe[0] < Const(0, width: 16),
          delayReadPipe[1] < Const(0, width: 16),
          for (var b = 0; b < nBanks; b++) ...[
            bankStatusQ[b] < Const(0),
            bankRowQ[b] < Const(0, width: rowBits),
            dPreQ[b] < dc(0),
            dActQ[b] < dc(0),
            dWrQ[b] < dc(0),
            dRdQ[b] < dc(0),
          ],
          for (var i = 0; i < readAckPipeWidth; i++)
            shiftRegQ[i] < Const(0, width: auxWidth + 1),
          for (var i = 0; i < maxAckDelay; i++)
            ackReadQ[i] < Const(0, width: auxWidth + 1),
          for (final r in [
            s1Aux,
            s1We,
            s1Dm,
            s1Col,
            s1Bank,
            s1Row,
            s1NextBank,
            s1NextRow,
            s1Data,
            s2Aux,
            s2We,
            s2Col,
            s2Bank,
            s2Row,
            s2DataUnaligned,
            s2DataUnalignedTemp,
            ...s2Data,
            s2DmUnaligned,
            s2DmUnalignedTemp,
            ...s2Dm,
            oWbDataQ[0],
            oWbDataQ[1],
          ])
            r < Const(0, width: r.width),
        ],
        orElse: [
          If(
            _resetDone,
            then: [
              oWbStall < (oWbStallD | ~done),
              oWbStallQ < oWbStallD,
              oWbStallCalib < oWbStallD,
              cmdOdtQ < cmdOdt,
              for (var b = 0; b < nBanks; b++) ...[
                bankStatusQ[b] < bankStatusD[b],
                bankRowQ[b] < bankRowD[b],
                dPreQ[b] < dPreD[b],
                dActQ[b] < dActD[b],
                dWrQ[b] < dWrD[b],
                dRdQ[b] < dRdD[b],
              ],
              // post-refresh precharge clears bank status (instruction 20).
              If(
                _instructionAddress.eq(20),
                then: [
                  for (var b = 0; b < nBanks; b++) bankStatusQ[b] < Const(0),
                ],
              ),
              // refresh on-going -> stall.
              If(
                ~_instruction[27],
                then: [oWbStall < Const(1), oWbStallCalib < Const(1)],
              ),
              // advance stage1 -> stage2.
              If(
                ~oWbStallQ & stage2Update,
                then: [
                  s1Pending < Const(0),
                  s2Pending < s1Pending,
                  s2Aux < s1Aux,
                  s2We < s1We,
                  s2Col < s1Col,
                  s2Bank < s1Bank,
                  s2Row < s1Row,
                  s2DataUnalignedTemp < s1Data,
                  s2DmUnalignedTemp < ~s1Dm,
                ],
              ),
              s2DataUnaligned < s2DataUnalignedTemp,
              s2DmUnaligned < s2DmUnalignedTemp,
              // accept a new request (wb or calib).
              If(
                acceptWb,
                then: [
                  s1Pending < wbStb,
                  s1Aux < aux,
                  s1We < wbWe,
                  s1Dm < wbSel,
                  s1Col < colOf(wbAddr),
                  s1Bank < bankOf(wbAddr),
                  s1Row < rowOf(wbAddr),
                  s1NextBank < nextBankOf(wbAddr),
                  s1NextRow < nextRowOf(wbAddr),
                  s1Data < wbData,
                ],
                orElse: [
                  If(
                    acceptCalib,
                    then: [
                      s1Pending < _calibStb,
                      s1We < _calibWe,
                      s1Dm < _calibSel,
                      s1Aux < _calibAux,
                      s1Col < colOf(_calibAddr),
                      s1Bank < bankOf(_calibAddr),
                      s1Row < rowOf(_calibAddr),
                      s1NextBank < nextBankOf(_calibAddr),
                      s1NextRow < nextRowOf(_calibAddr),
                      s1Data < _calibData,
                    ],
                  ),
                ],
              ),
              // stage2 data align (identity when data_start_index == 0).
              s2Data[0] < s2DataUnaligned,
              for (var i = 0; i < depth - 1; i++) s2Data[i + 1] < s2Data[i],
              s2Dm[0] < s2DmUnaligned,
              for (var i = 0; i < depth - 1; i++) s2Dm[i + 1] < s2Dm[i],
              // read-ack pipe (ddr3_controller.v:1200-1244). The read latency the
              // calibration found (added_read_pipe_max) times where the ack is
              // injected and when the ISERDES data is captured.
              for (var i = 0; i < readAckPipeWidth; i++)
                shiftRegQ[i] < shiftRegD[i],
              // delay_read_pipe: shift down each cycle; inject a 1 at bit
              // added_read_pipe_max (in the buffer index_read_pipe selects) when a
              // read ack reaches shiftRegQ[1][0].
              for (var buf = 0; buf < 2; buf++)
                delayReadPipe[buf] <
                    mux(
                      shiftRegQ[1][0] & indexReadPipe.eq(buf),
                      (delayReadPipe[buf] >> 1) |
                          (Const(1, width: 16) << _addedReadPipeMax),
                      delayReadPipe[buf] >> 1,
                    ),
              If(shiftRegQ[1][0], then: [indexReadPipe < ~indexReadPipe]),
              // capture each ISERDES word into the double-buffered o_wb_data_q. Per
              // lane the capture bit is delay_read_pipe[buf][max != added[lane]]: a
              // lane with LESS read latency than the max captures one cycle earlier
              // (bit 1) than the max-delay lane (bit 0). Faithful to
              // ddr3_controller.v:1213-1235 (was flattened to [buf][0] for all lanes,
              // which mis-times a faster lane and shows up as intermittent misreads).
              for (var buf = 0; buf < 2; buf++)
                oWbDataQ[buf] <
                    [
                      for (var b = 0; b < 8; b++)
                        for (var l = 0; l < lanes; l++)
                          mux(
                            mux(
                              _addedReadPipeMax.neq(_addedReadPipeLane[l]),
                              delayReadPipe[buf][1],
                              delayReadPipe[buf][0],
                            ),
                            iserdesData.getRange(
                              dq * b + 8 * l,
                              dq * b + 8 * l + 8,
                            ),
                            oWbDataQ[buf].getRange(
                              dq * b + 8 * l,
                              dq * b + 8 * l + 8,
                            ),
                          ),
                    ].rswizzle(),
              // o_wb_ack_read_q: shift down; inject shiftRegQ[0] at added_read_pipe_max.
              for (var i = 1; i < maxAckDelay; i++)
                ackReadQ[i - 1] < ackReadQ[i],
              ackReadQ[maxAckDelay - 1] < Const(0, width: auxWidth + 1),
              for (var i = 0; i < maxAckDelay; i++)
                If(_addedReadPipeMax.eq(i), then: [ackReadQ[i] < shiftRegQ[0]]),
              If(ackReadQ[0][0], then: [indexWbData < ~indexWbData]),
              If(
                ~wbCyc & done,
                then: [s1Pending < Const(0), s2Pending < Const(0)],
              ),
            ],
          ),
        ],
      ),
    ]);

    // --- outputs ---
    output('o_phy_cmd') <= [cmdD[3], cmdD[2], cmdD[1], cmdD[0]].swizzle();
    output('o_phy_data') <= s2Data[depth - 1];
    output('o_phy_dm') <= s2Dm[depth - 1];
    output('o_wb_stall') <= oWbStall;
    output('o_wb_ack') <= (ackReadQ[0][0] & done);
    output('o_aux') <= ackReadQ[0].getRange(1, auxWidth + 1);
    output('o_wb_data') <= mux(indexWbData, oWbDataQ[1], oWbDataQ[0]);
    _oWbStallCalib <= oWbStallCalib;
    _writeDqsSched <= writeDqsSched;
    _oWbAckRead <= ackReadQ[0];
    _oWbData <= mux(indexWbData, oWbDataQ[1], oWbDataQ[0]);
  }

  /// Read-return pipe base offset, in CONTROLLER cycles, from the read command
  /// to the cycle its CL-latency data lands. The within-window term `(serdes - 1
  /// - READ_SLOT + 1)` = `(serdes - READ_SLOT)` is CK inside the 4-slot command
  /// word (scales with [serdes]); the `~/ controllerClkRatio` converts the CK
  /// gap into controller cycles (CK/8 at gearRatio 2), so the read command->data
  /// CK separation stays CL. gearRatio 1: (6-(4-2))~/4 = 1 (unchanged). gearRatio
  /// 2: (6-(4-2))~/8 = 0 (the data lands one CK/8 cycle sooner in cycle-count,
  /// same real CK offset).
  int get _readDelay {
    final v = DdrTiming.clNck - (serdes - 1 - timing.readSlot + 1);
    return v ~/ params.controllerClkRatio;
  }

  /// STAGE2_DATA_DEPTH / read-delay, exposed so a CWL/CL differential test can
  /// assert the command->data / command->capture CK separations are identical
  /// across gearRatio (the gearbox correctness proof).
  int get stage2DataDepth => _stage2DataDepth;
  int get readDelay => _readDelay;

  /// CK from a WRITE command to the launch of its BL8 data burst. Must equal
  /// CWL (5) for the DRAM regardless of gearRatio: at CK/8 the whole-cycle depth
  /// halves (2 -> 1) while the mod-4 write slot is unchanged, so
  /// controllerClkRatio*depth - writeSlot stays 5.
  int get writeCommandToDataCk =>
      params.controllerClkRatio * _stage2DataDepth - timing.writeSlot;

  /// CK from a READ command to when the DRAM's returned data is on the bus
  /// (= CL, 6). The read command keeps its mod-4 slot across gearRatio, so the
  /// command->data-return separation is the DRAM's fixed CL either way.
  int get readCommandToDataCk => DdrTiming.clNck;

  static int _clog2(int x) {
    var n = 0;
    var v = x - 1;
    while (v > 0) {
      v >>= 1;
      n++;
    }
    return n;
  }

  /// Read/Write command word for the scheduled column access (COL_BITS<=10).
  Logic _rwCmd(
    int cmd3,
    Logic bank,
    Logic col,
    Logic odt,
    Logic cke,
    Logic resetN,
  ) => _slotCmd(
    csN: Const(0),
    cmd3: Const(cmd3, width: 3),
    odt: odt,
    cke: cke,
    resetN: resetN,
    bank: bank,
    // addr = {zeros, 1'b0(A10=no autoprecharge), col[9:0]} within rowBits.
    addr: [
      Const(0, width: params.rowBits - 11),
      Const(0), // A10 = 0
      col.getRange(0, 10),
    ].swizzle(),
  );

  Logic _actCmd(Logic bank, Logic row, Logic odt, Logic cke, Logic resetN) =>
      _slotCmd(
        csN: Const(0),
        cmd3: Const(Ddr3Cmd.act & 0x7, width: 3),
        odt: odt,
        cke: cke,
        resetN: resetN,
        bank: bank,
        addr: row,
      );

  Logic _preCmd(Logic bank, Logic row, Logic odt, Logic cke, Logic resetN) =>
      _slotCmd(
        csN: Const(0),
        cmd3: Const(Ddr3Cmd.pre & 0x7, width: 3),
        odt: odt,
        cke: cke,
        resetN: resetN,
        bank: bank,
        addr: [
          Const(0, width: params.rowBits - 11),
          Const(0), // A10 = 0 (single-bank precharge)
          row.getRange(0, 10),
        ].swizzle(),
      );

  // Reset-sequence registers, exposed for the sim testbench.
  late final Logic _instructionAddress;
  late final Logic _instruction;
  late final Logic _delayCounterIsZero;
  late final Logic _resetDone;
  late final Logic _syncRst;

  // Cross-block signals driven by the calibration FSM.
  late final Logic _pauseCounter; // gates the reset-ROM delay counter
  late final Logic _issueReadCommand; // gates the read-slot cs_n
  late final Logic _resetFromCalibrate; // calibration-triggered resync
  late final Logic _writeCalibDqs; // calibration DQS strobe request
  late final Logic _writeCalibDq; // calibration DQ strobe request
  // Calibration wishbone master (BIST issues writes/reads through the pipeline).
  late final Logic _calibStb;
  late final Logic _calibWe;
  late final Logic _calibAux; // [auxWidth]
  late final Logic _calibSel; // [wbSelBits]
  late final Logic _calibAddr; // [wbAddrBits]
  late final Logic _calibData; // [wbDataBits]
  late final Logic _oWbStallCalib; // scheduler stall seen by the cal FSM
  late final Logic _stateCalibrate; // calibration FSM state (6-bit)
  late final Logic _writeDqsSched; // scheduler stage2-write DQS strobe request
  late final Logic _oWbAckRead; // ackReadQ[0] (read-ack head, [auxWidth:0])
  late final Logic _oWbData; // aligned read data [wbDataBits]
  late final Logic _addedReadPipeMax; // calibration read-latency (4-bit)
  late final List<Logic> _addedReadPipeLane; // per-lane read latency

  /// STAGE2_DATA_DEPTH: the write-data shift-register depth (whole controller
  /// cycles) for the CWL launch pipeline (ddr3_controller.v:250). The within-
  /// window term `(serdes - 1 - WRITE_SLOT + 1)` = `(serdes - WRITE_SLOT)` is CK
  /// inside the 4-slot command word (scales with [serdes], stays 4-wide); the
  /// `~/ controllerClkRatio` is the CK-per-controller-cycle conversion (8 at
  /// gearRatio 2). gearRatio 1: (5-(4-3))~/4 + 1 = 2. gearRatio 2:
  /// (5-(4-3))~/8 + 1 = 1. Either way controllerClkRatio*depth - writeSlot = CWL.
  int get _stage2DataDepth =>
      (DdrTiming.cwlNck - (serdes - 1 - timing.writeSlot + 1)) ~/
          params.controllerClkRatio +
      1;

  int get _lanesClog2 => lanes <= 1 ? 1 : (lanes - 1).bitLength;

  /// Calibration state (o_debug1), for observation / bring-up LEDs.
  Logic get debug1 => output('o_debug1');

  /// Port a single ROM word to a 28-bit constant.
  Logic _romWord(int addr) => Const(modeRegs.romWord(addr), width: 28);

  /// Combinational ROM lookup on the 5-bit [addr] (0..22, else the idle NOP).
  Logic _romLookup(Logic addr) => cases(
    addr,
    {for (var a = 0; a <= 22; a++) Const(a, width: 5): _romWord(a)},
    defaultValue: _romWord(31),
    conditionalType: ConditionalType.unique,
  );

  /// Reset-sequence ROM controller (ddr3_controller.v:654-696). Walks the ROM,
  /// counting down each instruction's timer delay, wrapping 22 -> 19 to repeat
  /// the refresh loop, and latching reset_done when an instruction sets RST_DONE.
  void _buildResetSequence(Logic controllerClk, Logic rstN) {
    final delayCounterWidth = math.max(1, timing.delayCounterWidth);
    final initial = modeRegs.initialResetInstruction;
    final initialDelay = initial & ((1 << delayCounterWidth) - 1);

    _instructionAddress = Logic(name: 'instruction_address', width: 5);
    _instruction = Logic(name: 'instruction', width: 28);
    final delayCounter = Logic(name: 'delay_counter', width: delayCounterWidth);
    final delayCounterIsZero = Logic(name: 'delay_counter_is_zero');
    _delayCounterIsZero = delayCounterIsZero;
    _resetDone = Logic(name: 'reset_done');

    // sync_rst_controller (654-657): the other reset sources (wb2 / test) are
    // tied low until those blocks are ported; reset_from_calibrate is driven by
    // the calibration FSM.
    final syncRst = Logic(name: 'sync_rst_controller');
    _syncRst = syncRst;
    Sequential(controllerClk, [syncRst < (~rstN | _resetFromCalibrate)]);
    output('o_phy_reset') <= syncRst;

    // Instruction bit fields.
    final useTimer = _instruction[26];
    final rstDoneBit = _instruction[27];
    final instrDelay = _instruction.getRange(0, delayCounterWidth);

    // Load the next ROM word when the current timer is about to expire (==1) or
    // the instruction uses no timer.
    final loadNext = delayCounter.eq(1) | ~useTimer;

    Sequential(controllerClk, [
      If(
        syncRst,
        then: [
          _instructionAddress < Const(0, width: 5),
          _instruction < Const(initial, width: 28),
          delayCounter < Const(initialDelay, width: delayCounterWidth),
          delayCounterIsZero < Const(initialDelay == 0 ? 1 : 0),
          _resetDone < Const(0),
        ],
        orElse: [
          // delay_counter: reload on zero, else decrement while timing (and not
          // paused by calibration).
          If(
            delayCounterIsZero,
            then: [delayCounter < instrDelay],
            orElse: [
              If(
                useTimer & ~_pauseCounter,
                then: [delayCounter < delayCounter - 1],
              ),
            ],
          ),
          // advance to the next instruction (wrap 22 -> 19 for the refresh loop).
          If(
            loadNext,
            then: [
              delayCounterIsZero < Const(1),
              _instruction < _romLookup(_instructionAddress),
              _instructionAddress <
                  mux(
                    _instructionAddress.eq(22),
                    Const(19, width: 5),
                    _instructionAddress + 1,
                  ),
            ],
            orElse: [delayCounterIsZero < Const(0)],
          ),
          _resetDone < mux(rstDoneBit, Const(1), _resetDone),
        ],
      ),
    ]);

    // (debug words are driven by the calibration block; reset_done is exposed
    // there as debug1[6].)
  }

  // Calibration state codes (ddr3_controller.v:267-290).
  static const int _stIdle = 0;
  static const int _stBitslipTrain1 = 1;
  static const int _stMprRead = 2;
  static const int _stCollectDqs = 3;
  static const int _stAnalyzeDqs = 4;
  static const int _stCalibrateDqs = 5;
  static const int _stBitslipTrain2 = 6;
  static const int _stStartWriteLevel = 7;
  static const int _stIssueWrite1 = 9;
  static const int _stIssueWrite2 = 10;
  static const int _stIssueRead = 11;
  static const int _stReadData = 12;
  static const int _stAnalyzeData = 13;
  static const int _stDoneCalibrate = 23;
  // Self-training PHY only: report one test read, then wait for the PHY.
  static const int _stReadLevel = 24;
  static const int _stReadLevelWait = 25;

  // Self-training PHY only: calibration gave up (see [maxCalAttempts]).
  static const int _stCalFailed = 26;

  /// Ticks to wait after a leveling report before the next test read. Longer
  /// than the PHY needs to settle a point or to finish its scoring.
  static const int readLevelWaitTicks = 40;

  /// Default for [maxCalAttempts].
  static const int defaultMaxCalAttempts = 4;

  /// High when a self-trained calibration failed [maxCalAttempts] times. Null
  /// unless [phySelfTrainsRead].
  Logic? get calFailed => phySelfTrainsRead ? output('o_cal_failed') : null;

  /// Calibration write patterns: each 16-bit beat is a byte replicated across
  /// the two lanes (ddr3_controller.v:1554/1563). x16 (LANES=2) only.
  static BigInt get _calibDataW1 =>
      BigInt.parse('9191777729298c8cd0d0adad5151c1c1', radix: 16);
  static BigInt get _calibDataW2 =>
      BigInt.parse('8080dbdbcfcfd2d27575f1f12c2c3d3d', radix: 16);

  /// Read-verify reference (ddr3_controller.v:1584): the two per-lane byte
  /// sequences concatenated, {W2-lane-bytes, W1-lane-bytes}.
  static BigInt get _writePattern =>
      BigInt.parse('80dbcfd275f12c3d9177298cd0ad51c1', radix: 16);
  static const int _storedDqsSize = 5; // 40-bit dqs_store
  static const int _repeatDqsAnalyze = 1;
  // The DQS-analyze target: 10'b01_01_01_01_00 (toggling burst + postamble).
  static const int _dqsAnalyzePattern = 0x154;

  /// Read-calibration FSM (ddr3_controller.v:1276-1495). Ported: IDLE and
  /// BITSLIP_DQS_TRAIN_1 (the ISERDES bitslip training) plus the full register
  /// set and per-cycle housekeeping; MPR_READ..START_WRITE_LEVEL and the write/
  /// BIST states are stubbed to hold, pending the DQS-analyze + wishbone work.
  void _buildCalibration(
    Logic clk,
    Logic idelayctrlRdy,
    Logic iserdesDqs,
    Logic bitslipReference,
    Logic? readLevelDone,
  ) {
    final selfTrain = phySelfTrainsRead;
    final laneW = _lanesClog2;
    const idxW = 6; // clog2(STORED_DQS_SIZE*8=40)

    final state = Logic(name: 'state_calibrate', width: 6);
    final trainDelay = Logic(name: 'train_delay', width: 4);
    final dqsStore = Logic(name: 'dqs_store', width: _storedDqsSize * 8);
    final dqsCountRepeat = Logic(name: 'dqs_count_repeat', width: 4);
    final dqsStartIndex = Logic(name: 'dqs_start_index', width: idxW);
    final dqsStartIndexStored = Logic(
      name: 'dqs_start_index_stored',
      width: idxW,
    );
    final dqsStartIndexRepeat = Logic(name: 'dqs_start_index_repeat', width: 1);
    final dqsTargetIndex = Logic(name: 'dqs_target_index', width: idxW);
    final dqsTargetIndexOrig = Logic(
      name: 'dqs_target_index_orig',
      width: idxW,
    );
    final initialDqs = Logic(name: 'initial_dqs');
    final laneReg = Logic(name: 'lane', width: laneW);
    final laneTimes8 = Logic(name: 'lane_times_8', width: 4);
    final dqsBitslipArrangement = Logic(
      name: 'dqs_bitslip_arrangement',
      width: 16,
    );
    final delayBeforeReadData = Logic(name: 'delay_before_read_data', width: 4);
    final idelayDataCntPrev = Logic(
      name: 'idelay_data_cntvaluein_prev',
      width: 5,
    );
    final addedReadPipeMax = Logic(name: 'added_read_pipe_max', width: 4);
    final pauseCounterReg = Logic(name: 'pause_counter_reg');
    final resetFromCalibrateReg = Logic(name: 'reset_from_calibrate_reg');
    // Self-training PHY handshake (built only when the PHY self-trains).
    final levelStart = selfTrain ? Logic(name: 'read_level_start') : null;
    final levelCheck = selfTrain ? Logic(name: 'read_level_check') : null;
    final levelPass = selfTrain
        ? Logic(name: 'read_level_pass', width: lanes)
        : null;
    final levelWait = selfTrain
        ? Logic(name: 'read_level_wait', width: 6)
        : null;
    // Calibration restarts, counted from power-on (the restart reset does not
    // clear it).
    final calAttempts = selfTrain
        ? Logic(name: 'cal_attempts', width: 3)
        : null;
    if (selfTrain) {
      Sequential(clk, reset: ~input('i_rst_n'), [
        If(resetFromCalibrateReg, then: [calAttempts! < calAttempts + 1]),
      ]);
    }

    // Per-lane registers.
    List<Logic> perLane(String base, int w) => [
      for (var l = 0; l < lanes; l++) Logic(name: '${base}_$l', width: w),
    ];
    final odelayDataCnt = perLane('odelay_data_cnt', 5);
    final odelayDqsCnt = perLane('odelay_dqs_cnt', 5);
    final idelayDataCnt = perLane('idelay_data_cnt', 5);
    final idelayDqsCnt = perLane('idelay_dqs_cnt', 5);
    final dqTargetIndex = perLane('dq_target_index', idxW + 1);
    final addedReadPipe = perLane('added_read_pipe', 4);
    final dataStartIndex = perLane('data_start_index', 7); // clog2(64)+1
    final readDataStore = Logic(
      name: 'read_data_store',
      width: params.wbDataBits,
    );
    final writePattern = Logic(name: 'write_pattern', width: 128);
    final oBitslip = [
      for (var l = 0; l < lanes; l++) Logic(name: 'o_bitslip_$l'),
    ];
    final oIdelayDataLd = [
      for (var l = 0; l < lanes; l++) Logic(name: 'o_idelay_data_ld_$l'),
    ];
    final oIdelayDqsLd = [
      for (var l = 0; l < lanes; l++) Logic(name: 'o_idelay_dqs_ld_$l'),
    ];
    final oOdelayDataLd = [
      for (var l = 0; l < lanes; l++) Logic(name: 'o_odelay_data_ld_$l'),
    ];
    final oOdelayDqsLd = [
      for (var l = 0; l < lanes; l++) Logic(name: 'o_odelay_dqs_ld_$l'),
    ];
    final oWlCalib = Logic(name: 'o_write_leveling_calib');
    final writeCalibDqs = Logic(name: 'write_calib_dqs');
    final writeCalibDq = Logic(name: 'write_calib_dq');
    // Calibration wishbone master registers (driven by the BIST states).
    final calibStb = Logic(name: 'calib_stb');
    final calibWe = Logic(name: 'calib_we');
    final calibAux = Logic(name: 'calib_aux', width: auxWidth);
    final calibSel = Logic(name: 'calib_sel', width: params.wbSelBits);
    final calibAddr = Logic(name: 'calib_addr', width: params.wbAddrBits);
    final calibData = Logic(name: 'calib_data', width: params.wbDataBits);

    // Lane-indexed slice of a LANES*w-wide signal.
    Logic laneSlice(Logic wide, int w) => cases(
      laneReg,
      {
        for (var l = 0; l < lanes; l++)
          Const(l, width: laneW): wide.getRange(l * w, (l + 1) * w),
      },
      defaultValue: wide.getRange(0, w),
      conditionalType: ConditionalType.unique,
    );

    final dqsRefByte = laneSlice(bitslipReference, 8);
    final dqsByte = laneSlice(iserdesDqs, 8);
    final dqsTargetIndexValue = mux(
      dqsStartIndexStored[0],
      dqsStartIndexStored + 2,
      dqsStartIndexStored + 1,
    );
    // MPR-read data latency: READ_DELAY(1) + issue/ISERDES pipeline (1310-1319).
    const readCalDelay = 4;
    // dqs_store[dqs_start_index +: 10]: a variable 10-bit window (zero-extended
    // so a scan near the top pads with 0, matching Verilog +:).
    final dqsWindow =
        (dqsStore.zeroExtend(_storedDqsSize * 8 + 10) >> dqsStartIndex)
            .getRange(0, 10);
    // Read-verify: per-lane 64-bit gather of read_data_store, and the sliding
    // 64-bit window into write_pattern (ddr3_controller.v:1590).
    Logic gatherLane(int l) => [
      for (var b = 7; b >= 0; b--)
        readDataStore.getRange(dq * b + 8 * l, dq * b + 8 * l + 8),
    ].swizzle();
    final readGather = cases(
      laneReg,
      {for (var l = 0; l < lanes; l++) Const(l, width: laneW): gatherLane(l)},
      defaultValue: gatherLane(0),
      conditionalType: ConditionalType.unique,
    );
    final dataStartIndexCur = cases(
      laneReg,
      {
        for (var l = 0; l < lanes; l++)
          Const(l, width: laneW): dataStartIndex[l],
      },
      defaultValue: dataStartIndex[0],
      conditionalType: ConditionalType.unique,
    );
    final writePatternWindow =
        (writePattern.zeroExtend(128 + 64) >> dataStartIndexCur).getRange(
          0,
          64,
        );
    // aux=1 read-ack marker: {(auxWidth-2)*0, 2'd1, 1'b1}.
    final readAckMarker = Const((1 << 1) | 1, width: auxWidth + 1);
    final allSel = Const(
      (BigInt.one << params.wbSelBits) - BigInt.one,
      width: params.wbSelBits,
    );
    // Initial delay taps (ddr3_controller.v:1325-1328).
    final initOdelayData = Const(0, width: 5);
    final initOdelayDqs = Const(timing.dqsInitialOdelayTap & 0x1F, width: 5);
    final initIdelayData = Const(0, width: 5);
    final initIdelayDqs = Const(timing.dqsInitialIdelayTap & 0x1F, width: 5);

    final done = state.eq(_stDoneCalibrate);

    Sequential(clk, [
      If(
        _syncRst,
        then: [
          state < Const(_stIdle, width: 6),
          trainDelay < Const(0, width: 4),
          dqsStore < Const(0, width: _storedDqsSize * 8),
          dqsCountRepeat < Const(0, width: 4),
          dqsStartIndex < Const(0, width: idxW),
          dqsStartIndexStored < Const(0, width: idxW),
          dqsStartIndexRepeat < Const(0),
          dqsTargetIndex < Const(0, width: idxW),
          dqsTargetIndexOrig < Const(0, width: idxW),
          initialDqs < Const(1),
          laneReg < Const(0, width: laneW),
          laneTimes8 < Const(0, width: 4),
          dqsBitslipArrangement < Const(0, width: 16),
          delayBeforeReadData < Const(0, width: 4),
          idelayDataCntPrev < Const(0, width: 5),
          addedReadPipeMax < Const(selfTrain ? phyReadPipeTicks : 0, width: 4),
          pauseCounterReg < Const(0),
          resetFromCalibrateReg < Const(0),
          oWlCalib < Const(0),
          writeCalibDqs < Const(0),
          writeCalibDq < Const(0),
          calibStb < Const(0),
          calibWe < Const(0),
          calibAux < Const(0, width: auxWidth),
          calibSel < Const(0, width: params.wbSelBits),
          calibAddr < Const(0, width: params.wbAddrBits),
          calibData < Const(0, width: params.wbDataBits),
          readDataStore < Const(0, width: params.wbDataBits),
          writePattern < Const(0, width: 128),
          if (selfTrain) ...[
            levelStart! < Const(0),
            levelCheck! < Const(0),
            levelPass! < Const(0, width: lanes),
            levelWait! < Const(0, width: 6),
          ],
          for (var l = 0; l < lanes; l++)
            dataStartIndex[l] < Const(0, width: 7),
          for (var l = 0; l < lanes; l++) ...[
            odelayDataCnt[l] < initOdelayData,
            odelayDqsCnt[l] < initOdelayDqs,
            idelayDataCnt[l] < initIdelayData,
            idelayDqsCnt[l] < initIdelayDqs,
            dqTargetIndex[l] < Const(0, width: idxW + 1),
            addedReadPipe[l] <
                Const(selfTrain ? phyReadPipeTicks : 0, width: 4),
            oBitslip[l] < Const(0),
            oIdelayDataLd[l] < Const(0),
            oIdelayDqsLd[l] < Const(0),
            oOdelayDataLd[l] < Const(0),
            oOdelayDqsLd[l] < Const(0),
          ],
        ],
        orElse: [
          // --- per-cycle housekeeping (1333-1376) ---
          trainDelay <
              mux(trainDelay.eq(0), Const(0, width: 4), trainDelay - 1),
          delayBeforeReadData <
              mux(
                delayBeforeReadData.eq(0),
                Const(0, width: 4),
                delayBeforeReadData - 1,
              ),
          laneTimes8 < laneReg.zeroExtend(4) << 3,
          if (selfTrain) ...[
            levelCheck! < Const(0),
            levelWait! <
                mux(levelWait.eq(0), Const(0, width: 6), levelWait - 1),
          ],
          idelayDataCntPrev < laneSlice5(idelayDataCnt, laneReg, laneW),
          resetFromCalibrateReg < Const(0),
          // ld pulses default low each cycle; states re-assert.
          for (var l = 0; l < lanes; l++) ...[
            oBitslip[l] < Const(0),
            oIdelayDataLd[l] < Const(0),
            oIdelayDqsLd[l] < Const(0),
            oOdelayDataLd[l] < Const(0),
            oOdelayDqsLd[l] < Const(0),
          ],
          // cntvaluein increments one cycle after a load pulse (1359-1365).
          for (var l = 0; l < lanes; l++)
            If(
              laneReg.eq(l) & ~done,
              then: [
                If(
                  oOdelayDataLd[l],
                  then: [odelayDataCnt[l] < odelayDataCnt[l] + 1],
                ),
                If(
                  oOdelayDqsLd[l],
                  then: [odelayDqsCnt[l] < odelayDqsCnt[l] + 1],
                ),
                If(
                  oIdelayDataLd[l],
                  then: [idelayDataCnt[l] < idelayDataCnt[l] + 1],
                ),
                If(
                  oIdelayDqsLd[l],
                  then: [idelayDqsCnt[l] < idelayDqsCnt[l] + 1],
                ),
              ],
            ),
          // initial DQS target seeding (1366-1370).
          If(
            initialDqs,
            then: [
              dqsTargetIndex < dqsTargetIndexValue,
              for (var l = 0; l < lanes; l++)
                If(
                  laneReg.eq(l),
                  then: [
                    dqTargetIndex[l] < dqsTargetIndexValue.zeroExtend(idxW + 1),
                  ],
                ),
              dqsTargetIndexOrig < dqsTargetIndexValue,
            ],
          ),
          // IDELAY-wrap handling (1371-1376): when the DQS tap sweeps past 31 and
          // wraps to 0, walk the eye-centre target back to the previous odd index
          // so it stays reachable on the wrapped range. WITHOUT this the CALIBRATE_
          // DQS eye-walk never converges when the eye is beyond the initial tap
          // (the model never needed the wrap; real silicon does).
          If(
            laneSlice5(idelayDqsCnt, laneReg, laneW).eq(0),
            then: [dqsTargetIndex < (dqsTargetIndexOrig - 2)],
          ),
          for (var l = 0; l < lanes; l++)
            If(
              laneReg.eq(l) & idelayDataCnt[l].eq(0) & idelayDataCntPrev.eq(31),
              then: [
                dqTargetIndex[l] <
                    (dqsTargetIndexOrig - 2).zeroExtend(idxW + 1),
              ],
            ),

          // --- FSM ---
          Case(state, [
            // IDLE: wait for IDELAYCTRL ready at reset instruction 13.
            CaseItem(Const(_stIdle, width: 6), [
              If(
                idelayctrlRdy & _instructionAddress.eq(13),
                then: [
                  // A self-training PHY needs no sampled-DQS calibration: go
                  // to the write phase, which writes its test pattern.
                  state <
                      Const(
                        selfTrain ? _stStartWriteLevel : _stBitslipTrain1,
                        width: 6,
                      ),
                  laneReg < Const(0, width: laneW),
                  for (var l = 0; l < lanes; l++) ...[
                    oOdelayDataLd[l] < Const(1),
                    oOdelayDqsLd[l] < Const(1),
                    oIdelayDataLd[l] < Const(1),
                    oIdelayDqsLd[l] < Const(1),
                  ],
                  pauseCounterReg < Const(1),
                  oWlCalib < Const(0),
                ],
                orElse: [
                  If(
                    _instructionAddress.eq(13),
                    then: [pauseCounterReg < Const(1)],
                  ),
                ],
              ),
            ]),
            // BITSLIP_DQS_TRAIN_1: bitslip until the reference reads 0111_1000.
            CaseItem(Const(_stBitslipTrain1, width: 6), [
              If(
                trainDelay.eq(0),
                then: [
                  If(
                    dqsRefByte.eq(0x78),
                    then: [
                      state < Const(_stMprRead, width: 6),
                      initialDqs < Const(1),
                      dqsStartIndexRepeat < Const(0),
                      dqsStartIndexStored < Const(0, width: idxW),
                    ],
                    orElse: [
                      for (var l = 0; l < lanes; l++)
                        If(laneReg.eq(l), then: [oBitslip[l] < Const(1)]),
                      trainDelay < Const(3, width: 4),
                    ],
                  ),
                ],
              ),
            ]),
            // MPR_READ: issue an MPR read, then collect the returned DQS.
            CaseItem(Const(_stMprRead, width: 6), [
              If(
                delayBeforeReadData.eq(0),
                then: [
                  delayBeforeReadData < Const(readCalDelay, width: 4),
                  state < Const(_stCollectDqs, width: 6),
                  dqsCountRepeat < Const(0, width: 4),
                ],
              ),
            ]),
            // COLLECT_DQS: shift STORED_DQS_SIZE DQS bytes into dqs_store.
            CaseItem(Const(_stCollectDqs, width: 6), [
              If(
                delayBeforeReadData.eq(0),
                then: [
                  dqsStore <
                      [
                        dqsByte,
                        dqsStore.getRange(8, _storedDqsSize * 8),
                      ].swizzle(),
                  dqsCountRepeat < dqsCountRepeat + 1,
                  If(
                    dqsCountRepeat.eq(_storedDqsSize - 1),
                    then: [
                      state < Const(_stAnalyzeDqs, width: 6),
                      dqsStartIndexStored < dqsStartIndex,
                      dqsStartIndex < Const(0, width: idxW),
                    ],
                  ),
                ],
              ),
            ]),
            // ANALYZE_DQS: scan for the 01_01_01_01_00 burst boundary; once the
            // start index repeats, advance to CALIBRATE_DQS.
            CaseItem(Const(_stAnalyzeDqs, width: 6), [
              If(
                dqsWindow.eq(_dqsAnalyzePattern),
                then: [
                  dqsStartIndexRepeat <
                      mux(
                        dqsStartIndex.eq(dqsStartIndexStored),
                        dqsStartIndexRepeat + 1,
                        Const(0, width: 1),
                      ),
                  If(
                    dqsStartIndexRepeat.eq(_repeatDqsAnalyze),
                    then: [
                      initialDqs < Const(0),
                      dqsStartIndexRepeat < Const(0),
                      state < Const(_stCalibrateDqs, width: 6),
                    ],
                    orElse: [state < Const(_stMprRead, width: 6)],
                  ),
                ],
                orElse: [
                  If(
                    dqsStartIndex.eq(_storedDqsSize * 8 - 1),
                    then: [
                      for (var l = 0; l < lanes; l++)
                        If(
                          laneReg.eq(l),
                          then: [
                            oIdelayDataLd[l] < Const(1),
                            oIdelayDqsLd[l] < Const(1),
                          ],
                        ),
                      state < Const(_stMprRead, width: 6),
                      delayBeforeReadData < Const(10, width: 4),
                    ],
                    orElse: [dqsStartIndex < dqsStartIndex + 1],
                  ),
                ],
              ),
            ]),
            // CALIBRATE_DQS: step the per-bit IDELAY until the found start index
            // reaches the (next-odd) target eye centre.
            CaseItem(Const(_stCalibrateDqs, width: 6), [
              If(
                dqsStartIndexStored.eq(dqsTargetIndex),
                then: [
                  for (var l = 0; l < lanes; l++)
                    If(
                      laneReg.eq(l),
                      then: [
                        // added_read_pipe can only be 0 or 1 (UberDDR3
                        // ddr3_controller.v:2682-2683): a lane needs at most
                        // one extra controller-clock cycle of read pipe.
                        addedReadPipe[l] <
                            mux(
                              (dqTargetIndex[l].getRange(4, 6).zeroExtend(4) +
                                      dqTargetIndex[l]
                                          .getRange(0, 4)
                                          .gte(Const(13, width: 4))
                                          .zeroExtend(4))
                                  .or(),
                              Const(1, width: 4),
                              Const(0, width: 4),
                            ),
                        dqsBitslipArrangement <
                            (Const(0x3C3C, width: 16) >>
                                dqTargetIndex[l].getRange(0, 3)),
                      ],
                    ),
                  state < Const(_stBitslipTrain2, width: 6),
                ],
                orElse: [
                  for (var l = 0; l < lanes; l++)
                    If(
                      laneReg.eq(l),
                      then: [
                        oIdelayDataLd[l] < Const(1),
                        oIdelayDqsLd[l] < Const(1),
                      ],
                    ),
                  state < Const(_stMprRead, width: 6),
                  delayBeforeReadData < Const(10, width: 4),
                ],
              ),
            ]),
            // BITSLIP_DQS_TRAIN_2: retrain the ISERDES bitslip to the computed
            // arrangement, then move to the next lane or the write phase.
            CaseItem(Const(_stBitslipTrain2, width: 6), [
              If(
                trainDelay.eq(0),
                then: [
                  If(
                    dqsRefByte.eq(dqsBitslipArrangement.getRange(0, 8)),
                    then: [
                      if (lanes > 1)
                        If(
                          laneReg.eq(lanes - 1),
                          then: [
                            pauseCounterReg < Const(0),
                            laneReg < Const(0, width: laneW),
                            oWlCalib < Const(1),
                            state < Const(_stStartWriteLevel, width: 6),
                          ],
                          orElse: [
                            laneReg < laneReg + 1,
                            state < Const(_stBitslipTrain1, width: 6),
                          ],
                        )
                      else ...[
                        pauseCounterReg < Const(0),
                        laneReg < Const(0, width: laneW),
                        oWlCalib < Const(1),
                        state < Const(_stStartWriteLevel, width: 6),
                      ],
                      // Track the highest added_read_pipe across lanes: every
                      // lane is captured on the slowest lane's cycle, so the
                      // read-ack pipe needs that lane's own delay (UberDDR3
                      // ddr3_controller.v:2757).
                      addedReadPipeMax <
                          mux(
                            addedReadPipeMax.gt(
                              laneSlice5(addedReadPipe, laneReg, laneW),
                            ),
                            addedReadPipeMax,
                            laneSlice5(addedReadPipe, laneReg, laneW),
                          ),
                    ],
                    orElse: [
                      for (var l = 0; l < lanes; l++)
                        If(laneReg.eq(l), then: [oBitslip[l] < Const(1)]),
                      trainDelay < Const(3, width: 4),
                    ],
                  ),
                ],
              ),
            ]),
            // START_WRITE_LEVEL: the Arty S7 HR bank has no ODELAYE2, so write
            // leveling is skipped (ddr3_controller.v:1497) straight to the write
            // verify. (The ODELAY-supported path is added with the write states.)
            CaseItem(
              Const(_stStartWriteLevel, width: 6),
              params.odelaySupported
                  ? [
                      // Placeholder until write leveling is ported.
                      state < Const(_stStartWriteLevel, width: 6),
                    ]
                  : [
                      pauseCounterReg < Const(0),
                      laneReg < Const(0, width: laneW),
                      oWlCalib < Const(0),
                      state < Const(_stIssueWrite1, width: 6),
                    ],
            ),
            // ISSUE_WRITE_1: write pattern W1 to address 0.
            CaseItem(Const(_stIssueWrite1, width: 6), [
              If(
                _instructionAddress.eq(22) & ~_oWbStallCalib,
                then: [
                  calibStb < Const(1),
                  calibAux < Const(0, width: auxWidth),
                  calibSel < allSel,
                  calibWe < Const(1),
                  calibAddr < Const(0, width: params.wbAddrBits),
                  calibData < Const(_calibDataW1, width: params.wbDataBits),
                  state < Const(_stIssueWrite2, width: 6),
                ],
              ),
            ]),
            // ISSUE_WRITE_2: write pattern W2 to address 1.
            CaseItem(Const(_stIssueWrite2, width: 6), [
              calibStb < Const(1),
              calibAux < Const(0, width: auxWidth),
              calibSel < allSel,
              calibWe < Const(1),
              calibAddr < Const(1, width: params.wbAddrBits),
              calibData < Const(_calibDataW2, width: params.wbDataBits),
              state < Const(_stIssueRead, width: 6),
              if (selfTrain) levelStart! < Const(1),
            ]),
            // ISSUE_READ: read back address 0 (aux=1 marks the read ack).
            CaseItem(Const(_stIssueRead, width: 6), [
              calibStb < Const(1),
              calibAux < Const(1, width: auxWidth),
              calibWe < Const(0),
              calibAddr < Const(0, width: params.wbAddrBits),
              state < Const(_stReadData, width: 6),
            ]),
            // READ_DATA: wait for the aux=1 read ack, latch the data.
            CaseItem(Const(_stReadData, width: 6), [
              If(
                _oWbAckRead.eq(readAckMarker),
                then: [
                  readDataStore < _oWbData,
                  calibStb < Const(0),
                  state <
                      Const(
                        selfTrain ? _stReadLevel : _stAnalyzeData,
                        width: 6,
                      ),
                  for (var l = 0; l < lanes; l++)
                    If(
                      laneReg.eq(l),
                      then: [dataStartIndex[l] < Const(0, width: 7)],
                    ),
                  writePattern < Const(_writePattern, width: 128),
                ],
                orElse: [
                  If(~_oWbStallCalib, then: [calibStb < Const(0)]),
                ],
              ),
            ]),
            // ANALYZE_DATA: compare the read data against write_pattern; on a full
            // per-lane match, calibration is complete (the extended BIST sweep is a
            // robustness pass added later).
            CaseItem(Const(_stAnalyzeData, width: 6), [
              If(
                writePatternWindow.eq(readGather),
                then: [
                  if (lanes > 1)
                    If(
                      laneReg.eq(lanes - 1),
                      then: [state < Const(_stDoneCalibrate, width: 6)],
                      orElse: [laneReg < laneReg + 1],
                    )
                  else
                    state < Const(_stDoneCalibrate, width: 6),
                ],
                orElse: [
                  for (var l = 0; l < lanes; l++)
                    If(
                      laneReg.eq(l),
                      then: [
                        dataStartIndex[l] < dataStartIndex[l] + 8,
                        If(
                          dataStartIndex[l].eq(56),
                          then: [
                            dataStartIndex[l] < Const(0, width: 7),
                            if (selfTrain)
                              If(
                                calAttempts!.eq(maxCalAttempts - 1),
                                then: [state < Const(_stCalFailed, width: 6)],
                                orElse: [resetFromCalibrateReg < Const(1)],
                              )
                            else
                              resetFromCalibrateReg < Const(1),
                          ],
                        ),
                      ],
                    ),
                ],
              ),
            ]),
            // DONE_CALIBRATE: stay here, on both PHY paths. Without this item
            // the unique case leaves every register it drives at X in
            // simulation the cycle after DONE, and a different synthesis tool
            // or a later netlist change could resolve the undriven case
            // differently.
            CaseItem(Const(_stDoneCalibrate, width: 6), []),
            if (selfTrain) ...[
              // READ_LEVEL: once the PHY is done, check this read (it used the
              // final setting). Else report it per lane and wait for the PHY
              // to move to its next point. In train=runtime firmware owns the
              // read path, so the check is skipped.
              CaseItem(Const(_stReadLevel, width: 6), [
                If(
                  readLevelDone!,
                  then: [
                    state <
                        Const(
                          runtimeTrainable ? _stDoneCalibrate : _stAnalyzeData,
                          width: 6,
                        ),
                  ],
                  orElse: [
                    levelCheck! < Const(1),
                    levelPass! <
                        [
                          for (var l = lanes - 1; l >= 0; l--)
                            gatherLane(l).eq(writePattern.getRange(0, 64)),
                        ].swizzle(),
                    levelWait! < Const(readLevelWaitTicks, width: 6),
                    state < Const(_stReadLevelWait, width: 6),
                  ],
                ),
              ]),
              // CAL_FAILED: stay here. The bus is open and o_cal_failed is
              // high.
              CaseItem(Const(_stCalFailed, width: 6), []),
              CaseItem(Const(_stReadLevelWait, width: 6), [
                If(
                  levelWait.eq(0),
                  then: [state < Const(_stIssueRead, width: 6)],
                ),
              ]),
            ],
            // ISSUE_WRITE_1..DONE: remaining BIST sweep states stubbed (hold).
          ], conditionalType: ConditionalType.unique),
        ],
      ),
    ]);

    // Sticky BIST-capture latch: on ANALYZE_DATA, latch the lane read gather and
    // the expected write-pattern window. NOT reset by syncRst, so the values
    // survive the calibration restart loop and stream out over UART for offline
    // read-vs-expected analysis of the write-path mismatch.
    final capRead = Logic(name: 'cap_read', width: 64);
    final capExpect = Logic(name: 'cap_expect', width: 64);
    final capValid = Logic(name: 'cap_valid');
    Sequential(clk, [
      If(
        state.eq(Const(_stAnalyzeData, width: 6)),
        then: [
          capRead < readGather,
          capExpect < writePatternWindow,
          capValid < Const(1),
        ],
      ),
    ]);

    // Combinational PHY-facing outputs. In train=runtime, once the external
    // FSBL arms the override (the first CTL APPLY sets rtActive), the four knob
    // groups follow the wb2 knob registers instead of the cal FSM. In train=hw
    // (runtimeTrainable=false) these are the unchanged FSM drives.
    if (selfTrain) {
      output('o_cal_failed') <= state.eq(_stCalFailed);
      output('o_phy_read_level_start') <= levelStart!;
      output('o_phy_read_level_check') <= levelCheck!;
      output('o_phy_read_level_pass') <= levelPass!;
      if (runtimeTrainable) {
        output('o_phy_read_clk_sel') <= _rtClkSel!.rswizzle();
      }
    }
    if (runtimeTrainable) {
      final active = _rtActive!;
      // Each APPLY that commits the bitslip knob drives one strobe cycle,
      // one slip per APPLY, on both PHY paths.
      output('o_phy_bitslip') <=
          mux(active, _rtBitslipStep!.rswizzle(), oBitslip.rswizzle());
      output('o_phy_idelay_data_ld') <=
          mux(active, _rtIdelayLd!.rswizzle(), oIdelayDataLd.rswizzle());
      output('o_phy_idelay_dqs_ld') <= oIdelayDqsLd.rswizzle();
      output('o_phy_odelay_data_ld') <=
          mux(active, _rtOdelayLd!.rswizzle(), oOdelayDataLd.rswizzle());
      output('o_phy_odelay_dqs_ld') <= oOdelayDqsLd.rswizzle();
      output('o_phy_write_leveling_calib') <=
          mux(active, laneSlice5(_rtWlevel!, _rtLaneSel!, laneW), oWlCalib);
      output('o_phy_odelay_data_cntvaluein') <=
          mux(
            active,
            laneSlice5(_rtOdelay!, _rtLaneSel!, laneW),
            laneSlice5(odelayDataCnt, laneReg, laneW),
          );
      output('o_phy_odelay_dqs_cntvaluein') <=
          laneSlice5(odelayDqsCnt, laneReg, laneW);
      output('o_phy_idelay_data_cntvaluein') <=
          mux(
            active,
            laneSlice5(_rtIdelay!, _rtLaneSel!, laneW),
            laneSlice5(idelayDataCnt, laneReg, laneW),
          );
      output('o_phy_idelay_dqs_cntvaluein') <=
          laneSlice5(idelayDqsCnt, laneReg, laneW);
    } else {
      output('o_phy_bitslip') <= oBitslip.rswizzle();
      output('o_phy_idelay_data_ld') <= oIdelayDataLd.rswizzle();
      output('o_phy_idelay_dqs_ld') <= oIdelayDqsLd.rswizzle();
      output('o_phy_odelay_data_ld') <= oOdelayDataLd.rswizzle();
      output('o_phy_odelay_dqs_ld') <= oOdelayDqsLd.rswizzle();
      output('o_phy_write_leveling_calib') <= oWlCalib;
      output('o_phy_odelay_data_cntvaluein') <=
          laneSlice5(odelayDataCnt, laneReg, laneW);
      output('o_phy_odelay_dqs_cntvaluein') <=
          laneSlice5(odelayDqsCnt, laneReg, laneW);
      output('o_phy_idelay_data_cntvaluein') <=
          laneSlice5(idelayDataCnt, laneReg, laneW);
      output('o_phy_idelay_dqs_cntvaluein') <=
          laneSlice5(idelayDqsCnt, laneReg, laneW);
    }
    // Debug word 1: [5:0]=state, [6]=reset_done, [10:7]=added_read_pipe_max,
    // [16:11]=data_start_index[0], [17]=BIST data match at index 0.
    // Words 2/3 = the lane-0 read-data gather (what ANALYZE_DATA compares).
    final gather0 = [
      for (var b = 7; b >= 0; b--) readDataStore.getRange(dq * b, dq * b + 8),
    ].swizzle();
    final match0 = writePattern.getRange(0, 64).eq(gather0);
    // Debug word 1 (IDLE-gate diagnostic): [5:0]=state, [6]=reset_done,
    // [7]=idelayctrl_rdy, [12:8]=instruction_address, [13]=match0. The two
    // IDLE-exit gates (idelayctrl_rdy and instruction_address==13) are exposed
    // so a stuck-at-IDLE can be attributed to the correct cause.
    output('o_debug1') <=
        [
          Const(0, width: 14), // pad to 32: 14+1+1+1+1+1+5+1+1+6 = 32
          capValid,
          resetFromCalibrateReg,
          pauseCounterReg,
          _syncRst,
          match0,
          _instructionAddress,
          idelayctrlRdy,
          _resetDone,
          state,
        ].swizzle();
    // Words 2/3 = the sticky-latched BIST read gather vs expected window (lane
    // in laneReg at capture); low 32 bits of each. capValid = debug1[17].
    output('o_debug2') <= capRead.getRange(0, 32);
    output('o_debug3') <= capExpect.getRange(0, 32);

    _issueReadCommand <= state.eq(_stMprRead) & delayBeforeReadData.eq(0);
    _pauseCounter <= pauseCounterReg;
    _resetFromCalibrate <= resetFromCalibrateReg;
    _writeCalibDqs <= writeCalibDqs;
    _writeCalibDq <= writeCalibDq;
    _addedReadPipeMax <= addedReadPipeMax;
    for (var l = 0; l < lanes; l++) {
      _addedReadPipeLane[l] <= addedReadPipe[l];
    }
    _stateCalibrate <= state;
    _calibStb <= calibStb;
    _calibWe <= calibWe;
    _calibAux <= calibAux;
    _calibSel <= calibSel;
    _calibAddr <= calibAddr;
    _calibData <= calibData;
  }

  /// Lane-selected 5-bit register from a per-lane list.
  Logic laneSlice5(List<Logic> regs, Logic laneReg, int laneW) => cases(
    laneReg,
    {for (var l = 0; l < regs.length; l++) Const(l, width: laneW): regs[l]},
    defaultValue: regs[0],
    conditionalType: ConditionalType.unique,
  );

  /// Tie off the outputs whose driving blocks are not yet ported. o_wb_stall is
  /// held high (busy) so no SoC request is accepted before calibration completes.
  void _tieOffUnbuilt() {
    // wb2 register file: tied off in train=hw. When runtimeTrainable, the
    // knob-ABI block in _buildWb2Knobs drives these instead.
    if (!runtimeTrainable) {
      output('o_wb2_stall') <= Const(1);
      output('o_wb2_ack') <= Const(0);
      output('o_wb2_data') <= Const(0, width: wb2DataBits);
    }
  }

  /// Build the wb2 knob-ABI register file (train=runtime).
  ///
  /// This port decodes wb2Addr as a bus-width-independent register index (one
  /// per knob-ABI register, contiguous 0..6). The SoC-facing byte layout (the
  /// contract genip/FSBL use) is 8-byte-strided; the wrapper ([HarborDdr3])
  /// converts the fabric word address to this register index for whatever SoC
  /// bus width it sits behind, so the byte offsets below stay fixed:
  ///
  ///   index 0 (byte 0x00) WLEVEL  rw  per-lane write-leveling override
  ///   index 1 (byte 0x08) ODELAY  rw  per-lane write odelay tap (5-bit)
  ///   index 2 (byte 0x10) IDELAY  rw  per-lane read idelay tap (5-bit)
  ///   index 3 (byte 0x18) BITSLIP rw  per-lane bitslip level
  ///   index 4 (byte 0x20) CTL     wo  bit0 SET, bit1 LOAD/APPLY, [11:8] lane
  ///   index 5 (byte 0x28) STATUS  ro  bit0 BUSY, bit8 WL-done, [23:16] WL map
  ///   index 6 (byte 0x30) CAP     ro  bit0 active, [7:4] lanes, [15:8] tapMax,
  ///                                   [19:16] slipMax
  ///   index 7 (byte 0x38) RDCLKSEL rw per-lane read clock select (3-bit),
  ///                                   only with a self-training PHY
  ///
  /// With a self-training PHY, each LOAD/APPLY of a written BITSLIP of 1
  /// sends one bitslip step pulse, and slipMax is 15.
  ///
  /// The knob value/read data are 32-bit; on a wider SoC bus the wrapper takes
  /// the low 32 bits of the write word and zero-extends the read word.
  ///
  /// Knob write protocol (one knob per transaction): write the knob value,
  /// then CTL SET (with the lane in [11:8]), then CTL LOAD/APPLY. LOAD commits
  /// every knob that was written since the last LOAD into the selected lane,
  /// pulses the matching PHY load strobe, arms the override and raises BUSY for
  /// one cycle.
  void _buildWb2Knobs(Logic clk, Logic rstN) {
    final laneW = _lanesClog2;

    // Register indices (byteOffset >> 3; the wrapper maps the fabric word
    // address to this index for its bus width).
    const wWlevel = 0;
    const wOdelay = 1;
    const wIdelay = 2;
    const wBitslip = 3;
    const wCtl = 4;
    const wStatus = 5;
    const wCap = 6;
    const wRdClkSel = 7;
    final selfTrain = phySelfTrainsRead;

    final wb2Cyc = input('i_wb2_cyc');
    final wb2Stb = input('i_wb2_stb');
    final wb2We = input('i_wb2_we');
    final wb2Addr = input('i_wb2_addr');
    final wb2Data = input('i_wb2_data');

    final access = wb2Cyc & wb2Stb;
    final write = access & wb2We;

    // Staged (shadow) knob values + per-knob dirty flags.
    final shOdelay = Logic(name: 'rt_sh_odelay', width: 5);
    final shIdelay = Logic(name: 'rt_sh_idelay', width: 5);
    final shBitslip = Logic(name: 'rt_sh_bitslip');
    final shWlevel = Logic(name: 'rt_sh_wlevel');
    final dOdelay = Logic(name: 'rt_dirty_odelay');
    final dIdelay = Logic(name: 'rt_dirty_idelay');
    final dBitslip = Logic(name: 'rt_dirty_bitslip');
    final dWlevel = Logic(name: 'rt_dirty_wlevel');
    final shClkSel = selfTrain ? Logic(name: 'rt_sh_clk_sel', width: 3) : null;
    final dClkSel = selfTrain ? Logic(name: 'rt_dirty_clk_sel') : null;
    final rtClkSel = selfTrain
        ? [
            for (var l = 0; l < lanes; l++)
              Logic(name: 'rt_clk_sel_$l', width: 3),
          ]
        : null;
    // One-cycle strobe per lane, one pulse per APPLY that commits the
    // bitslip knob. Used on both PHY paths so a held knob value cannot
    // drive a held BITSLIP level into ISERDESE2.
    final rtBitslipStep = [
      for (var l = 0; l < lanes; l++) Logic(name: 'rt_bitslip_step_$l'),
    ];
    _rtClkSel = rtClkSel;
    _rtBitslipStep = rtBitslipStep;

    final laneSel = Logic(name: 'rt_lane_sel', width: laneW);
    final active = Logic(name: 'rt_active');
    final busy = Logic(name: 'rt_busy');

    final rtOdelay = [
      for (var l = 0; l < lanes; l++) Logic(name: 'rt_odelay_$l', width: 5),
    ];
    final rtIdelay = [
      for (var l = 0; l < lanes; l++) Logic(name: 'rt_idelay_$l', width: 5),
    ];
    final rtBitslip = [
      for (var l = 0; l < lanes; l++) Logic(name: 'rt_bitslip_$l'),
    ];
    final rtWlevel = [
      for (var l = 0; l < lanes; l++) Logic(name: 'rt_wlevel_$l'),
    ];
    final rtOdelayLd = [
      for (var l = 0; l < lanes; l++) Logic(name: 'rt_odelay_ld_$l'),
    ];
    final rtIdelayLd = [
      for (var l = 0; l < lanes; l++) Logic(name: 'rt_idelay_ld_$l'),
    ];

    _rtOdelay = rtOdelay;
    _rtIdelay = rtIdelay;
    _rtBitslip = rtBitslip;
    _rtWlevel = rtWlevel;
    _rtOdelayLd = rtOdelayLd;
    _rtIdelayLd = rtIdelayLd;
    _rtLaneSel = laneSel;
    _rtActive = active;

    final setLane = write & wb2Addr.eq(wCtl) & wb2Data[0];
    final apply = write & wb2Addr.eq(wCtl) & wb2Data[1];

    Sequential(clk, [
      If(
        ~rstN,
        then: [
          shOdelay < Const(0, width: 5),
          shIdelay < Const(0, width: 5),
          shBitslip < Const(0),
          shWlevel < Const(0),
          dOdelay < Const(0),
          dIdelay < Const(0),
          dBitslip < Const(0),
          dWlevel < Const(0),
          laneSel < Const(0, width: laneW),
          active < Const(0),
          busy < Const(0),
          if (selfTrain) ...[
            shClkSel! < Const(0, width: 3),
            dClkSel! < Const(0),
            for (var l = 0; l < lanes; l++) rtClkSel![l] < Const(0, width: 3),
          ],
          for (var l = 0; l < lanes; l++) ...[
            rtOdelay[l] < Const(0, width: 5),
            rtIdelay[l] < Const(0, width: 5),
            rtBitslip[l] < Const(0),
            rtBitslipStep[l] < Const(0),
            rtWlevel[l] < Const(0),
            rtOdelayLd[l] < Const(0),
            rtIdelayLd[l] < Const(0),
          ],
        ],
        orElse: [
          // One-cycle strobes default low.
          busy < Const(0),
          for (var l = 0; l < lanes; l++) ...[
            rtOdelayLd[l] < Const(0),
            rtIdelayLd[l] < Const(0),
            rtBitslipStep[l] < Const(0),
          ],
          if (selfTrain) ...[
            If(
              write & wb2Addr.eq(wRdClkSel),
              then: [shClkSel! < wb2Data.getRange(0, 3), dClkSel! < Const(1)],
            ),
            If(
              apply,
              then: [
                dClkSel < Const(0),
                for (var l = 0; l < lanes; l++)
                  If(
                    laneSel.eq(l),
                    then: [
                      If(dClkSel, then: [rtClkSel![l] < shClkSel]),
                    ],
                  ),
              ],
            ),
          ],
          // Knob-register writes stage a value + raise the dirty flag.
          If(
            write & wb2Addr.eq(wOdelay),
            then: [shOdelay < wb2Data.getRange(0, 5), dOdelay < Const(1)],
          ),
          If(
            write & wb2Addr.eq(wIdelay),
            then: [shIdelay < wb2Data.getRange(0, 5), dIdelay < Const(1)],
          ),
          If(
            write & wb2Addr.eq(wBitslip),
            then: [shBitslip < wb2Data[0], dBitslip < Const(1)],
          ),
          If(
            write & wb2Addr.eq(wWlevel),
            then: [shWlevel < wb2Data[0], dWlevel < Const(1)],
          ),
          // CTL SET latches the lane selector.
          If(setLane, then: [laneSel < wb2Data.getRange(8, 8 + laneW)]),
          // CTL LOAD/APPLY commits every dirty knob into the selected lane.
          If(
            apply,
            then: [
              active < Const(1),
              busy < Const(1),
              dOdelay < Const(0),
              dIdelay < Const(0),
              dBitslip < Const(0),
              dWlevel < Const(0),
              for (var l = 0; l < lanes; l++)
                If(
                  laneSel.eq(l),
                  then: [
                    If(
                      dOdelay,
                      then: [rtOdelay[l] < shOdelay, rtOdelayLd[l] < Const(1)],
                    ),
                    If(
                      dIdelay,
                      then: [rtIdelay[l] < shIdelay, rtIdelayLd[l] < Const(1)],
                    ),
                    If(dBitslip, then: [rtBitslip[l] < shBitslip]),
                    // One strobe cycle per APPLY that commits a bitslip
                    // value of 1. ISERDESE2 BITSLIP needs a pulse, not a
                    // held level, to slip exactly once (UG471).
                    If(
                      dBitslip & shBitslip,
                      then: [rtBitslipStep[l] < Const(1)],
                    ),
                    If(dWlevel, then: [rtWlevel[l] < shWlevel]),
                  ],
                ),
            ],
          ),
        ],
      ),
    ]);

    // Read response: knob read-backs, STATUS and CAP. Registered one cycle
    // (classic pipelined wishbone; the window never stalls).
    final readData = cases(
      wb2Addr,
      {
        Const(wWlevel, width: wb2AddrBits): laneSlice5(
          rtWlevel,
          laneSel,
          laneW,
        ).zeroExtend(wb2DataBits),
        Const(wOdelay, width: wb2AddrBits): laneSlice5(
          rtOdelay,
          laneSel,
          laneW,
        ).zeroExtend(wb2DataBits),
        Const(wIdelay, width: wb2AddrBits): laneSlice5(
          rtIdelay,
          laneSel,
          laneW,
        ).zeroExtend(wb2DataBits),
        Const(wBitslip, width: wb2AddrBits): laneSlice5(
          rtBitslip,
          laneSel,
          laneW,
        ).zeroExtend(wb2DataBits),
        Const(wStatus, width: wb2AddrBits): [
          Const(0, width: 8), // [31:24]
          Const(0, width: 8), // [23:16] WL feedback map (placeholder)
          Const(0, width: 7), // [15:9]
          Const(0), // [8] WL-done (placeholder)
          // [1] calibration failed (self-training PHY only)
          if (selfTrain) ...[
            Const(0, width: 6), // [7:2]
            output('o_cal_failed'),
          ] else
            Const(0, width: 7), // [7:1]
          busy, // [0] BUSY
        ].swizzle(),
        if (selfTrain)
          Const(wRdClkSel, width: wb2AddrBits): laneSlice5(
            rtClkSel!,
            laneSel,
            laneW,
          ).zeroExtend(wb2DataBits),
        Const(wCap, width: wb2AddrBits): [
          Const(0, width: 12), // [31:20]
          Const(selfTrain ? 15 : 7, width: 4), // [19:16] slipMax
          Const(31, width: 8), // [15:8] tapMax
          Const(lanes, width: 4), // [7:4] lanes
          Const(0, width: 3), // [3:1]
          active, // [0] runtimeActive
        ].swizzle(),
      },
      defaultValue: Const(0, width: wb2DataBits),
      conditionalType: ConditionalType.unique,
    );

    final ackReg = Logic(name: 'rt_wb2_ack');
    final dataReg = Logic(name: 'rt_wb2_data', width: wb2DataBits);
    Sequential(clk, [
      If(
        ~rstN,
        then: [
          ackReg < Const(0),
          dataReg < Const(0, width: wb2DataBits),
        ],
        orElse: [ackReg < access, dataReg < readData],
      ),
    ]);

    output('o_wb2_stall') <= Const(0);
    output('o_wb2_ack') <= ackReg;
    output('o_wb2_data') <= dataReg;
  }
}

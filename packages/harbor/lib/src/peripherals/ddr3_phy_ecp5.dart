import 'package:rohd/rohd.dart';

import '../blackbox/ecp5/ecp5.dart';
import 'ddr3_params.dart';
import 'ddr3_phy_base.dart';
import 'ddr3_timing.dart';

/// Lattice ECP5 DDR3 PHY for [Ddr3Controller], ported from litedram's
/// `ECP5DDRPHY` (litedram/phy/ecp5ddrphy.py) and its 1:4 wrapper
/// `ecp5ddrphy_with_ratio`. Simulation-proven only: no ECP5 board has run it.
///
/// The ECP5 DQ/DQS cells gear 2:1 (CK to CK/2). The controller talks CK/4, so
/// this PHY puts a synchronous 2:1 regear between the two, the way the litedram
/// wrapper does. ECLKSYNCB, CLKDIVF, and DDRDLLA make the CK and CK/2 clocks
/// from `ddr3Clk`.
///
/// Clock contract: `controllerClk` (CK/4) and `ddr3Clk` (CK) come from one
/// PLL with aligned rising edges. The regear depends on it.
///
/// ECP5 cannot sample the received DQS (DQSBUFM.DQSI must be its only load), so
/// the controller's sampled-DQS calibration does not apply. This PHY levels its
/// own read path ([selfTrainsRead]): a READCLKSEL x bitslip sweep judged by the
/// controller's test read (litedram BIOS `sdram_read_leveling`). With
/// [runtimeTrainable] the sweep is not built and firmware sets READCLKSEL,
/// bitslip, and the DELAYF read taps through the controller knob window.
class Ddr3PhyEcp5 extends Ddr3PhyBase {
  final DdrParams params;

  /// Firmware owns read leveling (train=runtime).
  final bool runtimeTrainable;

  /// DM pad `l` (in DQS group `l`) carries the mask of lane
  /// `dmRemapping[l]`. Identity when null. litedram uses `{0: 1, 1: 0}` on
  /// the OrangeCrab r0.2.
  final List<int>? dmRemapping;

  /// Require BURSTDET as well as good read data for a passing leveling point.
  final bool useBurstDet;

  /// Controller ticks added to the read return path. The controller adds
  /// these to its read capture pipe.
  static const int readPipeTicks = 6;

  int get lanes => params.lanes;
  int get dq => params.dqBits * lanes;

  @override
  bool get selfTrainsRead => true;

  @override
  Logic get readLevelDone => output('o_controller_read_level_done');

  @override
  Logic get idelayctrlRdy => output('o_controller_idelayctrl_rdy');
  @override
  Logic get iserdesData => output('o_controller_iserdes_data');
  @override
  Logic get iserdesDqs => output('o_controller_iserdes_dqs');
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

  Ddr3PhyEcp5(
    this.params, {
    required Logic controllerClk,
    required Logic ddr3Clk,
    required Logic refClk,
    required Logic ddr3Clk90,
    required Logic rstN,
    required Logic controllerReset,
    required Logic cmd,
    required Logic dqsTriControl,
    required Logic dqTriControl,
    required Logic toggleDqs,
    required Logic data,
    required Logic dm,
    required Logic odelayDataCntValueIn,
    required Logic odelayDqsCntValueIn,
    required Logic idelayDataCntValueIn,
    required Logic idelayDqsCntValueIn,
    required Logic odelayDataLd,
    required Logic odelayDqsLd,
    required Logic idelayDataLd,
    required Logic idelayDqsLd,
    required Logic bitslip,
    required Logic writeLevelingCalib,
    required Logic readLevelStart,
    required Logic readLevelCheck,
    required Logic readLevelPass,
    Logic? readClkSel,
    required LogicNet dqPad,
    required LogicNet dqsPad,
    required LogicNet dqsNPad,
    this.runtimeTrainable = false,
    this.dmRemapping,
    this.useBurstDet = true,
    super.name = 'ddr3_phy_ecp5',
  }) {
    if (params.gearRatio != 1) {
      throw ArgumentError.value(
        params.gearRatio,
        'params.gearRatio',
        'the ECP5 PHY needs a CK/4 controller (gearRatio 1)',
      );
    }
    if (runtimeTrainable && readClkSel == null) {
      throw ArgumentError.notNull('readClkSel');
    }
    final remap = dmRemapping ?? [for (var l = 0; l < lanes; l++) l];
    if (remap.length != lanes) {
      throw ArgumentError.value(dmRemapping, 'dmRemapping', 'one per lane');
    }

    controllerClk = addInput('i_controller_clk', controllerClk);
    ddr3Clk = addInput('i_ddr3_clk', ddr3Clk);
    // No ECP5 use: DQSBUFM makes the write strobes and DDRDLLA is
    // referenced to ddr3Clk.
    addInput('i_ref_clk', refClk);
    addInput('i_ddr3_clk_90', ddr3Clk90);
    rstN = addInput('i_rst_n', rstN);
    controllerReset = addInput('i_controller_reset', controllerReset);

    final cmdLen =
        4 + 3 + params.baBits + params.rowBits + (params.dualRankDimm ? 2 : 0);
    cmd = addInput('i_controller_cmd', cmd, width: cmdLen * 4);
    // litedram derives the DQ/DQS output enables, preamble, and postamble
    // from the write command, so the controller's Xilinx-timed tristate and
    // toggle controls are not used.
    addInput('i_controller_dqs_tri_control', dqsTriControl);
    addInput('i_controller_dq_tri_control', dqTriControl);
    addInput('i_controller_toggle_dqs', toggleDqs);
    data = addInput('i_controller_data', data, width: params.wbDataBits);
    dm = addInput('i_controller_dm', dm, width: params.wbSelBits);
    // ECP5 has no output delay in this datapath, and the DQS read delay is the
    // DDRDLLA code, so the write taps and the DQS read tap are not used.
    addInput(
      'i_controller_odelay_data_cntvaluein',
      odelayDataCntValueIn,
      width: 5,
    );
    addInput(
      'i_controller_odelay_dqs_cntvaluein',
      odelayDqsCntValueIn,
      width: 5,
    );
    idelayDataCntValueIn = addInput(
      'i_controller_idelay_data_cntvaluein',
      idelayDataCntValueIn,
      width: 5,
    );
    addInput(
      'i_controller_idelay_dqs_cntvaluein',
      idelayDqsCntValueIn,
      width: 5,
    );
    addInput('i_controller_odelay_data_ld', odelayDataLd, width: lanes);
    addInput('i_controller_odelay_dqs_ld', odelayDqsLd, width: lanes);
    idelayDataLd = addInput(
      'i_controller_idelay_data_ld',
      idelayDataLd,
      width: lanes,
    );
    addInput('i_controller_idelay_dqs_ld', idelayDqsLd, width: lanes);
    bitslip = addInput('i_controller_bitslip', bitslip, width: lanes);
    // ECP5 DDR3 is not write leveled (litedram), and the controller skips
    // write leveling when odelaySupported is false.
    addInput('i_controller_write_leveling_calib', writeLevelingCalib);
    readLevelStart = addInput('i_controller_read_level_start', readLevelStart);
    readLevelCheck = addInput('i_controller_read_level_check', readLevelCheck);
    readLevelPass = addInput(
      'i_controller_read_level_pass',
      readLevelPass,
      width: lanes,
    );
    final rtClkSel = runtimeTrainable
        ? addInput('i_controller_read_clk_sel', readClkSel!, width: 3 * lanes)
        : null;
    final dqPadIo = addInOut('io_ddr3_dq', dqPad, width: dq);
    final dqsPadIo = addInOut('io_ddr3_dqs', dqsPad, width: lanes);
    // DQS is one SSTL135D pad. nextpnr drives the complement ball itself.
    addInOut('io_ddr3_dqs_n', dqsNPad, width: lanes);

    addOutput('o_controller_iserdes_data', width: dq * 8);
    addOutput('o_controller_iserdes_dqs', width: lanes * 8);
    addOutput('o_controller_iserdes_bitslip_reference', width: lanes * 8);
    addOutput('o_controller_idelayctrl_rdy');
    addOutput('o_controller_read_level_done');

    // --- DDRDLLA init timeline and the edge-clock tree ---
    final porRst = ~rstN;
    final initLock = Logic(name: 'dll_lock');
    final init = Ddr3Ecp5Init(
      clk: controllerClk,
      reset: porRst,
      lock: initLock,
    );

    // The fabric (the regear phase and every CK/2 register) stays in reset
    // until the init timeline is done, so it starts after ECLK and CLKDIVF
    // restart. It is a CK/4 register, so it releases on a CK/4 edge and the
    // regear takes the CK/2 edge between two CK/4 edges.
    final fabRst = Logic(name: 'fabric_reset');
    Sequential(controllerClk, [
      fabRst < (porRst | controllerReset | ~init.done),
    ]);
    final tree = Ecp5DdrClockTree(
      ddr3Clk,
      porRst,
      uddcntln: init.uddcntln,
      freeze: init.freeze,
      eclkStop: init.stop,
      eclkReset: init.ioReset,
      alignwd: Const(0),
      name: 'ddr_clk_tree',
    );
    initLock <= tree.lock;
    final eclk = tree.eclk;
    final sclk = tree.sclk;
    // litedram io_rst_init: the IO gearing resets from the init pulse, which
    // falls while ECLK is stopped, so every IOLOGIC starts on one ECLK edge.
    final ioRst = init.ioReset;
    output('o_controller_idelayctrl_rdy') <= init.done;

    // --- CK/4 -> CK/2 transmit regear ---
    // In reset the command pipe holds a deselect: CS_n, RAS_n, CAS_n, WE_n
    // high, and ODT, CKE, RESET_n low.
    final idleSlot = BigInt.from(0xF) << (cmdLen - 4);
    final idleHalf = idleSlot | (idleSlot << cmdLen);
    final idleCmd = idleHalf | (idleHalf << (2 * cmdLen));
    final cmdTx = Ddr3Ecp5TxRegear(
      ctrlClk: controllerClk,
      sclk: sclk,
      reset: fabRst,
      word: cmd,
      idleWord: idleCmd,
      name: 'cmd_tx_regear',
    );
    final dataTx = Ddr3Ecp5TxRegear(
      ctrlClk: controllerClk,
      sclk: sclk,
      reset: fabRst,
      word: [dm, data].swizzle(),
      name: 'data_tx_regear',
    );
    // Two more CK/2 cycles on the commands put the write data, captured one
    // CK/4 tick later, at litedram's write_latency (cwl_sys_latency cycles
    // after the command).
    final cmdD1 = Logic(name: 'cmd_half_d1', width: cmdLen * 2);
    final cmdS = Logic(name: 'cmd_half_d2', width: cmdLen * 2);
    Sequential(
      sclk,
      reset: fabRst,
      resetValues: {
        cmdD1: Const(idleHalf, width: cmdLen * 2),
        cmdS: Const(idleHalf, width: cmdLen * 2),
      },
      [cmdD1 < cmdTx.half, cmdS < cmdD1],
    );
    final dataS = dataTx.full.getRange(0, params.wbDataBits);
    final dmS = dataTx.full.getRange(
      params.wbDataBits,
      params.wbDataBits + params.wbSelBits,
    );

    // --- command / address pads: ODDRX2F, two half-CK beats per command ---
    Logic slotBit(int slot, int bit) => cmdS[cmdLen * slot + bit];
    Logic cmdPad(int bit, String name) {
      final o = Ecp5Oddrx2f(
        d0: slotBit(0, bit),
        d1: slotBit(0, bit),
        d2: slotBit(1, bit),
        d3: slotBit(1, bit),
        sclk: sclk,
        eclk: eclk,
        rst: ioRst,
        name: '${name}_oddr',
      );
      return Ecp5Delayg(a: o.q, name: '${name}_delay').z;
    }

    Logic ckPad(int pattern, String name) {
      final o = Ecp5Oddrx2f(
        d0: Const(pattern & 1),
        d1: Const((pattern >> 1) & 1),
        d2: Const((pattern >> 2) & 1),
        d3: Const((pattern >> 3) & 1),
        sclk: sclk,
        eclk: eclk,
        rst: ioRst,
        name: '${name}_oddr',
      );
      return Ecp5Delayg(a: o.q, name: '${name}_delay').z;
    }

    addOutput('o_ddr3_clk_p') <= ckPad(0xA, 'ck_p');
    addOutput('o_ddr3_clk_n') <= ckPad(0x5, 'ck_n');
    addOutput('o_ddr3_cs_n') <= cmdPad(cmdLen - 1, 'cs_n');
    addOutput('o_ddr3_ras_n') <= cmdPad(cmdLen - 2, 'ras_n');
    addOutput('o_ddr3_cas_n') <= cmdPad(cmdLen - 3, 'cas_n');
    addOutput('o_ddr3_we_n') <= cmdPad(cmdLen - 4, 'we_n');
    addOutput('o_ddr3_odt') <= cmdPad(cmdLen - 5, 'odt');
    addOutput('o_ddr3_cke') <= cmdPad(cmdLen - 6, 'cke');
    addOutput('o_ddr3_reset_n') <= cmdPad(cmdLen - 7, 'reset_n');
    addOutput('o_ddr3_ba_addr', width: params.baBits) <=
        [
          for (var i = params.baBits - 1; i >= 0; i--)
            cmdPad(params.rowBits + i, 'ba_$i'),
        ].swizzle();
    addOutput('o_ddr3_addr', width: params.rowBits) <=
        [
          for (var i = params.rowBits - 1; i >= 0; i--) cmdPad(i, 'addr_$i'),
        ].swizzle();

    // --- read / write enable delay lines (litedram TappedDelayLine) ---
    Logic slotIs(int slot, int cmd3) =>
        ~slotBit(slot, cmdLen - 1) &
        cmdS
            .getRange(cmdLen * slot + cmdLen - 4, cmdLen * slot + cmdLen - 1)
            .eq(cmd3);
    final rdEn = slotIs(0, 0x5) | slotIs(1, 0x5);
    final wrEn = slotIs(0, 0x4) | slotIs(1, 0x4);
    final clSys = (DdrTiming.clNck + 1) ~/ 2;
    final cwlSys = (DdrTiming.cwlNck + 1) ~/ 2;
    List<Logic> taps(Logic input, int n, String name) {
      final t = [for (var i = 0; i < n; i++) Logic(name: '${name}_$i')];
      Sequential(sclk, reset: fabRst, [
        for (var i = 0; i < n; i++) t[i] < (i == 0 ? input : t[i - 1]),
      ]);
      return t;
    }

    final rdTaps = taps(rdEn, clSys + 2, 'rddata_en');
    final wrTaps = taps(wrEn, cwlSys + 4, 'wrdata_en');
    // DQSBUFM READ is high for the 2 CK/2 cycles before the read data
    // (Lattice FPGA-TN-02035 6.2.4).
    final dqsRe = (rdTaps[clSys] | rdTaps[clSys + 1]).named('dqs_re');
    final dqOe = (wrTaps[cwlSys] | wrTaps[cwlSys + 1]).named('dq_oe');
    final bl8Chunk = wrTaps[cwlSys];
    final dqsPreamble = (wrTaps[cwlSys - 1] & ~wrTaps[cwlSys]).named(
      'dqs_preamble',
    );
    final dqsPostamble = (wrTaps[cwlSys + 2] & ~wrTaps[cwlSys + 1]).named(
      'dqs_postamble',
    );

    // --- read leveling: hardware sweep, or knob-driven in train=runtime ---
    final burstSeen = Logic(name: 'burst_seen', width: lanes);
    final clearBurst = Logic(name: 'clear_burst');
    final List<Logic> laneClkSel;
    final List<Logic> laneSlip;
    final List<Logic> lanePause;
    if (runtimeTrainable) {
      laneClkSel = [
        for (var l = 0; l < lanes; l++) rtClkSel!.getRange(3 * l, 3 * l + 3),
      ];
      laneSlip = [];
      lanePause = [];
      for (var l = 0; l < lanes; l++) {
        final slip = Logic(
          name: 'rt_slip_$l',
          width: Ddr3Ecp5ReadLeveler.slipBits,
        );
        Sequential(controllerClk, reset: fabRst, [
          If(bitslip[l], then: [slip < slip + 1]),
        ]);
        laneSlip.add(slip);
        // Hold PAUSE for a few cycles around a READCLKSEL change.
        final prev = Logic(name: 'rt_clk_sel_prev_$l', width: 3);
        final hold = Logic(name: 'rt_pause_$l', width: 4);
        Sequential(controllerClk, reset: fabRst, [
          prev < laneClkSel[l],
          If(
            prev.neq(laneClkSel[l]),
            then: [hold < Const(8, width: 4)],
            orElse: [
              If(hold.neq(0), then: [hold < hold - 1]),
            ],
          ),
        ]);
        lanePause.add(hold.neq(0) | prev.neq(laneClkSel[l]));
      }
      clearBurst <= Const(0);
      output('o_controller_read_level_done') <= init.done;
    } else {
      final lev = Ddr3Ecp5ReadLeveler(
        lanes: lanes,
        clk: controllerClk,
        reset: fabRst,
        start: readLevelStart,
        check: readLevelCheck,
        pass: readLevelPass,
        burstSeen: burstSeen,
        useBurstDet: useBurstDet,
      );
      laneClkSel = [
        for (var l = 0; l < lanes; l++)
          lev.readClkSel.getRange(3 * l, 3 * l + 3),
      ];
      laneSlip = [
        for (var l = 0; l < lanes; l++)
          lev.slip.getRange(
            Ddr3Ecp5ReadLeveler.slipBits * l,
            Ddr3Ecp5ReadLeveler.slipBits * (l + 1),
          ),
      ];
      lanePause = [for (var l = 0; l < lanes; l++) lev.pause];
      clearBurst <= lev.clearBurst;
      output('o_controller_read_level_done') <= lev.done;
    }

    // --- per DQS group: DQSBUFM, DQS, DM, and the DQ bits ---
    final readHalf = List<Logic?>.filled(dq * 4, null);
    final dmPads = <Logic>[];
    final burstBits = <Logic>[];
    for (var l = 0; l < lanes; l++) {
      // DQS pad.
      final dqsOut = Logic(name: 'dqs_out_$l');
      final dqsT = Logic(name: 'dqs_t_$l');
      final dqsBb = Ecp5Bb(
        i: dqsOut,
        t: dqsT,
        b: dqsPadIo[l],
        name: 'dqs_bb_$l',
      );
      final bufm = Ecp5Dqsbufm(
        dqsi: dqsBb.o,
        read0: dqsRe,
        read1: dqsRe,
        readclksel: laneClkSel[l],
        ddrdel: tree.ddrdel,
        eclk: eclk,
        sclk: sclk,
        rst: ioRst,
        // LOADN low keeps the DDRDEL code in control (litedram).
        rdloadn: Const(0),
        rdmove: Const(0),
        rddirection: Const(1),
        wrloadn: Const(0),
        wrmove: Const(0),
        wrdirection: Const(1),
        pause: init.pause | lanePause[l],
        name: 'dqsbufm_$l',
      );
      dqsOut <=
          Ecp5Oddrx2dqsb(
            d0: Const(0),
            d1: Const(1),
            d2: Const(0),
            d3: Const(1),
            dqsw: bufm.dqsw,
            sclk: sclk,
            eclk: eclk,
            rst: ioRst,
            name: 'dqs_oddr_$l',
          ).q;
      dqsT <=
          Ecp5Tshx2dqsa(
            t0: ~(dqOe | dqsPostamble),
            t1: ~(dqOe | dqsPreamble),
            dqsw: bufm.dqsw,
            sclk: sclk,
            eclk: eclk,
            rst: ioRst,
            name: 'dqs_tsh_$l',
          ).q;

      // BURSTDET seen since the leveler last cleared it.
      final seen = Logic(name: 'burstdet_seen_$l');
      Sequential(sclk, reset: fabRst, [
        If(
          clearBurst,
          then: [seen < Const(0)],
          orElse: [
            If(bufm.burstdet, then: [seen < Const(1)]),
          ],
        ),
      ]);
      burstBits.add(seen);

      // Write gearing shared by DM and DQ (litedram bl8_chunk mux).
      Logic writeBeats(List<Logic> beats, String name) {
        final o = beats.rswizzle().named('${name}_o_data');
        final od = Logic(name: '${name}_o_data_d', width: 8);
        final muxed = Logic(name: '${name}_o_data_muxed', width: 4);
        Sequential(sclk, reset: fabRst, [
          od < o,
          muxed < mux(bl8Chunk, od.getRange(4, 8), o.getRange(0, 4)),
        ]);
        return muxed;
      }

      // DM pad l is in DQS group l and carries lane remap[l].
      final dmLane = remap[l];
      final dmMux = writeBeats([
        for (var b = 0; b < 8; b++) dmS[dmLane + lanes * b],
      ], 'dm_$l');
      dmPads.add(
        Ecp5Oddrx2dqa(
          d0: dmMux[0],
          d1: dmMux[1],
          d2: dmMux[2],
          d3: dmMux[3],
          dqsw270: bufm.dqsw270,
          sclk: sclk,
          eclk: eclk,
          rst: ioRst,
          name: 'dm_oddr_$l',
        ).q,
      );

      // DELAYF step control for train=runtime: load to 0, then MOVE up to the
      // requested tap.
      Logic? delayLoadn;
      Logic? delayMove;
      if (runtimeTrainable) {
        final loadn = Logic(name: 'rdly_loadn_$l');
        final move = Logic(name: 'rdly_move_$l');
        final remain = Logic(name: 'rdly_remain_$l', width: 5);
        Sequential(
          controllerClk,
          reset: fabRst,
          resetValues: {loadn: 1},
          [
            If(
              idelayDataLd[l],
              then: [
                loadn < Const(0),
                move < Const(0),
                remain < idelayDataCntValueIn,
              ],
              orElse: [
                loadn < Const(1),
                If(
                  remain.neq(0),
                  then: [
                    move < ~move,
                    If(move, then: [remain < remain - 1]),
                  ],
                  orElse: [move < Const(0)],
                ),
              ],
            ),
          ],
        );
        delayLoadn = loadn;
        delayMove = move;
      }

      for (var j = 0; j < params.dqBits; j++) {
        final gi = l * params.dqBits + j;
        final dqMux = writeBeats([
          for (var b = 0; b < 8; b++) dataS[gi + dq * b],
        ], 'dq_$gi');
        final dqOut = Ecp5Oddrx2dqa(
          d0: dqMux[0],
          d1: dqMux[1],
          d2: dqMux[2],
          d3: dqMux[3],
          dqsw270: bufm.dqsw270,
          sclk: sclk,
          eclk: eclk,
          rst: ioRst,
          name: 'dq_oddr_$gi',
        ).q;
        final dqT = Ecp5Tshx2dqa(
          t0: ~dqOe,
          t1: ~dqOe,
          dqsw270: bufm.dqsw270,
          sclk: sclk,
          eclk: eclk,
          rst: ioRst,
          name: 'dq_tsh_$gi',
        ).q;
        final bb = Ecp5Bb(i: dqOut, t: dqT, b: dqPadIo[gi], name: 'dq_bb_$gi');
        final delayed = runtimeTrainable
            ? Ecp5Delayf(
                a: bb.o,
                loadn: delayLoadn!,
                move: delayMove!,
                direction: Const(0),
                delMode: 'DQS_ALIGNED_X2',
                name: 'dq_delay_$gi',
              ).z
            : Ecp5Delayg(
                a: bb.o,
                delMode: 'DQS_ALIGNED_X2',
                name: 'dq_delay_$gi',
              ).z;
        final iddr = Ecp5Iddrx2dqa(
          d: delayed,
          dqsr90: bufm.dqsr90,
          rdpntr: bufm.rdpntr,
          wrpntr: bufm.wrpntr,
          eclk: eclk,
          sclk: sclk,
          rst: ioRst,
          name: 'dq_iddr_$gi',
        );
        // One register, then a litedram BitSlip over Ddr3Ecp5ReadLeveler
        // .bitslips beat positions.
        final q = [iddr.q3, iddr.q2, iddr.q1, iddr.q0].swizzle();
        final qd = Logic(name: 'dq_i_d_$gi', width: 4);
        final rw = 4 * (Ddr3Ecp5ReadLeveler.bitslips ~/ 4 + 1);
        final r = Logic(name: 'dq_i_bitslip_r_$gi', width: rw);
        Sequential(sclk, reset: fabRst, [
          qd < q,
          r < [qd, r.getRange(4, rw)].swizzle(),
        ]);
        final o = (r >>> laneSlip[l].zeroExtend(r.width)).getRange(0, 4);
        for (var b = 0; b < 4; b++) {
          readHalf[dq * b + gi] = o[b];
        }
      }
    }
    addOutput('o_ddr3_dm', width: lanes) <= dmPads.rswizzle();
    burstSeen <= burstBits.rswizzle();

    // --- CK/2 -> CK/4 receive regear ---
    final rx = Ddr3Ecp5RxRegear(
      ctrlClk: controllerClk,
      sclk: sclk,
      reset: fabRst,
      half: [for (final b in readHalf) b!].rswizzle(),
      name: 'read_rx_regear',
    );
    output('o_controller_iserdes_data') <= rx.word;
    // ECP5 cannot sample DQS, and the bitslip is fabric, so these Xilinx
    // calibration returns stay low. The controller does not read them when
    // the PHY self-trains.
    output('o_controller_iserdes_dqs') <= Const(0, width: lanes * 8);
    output('o_controller_iserdes_bitslip_reference') <=
        Const(0, width: lanes * 8);
  }
}

/// Synchronous CK/4 to CK/2 transmit regear (litedram `RateSerializer`).
///
/// The CK/4 word is registered, then taken into the CK/2 domain on the CK/2
/// edge between two CK/4 edges. [half] gives the low half, then the high half.
/// [full] holds the whole word for both CK/2 cycles. [reset] must come from a
/// CK/4 register so the capture edge is the middle one. The two clocks must
/// come from one PLL with aligned rising edges. In reset every register holds
/// [idleWord] (zero when null).
class Ddr3Ecp5TxRegear extends Module {
  Logic get half => output('o_half');
  Logic get full => output('o_full');

  Ddr3Ecp5TxRegear({
    required Logic ctrlClk,
    required Logic sclk,
    required Logic reset,
    required Logic word,
    BigInt? idleWord,
    super.name = 'ecp5_tx_regear',
  }) : super(
         definitionName:
             'Ddr3Ecp5TxRegear_W${word.width}${idleWord == null ? '' : '_I'}',
       ) {
    if (word.width.isOdd) {
      throw ArgumentError.value(word.width, 'word.width', 'must be even');
    }
    final w = word.width ~/ 2;
    ctrlClk = addInput('i_ctrl_clk', ctrlClk);
    sclk = addInput('i_sclk', sclk);
    reset = addInput('i_reset', reset);
    word = addInput('i_word', word, width: 2 * w);
    final halfO = addOutput('o_half', width: w);
    final fullO = addOutput('o_full', width: 2 * w);

    final idle = idleWord ?? BigInt.zero;
    final idleLo = idle & ((BigInt.one << w) - BigInt.one);
    final idleHi = idle >> w;
    final wordD = Logic(name: 'word_d', width: 2 * w);
    Sequential(
      ctrlClk,
      reset: reset,
      resetValues: {wordD: Const(idle, width: 2 * w)},
      [wordD < word],
    );
    final ph = Logic(name: 'ph');
    final hi = Logic(name: 'hi', width: w);
    Sequential(
      sclk,
      reset: reset,
      resetValues: {
        halfO: Const(idleLo, width: w),
        hi: Const(idleHi, width: w),
        fullO: Const(idle, width: 2 * w),
      },
      [
        ph < ~ph,
        If(
          ph.eq(0),
          then: [
            halfO < wordD.getRange(0, w),
            hi < wordD.getRange(w, 2 * w),
            fullO < wordD,
          ],
          orElse: [halfO < hi],
        ),
      ],
    );
  }
}

/// Synchronous CK/2 to CK/4 receive regear (litedram `RateDeserializer` with
/// shift 0). Two consecutive CK/2 words form one CK/4 word, the earlier one in
/// the low half. [reset] must come from a CK/4 register.
class Ddr3Ecp5RxRegear extends Module {
  Logic get word => output('o_word');

  Ddr3Ecp5RxRegear({
    required Logic ctrlClk,
    required Logic sclk,
    required Logic reset,
    required Logic half,
    super.name = 'ecp5_rx_regear',
  }) : super(definitionName: 'Ddr3Ecp5RxRegear_W${half.width}') {
    final w = half.width;
    ctrlClk = addInput('i_ctrl_clk', ctrlClk);
    sclk = addInput('i_sclk', sclk);
    reset = addInput('i_reset', reset);
    half = addInput('i_half', half, width: w);
    final wordO = addOutput('o_word', width: 2 * w);

    final ph = Logic(name: 'ph');
    final p1 = Logic(name: 'p1', width: w);
    final pair = Logic(name: 'pair', width: 2 * w);
    Sequential(sclk, reset: reset, [
      ph < ~ph,
      p1 < half,
      If(
        ph.eq(0),
        then: [
          pair < [half, p1].swizzle(),
        ],
      ),
    ]);
    // Taken half a CK/4 period after the CK/2 capture.
    Sequential(ctrlClk, reset: reset, [wordO < pair]);
  }
}

/// ECP5 read leveling in hardware, after the LiteX BIOS `sdram_read_leveling`
/// (litex/soc/software/liblitedram/sdram.c). Each lane is leveled at the same
/// time.
///
/// For each bitslip, then each READCLKSEL value (litedram "delay"), the
/// controller reads a known pattern back and pulses [check] with a per-lane
/// [pass]. The bitslip with the most passing delays wins (the first one on a
/// tie). The delay is the centre of the widest passing run on that bitslip,
/// by the `sdram_leveling_center_module` rules.
///
/// [pause] follows litedram (`sdram_select`, action, `sdram_deselect` in
/// liblitedram/accessors.c): it is high around each READCLKSEL and bitslip
/// change, then pulses once more to sync the DQSBUFMs. It is low during every
/// test write and read. The first point needs no change, so it has no pulse.
class Ddr3Ecp5ReadLeveler extends Module {
  /// DQSBUFM READCLKSEL values (litedram `delays`).
  static const int delays = 8;

  /// Fabric bitslip positions, in DDR beats.
  static const int bitslips = 16;
  static const int slipBits = 4;

  // Point-change sequence in CK/4 cycles: PAUSE high, change the setting,
  // PAUSE high (Lattice wants 4T on each side), PAUSE low, the litedram sync
  // pulse, then settle. The controller waits longer than all of this (plus
  // the scoring) before its next test read.
  static const int _seqApply = 4;
  static const int _seqPauseOff = 9;
  static const int _seqSyncOn = 11;
  static const int _seqSyncOff = 13;
  static const int _seqEnd = 17;

  /// CK/4 cycles from a [check] to the next point being ready, or from the
  /// last [check] to [done] (scoring included).
  static const int maxBusyCycles = bitslips + 2 + _seqEnd + 1;

  final int lanes;
  final bool useBurstDet;

  Logic get readClkSel => output('o_read_clk_sel');
  Logic get slip => output('o_slip');
  Logic get pause => output('o_pause');
  Logic get done => output('o_done');
  Logic get clearBurst => output('o_clear_burst');

  /// The litedram centre of an 8-bit pass vector (bit d = delay d passed).
  /// [ok] is false when no two consecutive delays pass.
  static ({bool ok, int mid}) center(int vec) {
    bool p(int d) => (vec >> d) & 1 == 1;
    var delay = 0;
    var working = false;
    var delayMin = -1;
    while (true) {
      final last = working;
      working = p(delay);
      if (working && last && delayMin < 0) {
        delayMin = delay - 1;
        break;
      }
      delay++;
      if (delay >= delays) break;
    }
    if (delayMin < 0) return (ok: false, mid: 0);
    var delayMax = delayMin;
    var curMin = delayMin;
    while (true) {
      if (p(delay)) {
        if (delay - curMin > delayMax - delayMin) {
          delayMin = curMin;
          delayMax = delay;
        }
      } else {
        curMin = delay + 1;
      }
      delay++;
      if (delay >= delays) break;
    }
    return (ok: true, mid: ((delayMin + delayMax) ~/ 2) % delays);
  }

  /// Delay chosen for a vector: the centre, else the first passing delay.
  static int chosenDelay(int vec) {
    final c = center(vec);
    if (c.ok) return c.mid;
    for (var d = 0; d < delays; d++) {
      if ((vec >> d) & 1 == 1) return d;
    }
    return 0;
  }

  static const int _stIdle = 0;
  static const int _stApply = 1;
  static const int _stWait = 2;
  static const int _stScore = 3;
  static const int _stCenter = 4;
  static const int _stDone = 5;

  Ddr3Ecp5ReadLeveler({
    required this.lanes,
    required Logic clk,
    required Logic reset,
    required Logic start,
    required Logic check,
    required Logic pass,
    required Logic burstSeen,
    this.useBurstDet = true,
    super.name = 'ecp5_read_leveler',
  }) {
    clk = addInput('i_clk', clk);
    reset = addInput('i_reset', reset);
    start = addInput('i_start', start);
    check = addInput('i_check', check);
    pass = addInput('i_pass', pass, width: lanes);
    burstSeen = addInput('i_burst_seen', burstSeen, width: lanes);
    addOutput('o_read_clk_sel', width: 3 * lanes);
    addOutput('o_slip', width: slipBits * lanes);
    addOutput('o_pause');
    addOutput('o_done');
    addOutput('o_clear_burst');

    const vecW = bitslips * delays;
    final state = Logic(name: 'state', width: 3);
    final b = Logic(name: 'slip_idx', width: slipBits);
    final d = Logic(name: 'delay_idx', width: 3);
    final seq = Logic(name: 'seq', width: 5);
    final nb = Logic(name: 'next_slip_idx', width: slipBits);
    final nd = Logic(name: 'next_delay_idx', width: 3);
    final toFinal = Logic(name: 'to_final');
    final applied = Logic(name: 'final_applied');
    final sb = Logic(name: 'score_idx', width: slipBits);
    final vec = [
      for (var l = 0; l < lanes; l++) Logic(name: 'pass_vec_$l', width: vecW),
    ];
    final bestCnt = [
      for (var l = 0; l < lanes; l++) Logic(name: 'best_cnt_$l', width: 4),
    ];
    final bestB = [
      for (var l = 0; l < lanes; l++)
        Logic(name: 'best_slip_$l', width: slipBits),
    ];
    final finB = [
      for (var l = 0; l < lanes; l++)
        Logic(name: 'final_slip_$l', width: slipBits),
    ];
    final finD = [
      for (var l = 0; l < lanes; l++) Logic(name: 'final_delay_$l', width: 3),
    ];

    Logic slice(Logic v, Logic idx) =>
        (v >>> [idx, Const(0, width: 3)].swizzle().zeroExtend(v.width))
            .getRange(0, delays);
    Logic popcount(Logic v) => [
      for (var i = 0; i < delays; i++) v[i].zeroExtend(4),
    ].reduce((a, c) => a + c);
    final table = <Logic, Logic>{
      for (var v = 0; v < 256; v++)
        Const(v, width: 8): Const(chosenDelay(v), width: 3),
    };
    Logic centreOf(Logic v8) => cases(
      v8,
      table,
      defaultValue: Const(0, width: 3),
      conditionalType: ConditionalType.unique,
    );
    final pointIdx = [b, d].swizzle().zeroExtend(8);
    final pointBit = (Const(1, width: vecW) << pointIdx).named('point_bit');

    Sequential(clk, reset: reset, [
      Case(state, [
        CaseItem(Const(_stIdle, width: 3), [
          If(
            start,
            then: [
              b < Const(0, width: slipBits),
              d < Const(0, width: 3),
              for (var l = 0; l < lanes; l++) vec[l] < Const(0, width: vecW),
              state < Const(_stWait, width: 3),
            ],
          ),
        ]),
        CaseItem(Const(_stWait, width: 3), [
          If(
            check,
            then: [
              for (var l = 0; l < lanes; l++)
                If(
                  useBurstDet ? pass[l] & burstSeen[l] : pass[l],
                  then: [vec[l] < (vec[l] | pointBit)],
                ),
              If(
                d.eq(delays - 1) & b.eq(bitslips - 1),
                then: [
                  sb < Const(0, width: slipBits),
                  for (var l = 0; l < lanes; l++) ...[
                    bestCnt[l] < Const(0, width: 4),
                    bestB[l] < Const(0, width: slipBits),
                  ],
                  state < Const(_stScore, width: 3),
                ],
                orElse: [
                  nd < mux(d.eq(delays - 1), Const(0, width: 3), d + 1),
                  nb < mux(d.eq(delays - 1), b + 1, b),
                  toFinal < Const(0),
                  seq < Const(0, width: 5),
                  state < Const(_stApply, width: 3),
                ],
              ),
            ],
          ),
        ]),
        CaseItem(Const(_stApply, width: 3), [
          seq < seq + 1,
          If(
            seq.eq(_seqApply),
            then: [
              If(toFinal, then: [applied < Const(1)], orElse: [b < nb, d < nd]),
            ],
          ),
          If(
            seq.eq(_seqEnd),
            then: [
              state <
                  mux(
                    toFinal,
                    Const(_stDone, width: 3),
                    Const(_stWait, width: 3),
                  ),
            ],
          ),
        ]),
        CaseItem(Const(_stScore, width: 3), [
          for (var l = 0; l < lanes; l++)
            If(
              popcount(slice(vec[l], sb)).gt(bestCnt[l]),
              then: [bestCnt[l] < popcount(slice(vec[l], sb)), bestB[l] < sb],
            ),
          If(
            sb.eq(bitslips - 1),
            then: [state < Const(_stCenter, width: 3)],
            orElse: [sb < sb + 1],
          ),
        ]),
        CaseItem(Const(_stCenter, width: 3), [
          for (var l = 0; l < lanes; l++) ...[
            finB[l] < bestB[l],
            finD[l] < centreOf(slice(vec[l], bestB[l])),
          ],
          toFinal < Const(1),
          seq < Const(0, width: 5),
          state < Const(_stApply, width: 3),
        ]),
        CaseItem(Const(_stDone, width: 3), []),
      ]),
    ]);

    final inApply = state.eq(_stApply);
    output('o_done') <= state.eq(_stDone);
    output('o_pause') <=
        inApply &
            ((seq.lt(_seqPauseOff)) |
                (seq.gte(_seqSyncOn) & seq.lt(_seqSyncOff)));
    output('o_clear_burst') <= state.eq(_stIdle) | inApply;
    output('o_read_clk_sel') <=
        [for (var l = 0; l < lanes; l++) mux(applied, finD[l], d)].rswizzle();
    output('o_slip') <=
        [for (var l = 0; l < lanes; l++) mux(applied, finB[l], b)].rswizzle();
  }
}

/// The litedram `ECP5DDRPHYInit` timeline. After DDRDLLA locks it freezes the
/// DLL, stops and resets the ECLK domain, then loads the DDRDEL code into the
/// DQSBUFMs (UDDCNTLN low inside a PAUSE window). [done] rises after the last
/// step. Runs on a clock that ECLKSYNCB STOP does not stop.
class Ddr3Ecp5Init extends Module {
  /// litedram step length in cycles.
  static const int step = 8;

  Logic get freeze => output('o_freeze');
  Logic get stop => output('o_stop');
  Logic get ioReset => output('o_io_reset');
  Logic get pause => output('o_pause');
  Logic get uddcntln => output('o_uddcntln');
  Logic get done => output('o_done');

  Ddr3Ecp5Init({
    required Logic clk,
    required Logic reset,
    required Logic lock,
    super.name = 'ecp5_ddr_init',
  }) {
    clk = addInput('i_clk', clk);
    reset = addInput('i_reset', reset);
    lock = addInput('i_lock', lock);

    // MultiReg, then a rising-edge detect.
    final lockS = Logic(name: 'lock_s', width: 2);
    final lockD = Logic(name: 'lock_d');
    final running = Logic(name: 'running');
    final cnt = Logic(name: 'count', width: 7);
    final freezeR = Logic(name: 'freeze');
    final stopR = Logic(name: 'stop');
    final resetR = Logic(name: 'io_reset');
    final pauseR = Logic(name: 'pause');
    final updateR = Logic(name: 'update');
    final doneR = Logic(name: 'done');
    final newLock = lockS[1] & ~lockD;

    Conditional at(int n, List<Conditional> then) => If(cnt.eq(n), then: then);
    Sequential(clk, reset: reset, [
      lockS < [lockS[0], lock].swizzle(),
      lockD < lockS[1],
      If(
        newLock & ~running & ~doneR,
        then: [running < Const(1), cnt < Const(0, width: 7)],
      ),
      If(
        running,
        then: [
          cnt < cnt + 1,
          at(1 * step, [freezeR < Const(1)]),
          at(2 * step, [stopR < Const(1)]),
          at(3 * step, [resetR < Const(1)]),
          at(4 * step, [resetR < Const(0)]),
          at(5 * step, [stopR < Const(0)]),
          at(6 * step, [freezeR < Const(0)]),
          at(7 * step, [pauseR < Const(1)]),
          at(8 * step, [updateR < Const(1)]),
          at(9 * step, [updateR < Const(0)]),
          at(10 * step, [pauseR < Const(0)]),
          at(10 * step + 1, [doneR < Const(1), running < Const(0)]),
        ],
      ),
    ]);
    addOutput('o_freeze') <= freezeR;
    addOutput('o_stop') <= stopR;
    addOutput('o_io_reset') <= resetR;
    addOutput('o_pause') <= pauseR;
    addOutput('o_uddcntln') <= ~updateR;
    addOutput('o_done') <= doneR;
  }
}

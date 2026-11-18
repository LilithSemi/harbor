import 'dart:io';

import 'package:harbor/src/blackbox/xilinx/xilinx.dart';
import 'package:harbor/src/peripherals/ddr3_controller.dart';
import 'package:harbor/src/peripherals/ddr3_params.dart';
import 'package:harbor/src/peripherals/ddr3_phy.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Standalone DDR3 calibration bring-up harness for the Arty S7. Instantiates
/// the Dart [Ddr3Controller] + [Ddr3Phy] on an MMCM clock tree off the 100 MHz
/// oscillator, drives the DDR3 pads, and puts the calibration progress on the
/// four user LEDs. No SoC / wishbone traffic: the controller just runs its
/// power-up + calibration sequence so the LEDs show whether (and where) it
/// calibrates on real silicon.
///
/// LED map (latched to the furthest progress reached):
///   led0 = IDELAYCTRL ready (clock tree + IDELAYCTRL locked)
///   led1 = read calibration progressing (reached BITSLIP_DQS_TRAIN_2, state 6)
///   led2 = read calibration done, write phase (reached ISSUE_WRITE_1, state 9)
///   led3 = DONE_CALIBRATE (fully calibrated, state 23)
class Ddr3CalHarness extends BridgeModule {
  Ddr3CalHarness() : super('creek_ddr3_cal') {
    final clk100 = addInput('clk100', Logic());

    // 300 MHz DDR CK (the creek_hack-proven point); controller = CK/4 = 75 MHz.
    final p = DdrParams.artyS7(ckPeriodPs: 3333);
    final clocks = buildXilinxDdr3ClockTree(
      this,
      source: clk100,
      sourceHz: 100000000,
      ddrCkHz: 300000000,
    );
    final cclk = clocks.controller;

    // Power-on reset: hold rst_n low for 4096 controller cycles after config
    // (registers power up at 0), then release. Independent of MMCM LOCKED
    // (which may not reach the fabric on openXC7).
    final porCnt = Logic(name: 'por_cnt', width: 12);
    final rstN = Logic(name: 'rst_n');
    Sequential(cclk, [
      If(
        porCnt.lt(4095),
        then: [porCnt < porCnt + 1, rstN < Const(0)],
        orElse: [rstN < Const(1)],
      ),
    ]);

    // DDR3 bidirectional pads: create the top-level inout ports first, then pass
    // their nets into the PHY (the harbor idiom - a fresh LogicNet passed to both
    // addInOut sites does NOT bridge across the submodule boundary).
    final dq = p.dqBits * p.lanes;
    createPort('ddr3_dq', PortDirection.inOut, width: dq);
    createPort('ddr3_dqs_p', PortDirection.inOut, width: p.lanes);
    createPort('ddr3_dqs_n', PortDirection.inOut, width: p.lanes);
    final dqPad = inOut('ddr3_dq') as LogicNet;
    final dqsPad = inOut('ddr3_dqs_p') as LogicNet;
    final dqsNPad = inOut('ddr3_dqs_n') as LogicNet;

    // Placeholder PHY-return nets, driven from the PHY after it is built (breaks
    // the controller<->PHY construction cycle).
    final phyDataNet = Logic(name: 'phy_iserdes_data', width: dq * 8);
    final phyDqsNet = Logic(name: 'phy_iserdes_dqs', width: p.lanes * 8);
    final phyBsRefNet = Logic(name: 'phy_iserdes_bsref', width: p.lanes * 8);
    final phyRdyNet = Logic(name: 'phy_idelayctrl_rdy');

    // --- full-array memtest master ---------------------------------------
    // After calibration reaches DONE, this wishbone master writes an address-
    // derived pattern across 2^testAddrBits burst words (crossing DRAM rows and
    // banks), reads them all back, and compares. Pass/fail + counters go to the
    // LEDs and the UART. Loops forever so refresh/retention faults latch.
    const testAddrBits = 22; // 64 MiB, many banks+rows
    final wbAB = p.wbAddrBits;
    final wbDB = p.wbDataBits;
    final wbSB = p.wbSelBits;
    Logic mreg(String n, int w) => Logic(name: n, width: w);
    final memState = mreg('mt_state', 3); // 0 wait,1 write,2 read,3 drain
    final wAddr = mreg('mt_waddr', testAddrBits + 1);
    final rAddr = mreg('mt_raddr', testAddrBits + 1);
    final aAddr = mreg('mt_aaddr', testAddrBits + 1);
    final passCount = mreg('mt_pass', 8);
    final errCount = mreg('mt_err', 16);
    final failLatched = mreg('mt_faillatch', 1);
    final failAddr = mreg('mt_failaddr', testAddrBits);
    final failExp = mreg('mt_failexp', wbDB);
    final failRead = mreg('mt_failread', wbDB);
    final drainCnt = mreg('mt_drain', 10); // let writes retire before reads
    final calDoneSeen = mreg('mt_caldone', 1);
    final hb = mreg('mt_hb', 26);
    // wishbone master drive wires
    final mCyc = Logic(name: 'mt_cyc');
    final mStb = Logic(name: 'mt_stb');
    final mWe = Logic(name: 'mt_we');
    final mAddr = Logic(name: 'mt_addr_o', width: wbAB);
    final mData = Logic(name: 'mt_data_o', width: wbDB);
    final mSel = Logic(name: 'mt_sel_o', width: wbSB);
    final mAux = Logic(name: 'mt_aux_o', width: Ddr3Controller.auxWidth);
    // Address-derived 128-bit burst pattern: 8 beats, each = addr_lo16 ^ addr_hi
    // ^ const_b, so every burst word across the whole 4 MiB span is distinct
    // (high address bits fold in, catching row/bank aliasing). Takes the full
    // (testAddrBits-wide) address.
    const patConsts = [
      0x0000,
      0x1111,
      0x2222,
      0x3333,
      0xcccc,
      0xdddd,
      0xeeee,
      0xffff,
    ];
    Logic pat(Logic addr) {
      final lo = addr.getRange(0, 16);
      final hi = testAddrBits > 16
          ? addr.getRange(16, testAddrBits).zeroExtend(16)
          : Const(0, width: 16);
      return [
        for (var b = 7; b >= 0; b--) (lo ^ hi ^ Const(patConsts[b], width: 16)),
      ].concat();
    }

    // Controller: driven by the memtest master.
    final ctrl = Ddr3Controller(
      p,
      controllerClk: cclk,
      rstN: rstN,
      wbCyc: mCyc,
      wbStb: mStb,
      wbWe: mWe,
      wbAddr: mAddr,
      wbData: mData,
      wbSel: mSel,
      aux: mAux,
      wb2Cyc: Const(0),
      wb2Stb: Const(0),
      wb2We: Const(0),
      wb2Addr: Const(0, width: Ddr3Controller.wb2AddrBits),
      wb2Sel: Const(0, width: Ddr3Controller.wb2SelBits),
      wb2Data: Const(0, width: Ddr3Controller.wb2DataBits),
      phyIserdesData: phyDataNet,
      phyIserdesDqs: phyDqsNet,
      phyIserdesBitslipReference: phyBsRefNet,
      phyIdelayctrlRdy: phyRdyNet,
    );

    // PHY: driven by the controller outputs.
    final phy = Ddr3Phy(
      p,
      controllerClk: cclk,
      ddr3Clk: clocks.ddrCk,
      refClk: clocks.idelayRef,
      ddr3Clk90: clocks.ddrCk90,
      rstN: rstN,
      controllerReset: ctrl.phyReset,
      cmd: ctrl.phyCmd,
      dqsTriControl: ctrl.output('o_phy_dqs_tri_control'),
      dqTriControl: ctrl.output('o_phy_dq_tri_control'),
      toggleDqs: ctrl.output('o_phy_toggle_dqs'),
      data: ctrl.output('o_phy_data'),
      dm: ctrl.output('o_phy_dm'),
      odelayDataCntValueIn: ctrl.output('o_phy_odelay_data_cntvaluein'),
      odelayDqsCntValueIn: ctrl.output('o_phy_odelay_dqs_cntvaluein'),
      idelayDataCntValueIn: ctrl.output('o_phy_idelay_data_cntvaluein'),
      idelayDqsCntValueIn: ctrl.output('o_phy_idelay_dqs_cntvaluein'),
      odelayDataLd: ctrl.output('o_phy_odelay_data_ld'),
      odelayDqsLd: ctrl.output('o_phy_odelay_dqs_ld'),
      idelayDataLd: ctrl.output('o_phy_idelay_data_ld'),
      idelayDqsLd: ctrl.output('o_phy_idelay_dqs_ld'),
      bitslip: ctrl.output('o_phy_bitslip'),
      writeLevelingCalib: ctrl.output('o_phy_write_leveling_calib'),
      dqPad: dqPad,
      dqsPad: dqsPad,
      dqsNPad: dqsNPad,
    );

    // Close the loop: drive the placeholder nets from the PHY read-returns.
    phyDataNet <= phy.iserdesData;
    phyDqsNet <= phy.iserdesDqs;
    phyBsRefNet <= phy.iserdesBitslipReference;
    phyRdyNet <= phy.idelayctrlRdy;

    // DDR3 pads to the top level (constrained by the XDC).
    addOutput('ddr3_ck_p') <= phy.output('o_ddr3_clk_p');
    addOutput('ddr3_ck_n') <= phy.output('o_ddr3_clk_n');
    addOutput('ddr3_cs_n') <= phy.output('o_ddr3_cs_n');
    addOutput('ddr3_ras_n') <= phy.output('o_ddr3_ras_n');
    addOutput('ddr3_cas_n') <= phy.output('o_ddr3_cas_n');
    addOutput('ddr3_we_n') <= phy.output('o_ddr3_we_n');
    addOutput('ddr3_odt') <= phy.output('o_ddr3_odt');
    addOutput('ddr3_cke') <= phy.output('o_ddr3_cke');
    addOutput('ddr3_reset_n') <= phy.output('o_ddr3_reset_n');
    addOutput('ddr3_ba', width: p.baBits) <= phy.output('o_ddr3_ba_addr');
    addOutput('ddr3_addr', width: p.rowBits) <= phy.output('o_ddr3_addr');
    addOutput('ddr3_dm', width: p.lanes) <= phy.output('o_ddr3_dm');

    // --- memtest wishbone master + status ---------------------------------
    final stall = ctrl.output('o_wb_stall');
    final ack = ctrl.output('o_wb_ack');
    final rdata = ctrl.output('o_wb_data');
    final calDone = ctrl.debug1.getRange(0, 6).eq(Const(23, width: 6));
    final nWords = Const(1 << testAddrBits, width: testAddrBits + 1);
    final nWordsM1 = Const((1 << testAddrBits) - 1, width: testAddrBits + 1);
    final allSel = Const((BigInt.one << wbSB) - BigInt.one, width: wbSB);

    // Combinational wishbone drive off the master state.
    Combinational([
      mCyc < Const(0),
      mStb < Const(0),
      mWe < Const(0),
      mAddr < Const(0, width: wbAB),
      mData < Const(0, width: wbDB),
      mSel < Const(0, width: wbSB),
      mAux < Const(1, width: Ddr3Controller.auxWidth),
      If(
        memState.eq(1),
        then: [
          mCyc < Const(1),
          mStb < Const(1),
          mWe < Const(1),
          mAddr < wAddr.getRange(0, testAddrBits).zeroExtend(wbAB),
          mData < pat(wAddr),
          mSel < allSel,
        ],
      ),
      If(
        memState.eq(2),
        then: [
          // READ_ISSUE: one outstanding read at a time (non-pipelined) at aAddr.
          mCyc < Const(1),
          mStb < Const(1),
          mAddr < aAddr.getRange(0, testAddrBits).zeroExtend(wbAB),
        ],
      ),
      If(memState.eq(3), then: [mCyc < Const(1)]),
      If(memState.eq(4), then: [mCyc < Const(1)]), // write-drain
      If(memState.eq(6), then: [mCyc < Const(1)]), // READ_WAIT (stb low)
    ]);

    Sequential(cclk, [
      If(
        ~rstN,
        then: [
          memState < Const(0, width: 3),
          wAddr < Const(0, width: testAddrBits + 1),
          rAddr < Const(0, width: testAddrBits + 1),
          aAddr < Const(0, width: testAddrBits + 1),
          passCount < Const(0, width: 8),
          errCount < Const(0, width: 16),
          failLatched < Const(0),
          failAddr < Const(0, width: testAddrBits),
          failExp < Const(0, width: wbDB),
          failRead < Const(0, width: wbDB),
          drainCnt < Const(0, width: 10),
          calDoneSeen < Const(0),
          hb < Const(0, width: 26),
        ],
        orElse: [
          hb < hb + 1,
          If(calDone, then: [calDoneSeen < Const(1)]),
          // read-ack compare (non-pipelined: one outstanding read at a time).
          If(
            ack & (memState.eq(2) | memState.eq(6)),
            then: [
              If(
                rdata.neq(pat(aAddr)),
                then: [
                  errCount < errCount + 1,
                  If(
                    ~failLatched,
                    then: [
                      failLatched < Const(1),
                      failAddr < aAddr.getRange(0, testAddrBits),
                      failExp < pat(aAddr),
                      failRead < rdata,
                    ],
                  ),
                ],
              ),
              aAddr < aAddr + 1,
            ],
          ),
          Case(memState, [
            CaseItem(Const(0, width: 3), [
              If(
                calDone,
                then: [
                  memState < Const(1, width: 3),
                  wAddr < Const(0, width: testAddrBits + 1),
                  rAddr < Const(0, width: testAddrBits + 1),
                  aAddr < Const(0, width: testAddrBits + 1),
                ],
              ),
            ]),
            CaseItem(Const(1, width: 3), [
              If(
                ~stall,
                then: [
                  wAddr < wAddr + 1,
                  If(
                    wAddr.eq(nWordsM1),
                    then: [
                      memState < Const(4, width: 3), // write-drain
                      drainCnt < Const(1023, width: 10),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(4, width: 3), [
              If(
                drainCnt.eq(0),
                then: [memState < Const(2, width: 3)],
                orElse: [drainCnt < drainCnt - 1],
              ),
            ]),
            CaseItem(Const(2, width: 3), [
              // READ_ISSUE: when the read is accepted, wait for its ack.
              If(~stall, then: [memState < Const(6, width: 3)]),
            ]),
            CaseItem(Const(6, width: 3), [
              // READ_WAIT: on the ack (which advances aAddr), issue the next read
              // or finish the pass when the last address was read.
              If(
                ack,
                then: [
                  If(
                    aAddr.eq(nWordsM1),
                    then: [memState < Const(3, width: 3)],
                    orElse: [memState < Const(2, width: 3)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(3, width: 3), [
              If(
                aAddr.eq(nWords),
                then: [
                  passCount < passCount + 1,
                  memState < Const(1, width: 3),
                  wAddr < Const(0, width: testAddrBits + 1),
                  rAddr < Const(0, width: testAddrBits + 1),
                  aAddr < Const(0, width: testAddrBits + 1),
                ],
              ),
            ]),
          ], defaultItem: []),
        ],
      ),
    ]);

    // LEDs (board order reversed: physical LDn = led[3-n], so physical read is
    // LD0=fail, LD1=pass, LD2=running-blink, LD3=cal-done).
    final ledFail = failLatched;
    final ledPass = passCount.gt(Const(0, width: 8)) & ~failLatched;
    final ledRunning = hb[24];
    final ledCalDone = calDoneSeen;
    addOutput('led', width: 4) <=
        [ledFail, ledPass, ledRunning, ledCalDone].concat();

    // --- UART status frame (13 bytes): 0xAA, d1, d2, d3 (LSB-first 32-bit words).
    // d1[2:0]=mem_state, [3]=cal_done, [4]=fail, [12:5]=pass_count,
    // [28:13]=err_count. d2 = first-fail expected lo32. d3 = {failAddr, failRead
    // lo16}. All-pass shows fail=0, err=0, pass_count climbing.
    const frameLen = 13;
    final d1 = [
      Const(0, width: 3),
      errCount,
      passCount,
      failLatched,
      calDoneSeen,
      memState,
    ].concat();
    final d2 = failExp.getRange(0, 32);
    final d3 = [failAddr.getRange(0, 16), failRead.getRange(0, 16)].concat();
    Logic frameByte(Logic idx) {
      final map = <Logic, Logic>{Const(0, width: 6): Const(0xAA, width: 8)};
      for (var i = 0; i < 4; i++) {
        map[Const(1 + i, width: 6)] = d1.getRange(i * 8, i * 8 + 8);
        map[Const(5 + i, width: 6)] = d2.getRange(i * 8, i * 8 + 8);
        map[Const(9 + i, width: 6)] = d3.getRange(i * 8, i * 8 + 8);
      }
      return cases(
        idx,
        map,
        defaultValue: Const(0, width: 8),
        conditionalType: ConditionalType.unique,
      );
    }

    // Derive the baud divisor from the ACTUAL controller clock the MMCM
    // realizes (not an assumed value - the solver may pick a different VCO).
    // 9600 baud, matching the proven openXC7 ddr3-test-arty-s7 demo (slow but
    // rock-solid over the FT2232 channel-B UART). At 75 MHz the divisor is
    // 7812, so the counter needs 16 bits.
    final baudDiv = (clocks.controllerMhz * 1e6 / 9600).round();
    final baudCnt = Logic(name: 'baud_cnt', width: 16);
    final bitCnt = Logic(name: 'bit_cnt', width: 4);
    final shiftReg = Logic(name: 'uart_sh', width: 10);
    final sending = Logic(name: 'uart_sending');
    final frameIdx = Logic(name: 'frame_idx', width: 6);
    Sequential(cclk, [
      If(
        ~rstN,
        then: [
          baudCnt < Const(0, width: 16),
          bitCnt < Const(0, width: 4),
          shiftReg < Const(0x3FF, width: 10),
          sending < Const(0),
          frameIdx < Const(0, width: 6),
        ],
        orElse: [
          If(
            ~sending,
            then: [
              // load the next frame byte: {stop=1, data[7:0], start=0}.
              shiftReg < [Const(1), frameByte(frameIdx), Const(0)].concat(),
              sending < Const(1),
              bitCnt < Const(10, width: 4),
              baudCnt < Const(baudDiv - 1, width: 16),
              frameIdx <
                  mux(
                    frameIdx.eq(frameLen - 1),
                    Const(0, width: 6),
                    frameIdx + 1,
                  ),
            ],
            orElse: [
              If(
                baudCnt.eq(0),
                then: [
                  baudCnt < Const(baudDiv - 1, width: 16),
                  shiftReg < [Const(1), shiftReg.getRange(1, 10)].concat(),
                  bitCnt < bitCnt - 1,
                  If(bitCnt.eq(1), then: [sending < Const(0)]),
                ],
                orElse: [baudCnt < baudCnt - 1],
              ),
            ],
          ),
        ],
      ),
    ]);
    addOutput('uart_tx') <= shiftReg[0];
  }
}

Future<void> main(List<String> args) async {
  final outDir = Directory(args.isNotEmpty ? args[0] : '/tmp/ddr3_cal')
    ..createSync(recursive: true);
  final h = Ddr3CalHarness();
  await h.build();
  File(
    '${outDir.path}/creek_ddr3_cal.sv',
  ).writeAsStringSync(h.dumpSystemVerilog());
  stdout.writeln('wrote ${outDir.path}/creek_ddr3_cal.sv');
}

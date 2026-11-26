import 'package:rohd/rohd.dart';

import '../../blackbox/xilinx/xilinx.dart';

class HarborPipeClocks {
  final Logic pclk;
  final Logic userClk1;
  final Logic userClk2;
  final Logic mmcmLock;

  /// A 62.5 MHz clock that does not change with the link rate. Null when the
  /// PHY has no such clock, and then `pclk` is used.
  final Logic? oobClk;

  const HarborPipeClocks({
    required this.pclk,
    required this.userClk1,
    required this.userClk2,
    required this.mmcmLock,
    this.oobClk,
  });
}

/// PIPE clocks for a Xilinx 7-series PCIe link.
///
/// The MMCM takes a 100 MHz clock and its VCO is 1 GHz. `pclk` is 125 MHz.
/// With [gen2], `pclk` is a 125 MHz or 250 MHz clock that `pclk_sel` picks
/// without a glitch. `oob_clk` is a fixed 62.5 MHz clock.
class HarborPipeClock extends Module {
  /// VCO frequency of the MMCM in Hz.
  static const int vcoHz = 1000000000;

  /// Frequency in Hz of `userclk1` and `userclk2` for a divide value.
  /// The user clock frequencies in Hz of a x1 link with a 64-bit interface,
  /// PG054 Table 2-8 and Table 4-3. The MMCM makes each with a divide of 16,
  /// 8 or 4.
  static const Set<int> x1UserClkHz = {62500000, 125000000, 250000000};

  static int userClkHz(int userClkDivide) => vcoHz ~/ userClkDivide;

  /// The USER_CLK_FREQ parameter of the PCIe hard block for a divide value:
  /// 1 for 62.5 MHz, 2 for 125 MHz and 3 for 250 MHz.
  static int userClkFreqCode(int userClkDivide) => switch (userClkDivide) {
    16 => 1,
    8 => 2,
    4 => 3,
    _ => throw ArgumentError.value(userClkDivide, 'userClkDivide'),
  };

  final int userClkDivide;
  final int? lockTimerBits;
  final bool gen2;

  /// Add the fixed 62.5 MHz `oob_clk` output.
  final bool oobClock;

  /// Take `mmcm_lock` from a flop on the MMCM input clock, not from the
  /// LOCKED pin. The flop has an asynchronous clear from `reset`. A LOCKED
  /// pin with sinks far from the MMCM does not route in nextpnr-xilinx.
  /// [lockTimerBits] takes priority.
  final bool registerLock;

  Logic get pclk => output('pclk');
  Logic get userClk1 => output('userclk1');
  Logic get userClk2 => output('userclk2');
  Logic get mmcmLock => output('mmcm_lock');

  /// A 62.5 MHz clock for the GT OOB logic. Null without [oobClock].
  Logic? get oobClk => oobClock ? output('oob_clk') : null;

  HarborPipeClocks get clocks => HarborPipeClocks(
    pclk: pclk,
    userClk1: userClk1,
    userClk2: userClk2,
    mmcmLock: mmcmLock,
    oobClk: oobClk,
  );

  /// With [gen2], [pclkSel] is 0 for 125 MHz and 1 for 250 MHz. It must come
  /// from a flop on `pclk`.
  HarborPipeClock({
    required Logic txOutClk,
    required Logic reset,
    this.userClkDivide = 16,
    this.lockTimerBits,
    this.gen2 = false,
    this.oobClock = false,
    Logic? pclkSel,
    this.registerLock = false,
    super.name = 'pipe_clock',
  }) : super(
         definitionName: [
           'HarborPipeClock_U$userClkDivide',
           if (lockTimerBits != null) 'T$lockTimerBits',
           if (gen2) 'G2',
           if (oobClock) 'Oob',
           if (registerLock && lockTimerBits == null) 'R',
         ].join('_'),
       ) {
    if (gen2 != (pclkSel != null)) {
      throw ArgumentError('pclkSel is given if and only if gen2 is set');
    }
    if (userClkDivide != 4 && userClkDivide != 8 && userClkDivide != 16) {
      throw ArgumentError.value(
        userClkDivide,
        'userClkDivide',
        'must be 4, 8 or 16',
      );
    }
    if (lockTimerBits != null && (lockTimerBits! < 4 || lockTimerBits! > 30)) {
      throw ArgumentError.value(lockTimerBits, 'lockTimerBits', 'not 4..30');
    }

    txOutClk = addInput('txoutclk', txOutClk);
    reset = addInput('reset', reset);
    if (pclkSel != null) pclkSel = addInput('pclk_sel', pclkSel);
    addOutput('pclk');
    addOutput('userclk1');
    addOutput('userclk2');
    addOutput('mmcm_lock');

    final inBuf = XilinxBufg(name: 'txoutclk_bufg');
    inBuf.input('I').srcConnection! <= txOutClk;
    final refClk = inBuf.output('O').named('txoutclk_buf');

    final mmcm = XilinxMmcme2Adv(
      clkfboutMult: 10,
      clkout0Divide: 8,
      divclkDivide: 1,
      clkinPeriod: 10,
      clkout1Divide: gen2 ? 4 : null,
      clkout2Divide: userClkDivide,
      clkout3Divide: oobClock ? 16 : null,
      name: 'pipe_mmcm',
    );
    mmcm.input('CLKIN1').srcConnection! <= refClk;
    mmcm.input('CLKIN2').srcConnection! <= Const(0);
    mmcm.input('CLKINSEL').srcConnection! <= Const(1);
    mmcm.input('CLKFBIN').srcConnection! <= mmcm.output('CLKFBOUT');
    mmcm.input('RST').srcConnection! <= reset;
    mmcm.input('PWRDWN').srcConnection! <= Const(0);

    if (pclkSel == null) {
      final pclkBuf = XilinxBufg(name: 'pclk_bufg');
      pclkBuf.input('I').srcConnection! <= mmcm.output('CLKOUT0');
      pclk <= pclkBuf.output('O');
    } else {
      final pclkMux = XilinxBufgctrl(
        i0: mmcm.output('CLKOUT0'),
        i1: mmcm.output('CLKOUT1'),
        s0: ~pclkSel,
        s1: pclkSel,
        name: 'pclk_bufgctrl',
      );
      pclk <= pclkMux.output('O');
    }
    if (oobClock) {
      final oobBuf = XilinxBufg(name: 'oob_bufg');
      oobBuf.input('I').srcConnection! <= mmcm.output('CLKOUT3');
      addOutput('oob_clk') <= oobBuf.output('O');
    }
    final userBuf = XilinxBufg(name: 'userclk_bufg');
    userBuf.input('I').srcConnection! <= mmcm.output('CLKOUT2');

    userClk1 <= userBuf.output('O');
    userClk2 <= userBuf.output('O');

    final bits = lockTimerBits;
    if (bits == null && registerLock) {
      // Three flops split the long wire from the MMCM to the logic that uses
      // the lock, so the placer can keep the first flop near the MMCM.
      final stages = [for (var i = 0; i < 3; i++) Logic(name: 'lock_q$i')];
      Sequential(
        refClk,
        [
          stages[0] < mmcm.output('LOCKED'),
          stages[1] < stages[0],
          stages[2] < stages[1],
        ],
        reset: reset,
        asyncReset: true,
      );
      mmcmLock <= stages[2];
    } else if (bits == null) {
      mmcmLock <= mmcm.output('LOCKED');
    } else {
      final count = Logic(name: 'lock_count', width: bits + 1);
      Sequential(
        refClk,
        [
          If(~count[bits], then: [count < count + 1]),
        ],
        reset: reset,
        asyncReset: true,
      );
      mmcmLock <= count[bits];
    }
  }
}

import 'package:rohd/rohd.dart';

import '../../blackbox/xilinx/xilinx.dart';

class HarborPipeClocks {
  final Logic pclk;
  final Logic userClk1;
  final Logic userClk2;
  final Logic mmcmLock;

  const HarborPipeClocks({
    required this.pclk,
    required this.userClk1,
    required this.userClk2,
    required this.mmcmLock,
  });
}

/// PIPE clocks for a Xilinx 7-series PCIe Gen1 link.
class HarborPipeClock extends Module {
  final int userClkDivide;
  final int? lockTimerBits;

  Logic get pclk => output('pclk');
  Logic get userClk1 => output('userclk1');
  Logic get userClk2 => output('userclk2');
  Logic get mmcmLock => output('mmcm_lock');

  HarborPipeClocks get clocks => HarborPipeClocks(
    pclk: pclk,
    userClk1: userClk1,
    userClk2: userClk2,
    mmcmLock: mmcmLock,
  );

  HarborPipeClock({
    required Logic txOutClk,
    required Logic reset,
    this.userClkDivide = 16,
    this.lockTimerBits,
    super.name = 'pipe_clock',
  }) : super(
         definitionName: lockTimerBits == null
             ? 'HarborPipeClock_U$userClkDivide'
             : 'HarborPipeClock_U${userClkDivide}_T$lockTimerBits',
       ) {
    if (userClkDivide != 8 && userClkDivide != 16) {
      throw ArgumentError.value(
        userClkDivide,
        'userClkDivide',
        'must be 8 or 16',
      );
    }
    if (lockTimerBits != null && (lockTimerBits! < 4 || lockTimerBits! > 30)) {
      throw ArgumentError.value(lockTimerBits, 'lockTimerBits', 'not 4..30');
    }

    txOutClk = addInput('txoutclk', txOutClk);
    reset = addInput('reset', reset);
    addOutput('pclk');
    addOutput('userclk1');
    addOutput('userclk2');
    addOutput('mmcm_lock');

    final inBuf = XilinxBufg(name: 'txoutclk_bufg');
    inBuf.input('I').srcConnection! <= txOutClk;
    final refClk = inBuf.output('O');

    final mmcm = XilinxMmcme2Adv(
      clkfboutMult: 10,
      clkout0Divide: 8,
      divclkDivide: 1,
      clkinPeriod: 10,
      clkout2Divide: userClkDivide,
      name: 'pipe_mmcm',
    );
    mmcm.input('CLKIN1').srcConnection! <= refClk;
    mmcm.input('CLKIN2').srcConnection! <= Const(0);
    mmcm.input('CLKINSEL').srcConnection! <= Const(1);
    mmcm.input('CLKFBIN').srcConnection! <= mmcm.output('CLKFBOUT');
    mmcm.input('RST').srcConnection! <= reset;
    mmcm.input('PWRDWN').srcConnection! <= Const(0);

    final pclkBuf = XilinxBufg(name: 'pclk_bufg');
    pclkBuf.input('I').srcConnection! <= mmcm.output('CLKOUT0');
    final userBuf = XilinxBufg(name: 'userclk_bufg');
    userBuf.input('I').srcConnection! <= mmcm.output('CLKOUT2');

    pclk <= pclkBuf.output('O');
    userClk1 <= userBuf.output('O');
    userClk2 <= userBuf.output('O');

    final bits = lockTimerBits;
    if (bits == null) {
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

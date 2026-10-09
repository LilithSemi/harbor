/// Sdr sdram power-up and init sequencer.
library;

import 'package:rohd/rohd.dart';

import 'sdram_command.dart';
import 'sdram_cycles.dart';

/// Walks the fixed power-up sequence a sdr sdram device needs: hold `cke`
/// low, raise `cke`, precharge every bank, program the mode register, then
/// run the minimum auto refreshes. as4c16m16sb datasheet rev 2.0, note 11,
/// p22.
class SdramInitSequencer extends Module {
  /// The device and clock this sequence is built for.
  final HarborSdramCycles cycles;

  /// 3-bit command, a [SdramCommand] index.
  Logic get cmd => output('cmd');

  /// Command address, valid only on the cycle [cmd] carries `mrs`.
  Logic get cmdAddr => output('cmd_addr');

  /// Command bank, always 0 during init.
  Logic get cmdBa => output('cmd_ba');

  /// Clock enable.
  Logic get cke => output('cke');

  /// High once the init sequence has run its last auto refresh.
  Logic get done => output('done');

  SdramInitSequencer(
    this.cycles, {
    required Logic clk,
    required Logic reset,
    Logic? warmReset,
    super.name = 'sdram_init',
  }) {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    final warm = addInput('warm_reset', warmReset ?? Const(0));

    final rowWidth = cycles.config.rowWidth;
    final bankBits = cycles.config.bankBits;
    addOutput('cmd', width: 3);
    addOutput('cmd_addr', width: rowWidth);
    addOutput('cmd_ba', width: bankBits);
    addOutput('cke');
    addOutput('done');

    const stPowerUp = 0;
    const stCkeHigh = 1;
    const stPreAll = 2;
    const stWaitRp = 3;
    const stMrs = 4;
    const stWaitMrd = 5;
    const stRef = 6;
    const stWaitRfc = 7;
    const stDone = 8;
    // Warm-reset only: close any open bank before cke drops, so the long
    // power-up wait never leaves a row open past tRAS max.
    const stWarmPre = 9;
    const stWarmWaitRp = 10;

    final waits = [cycles.powerUp, cycles.rp, cycles.mrd, cycles.rfc];
    final counterWidth = waits.reduce((a, b) => a > b ? a : b).bitLength;
    final refreshWidth = (cycles.initRefreshes + 1).bitLength;

    final st = Logic(name: 'st', width: 4);
    final counter = Logic(name: 'counter', width: counterWidth);
    final refreshesLeft = Logic(name: 'refreshes_left', width: refreshWidth);

    final cmdReg = Logic(name: 'cmd_reg', width: 3);
    final cmdAddrReg = Logic(name: 'cmd_addr_reg', width: rowWidth);
    final cmdBaReg = Logic(name: 'cmd_ba_reg', width: bankBits);
    final ckeReg = Logic(name: 'cke_reg');
    final doneReg = Logic(name: 'done_reg');

    output('cmd') <= cmdReg;
    output('cmd_addr') <= cmdAddrReg;
    output('cmd_ba') <= cmdBaReg;
    output('cke') <= ckeReg;
    output('done') <= doneReg;

    Const nopCode() => Const(SdramCommand.nop.index, width: 3);

    Sequential(clk, [
      If(
        reset,
        then: [
          st <
              mux(
                warm,
                Const(stWarmPre, width: 4),
                Const(stPowerUp, width: 4),
              ),
          counter < Const(0, width: counterWidth),
          refreshesLeft < Const(cycles.initRefreshes, width: refreshWidth),
          cmdReg < nopCode(),
          cmdAddrReg < Const(0, width: rowWidth),
          cmdBaReg < Const(0, width: bankBits),
          // A warm reset keeps cke high through the precharge below; a
          // real power-on starts with cke low, unchanged.
          ckeReg < mux(warm, Const(1), Const(0)),
          doneReg < Const(0),
        ],
        orElse: [
          // Default to nop/cke-high every cycle. Each state below overrides
          // only the fields the datasheet step actually needs.
          cmdReg < nopCode(),
          cmdAddrReg < Const(0, width: rowWidth),
          cmdBaReg < Const(0, width: bankBits),
          ckeReg < Const(1),
          Case(
            st,
            [
              CaseItem(Const(stPowerUp, width: 4), [
                ckeReg < Const(0),
                If(
                  counter.lt(Const(cycles.powerUp - 1, width: counterWidth)),
                  then: [counter < counter + 1],
                  orElse: [
                    counter < Const(0, width: counterWidth),
                    st < Const(stCkeHigh, width: 4),
                  ],
                ),
              ]),
              CaseItem(Const(stCkeHigh, width: 4), [
                st < Const(stPreAll, width: 4),
              ]),
              CaseItem(Const(stPreAll, width: 4), [
                cmdReg < Const(SdramCommand.preAll.index, width: 3),
                st < Const(stWaitRp, width: 4),
              ]),
              CaseItem(Const(stWaitRp, width: 4), [
                If(
                  counter.lt(Const(cycles.rp - 1, width: counterWidth)),
                  then: [counter < counter + 1],
                  orElse: [
                    counter < Const(0, width: counterWidth),
                    st < Const(stMrs, width: 4),
                  ],
                ),
              ]),
              CaseItem(Const(stMrs, width: 4), [
                cmdReg < Const(SdramCommand.mrs.index, width: 3),
                cmdAddrReg < Const(cycles.modeRegister, width: rowWidth),
                st < Const(stWaitMrd, width: 4),
              ]),
              CaseItem(Const(stWaitMrd, width: 4), [
                If(
                  counter.lt(Const(cycles.mrd - 1, width: counterWidth)),
                  then: [counter < counter + 1],
                  orElse: [
                    counter < Const(0, width: counterWidth),
                    st < Const(stRef, width: 4),
                  ],
                ),
              ]),
              CaseItem(Const(stRef, width: 4), [
                cmdReg < Const(SdramCommand.ref.index, width: 3),
                st < Const(stWaitRfc, width: 4),
              ]),
              CaseItem(Const(stWaitRfc, width: 4), [
                If(
                  counter.lt(Const(cycles.rfc - 1, width: counterWidth)),
                  then: [counter < counter + 1],
                  orElse: [
                    counter < Const(0, width: counterWidth),
                    If(
                      refreshesLeft.gt(Const(1, width: refreshWidth)),
                      then: [
                        refreshesLeft < refreshesLeft - 1,
                        st < Const(stRef, width: 4),
                      ],
                      orElse: [st < Const(stDone, width: 4)],
                    ),
                  ],
                ),
              ]),
              CaseItem(Const(stDone, width: 4), [doneReg < Const(1)]),
              CaseItem(Const(stWarmPre, width: 4), [
                cmdReg < Const(SdramCommand.preAll.index, width: 3),
                st < Const(stWarmWaitRp, width: 4),
              ]),
              CaseItem(Const(stWarmWaitRp, width: 4), [
                If(
                  counter.lt(Const(cycles.rp - 1, width: counterWidth)),
                  then: [counter < counter + 1],
                  orElse: [
                    counter < Const(0, width: counterWidth),
                    st < Const(stPowerUp, width: 4),
                  ],
                ),
              ]),
            ],
            conditionalType: ConditionalType.unique,
            defaultItem: [st < Const(stPowerUp, width: 4)],
          ),
        ],
      ),
    ]);
  }
}

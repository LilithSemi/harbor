import 'package:rohd/rohd.dart';

/// Artix-7 GTP receive-reset DRP transaction from AMD AR 53561.
class HarborGtpDrpReset extends Module {
  Logic get gtReset => output('gt_reset');
  Logic get done => output('done');
  Logic get failed => output('failed');
  Logic get drpAddr => output('drp_addr');
  Logic get drpDataIn => output('drp_data_in');
  Logic get drpEnable => output('drp_enable');
  Logic get drpWrite => output('drp_write');

  HarborGtpDrpReset({
    required Logic clk,
    required Logic reset,
    required Logic start,
    required Logic rxPmaResetDone,
    required Logic drpReady,
    required Logic drpDataOut,
    int timeoutCycles = 1 << 12,
    super.name = 'gtp_drp_reset',
  }) : super(definitionName: 'HarborGtpDrpReset_T$timeoutCycles') {
    if (timeoutCycles < 4) {
      throw RangeError.range(timeoutCycles, 4, null, 'timeoutCycles');
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    start = addInput('start', start);
    rxPmaResetDone = addInput('rx_pma_reset_done', rxPmaResetDone);
    drpReady = addInput('drp_ready', drpReady);
    drpDataOut = addInput('drp_data_out', drpDataOut, width: 16);

    const idle = 0;
    const read = 1;
    const readWait = 2;
    const writeMasked = 3;
    const writeMaskedWait = 4;
    const waitPmaLow = 5;
    const restore = 6;
    const restoreWait = 7;
    final state = Logic(name: 'state', width: 3);
    final saved = Logic(name: 'saved_drp_011', width: 16);
    final timer = Logic(name: 'timer', width: timeoutCycles.bitLength);
    // The compare is registered: timeout_hit is high when the timer was
    // timeoutCycles - 2 in the last cycle. timer_cleared is high when the
    // timer was cleared at the last edge.
    final timeoutHit = Logic(name: 'timeout_hit');
    final timerCleared = Logic(name: 'timer_cleared');
    final timeout = timeoutHit & ~timerCleared;
    final completed = state.eq(Const(restoreWait, width: 3)) & drpReady;
    final doneQ = Logic(name: 'done_q');
    // failed_q blocks a new transaction until start falls. failed is a pulse.
    final failedQ = Logic(name: 'failed_q');
    final failedPulse = Logic(name: 'failed_pulse');
    final waiting =
        state.eq(Const(readWait, width: 3)) |
        state.eq(Const(writeMaskedWait, width: 3)) |
        state.eq(Const(waitPmaLow, width: 3)) |
        state.eq(Const(restoreWait, width: 3));

    final next = Logic(name: 'state_next', width: 3);
    Combinational([
      next < state,
      Case(
        state,
        [
          CaseItem(Const(idle, width: 3), [
            If(start & ~doneQ & ~failedQ, then: [next < Const(read, width: 3)]),
          ]),
          CaseItem(Const(read, width: 3), [next < Const(readWait, width: 3)]),
          CaseItem(Const(readWait, width: 3), [
            If(drpReady, then: [next < Const(writeMasked, width: 3)]),
          ]),
          CaseItem(Const(writeMasked, width: 3), [
            next < Const(writeMaskedWait, width: 3),
          ]),
          CaseItem(Const(writeMaskedWait, width: 3), [
            If(drpReady, then: [next < Const(waitPmaLow, width: 3)]),
          ]),
          CaseItem(Const(waitPmaLow, width: 3), [
            If(~rxPmaResetDone, then: [next < Const(restore, width: 3)]),
          ]),
          CaseItem(Const(restore, width: 3), [
            next < Const(restoreWait, width: 3),
          ]),
          CaseItem(Const(restoreWait, width: 3), [
            If(drpReady, then: [next < Const(idle, width: 3)]),
          ]),
        ],
        defaultItem: [next < Const(idle, width: 3)],
      ),
      If(waiting & timeout, then: [next < Const(idle, width: 3)]),
    ]);

    Sequential(
      clk,
      [
        state < next,
        timeoutHit <
            timer.eq(Const(timeoutCycles - 2, width: timeoutCycles.bitLength)),
        timerCleared < ~next.eq(state),
        If(
          ~next.eq(state),
          then: [timer < 0],
          orElse: [
            If(waiting, then: [timer < timer + 1]),
          ],
        ),
        If(
          state.eq(Const(readWait, width: 3)) & drpReady,
          then: [saved < drpDataOut],
        ),
        failedPulse < (waiting & timeout),
        If(
          ~start,
          then: [failedQ < 0],
          orElse: [
            If(waiting & timeout, then: [failedQ < 1]),
          ],
        ),
        If(
          ~start,
          then: [doneQ < 0],
          orElse: [
            If(completed, then: [doneQ < 1]),
          ],
        ),
      ],
      reset: reset,
      resetValues: {timerCleared: Const(1)},
    );

    addOutput('gt_reset') <=
        (state.eq(Const(idle, width: 3)) & start & ~doneQ & ~failedQ) |
            state.eq(Const(read, width: 3)) |
            state.eq(Const(readWait, width: 3)) |
            state.eq(Const(writeMasked, width: 3)) |
            state.eq(Const(writeMaskedWait, width: 3));
    addOutput('done') <= doneQ;
    addOutput('failed') <= failedPulse;
    addOutput('drp_addr', width: 9) <= Const(0x011, width: 9);
    addOutput('drp_data_in', width: 16) <=
        mux(
          state.eq(Const(writeMasked, width: 3)),
          saved & Const(0xf7ff, width: 16),
          saved,
        );
    addOutput('drp_enable') <=
        state.eq(Const(read, width: 3)) |
            state.eq(Const(writeMasked, width: 3)) |
            state.eq(Const(restore, width: 3));
    addOutput('drp_write') <=
        state.eq(Const(writeMasked, width: 3)) |
            state.eq(Const(restore, width: 3));
  }
}

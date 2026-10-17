import 'dart:math' as math;

import 'package:rohd/rohd.dart';

/// Power-up reset and I2C setup for a Silicon Image SiI9134 transmitter.
///
/// The outputs use open-drain enables. Connect `scl_out` and `sda_out` to
/// zero-valued bidirectional pads and release each pad when its enable is low.
class HarborSii9134Initializer extends Module {
  Logic get resetN => output('reset_n');
  Logic get sclOut => output('scl_out');
  Logic get sclOe => output('scl_oe');
  Logic get sdaOut => output('sda_out');
  Logic get sdaOe => output('sda_oe');
  Logic get done => output('done');
  Logic get error => output('error');

  final int clockFrequency;
  final int i2cFrequency;
  final int resetHoldUs;

  HarborSii9134Initializer({
    required Logic clk,
    required Logic reset,
    required Logic sclIn,
    required Logic sdaIn,
    required this.clockFrequency,
    this.i2cFrequency = 100000,
    this.resetHoldUs = 100,
    super.name = 'sii9134_initializer',
  }) : super(
         definitionName:
             'HarborSii9134Initializer_${clockFrequency}_${i2cFrequency}_'
             '$resetHoldUs',
       ) {
    if (clockFrequency <= 0) {
      throw ArgumentError.value(clockFrequency, 'clockFrequency');
    }
    if (i2cFrequency <= 0 || i2cFrequency > 400000) {
      throw ArgumentError.value(
        i2cFrequency,
        'i2cFrequency',
        'must be between 1 and 400000 Hz',
      );
    }
    if (resetHoldUs < 50) {
      throw ArgumentError.value(
        resetHoldUs,
        'resetHoldUs',
        'the SiI9134 requires RESET# low for at least 50 us',
      );
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    sclIn = addInput('scl_in', sclIn);
    sdaIn = addInput('sda_in', sdaIn);
    addOutput('reset_n');
    addOutput('scl_out');
    addOutput('scl_oe');
    addOutput('sda_out');
    addOutput('sda_oe');
    addOutput('done');
    addOutput('error');

    final quarterCycles = math.max(2, clockFrequency ~/ (i2cFrequency * 4));
    final dividerWidth = math.max(1, (quarterCycles - 1).bitLength);
    final resetCycles = math.max(
      1,
      (clockFrequency * resetHoldUs + 999999) ~/ 1000000,
    );
    final resetWidth = math.max(1, resetCycles.bitLength);

    const stReset = 0;
    const stSettle = 1;
    const stStart = 2;
    const stData = 3;
    const stAck = 4;
    const stStop = 5;
    const stDone = 6;
    const stError = 7;

    final state = Logic(name: 'state', width: 3);
    final phase = Logic(name: 'phase', width: 2);
    final divider = Logic(name: 'divider', width: dividerWidth);
    final resetCounter = Logic(name: 'reset_counter', width: resetWidth);
    final transaction = Logic(name: 'transaction');
    final byteIndex = Logic(name: 'byte_index', width: 2);
    final bitIndex = Logic(name: 'bit_index', width: 3);
    final shift = Logic(name: 'shift', width: 8);
    final resetNReg = Logic(name: 'reset_n_reg');
    final sclOeReg = Logic(name: 'scl_oe_reg');
    final sdaOeReg = Logic(name: 'sda_oe_reg');
    final sclMeta = Logic(name: 'scl_meta');
    final sclSync = Logic(name: 'scl_sync');
    final sdaMeta = Logic(name: 'sda_meta');
    final sdaSync = Logic(name: 'sda_sync');
    final failed = Logic(name: 'failed');

    Logic sequenceByte(Logic txn, Logic index) => mux(
      txn,
      mux(
        index.eq(0),
        Const(0x7a, width: 8),
        mux(index.eq(1), Const(0x2f, width: 8), Const(0x00, width: 8)),
      ),
      mux(
        index.eq(0),
        Const(0x72, width: 8),
        mux(index.eq(1), Const(0x08, width: 8), Const(0x35, width: 8)),
      ),
    );

    Conditional tick(List<Conditional> actions) => If(
      divider.eq(0),
      then: [
        ...actions,
        divider < Const(quarterCycles - 1, width: dividerWidth),
      ],
      orElse: [divider < (divider - Const(1, width: dividerWidth))],
    );

    List<Conditional> waitForSclHigh(int nextPhase) => [
      sclOeReg < Const(0),
      If(
        sclSync,
        then: [
          tick([phase < Const(nextPhase, width: 2)]),
        ],
        orElse: [divider < Const(quarterCycles - 1, width: dividerWidth)],
      ),
    ];

    sclOut <= Const(0);
    sdaOut <= Const(0);
    resetN <= resetNReg;
    sclOe <= sclOeReg;
    sdaOe <= sdaOeReg;
    done <= state.eq(stDone);
    error <= state.eq(stError);

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(stReset, width: 3),
          phase < Const(0, width: 2),
          divider < Const(quarterCycles - 1, width: dividerWidth),
          resetCounter < Const(resetCycles, width: resetWidth),
          transaction < Const(0),
          byteIndex < Const(0, width: 2),
          bitIndex < Const(0, width: 3),
          shift < Const(0, width: 8),
          resetNReg < Const(0),
          sclOeReg < Const(0),
          sdaOeReg < Const(0),
          sclMeta < Const(1),
          sclSync < Const(1),
          sdaMeta < Const(1),
          sdaSync < Const(1),
          failed < Const(0),
        ],
        orElse: [
          sclMeta < sclIn,
          sclSync < sclMeta,
          sdaMeta < sdaIn,
          sdaSync < sdaMeta,
          Case(state, [
            CaseItem(Const(stReset, width: 3), [
              resetNReg < Const(0),
              sclOeReg < Const(0),
              sdaOeReg < Const(0),
              If(
                resetCounter.eq(0),
                then: [
                  resetNReg < Const(1),
                  resetCounter < Const(resetCycles, width: resetWidth),
                  state < Const(stSettle, width: 3),
                ],
                orElse: [
                  resetCounter < (resetCounter - Const(1, width: resetWidth)),
                ],
              ),
            ]),
            CaseItem(Const(stSettle, width: 3), [
              If(
                resetCounter.eq(0),
                then: [
                  divider < Const(quarterCycles - 1, width: dividerWidth),
                  phase < Const(0, width: 2),
                  shift < sequenceByte(transaction, byteIndex),
                  state < Const(stStart, width: 3),
                ],
                orElse: [
                  resetCounter < (resetCounter - Const(1, width: resetWidth)),
                ],
              ),
            ]),
            CaseItem(Const(stStart, width: 3), [
              Case(phase, [
                CaseItem(Const(0, width: 2), [
                  tick([
                    sdaOeReg < Const(0),
                    sclOeReg < Const(0),
                    phase < Const(1, width: 2),
                  ]),
                ]),
                CaseItem(Const(1, width: 2), waitForSclHigh(2)),
                CaseItem(Const(2, width: 2), [
                  tick([sdaOeReg < Const(1), phase < Const(3, width: 2)]),
                ]),
                CaseItem(Const(3, width: 2), [
                  tick([
                    sclOeReg < Const(1),
                    bitIndex < Const(0, width: 3),
                    phase < Const(0, width: 2),
                    state < Const(stData, width: 3),
                  ]),
                ]),
              ]),
            ]),
            CaseItem(Const(stData, width: 3), [
              Case(phase, [
                CaseItem(Const(0, width: 2), [
                  sclOeReg < Const(1),
                  sdaOeReg < ~shift[7],
                  tick([phase < Const(1, width: 2)]),
                ]),
                CaseItem(Const(1, width: 2), [
                  tick([phase < Const(2, width: 2)]),
                ]),
                CaseItem(Const(2, width: 2), waitForSclHigh(3)),
                CaseItem(Const(3, width: 2), [
                  tick([
                    sclOeReg < Const(1),
                    shift < (shift << Const(1, width: 8)),
                    phase < Const(0, width: 2),
                    If(
                      bitIndex.eq(7),
                      then: [state < Const(stAck, width: 3)],
                      orElse: [bitIndex < (bitIndex + Const(1, width: 3))],
                    ),
                  ]),
                ]),
              ]),
            ]),
            CaseItem(Const(stAck, width: 3), [
              Case(phase, [
                CaseItem(Const(0, width: 2), [
                  sclOeReg < Const(1),
                  sdaOeReg < Const(0),
                  tick([phase < Const(1, width: 2)]),
                ]),
                CaseItem(Const(1, width: 2), [
                  tick([phase < Const(2, width: 2)]),
                ]),
                CaseItem(Const(2, width: 2), waitForSclHigh(3)),
                CaseItem(Const(3, width: 2), [
                  tick([
                    sclOeReg < Const(1),
                    phase < Const(0, width: 2),
                    If(
                      sdaSync,
                      then: [
                        failed < Const(1),
                        state < Const(stStop, width: 3),
                      ],
                      orElse: [
                        If(
                          byteIndex.eq(2),
                          then: [state < Const(stStop, width: 3)],
                          orElse: [
                            byteIndex < (byteIndex + Const(1, width: 2)),
                            bitIndex < Const(0, width: 3),
                            shift <
                                sequenceByte(
                                  transaction,
                                  byteIndex + Const(1, width: 2),
                                ),
                            state < Const(stData, width: 3),
                          ],
                        ),
                      ],
                    ),
                  ]),
                ]),
              ]),
            ]),
            CaseItem(Const(stStop, width: 3), [
              Case(phase, [
                CaseItem(Const(0, width: 2), [
                  sdaOeReg < Const(1),
                  sclOeReg < Const(1),
                  tick([phase < Const(1, width: 2)]),
                ]),
                CaseItem(Const(1, width: 2), waitForSclHigh(2)),
                CaseItem(Const(2, width: 2), [
                  tick([sdaOeReg < Const(0), phase < Const(3, width: 2)]),
                ]),
                CaseItem(Const(3, width: 2), [
                  tick([
                    phase < Const(0, width: 2),
                    If(
                      failed,
                      then: [state < Const(stError, width: 3)],
                      orElse: [
                        If(
                          transaction,
                          then: [state < Const(stDone, width: 3)],
                          orElse: [
                            transaction < Const(1),
                            byteIndex < Const(0, width: 2),
                            shift < sequenceByte(Const(1), Const(0, width: 2)),
                            state < Const(stStart, width: 3),
                          ],
                        ),
                      ],
                    ),
                  ]),
                ]),
              ]),
            ]),
            CaseItem(Const(stDone, width: 3), [
              sclOeReg < Const(0),
              sdaOeReg < Const(0),
            ]),
            CaseItem(Const(stError, width: 3), [
              sclOeReg < Const(0),
              sdaOeReg < Const(0),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

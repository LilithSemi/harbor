/// Wishbone front end for one [SdramPortInterface] client port.
library;

import 'package:rohd/rohd.dart';

import 'sdram_port.dart';

/// Turns one 32-bit wishbone access into two 16-bit sdram words: the low
/// word at the even word address, the high word at the next one. `sel`
/// splits the same way.
///
/// The port latches the write data and `sel` when it starts a request. If
/// `cyc` drops before the ack, the request still runs to completion on
/// the engine side, but the port does not ack it.
///
/// `reset` clears everything. `abort` is the bus side reset: it drops a
/// read or a request not yet taken, but a write the arbiter took still
/// hands over both words, so no taken write is lost or torn.
class SdramWishbonePort extends Module {
  Logic get ack => output('ack');
  Logic get datR => output('dat_r');

  SdramWishbonePort({
    required Logic clk,
    required Logic reset,
    Logic? abort,
    required Logic cyc,
    required Logic we,
    required Logic adr,
    required Logic datW,
    required Logic sel,
    required SdramPortInterface port,
    int portId = 0,
    super.name = 'sdram_wb_port',
  }) {
    final wordAddrWidth = port.addrWidth;
    if (adr.width < wordAddrWidth + 1) {
      throw ArgumentError(
        'adr must be at least ${wordAddrWidth + 1} bits wide, got '
        '${adr.width}',
      );
    }
    if (datW.width != 32 || sel.width != 4) {
      throw ArgumentError('datW must be 32 bits wide and sel 4 bits wide');
    }
    if (port.wrLookahead) {
      throw ArgumentError('a wishbone front end port must not be lookahead');
    }

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    abort = addInput('abort', abort ?? Const(0));
    cyc = addInput('cyc', cyc);
    we = addInput('we', we);
    adr = addInput('adr', adr, width: adr.width);
    datW = addInput('dat_w', datW, width: 32);
    sel = addInput('sel', sel, width: 4);

    addOutput('ack');
    addOutput('dat_r', width: 32);

    port = SdramPortInterface(
      addrWidth: port.addrWidth,
      wordsWidth: port.wordsWidth,
      portIdWidth: port.portIdWidth,
    )..pairConnectIO(this, port, PairRole.consumer);

    // The sdram word address is the byte address without its own bit 0,
    // with that address's own bit 0 forced to 0: the low word of a 32-bit
    // access always lands on the even word.
    final wordAddrRaw = adr.getRange(1, 1 + wordAddrWidth);
    final evenWordAddr = [
      wordAddrRaw.getRange(1, wordAddrWidth),
      Const(0),
    ].swizzle();

    final loData = datW.getRange(0, 16);
    final loMask = sel.getRange(0, 2);
    final hiWord = [sel.getRange(2, 4), datW.getRange(16, 32)].swizzle();

    // Phase sequencing, bookkeeping only: nothing downstream reads these
    // bits directly, they only pick which dedicated register loads next.
    const pIdle = 0, pReq = 1, pWr0 = 2, pWr1 = 3, pRd0 = 4, pRd1 = 5;
    const pAck = 6, pGap = 7;
    final phase = Logic(name: 'phase', width: 3);

    final reqAddrReg = Logic(name: 'req_addr_r', width: wordAddrWidth);
    final reqWriteReg = Logic(name: 'req_write_r');
    final reqValidReg = Logic(name: 'req_valid_r');
    final wrValidReg = Logic(name: 'wr_valid_r');
    final wrDataReg = Logic(name: 'wr_data_r', width: 16);
    final wrMaskReg = Logic(name: 'wr_mask_r', width: 2);
    final loWordReg = Logic(name: 'lo_word_r', width: 16);
    final datRReg = Logic(name: 'dat_r_r', width: 32);
    final hiWordReg = Logic(name: 'hi_word_r', width: 18);
    final ackReg = Logic(name: 'ack_r');
    // The master dropped cyc after this request started.
    final aborted = Logic(name: 'aborted');

    port.reqValid <= reqValidReg;
    port.reqWrite <= reqWriteReg;
    port.reqAddr <= reqAddrReg;
    port.reqWords <= Const(2, width: port.wordsWidth);
    port.wrValid <= wrValidReg;
    port.wrData <= wrDataReg;
    port.wrMask <= wrMaskReg;
    if (port.portIdWidth > 0) {
      port.reqPort <= Const(portId, width: port.portIdWidth);
    }

    output('ack') <= ackReg & cyc;
    output('dat_r') <= datRReg;

    Const st(int p) => Const(p, width: 3);

    final committed =
        phase.eq(st(pWr0)) |
        phase.eq(st(pWr1)) |
        (phase.eq(st(pReq)) & reqWriteReg & port.reqReady);
    final drop = (reset | (abort & ~committed)).named('drop');

    // Only the control registers clear on drop. The data registers clear
    // on reset alone, so drop has a small fanout.
    Sequential(clk, [
      If(
        drop,
        then: [
          phase < st(pIdle),
          reqWriteReg < Const(0),
          reqValidReg < Const(0),
          wrValidReg < Const(0),
          ackReg < Const(0),
          aborted < Const(0),
        ],
        orElse: [
          ackReg < Const(0),
          aborted < (aborted | ~cyc | abort) & ~phase.eq(st(pIdle)),
          Case(
            phase,
            [
              CaseItem(st(pIdle), [
                If(
                  cyc,
                  then: [
                    phase < st(pReq),
                    reqWriteReg < we,
                    reqValidReg < Const(1),
                  ],
                ),
              ]),
              CaseItem(st(pReq), [
                If(
                  port.reqReady,
                  then: [
                    reqValidReg < Const(0),
                    If(
                      reqWriteReg,
                      then: [phase < st(pWr0), wrValidReg < Const(1)],
                      orElse: [phase < st(pRd0)],
                    ),
                  ],
                ),
              ]),
              CaseItem(st(pWr0), [
                If(port.wrReady, then: [phase < st(pWr1)]),
              ]),
              CaseItem(st(pWr1), [
                If(
                  port.wrReady,
                  then: [
                    phase < st(pAck),
                    wrValidReg < Const(0),
                    ackReg < cyc & ~aborted & ~abort,
                  ],
                ),
              ]),
              CaseItem(st(pRd0), [
                If(port.rdValid, then: [phase < st(pRd1)]),
              ]),
              CaseItem(st(pRd1), [
                If(
                  port.rdValid & port.rdLast,
                  then: [phase < st(pAck), ackReg < cyc & ~aborted & ~abort],
                ),
              ]),
              CaseItem(st(pAck), [phase < st(pGap)]),
              CaseItem(st(pGap), [phase < st(pIdle)]),
            ],
            defaultItem: [phase < st(pIdle)],
          ),
        ],
      ),
    ]);

    Sequential(clk, [
      If(
        reset,
        then: [
          reqAddrReg < Const(0, width: wordAddrWidth),
          wrDataReg < Const(0, width: 16),
          wrMaskReg < Const(0, width: 2),
          loWordReg < Const(0, width: 16),
          datRReg < Const(0, width: 32),
          hiWordReg < Const(0, width: 18),
        ],
        orElse: [
          Case(phase, [
            CaseItem(st(pIdle), [
              If(
                cyc,
                then: [
                  reqAddrReg < evenWordAddr,
                  wrDataReg < loData,
                  wrMaskReg < loMask,
                  hiWordReg < hiWord,
                ],
              ),
            ]),
            CaseItem(st(pWr0), [
              If(
                port.wrReady,
                then: [
                  wrDataReg < hiWordReg.getRange(0, 16),
                  wrMaskReg < hiWordReg.getRange(16, 18),
                ],
              ),
            ]),
            CaseItem(st(pWr1), [
              If(port.wrReady, then: [datRReg < Const(0, width: 32)]),
            ]),
            CaseItem(st(pRd0), [
              If(port.rdValid, then: [loWordReg < port.rdData]),
            ]),
            CaseItem(st(pRd1), [
              If(
                port.rdValid & port.rdLast,
                then: [
                  datRReg < [port.rdData, loWordReg].swizzle(),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

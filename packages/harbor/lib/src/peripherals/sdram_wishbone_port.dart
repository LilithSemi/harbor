/// Wishbone front end for one [SdramPortInterface] client port.
library;

import 'package:rohd/rohd.dart';

import 'sdram_port.dart';

/// Turns one 32-bit or 64-bit wishbone access into two or four 16-bit sdram
/// words: the low word at the first word address, the others at the next
/// ones. `sel` splits the same way.
///
/// The port latches the write data and `sel` when it starts a request. If
/// `cyc` drops before the ack, the request still runs to completion on
/// the engine side, but the port does not ack it.
///
/// `reset` clears everything. `abort` is the bus side reset: it drops a
/// read or a request not yet taken, but a write the arbiter took still
/// hands over both words, so no taken write is lost or torn.
///
/// A write is acked once both words are out and the arbiter took it. With
/// a [SdramPortSlice] in front of the arbiter, give its `wr_taken` pulse as
/// `writeTaken`. Without it, the take on `req_ready` counts.
class SdramWishbonePort extends Module {
  Logic get ack => output('ack');
  Logic get datR => output('dat_r');

  /// 16-bit sdram words in one access: 2 for a 32-bit bus, 4 for a 64-bit
  /// bus.
  final int words;

  /// The ACK flop without the `cyc` gate, for a master that gates it with
  /// its own `cyc`.
  Logic get ackPulse => output('ack_pulse');

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
    Logic? writeTaken,
    int portId = 0,
    super.name = 'sdram_wb_port',
  }) : words = datW.width ~/ 16 {
    final wordAddrWidth = port.addrWidth;
    if (adr.width < wordAddrWidth + 1) {
      throw ArgumentError(
        'adr must be at least ${wordAddrWidth + 1} bits wide, got '
        '${adr.width}',
      );
    }
    final dw = datW.width;
    if ((dw != 32 && dw != 64) || sel.width != dw ~/ 8) {
      throw ArgumentError(
        'datW must be 32 or 64 bits wide and sel one bit per byte',
      );
    }
    final wpa = words;
    final wpaBits = wpa.bitLength - 1;
    if (port.wordsWidth < wpa.bitLength) {
      throw ArgumentError('the client port must hold $wpa words');
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
    datW = addInput('dat_w', datW, width: dw);
    sel = addInput('sel', sel, width: dw ~/ 8);
    if (writeTaken != null) writeTaken = addInput('wr_taken', writeTaken);

    addOutput('ack');
    addOutput('ack_pulse');
    addOutput('dat_r', width: dw);

    port = SdramPortInterface(
      addrWidth: port.addrWidth,
      wordsWidth: port.wordsWidth,
      portIdWidth: port.portIdWidth,
    )..pairConnectIO(this, port, PairRole.consumer);

    // The sdram word address is the byte address without its own bit 0,
    // with the low bits that count the words of an access forced to 0: the
    // first word of an access always lands on an aligned word.
    final wordAddrRaw = adr.getRange(1, 1 + wordAddrWidth);
    final alignedWordAddr = [
      wordAddrRaw.getRange(wpaBits, wordAddrWidth),
      Const(0, width: wpaBits),
    ].concat();

    Logic dataWord(int i) => datW.getRange(16 * i, 16 * i + 16);
    Logic maskWord(int i) => sel.getRange(2 * i, 2 * i + 2);
    final loData = dataWord(0);
    final loMask = maskWord(0);

    // Phase sequencing, bookkeeping only: nothing downstream reads these
    // bits directly, they only pick which dedicated register loads next.
    // Phase wr(i) presents word i of a write, rd(i) takes word i of a read.
    const pIdle = 0, pReq = 1;
    int wr(int i) => 2 + i;
    int rd(int i) => 2 + wpa + i;
    final pAck = 2 + 2 * wpa, pGap = 3 + 2 * wpa;
    final pWrLast = wr(wpa - 1), pRdLast = rd(wpa - 1);
    final phase = Logic(name: 'phase', width: (pGap).bitLength);

    final reqAddrReg = Logic(name: 'req_addr_r', width: wordAddrWidth);
    final reqWriteReg = Logic(name: 'req_write_r');
    final reqValidReg = Logic(name: 'req_valid_r');
    final wrValidReg = Logic(name: 'wr_valid_r');
    final wrDataReg = Logic(name: 'wr_data_r', width: 16);
    final wrMaskReg = Logic(name: 'wr_mask_r', width: 2);
    final loWordRegs = [
      for (var i = 0; i < wpa - 1; i++)
        Logic(name: 'lo_word_${i}_r', width: 16),
    ];
    final datRReg = Logic(name: 'dat_r_r', width: dw);
    // Mask and data of the words after the first, held until they go out.
    final hiWordRegs = [
      for (var i = 1; i < wpa; i++) Logic(name: 'hi_word_${i}_r', width: 18),
    ];
    final ackReg = Logic(name: 'ack_r');
    // The master dropped cyc after this request started.
    final aborted = Logic(name: 'aborted');
    // The arbiter took this write, and both write words are out.
    final taken = Logic(name: 'wr_taken_seen');
    final wordsOut = Logic(name: 'wr_words_out');

    port.reqValid <= reqValidReg;
    port.reqWrite <= reqWriteReg;
    port.reqAddr <= reqAddrReg;
    port.reqWords <= Const(wpa, width: port.wordsWidth);
    port.wrValid <= wrValidReg;
    port.wrData <= wrDataReg;
    port.wrMask <= wrMaskReg;
    if (port.portIdWidth > 0) {
      port.reqPort <= Const(portId, width: port.portIdWidth);
    }

    output('ack') <= ackReg & cyc;
    output('ack_pulse') <= ackReg;
    output('dat_r') <= datRReg;

    Logic st(int p) => Const(p, width: phase.width);

    final committed =
        [
          for (var i = 0; i < wpa; i++) phase.eq(st(wr(i))),
        ].reduce((a, b) => a | b) |
        (phase.eq(st(pReq)) & reqWriteReg & port.reqReady);
    final drop = (reset | (abort & ~committed)).named('drop');
    final takenNow =
        writeTaken ?? (phase.eq(st(pReq)) & reqWriteReg & port.reqReady);
    final wrDone = (port.wrReady | wordsOut) & (taken | takenNow);

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
          taken < Const(0),
          wordsOut < Const(0),
        ],
        orElse: [
          ackReg < Const(0),
          taken < (taken | takenNow) & ~phase.eq(st(pAck)),
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
                      then: [phase < st(wr(0)), wrValidReg < Const(1)],
                      orElse: [phase < st(rd(0))],
                    ),
                  ],
                ),
              ]),
              for (var i = 0; i < wpa - 1; i++)
                CaseItem(st(wr(i)), [
                  If(port.wrReady, then: [phase < st(wr(i + 1))]),
                ]),
              CaseItem(st(pWrLast), [
                If(
                  port.wrReady,
                  then: [wrValidReg < Const(0), wordsOut < Const(1)],
                ),
                If(
                  wrDone,
                  then: [
                    phase < st(pAck),
                    wordsOut < Const(0),
                    ackReg < cyc & ~aborted & ~abort,
                  ],
                ),
              ]),
              for (var i = 0; i < wpa - 1; i++)
                CaseItem(st(rd(i)), [
                  If(port.rdValid, then: [phase < st(rd(i + 1))]),
                ]),
              CaseItem(st(pRdLast), [
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
          for (final r in loWordRegs) r < Const(0, width: 16),
          datRReg < Const(0, width: dw),
          for (final r in hiWordRegs) r < Const(0, width: 18),
        ],
        orElse: [
          Case(phase, [
            CaseItem(st(pIdle), [
              If(
                cyc,
                then: [
                  reqAddrReg < alignedWordAddr,
                  wrDataReg < loData,
                  wrMaskReg < loMask,
                  for (var i = 1; i < wpa; i++)
                    hiWordRegs[i - 1] < [maskWord(i), dataWord(i)].concat(),
                ],
              ),
            ]),
            for (var i = 0; i < wpa - 1; i++)
              CaseItem(st(wr(i)), [
                If(
                  port.wrReady,
                  then: [
                    wrDataReg < hiWordRegs[i].getRange(0, 16),
                    wrMaskReg < hiWordRegs[i].getRange(16, 18),
                  ],
                ),
              ]),
            CaseItem(st(pWrLast), [
              If(port.wrReady, then: [datRReg < Const(0, width: dw)]),
            ]),
            for (var i = 0; i < wpa - 1; i++)
              CaseItem(st(rd(i)), [
                If(port.rdValid, then: [loWordRegs[i] < port.rdData]),
              ]),
            CaseItem(st(pRdLast), [
              If(
                port.rdValid & port.rdLast,
                then: [
                  datRReg < [...loWordRegs, port.rdData].rconcat(),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);
  }
}

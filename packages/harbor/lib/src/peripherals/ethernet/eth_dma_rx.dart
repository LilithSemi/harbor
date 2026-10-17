import 'dart:math';

import 'package:rohd/rohd.dart';

import '../../arith/fpu_config.dart' show harborStableDefinitionName;
import '../../bus/port/memory_waist.dart';
import 'eth_config.dart';

/// RX descriptor DMA on the sys clock.
///
/// The DMA takes complete frames from the read side of an RX frame FIFO and
/// writes each one into the buffer of one RX descriptor through a memory
/// master waist. For each frame:
///
/// 1. If `head` equals `tail`, or the descriptor at `head` has OWN clear,
///    the DMA drops the frame from the FIFO and pulses `rx_missed`.
/// 2. Else it writes the frame words into the buffer in INCR bursts of up to
///    `burstBeats` beats that never cross 4 KB, with up to `outstanding`
///    bursts in flight. The FIFO tells the frame end only on its last word,
///    so the beats of a burst after the frame end have all strobes low.
/// 3. After every WRESP of the buffer, it finds the error code from the
///    status. A bad frame with `keep_bad` low is dropped: no write-back,
///    `head` does not move and the descriptor takes the next frame.
/// 4. Else it writes word 3, waits for the WRESP, then clears OWN in word 2
///    and waits for that WRESP. Then it moves `head` and pulses `rx_done`.
///
/// The word 3 error codes are [errOk], [errFcs], [errRunt], [errOversize],
/// [errWrite], [errCut] and [errRxEr]. When more than one status bit is set,
/// the first of cut, rx_er, fcs, oversize and runt gives the code.
///
/// The DMA takes the first word of a frame from the FIFO before any bus
/// access. After that the FIFO always ends the frame with `r_last`, also
/// when the RX side resets.
///
/// A frame longer than the buffer fills the buffer, the DMA drops the rest
/// from the FIFO and writes back [errOversize] also when `keep_bad` is low.
/// A buffer with an address that is not a multiple of 4, or that does not
/// fit in the waist address width, counts as a buffer of size 0: no data is
/// written and the frame gets [errOversize]. The abort word of a frame that
/// a clock loss cut adds no bytes.
///
/// A bus error on the descriptor read or on any write sets `ring_err` with
/// [errWrite]. The DMA sends no more writes, drops the rest of the frame,
/// leaves OWN set and holds `head`. So [errWrite] is given only on
/// `err_code`, never in word 3. `rx_err` pulses for each nonzero code.
///
/// When `rx_en` is low or `ring_err` is set, the DMA starts no new frame
/// and keeps `head`. The frames stay in the FIFO. A pulse on `ring_reset`
/// is kept until the DMA is idle. Then it sets `head` to 0 and clears
/// `ring_err`. No new frame starts while the reset is pending.
///
/// The low bits of `ring_base` below the descriptor size are ignored. The
/// write to word 2 sets bits 31 to 24 to 0.
class HarborEthDmaRx extends Module {
  /// Configuration of the MAC that contains this DMA.
  final HarborEthernetConfig config;

  /// No error.
  static const errOk = 0;

  /// FCS error.
  static const errFcs = 1;

  /// Runt frame.
  static const errRunt = 2;

  /// Oversize frame, or a frame longer than the buffer.
  static const errOversize = 3;

  /// A descriptor read or a write failed.
  static const errWrite = 5;

  /// An RX clock loss cut the frame.
  static const errCut = 6;

  /// The PHY signalled rx_er.
  static const errRxEr = 7;

  /// Width of the ring indexes.
  static const indexWidth = 12;

  Logic get head => output('head');
  Logic get rxDone => output('rx_done');
  Logic get rxErr => output('rx_err');
  Logic get rxMissed => output('rx_missed');
  Logic get ringErr => output('ring_err');

  /// Code of the last nonzero error.
  Logic get errCode => output('err_code');

  /// High while the DMA works on a frame.
  Logic get busy => output('busy');

  Logic get rReady => output('r_ready');

  static const _idle = 0;
  static const _descReq = 1;
  static const _descWait = 2;
  static const _descEval = 3;
  static const _data = 4;
  static const _drain = 5;
  static const _end = 6;
  static const _writeBack = 7;

  /// [ringBase] has the width of the waist address. [ringSize] is log2 of
  /// the entries. [tail] is the next index the driver gives. The `r*`
  /// signals are the read side of an RX frame FIFO.
  HarborEthDmaRx(
    Logic clk,
    Logic reset, {
    required HarborMemoryWaist waist,
    required this.config,
    required Logic ringBase,
    required Logic ringSize,
    required Logic tail,
    required Logic rxEn,
    required Logic keepBad,
    required Logic ringReset,
    required Logic rValid,
    required Logic rData,
    required Logic rBytes,
    required Logic rLast,
    required Logic rStatus,
    super.name = 'eth_dma_rx',
  }) : super(
         definitionName: harborStableDefinitionName('HarborEthDmaRx', [
           'a${waist.config.addressWidth}',
           'i${waist.config.idWidth}',
           'n${waist.config.outstanding}',
           'd${config.descBytes}',
           'o${config.outstanding}',
           'b${config.burstBeats}',
         ]),
       ) {
    final aw = waist.config.addressWidth;
    if (waist.config.dataWidth != 32 || aw < 12 || aw > 64) {
      throw ArgumentError(
        'HarborEthDmaRx needs 32-bit data and a 12 to 64-bit address, '
        'got ${waist.config}',
      );
    }
    const iw = indexWidth;
    const ww = 17;
    const bw = 9;
    const lenW = HarborMemoryWaistConfig.lenWidth;
    final descShift = config.descBytes.bitLength - 1;
    final limit = min(config.outstanding, waist.config.outstanding);
    final cw = limit.bitLength + 1;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    ringBase = addInput('ring_base', ringBase, width: aw);
    ringSize = addInput('ring_size', ringSize, width: 4);
    tail = addInput('tail', tail, width: iw);
    rxEn = addInput('rx_en', rxEn);
    keepBad = addInput('keep_bad', keepBad);
    ringReset = addInput('ring_reset', ringReset);
    rValid = addInput('r_valid', rValid);
    rData = addInput('r_data', rData, width: 32);
    rBytes = addInput('r_bytes', rBytes, width: 2);
    rLast = addInput('r_last', rLast);
    rStatus = addInput('r_status', rStatus, width: 8);

    final headOut = addOutput('head', width: iw);
    final rxDoneOut = addOutput('rx_done');
    final rxErrOut = addOutput('rx_err');
    final rxMissedOut = addOutput('rx_missed');
    final ringErrOut = addOutput('ring_err');
    final errCodeOut = addOutput('err_code', width: 3);
    final busyOut = addOutput('busy');
    final rReadyOut = addOutput('r_ready');

    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.provider, uniquify: (n) => 'm_$n');

    final state = Logic(name: 'state', width: 4);
    Logic inState(int s) => state.eq(Const(s, width: 4));
    final headReg = Logic(name: 'head_reg', width: iw);
    final dBeat = Logic(name: 'd_beat', width: 2);
    final dErr = Logic(name: 'd_err');
    final dw0 = Logic(name: 'dw0', width: 32);
    final dw1 = Logic(name: 'dw1', width: 32);
    final dw2 = Logic(name: 'dw2', width: 32);
    final bufAddr = Logic(name: 'buf_addr', width: aw);
    final wordsLeft = Logic(name: 'words_left', width: ww);
    final beatsLeft = Logic(name: 'beats_left', width: bw);
    final rem = Logic(name: 'rem', width: ww);
    final count = Logic(name: 'count', width: 16);
    final ended = Logic(name: 'ended');
    final bufOver = Logic(name: 'buf_over');
    final wErr = Logic(name: 'w_err');
    final missed = Logic(name: 'missed');
    final descFail = Logic(name: 'desc_fail');
    final status = Logic(name: 'status', width: 8);
    final inflight = Logic(name: 'inflight', width: cw);
    final code = Logic(name: 'code', width: 3);
    final wbData = Logic(name: 'wb_data');
    final wbBeat = Logic(name: 'wb_beat');
    final wbReqDone = Logic(name: 'wb_req_done');
    final ringErrReg = Logic(name: 'ring_err_reg');
    final errCodeReg = Logic(name: 'err_code_reg', width: 3);
    final rxDoneReg = Logic(name: 'rx_done_reg');
    final rxErrReg = Logic(name: 'rx_err_reg');
    final rxMissedReg = Logic(name: 'rx_missed_reg');
    final ringPend = Logic(name: 'ring_pend');
    final hValid = Logic(name: 'hold_valid');
    final hData = Logic(name: 'hold_data', width: 32);
    final hBytes = Logic(name: 'hold_bytes', width: 2);
    final hLast = Logic(name: 'hold_last');
    final hStatus = Logic(name: 'hold_status', width: 8);

    Logic minOf(Logic a, Logic b) => mux(a.lt(b), a, b);

    final mask = [
      for (var i = iw - 1; i >= 0; i--) ringSize.gt(Const(i, width: 4)),
    ].swizzle().named('ring_mask');
    final base = (ringBase & ~Const(config.descBytes - 1, width: aw)).named(
      'ring_base_aligned',
    );
    final ew = max(aw, iw + descShift);
    final descAddr =
        (base + (headReg.zeroExtend(ew) << descShift).getRange(0, aw)).named(
          'desc_addr',
        );

    final own = dw2[31];
    final size = dw2.getRange(0, 16);
    final dAddr = [dw1, dw0].swizzle().getRange(0, aw).named('d_addr');
    final fits = aw < 64 ? ~[dw1, dw0].swizzle().getRange(aw).or() : Const(1);
    final aligned = (dAddr.getRange(0, 2).eq(0) & fits).named('d_aligned');
    // The buffer checks are flops, set when word 2 of the descriptor comes,
    // so the evaluation starts from flops.
    final alignedR = Logic(name: 'd_aligned_r');
    final sizeZero = Logic(name: 'd_size_zero');

    final busyIn = inflight.neq(0);
    final wrespTake = (busyIn & ~inState(_descWait)).named('wresp_take');
    m.wrespReady <= wrespTake;
    final wrespFire = (m.wrespValid & wrespTake).named('wresp_fire');
    final wrespBad = (wrespFire & m.wrespErr).named('wresp_bad');
    final stopW = (wErr | wrespBad).named('stop_w');

    // Data requests. A new burst starts only when the last one has all its
    // beats sent.
    final toBoundary =
        (Const(1024, width: ww) - bufAddr.getRange(2, 12).zeroExtend(ww)).named(
          'to_boundary',
        );
    // The burst length is registered. It is ready one cycle after the
    // address and the word count change.
    final beatsCalc = minOf(
      minOf(wordsLeft, Const(config.burstBeats, width: ww)),
      toBoundary,
    ).named('beats_calc');
    final beats = Logic(name: 'beats', width: ww);
    final beatsReady = Logic(name: 'beats_ready');
    final room = inflight.lt(Const(limit, width: cw)).named('room');
    final dataReqValid =
        (inState(_data) &
                beatsReady &
                beatsLeft.eq(0) &
                ~ended &
                ~bufOver &
                ~stopW &
                wordsLeft.neq(0) &
                room)
            .named('data_req_valid');
    final wbReqValid =
        (inState(_writeBack) & ~wbReqDone & ~wbData & inflight.eq(0)).named(
          'wb_req_valid',
        );
    m.reqValid <= inState(_descReq) | dataReqValid | wbReqValid;
    m.reqId <= Const(0, width: waist.config.idWidth);
    m.reqWrite <= ~inState(_descReq);
    m.reqAddr <=
        mux(
          inState(_data),
          bufAddr,
          mux(
            inState(_writeBack),
            descAddr + mux(wbBeat, Const(8, width: aw), Const(12, width: aw)),
            descAddr,
          ),
        );
    m.reqLen <=
        mux(
          inState(_data),
          (beats - 1).getRange(0, lenW),
          mux(
            inState(_writeBack),
            Const(0, width: lenW),
            Const(2, width: lenW),
          ),
        );
    m.reqSize <= Const(2, width: HarborMemoryWaistConfig.sizeWidth);
    m.reqBurst <=
        Const(
          HarborMemoryBurst.incr.value,
          width: HarborMemoryWaistConfig.burstWidth,
        );
    m.reqExclusive <= Const(0);
    final reqFire = (m.reqValid & m.reqReady).named('req_fire');

    // Descriptor read. READY is high only with the read in flight.
    final rdTake = (busyIn & inState(_descWait)).named('rd_take');
    m.rdataReady <= rdTake;
    final rdFire = (m.rdataValid & rdTake).named('rd_fire');
    final rdLastFire = (rdFire & m.rdataLast).named('rd_last_fire');

    // Frame words come from the hold register first, then from the FIFO.
    final sValid = (hValid | rValid).named('src_valid');
    final sData = mux(hValid, hData, rData).named('src_data');
    final sBytes = mux(hValid, hBytes, rBytes).named('src_bytes');
    final sLast = mux(hValid, hLast, rLast).named('src_last');
    final sStatus = mux(hValid, hStatus, rStatus).named('src_status');
    final sCut = (sLast & sStatus[6]).named('src_cut');

    // Data beats. After the frame end or the buffer end a beat is padding.
    final pad = (ended | bufOver).named('pad');
    final beatValid = (inState(_data) & beatsLeft.neq(0) & (pad | sValid))
        .named('beat_valid');
    final n = mux(
      sLast & sBytes.neq(0),
      sBytes.zeroExtend(3),
      Const(4, width: 3),
    ).named('word_n');
    final put = mux(
      sCut,
      Const(0, width: 3),
      mux(rem.lt(n.zeroExtend(ww)), rem.getRange(0, 3), n),
    ).named('word_put');
    final over =
        (~sCut &
                mux(
                  sLast,
                  rem.lt(n.zeroExtend(ww)),
                  rem.lte(Const(4, width: ww)),
                ))
            .named('word_over');
    final strb = [
      for (var i = 3; i >= 0; i--) put.gt(Const(i, width: 3)),
    ].swizzle().named('word_strb');

    final word3 = [
      Const(0, width: 7),
      code,
      Const(0, width: 2),
      status[5],
      status[4],
      Const(1),
      Const(1),
      count,
    ].swizzle().named('word3');
    m.wdataValid <= beatValid | (inState(_writeBack) & wbData);
    m.wdataData <=
        mux(
          inState(_writeBack),
          mux(wbBeat, Const(0, width: 32), word3),
          mux(pad, Const(0, width: 32), sData),
        );
    m.wdataStrb <=
        mux(
          inState(_writeBack),
          mux(wbBeat, Const(0x8, width: 4), Const(0xf, width: 4)),
          mux(pad | stopW, Const(0, width: 4), strb),
        );
    m.wdataLast <= ~inState(_data) | beatsLeft.eq(1);
    final wFire = (m.wdataValid & m.wdataReady).named('w_fire');
    final pop = (wFire & inState(_data) & ~pad).named('pop');
    final drainTake = (inState(_drain) & sValid).named('drain_take');

    final inflightNext =
        (inflight +
                reqFire.zeroExtend(cw) -
                rdLastFire.zeroExtend(cw) -
                wrespFire.zeroExtend(cw))
            .named('inflight_next');

    // Error code from the status, first of cut, rx_er, fcs, oversize, runt.
    final bigErr = (status[2] | bufOver).named('big_err');
    final statusCode = mux(
      status[6],
      Const(errCut, width: 3),
      mux(
        status[3],
        Const(errRxEr, width: 3),
        mux(
          status[0],
          Const(errFcs, width: 3),
          mux(
            bigErr,
            Const(errOversize, width: 3),
            mux(status[1], Const(errRunt, width: 3), Const(errOk, width: 3)),
          ),
        ),
      ),
    ).named('status_code');
    final keep =
        (statusCode.eq(errOk) |
                keepBad |
                (statusCode.eq(errOversize) & bufOver))
            .named('keep_frame');

    final startFrame =
        (inState(_idle) & rxEn & ~ringErrReg & ~ringPend & ~ringReset & rValid)
            .named('start_frame');
    rReadyOut <= startFrame | ((pop | inState(_drain)) & ~hValid);

    headOut <= headReg;
    rxDoneOut <= rxDoneReg;
    rxErrOut <= rxErrReg;
    rxMissedOut <= rxMissedReg;
    ringErrOut <= ringErrReg;
    errCodeOut <= errCodeReg;
    busyOut <= ~inState(_idle);

    Sequential(clk, reset: reset, [
      rxDoneReg < Const(0),
      rxErrReg < Const(0),
      rxMissedReg < Const(0),
      inflight < inflightNext,
      beats < beatsCalc,
      beatsReady < inState(_data) & ~reqFire,
      If(wrespBad, then: [wErr < Const(1)]),
      Case(state, [
        CaseItem(Const(_idle, width: 4), [
          If(
            ringPend,
            then: [
              ringPend < Const(0),
              ringErrReg < Const(0),
              headReg < Const(0, width: iw),
            ],
          ),
          If(
            startFrame,
            then: [
              ended < Const(0),
              bufOver < Const(0),
              wErr < Const(0),
              descFail < Const(0),
              count < Const(0, width: 16),
              beatsLeft < Const(0, width: bw),
              wordsLeft < Const(0, width: ww),
              status < Const(0, width: 8),
              hValid < Const(1),
              hData < rData,
              hBytes < rBytes,
              hLast < rLast,
              hStatus < rStatus,
              If(
                headReg.eq(tail),
                then: [missed < Const(1), state < Const(_drain, width: 4)],
                orElse: [missed < Const(0), state < Const(_descReq, width: 4)],
              ),
            ],
          ),
        ]),
        CaseItem(Const(_descReq, width: 4), [
          If(
            reqFire,
            then: [
              dBeat < Const(0, width: 2),
              dErr < Const(0),
              state < Const(_descWait, width: 4),
            ],
          ),
        ]),
        CaseItem(Const(_descWait, width: 4), [
          If(
            rdFire,
            then: [
              dBeat < dBeat + 1,
              dErr < dErr | m.rdataErr,
              If(dBeat.eq(0), then: [dw0 < m.rdataData]),
              If(dBeat.eq(1), then: [dw1 < m.rdataData]),
              If(
                dBeat.eq(2),
                then: [
                  dw2 < m.rdataData,
                  alignedR < aligned,
                  sizeZero < m.rdataData.getRange(0, 16).eq(0),
                ],
              ),
              If(m.rdataLast, then: [state < Const(_descEval, width: 4)]),
            ],
          ),
        ]),
        CaseItem(Const(_descEval, width: 4), [
          If.block([
            Iff(dErr, [descFail < Const(1), state < Const(_drain, width: 4)]),
            ElseIf(~own, [missed < Const(1), state < Const(_drain, width: 4)]),
            ElseIf(~alignedR | sizeZero, [
              bufOver < Const(1),
              state < Const(_data, width: 4),
            ]),
            Else([
              bufAddr < dAddr,
              rem < size.zeroExtend(ww),
              wordsLeft <
                  ((size.zeroExtend(ww) + Const(3, width: ww)) >>> 2).named(
                    'size_words',
                  ),
              state < Const(_data, width: 4),
            ]),
          ]),
        ]),
        CaseItem(Const(_data, width: 4), [
          If(
            reqFire,
            then: [
              beatsLeft < beats.getRange(0, bw),
              wordsLeft < wordsLeft - beats,
              bufAddr <
                  bufAddr +
                      (beats.zeroExtend(max(aw, ww)) << 2).getRange(0, aw),
            ],
          ),
          If(wFire, then: [beatsLeft < beatsLeft - 1]),
          If(
            pop,
            then: [
              rem < rem - put.zeroExtend(ww),
              count < count + put.zeroExtend(16),
              hValid < Const(0),
              If(over, then: [bufOver < Const(1)]),
              If(sLast, then: [ended < Const(1), status < sStatus]),
            ],
          ),
          If(
            beatsLeft.eq(0) & ~dataReqValid,
            then: [
              If.block([
                Iff(ended, [state < Const(_end, width: 4)]),
                ElseIf(bufOver | stopW | wordsLeft.eq(0), [
                  state < Const(_drain, width: 4),
                ]),
              ]),
            ],
          ),
        ]),
        CaseItem(Const(_drain, width: 4), [
          If(
            drainTake,
            then: [
              hValid < Const(0),
              If(
                sLast,
                then: [status < sStatus, state < Const(_end, width: 4)],
              ),
            ],
          ),
        ]),
        CaseItem(Const(_end, width: 4), [
          If(
            inflight.eq(0),
            then: [
              state < Const(_idle, width: 4),
              If.block([
                Iff(missed, [rxMissedReg < Const(1)]),
                ElseIf(descFail | wErr, [
                  ringErrReg < Const(1),
                  errCodeReg < Const(errWrite, width: 3),
                  rxErrReg < Const(1),
                ]),
                ElseIf(~keep, [errCodeReg < statusCode, rxErrReg < Const(1)]),
                Else([
                  code < statusCode,
                  wbReqDone < Const(0),
                  wbData < Const(0),
                  wbBeat < Const(0),
                  state < Const(_writeBack, width: 4),
                ]),
              ]),
            ],
          ),
        ]),
        CaseItem(Const(_writeBack, width: 4), [
          If(reqFire, then: [wbData < Const(1)]),
          If(wFire, then: [wbData < Const(0)]),
          If(
            wrespFire,
            then: [
              If(
                wbBeat | m.wrespErr,
                then: [wbReqDone < Const(1)],
                orElse: [wbBeat < Const(1)],
              ),
            ],
          ),
          If(
            wbReqDone & inflight.eq(0),
            then: [
              If(
                wErr,
                then: [
                  ringErrReg < Const(1),
                  errCodeReg < Const(errWrite, width: 3),
                  rxErrReg < Const(1),
                ],
                orElse: [
                  headReg < (headReg + 1) & mask,
                  rxDoneReg < Const(1),
                  If(
                    code.neq(0),
                    then: [errCodeReg < code, rxErrReg < Const(1)],
                  ),
                ],
              ),
              state < Const(_idle, width: 4),
            ],
          ),
        ]),
      ]),
      If(ringReset, then: [ringPend < Const(1)]),
    ]);
  }
}

import 'dart:math';

import 'package:rohd/rohd.dart';

import '../../arith/fpu_config.dart' show harborStableDefinitionName;
import '../../bus/port/memory_waist.dart';
import 'eth_config.dart';

/// TX descriptor DMA on the sys clock.
///
/// The DMA reads TX descriptors and frame buffers through a memory master
/// waist and writes the frames to the sys side of a TX frame FIFO. It works
/// on one frame at a time, in three passes:
///
/// 1. It reads the descriptors from `head` up to the one with EOP and adds
///    the lengths. A read error, no EOP before `tail` or a sum larger than
///    [maxFrameBytes] stops the ring before a buffer read.
/// 2. It reads the buffers in INCR bursts of up to `burstBeats` beats that
///    never cross 4 KB, with up to `outstanding` requests in flight, and
///    packs the bytes into FIFO words. The first descriptor comes from
///    pass 1, the others are read again.
/// 3. After the last word is in the FIFO and every read is back, it writes
///    word 3 of each descriptor, waits for the WRESP, then clears OWN in
///    word 2 and waits for that WRESP. After the last WRESP it moves `head`
///    and pulses `tx_done` if a descriptor of the frame has IRQ.
///
/// The word 3 error codes are [errOk], [errRead], [errNoEop], [errOversize]
/// and [errClkLost]. Codes 1 to 3 go only to the first descriptor of the
/// frame. They set `ring_err`, which stops the ring until `ring_reset`, and
/// `head` does not move. A read error marks the frame
/// with `w_err`, so the FIFO drops it. A frame that the FIFO drops because
/// the TX clock is lost gets [errClkLost] and the ring continues.
/// `tx_err` pulses for each nonzero code.
///
/// A descriptor at `head` with OWN clear makes the DMA wait for a new value
/// of `tail`. When `tx_en` is low, the DMA starts no new frame and keeps
/// `head`. A pulse on `ring_reset` is kept until the DMA is idle. Then it
/// sets `head` to 0 and clears `ring_err`. No new frame starts while the
/// reset is pending.
///
/// A buffer read is sent only when its beats fit in `w_free`, the free FIFO
/// words, less the beats of reads in flight, the output word and a part
/// word. Each beat gives at most one FIFO word, so the DMA always takes the
/// read data at once and never holds the bus while the wire drains the
/// FIFO. When the space is short, the burst is made shorter. A frame has
/// at most 380 words and the FIFO at least 512, so after the earlier frames
/// go out there is always space for the next beat.
///
/// A buffer with a length and an address that does not fit in the waist
/// address width is a read error.
///
/// The low bits of `ring_base` below the descriptor size are ignored. The
/// write to word 2 sets bits 31 to 24 to 0. If the lengths change between
/// pass 1 and pass 2 to a larger sum, the frame stops with [errOversize].
class HarborEthDmaTx extends Module {
  /// Configuration of the MAC that contains this DMA.
  final HarborEthernetConfig config;

  /// No error.
  static const errOk = 0;

  /// A descriptor or buffer read failed.
  static const errRead = 1;

  /// No EOP before `tail`.
  static const errNoEop = 2;

  /// The frame is larger than [maxFrameBytes].
  static const errOversize = 3;

  /// Largest frame in bytes, the data of a VLAN frame without the FCS.
  static const maxFrameBytes = 1518;

  /// The TX clock was lost, so the FIFO dropped the frame.
  static const errClkLost = 4;

  /// Width of the ring indexes.
  static const indexWidth = 12;

  Logic get head => output('head');
  Logic get txDone => output('tx_done');
  Logic get txErr => output('tx_err');
  Logic get ringErr => output('ring_err');

  /// Code of the last nonzero error.
  Logic get errCode => output('err_code');

  /// High while the DMA works on a frame.
  Logic get busy => output('busy');

  Logic get wValid => output('w_valid');
  Logic get wData => output('w_data');
  Logic get wBytes => output('w_bytes');
  Logic get wLast => output('w_last');
  Logic get wErr => output('w_err');

  static const _idle = 0;
  static const _descReq = 1;
  static const _descWait = 2;
  static const _descEval = 3;
  static const _buf = 4;
  static const _flush = 5;
  static const _flushWait = 6;
  static const _writeBack = 7;

  /// [ringBase] has the width of the waist address. [ringSize] is log2 of
  /// the entries. [tail] is the next index the driver gives.
  HarborEthDmaTx(
    Logic clk,
    Logic reset, {
    required HarborMemoryWaist waist,
    required this.config,
    required Logic ringBase,
    required Logic ringSize,
    required Logic tail,
    required Logic txEn,
    required Logic ringReset,
    required Logic wReady,
    required Logic wFree,
    required Logic txClkLost,
    super.name = 'eth_dma_tx',
  }) : super(
         definitionName: harborStableDefinitionName('HarborEthDmaTx', [
           'a${waist.config.addressWidth}',
           'i${waist.config.idWidth}',
           'n${waist.config.outstanding}',
           'd${config.descBytes}',
           'f${config.txFifoBytes}',
           'o${config.outstanding}',
           'b${config.burstBeats}',
         ]),
       ) {
    final aw = waist.config.addressWidth;
    if (waist.config.dataWidth != 32 || aw < 12 || aw > 64) {
      throw ArgumentError(
        'HarborEthDmaTx needs 32-bit data and a 12 to 64-bit address, '
        'got ${waist.config}',
      );
    }
    const iw = indexWidth;
    const ww = 17;
    const lenW = HarborMemoryWaistConfig.lenWidth;
    final descBytes = config.descBytes;
    final descShift = descBytes.bitLength - 1;
    final descBeats = descBytes ~/ 4;
    final limit = min(config.outstanding, waist.config.outstanding);
    final cw = limit.bitLength + 1;
    final sw = max(17, config.txFifoBytes.bitLength) + 1;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    ringBase = addInput('ring_base', ringBase, width: aw);
    ringSize = addInput('ring_size', ringSize, width: 4);
    tail = addInput('tail', tail, width: iw);
    txEn = addInput('tx_en', txEn);
    ringReset = addInput('ring_reset', ringReset);
    wReady = addInput('w_ready', wReady);
    final fw = (config.txFifoBytes ~/ 4).bitLength;
    wFree = addInput('w_free', wFree, width: fw);
    txClkLost = addInput('tx_clk_lost', txClkLost);

    final headOut = addOutput('head', width: iw);
    final txDoneOut = addOutput('tx_done');
    final txErrOut = addOutput('tx_err');
    final ringErrOut = addOutput('ring_err');
    final errCodeOut = addOutput('err_code', width: 3);
    final busyOut = addOutput('busy');
    final wValidOut = addOutput('w_valid');
    final wDataOut = addOutput('w_data', width: 32);
    final wBytesOut = addOutput('w_bytes', width: 2);
    final wLastOut = addOutput('w_last');
    final wErrOut = addOutput('w_err');

    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.provider, uniquify: (n) => 'm_$n');

    final state = Logic(name: 'state', width: 4);
    Logic inState(int s) => state.eq(Const(s, width: 4));
    final idx = Logic(name: 'idx', width: iw);
    final headReg = Logic(name: 'head_reg', width: iw);
    final eopIdx = Logic(name: 'eop_idx', width: iw);
    final wbLast = Logic(name: 'wb_last', width: iw);
    final pass2 = Logic(name: 'pass2');
    final sum = Logic(name: 'sum', width: sw);
    final sum2 = Logic(name: 'sum2', width: sw);
    final irqAcc = Logic(name: 'irq_acc');
    final firstLen = Logic(name: 'first_len', width: 16);
    final dBeat = Logic(name: 'd_beat', width: 4);
    final dErr = Logic(name: 'd_err');
    final dw0 = Logic(name: 'dw0', width: 32);
    final dw1 = Logic(name: 'dw1', width: 32);
    final dw2 = Logic(name: 'dw2', width: 32);
    final bufEndLo = Logic(name: 'buf_end_lo', width: 2);
    final reqAddr = Logic(name: 'req_addr', width: aw);
    // Words to the next 4 KB boundary, a flop that follows `req_addr`.
    final toBoundary = Logic(name: 'to_boundary', width: ww);
    final reqWords = Logic(name: 'req_words', width: ww);
    final rxWords = Logic(name: 'rx_words', width: ww);
    // The first byte and the byte count of the next read beat are flops,
    // set with the buffer and after each beat, so the packer starts from
    // flops.
    final beatLo = Logic(name: 'beat_lo', width: 2);
    final beatN = Logic(name: 'beat_n', width: 3);
    Logic endHiOf(Logic endLo) =>
        mux(endLo.eq(0), Const(4, width: 3), endLo.zeroExtend(3));
    final inflight = Logic(name: 'inflight', width: cw);
    final acc = Logic(name: 'acc', width: 32);
    final accN = Logic(name: 'acc_n', width: 3);
    final oValid = Logic(name: 'o_valid');
    final oData = Logic(name: 'o_data', width: 32);
    final oBytes = Logic(name: 'o_bytes', width: 2);
    final oLast = Logic(name: 'o_last');
    final oErr = Logic(name: 'o_err');
    final abort = Logic(name: 'abort');
    final fail = Logic(name: 'fail');
    final code = Logic(name: 'code', width: 3);
    final wbData = Logic(name: 'wb_data');
    final wbBeat = Logic(name: 'wb_beat');
    final wbReqDone = Logic(name: 'wb_req_done');
    final wbErr = Logic(name: 'wb_err');
    final ringErrReg = Logic(name: 'ring_err_reg');
    final errCodeReg = Logic(name: 'err_code_reg', width: 3);
    final waitKick = Logic(name: 'wait_kick');
    final tailSeen = Logic(name: 'tail_seen', width: iw);
    final txDoneReg = Logic(name: 'tx_done_reg');
    final txErrReg = Logic(name: 'tx_err_reg');
    final ringPend = Logic(name: 'ring_pend');

    Logic minOf(Logic a, Logic b) => mux(a.lt(b), a, b);

    final mask = [
      for (var i = iw - 1; i >= 0; i--) ringSize.gt(Const(i, width: 4)),
    ].swizzle().named('ring_mask');
    final nextIdx = ((idx + 1) & mask).named('next_idx');
    final base = (ringBase & ~Const(descBytes - 1, width: aw)).named(
      'ring_base_aligned',
    );
    final ew = max(aw, iw + descShift);
    final descAddr = (base + (idx.zeroExtend(ew) << descShift).getRange(0, aw))
        .named('desc_addr');

    // Descriptor fields from the last descriptor read.
    final own = dw2[31];
    final dLen = dw2.getRange(0, 16);
    final eop = dw2[17];
    final irq = dw2[18];
    final dAddr = [dw1, dw0].swizzle().getRange(0, aw).named('d_addr');
    final dBad = Logic(name: 'd_addr_bad');

    // Buffer setup from a start address and a length: the request address,
    // the words to the 4 KB boundary, the words of the buffer, the end byte
    // and the first beat's range. It is computed when word 2 of a
    // descriptor comes, so the evaluation only selects flops.
    final setupW = aw + ww + ww + 2 + 2 + 3;
    Logic setupOf(Logic a, Logic len) {
      final lo = a.getRange(0, 2);
      final words = mux(
        len.eq(0),
        Const(0, width: ww),
        (lo.zeroExtend(ww) + len.zeroExtend(ww) + Const(3, width: ww)) >>> 2,
      );
      final endLo = lo + len.getRange(0, 2);
      // One word when the bytes end in the first word: 0 < len <= 4 - lo.
      final oneWord =
          len.neq(0) &
          len.getRange(3).eq(0) &
          len.getRange(0, 3).lte(Const(4, width: 3) - lo.zeroExtend(3));
      final n =
          mux(oneWord, endHiOf(endLo), Const(4, width: 3)) - lo.zeroExtend(3);
      return [
        n,
        lo,
        endLo,
        words,
        Const(1024, width: ww) - a.getRange(2, 12).zeroExtend(ww),
        [a.getRange(2), Const(0, width: 2)].swizzle(),
      ].swizzle();
    }

    final curSetup = Logic(name: 'cur_setup', width: setupW);
    final firstSetup = Logic(name: 'first_setup', width: setupW);

    List<Conditional> loadBuf(Logic set) {
      var at = 0;
      Logic f(int w) {
        final x = set.getRange(at, at + w);
        at += w;
        return x;
      }

      final addr = f(aw);
      final bound = f(ww);
      final words = f(ww);
      final endLo = f(2);
      final lo = f(2);
      final n = f(3);
      return [
        bufEndLo < endLo,
        beatLo < lo,
        beatN < n,
        reqAddr < addr,
        toBoundary < bound,
        reqWords < words,
        rxWords < words,
      ];
    }

    // Request channel.
    // FIFO words that the reads in flight, the packer and an armed request
    // can still need. The owed count, the space and the burst length are
    // flops. The space is thus 2 cycles old, so after a request is sent no
    // new one is armed for 2 cycles (`arm_wait`). In that time the owed
    // count can only go down, so the space never shows more than is free.
    final resv = Logic(name: 'resv_beats', width: ww);
    final armed = Logic(name: 'buf_req_armed');
    final beats = Logic(name: 'beats', width: ww);
    final armWait = Logic(name: 'arm_wait', width: 2);
    final owed =
        (resv +
                oValid.zeroExtend(ww) +
                accN.neq(0).zeroExtend(ww) +
                mux(armed, beats, Const(0, width: ww)))
            .named('owed_words');
    final owedR = Logic(name: 'owed_r', width: ww);
    final freeW = wFree.zeroExtend(ww);
    final spaceNext = mux(
      freeW.gt(owedR),
      freeW - owedR,
      Const(0, width: ww),
    ).named('space_next');
    final space = Logic(name: 'space_words', width: ww);
    final beatsCalc = minOf(
      minOf(reqWords, Const(config.burstBeats, width: ww)),
      minOf(toBoundary, space),
    ).named('beats_calc');
    final room = inflight.lt(Const(limit, width: cw)).named('room');
    final bufReqValid = (inState(_buf) & armed & ~abort & room).named(
      'buf_req_valid',
    );
    final wbReqValid =
        (inState(_writeBack) & ~wbReqDone & ~wbData & inflight.eq(0)).named(
          'wb_req_valid',
        );
    m.reqValid <= inState(_descReq) | bufReqValid | wbReqValid;
    m.reqId <= Const(0, width: waist.config.idWidth);
    m.reqWrite <= inState(_writeBack);
    m.reqAddr <=
        mux(
          inState(_buf),
          reqAddr,
          mux(
            inState(_writeBack),
            descAddr + mux(wbBeat, Const(8, width: aw), Const(12, width: aw)),
            descAddr,
          ),
        );
    m.reqLen <=
        mux(
          inState(_buf),
          (beats - 1).getRange(0, lenW),
          mux(
            inState(_writeBack),
            Const(0, width: lenW),
            Const(descBeats - 1, width: lenW),
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

    // Output word register to the FIFO.
    final oTake = (oValid & wReady).named('o_take');
    final canTake = (~oValid | wReady).named('can_take');

    // Read data. READY is high only with a read in flight.
    final busyIn = inflight.neq(0);
    final rdTake =
        (busyIn & (inState(_descWait) | (inState(_buf) & (abort | canTake))))
            .named('rd_take');
    m.rdataReady <= rdTake;
    final rdFire = (m.rdataValid & rdTake).named('rd_fire');
    final rdLastFire = (rdFire & m.rdataLast).named('rd_last_fire');

    // Write back: word 3 first (wb_beat low), then byte 3 of word 2 (OWN).
    final word3 = [
      Const(0, width: 28),
      code,
      Const(1),
    ].swizzle().named('word3');
    m.wdataValid <= inState(_writeBack) & wbData;
    m.wdataData <= mux(wbBeat, Const(0, width: 32), word3);
    m.wdataStrb <= mux(wbBeat, Const(0x8, width: 4), Const(0xf, width: 4));
    m.wdataLast <= Const(1);
    final wFire = (m.wdataValid & m.wdataReady).named('w_fire');
    m.wrespReady <= inState(_writeBack) & busyIn;
    final wrespFire = (m.wrespValid & m.wrespReady).named('wresp_fire');

    final inflightNext =
        (inflight +
                reqFire.zeroExtend(cw) -
                rdLastFire.zeroExtend(cw) -
                wrespFire.zeroExtend(cw))
            .named('inflight_next');

    // Byte packer. The accumulator holds 0 to 4 bytes, so the last word of a
    // frame is always in it when the last buffer ends.
    final lo = beatLo;
    final n = beatN;
    final keep = [
      for (var i = 3; i >= 0; i--) n.gt(Const(i, width: 3)).replicate(8),
    ].swizzle().named('beat_keep');
    final shifted =
        ((m.rdataData >>> [lo, Const(0, width: 3)].swizzle()) & keep).named(
          'beat_shifted',
        );
    final total = (accN.zeroExtend(4) + n.zeroExtend(4)).named('pack_total');
    final combined =
        (acc.zeroExtend(64) |
                (shifted.zeroExtend(64) <<
                    [accN, Const(0, width: 3)].swizzle()))
            .named('pack_combined');
    final over = total.gt(Const(4, width: 4)).named('pack_over');
    final packFire = (rdFire & inState(_buf) & ~abort & ~m.rdataErr).named(
      'pack_fire',
    );

    final startFrame =
        (txEn &
                ~ringErrReg &
                ~waitKick &
                ~ringPend &
                ~ringReset &
                headReg.neq(tail))
            .named('start_frame');
    // The length sums and their checks are registered when word 2 of the
    // descriptor comes, so the evaluation starts from flops.
    final sumNext = Logic(name: 'sum_next', width: sw);
    final sum2Next = Logic(name: 'sum2_next', width: sw);
    final tooBig = Logic(name: 'too_big');
    final sum2Over = Logic(name: 'sum2_over');
    final rdLen = m.rdataData.getRange(0, 16).zeroExtend(sw);
    final sumIn = (sum + rdLen).named('sum_in');
    final sum2In = (sum2 + rdLen).named('sum2_in');
    // `idx` and `head` do not change between the descriptor request and
    // its evaluation, so the compare is a flop.
    final atHead = Logic(name: 'at_head');

    List<Conditional> toWriteBack(Logic last) => [
      idx < headReg,
      wbLast < last,
      wbReqDone < Const(0),
      wbData < Const(0),
      wbBeat < Const(0),
      wbErr < Const(0),
      state < Const(_writeBack, width: 4),
    ];

    List<Conditional> failTo(int c) => [
      fail < Const(1),
      code < Const(c, width: 3),
      ...toWriteBack(headReg),
    ];

    List<Conditional> abortWith(int c) => [
      abort < Const(1),
      oErr < Const(1),
      code < Const(c, width: 3),
    ];

    headOut <= headReg;
    txDoneOut <= txDoneReg;
    txErrOut <= txErrReg;
    ringErrOut <= ringErrReg;
    errCodeOut <= errCodeReg;
    busyOut <= ~inState(_idle);
    wValidOut <= oValid;
    wDataOut <= oData;
    wBytesOut <= oBytes;
    wLastOut <= oLast;
    wErrOut <= oErr;

    Sequential(clk, reset: reset, [
      txDoneReg < Const(0),
      txErrReg < Const(0),
      inflight < inflightNext,
      // The four sums come from flops, the late fire signals only select.
      resv <
          mux(
            reqFire & inState(_buf),
            mux(rdFire & inState(_buf), resv + beats - 1, resv + beats),
            mux(rdFire & inState(_buf), resv - 1, resv),
          ),
      owedR < owed,
      atHead < idx.eq(headReg),
      space < spaceNext,
      // An armed request keeps its length. The space only grows meanwhile.
      If(
        armed,
        then: [
          If(reqFire | abort | ~inState(_buf), then: [armed < Const(0)]),
        ],
        orElse: [
          beats < beatsCalc,
          armed <
              inState(_buf) &
                  reqWords.neq(0) &
                  ~abort &
                  space.neq(0) &
                  armWait.eq(0),
        ],
      ),
      If.block([
        Iff(reqFire & inState(_buf), [armWait < Const(2, width: 2)]),
        ElseIf(armWait.neq(0), [armWait < armWait - 1]),
      ]),
      If(oTake, then: [oValid < Const(0)]),
      Case(state, [
        CaseItem(Const(_idle, width: 4), [
          If(
            ringPend,
            then: [
              ringPend < Const(0),
              ringErrReg < Const(0),
              headReg < Const(0, width: iw),
              waitKick < Const(0),
            ],
          ),
          If(tail.neq(tailSeen), then: [waitKick < Const(0)]),
          If(
            startFrame,
            then: [
              idx < headReg,
              pass2 < Const(0),
              sum < Const(0, width: sw),
              irqAcc < Const(0),
              fail < Const(0),
              state < Const(_descReq, width: 4),
            ],
          ),
        ]),
        CaseItem(Const(_descReq, width: 4), [
          If(
            reqFire,
            then: [
              dBeat < Const(0, width: 4),
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
                  curSetup < setupOf(dAddr, rdLen.getRange(0, 16)),
                  dBad <
                      (aw < 64
                              ? [dw1, dw0].swizzle().getRange(aw).or()
                              : Const(0)) &
                          rdLen.getRange(0, 16).neq(0),
                  sumNext < sumIn,
                  sum2Next < sum2In,
                  tooBig < sumIn.gt(Const(maxFrameBytes, width: sw)),
                  sum2Over < sum2In.gt(sum),
                ],
              ),
              If(m.rdataLast, then: [state < Const(_descEval, width: 4)]),
            ],
          ),
        ]),
        CaseItem(Const(_descEval, width: 4), [
          If.block([
            Iff(~pass2, [
              If.block([
                Iff(dErr, failTo(errRead)),
                ElseIf(~own, [
                  waitKick < Const(1),
                  tailSeen < tail,
                  state < Const(_idle, width: 4),
                ]),
                ElseIf(tooBig, failTo(errOversize)),
                ElseIf(dBad, failTo(errRead)),
                Else([
                  sum < sumNext,
                  irqAcc < irqAcc | irq,
                  If(atHead, then: [firstSetup < curSetup, firstLen < dLen]),
                  If.block([
                    Iff(eop, [
                      eopIdx < idx,
                      pass2 < Const(1),
                      idx < headReg,
                      sum2 < mux(atHead, dLen, firstLen).zeroExtend(sw),
                      abort < Const(0),
                      oErr < Const(0),
                      acc < Const(0, width: 32),
                      accN < Const(0, width: 3),
                      ...loadBuf(
                        mux(atHead, curSetup, firstSetup).named('start_setup'),
                      ),
                      state < Const(_buf, width: 4),
                    ]),
                    ElseIf(nextIdx.eq(tail), failTo(errNoEop)),
                    Else([idx < nextIdx, state < Const(_descReq, width: 4)]),
                  ]),
                ]),
              ]),
            ]),
            Else([
              If.block([
                Iff(dErr | dBad, [
                  ...abortWith(errRead),
                  state < Const(_flush, width: 4),
                ]),
                ElseIf(sum2Over, [
                  ...abortWith(errOversize),
                  state < Const(_flush, width: 4),
                ]),
                Else([
                  sum2 < sum2Next,
                  ...loadBuf(curSetup),
                  state < Const(_buf, width: 4),
                ]),
              ]),
            ]),
          ]),
        ]),
        CaseItem(Const(_buf, width: 4), [
          If(
            reqFire,
            then: [
              reqAddr <
                  reqAddr +
                      (beats.zeroExtend(max(aw, ww)) << 2).getRange(0, aw),
              reqWords < reqWords - beats,
              toBoundary <
                  mux(
                    toBoundary.eq(beats),
                    Const(1024, width: ww),
                    toBoundary - beats,
                  ),
            ],
          ),
          If(
            rdFire,
            then: [
              rxWords < rxWords - 1,
              beatLo < Const(0, width: 2),
              beatN < mux(rxWords.eq(2), endHiOf(bufEndLo), Const(4, width: 3)),
              If(m.rdataErr & ~abort, then: abortWith(errRead)),
            ],
          ),
          If(
            packFire,
            then: [
              If(
                over,
                then: [
                  oValid < Const(1),
                  oData < combined.getRange(0, 32),
                  oBytes < Const(0, width: 2),
                  oLast < Const(0),
                  acc < combined.getRange(32, 64),
                  accN < (total - 4).getRange(0, 3),
                ],
                orElse: [
                  acc < combined.getRange(0, 32),
                  accN < total.getRange(0, 3),
                ],
              ),
            ],
          ),
          If(
            inflight.eq(0) & (abort | rxWords.eq(0)),
            then: [
              If(
                abort | idx.eq(eopIdx),
                then: [state < Const(_flush, width: 4)],
                orElse: [idx < nextIdx, state < Const(_descReq, width: 4)],
              ),
            ],
          ),
        ]),
        CaseItem(Const(_flush, width: 4), [
          If(
            canTake,
            then: [
              If(
                accN.neq(0) | abort,
                then: [
                  oValid < Const(1),
                  oData < acc,
                  oBytes < accN.getRange(0, 2),
                  oLast < Const(1),
                  state < Const(_flushWait, width: 4),
                ],
                orElse: [code < Const(errOk, width: 3), ...toWriteBack(eopIdx)],
              ),
            ],
          ),
        ]),
        CaseItem(Const(_flushWait, width: 4), [
          If(
            oTake,
            then: [
              oLast < Const(0),
              If(
                abort,
                then: [fail < Const(1), ...toWriteBack(headReg)],
                orElse: [
                  code <
                      mux(
                        txClkLost,
                        Const(errClkLost, width: 3),
                        Const(errOk, width: 3),
                      ),
                  ...toWriteBack(eopIdx),
                ],
              ),
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
                wbBeat,
                then: [
                  wbBeat < Const(0),
                  If(
                    idx.eq(wbLast),
                    then: [wbReqDone < Const(1)],
                    orElse: [idx < nextIdx],
                  ),
                ],
                orElse: [wbBeat < Const(1)],
              ),
              If(m.wrespErr, then: [wbErr < Const(1), wbReqDone < Const(1)]),
            ],
          ),
          If(
            wbReqDone & inflight.eq(0),
            then: [
              oErr < Const(0),
              If(
                fail | wbErr,
                then: [
                  ringErrReg < Const(1),
                  errCodeReg < mux(fail, code, Const(errRead, width: 3)),
                  txErrReg < Const(1),
                ],
                orElse: [
                  headReg < (eopIdx + 1) & mask,
                  txDoneReg < irqAcc,
                  If(
                    code.neq(0),
                    then: [errCodeReg < code, txErrReg < Const(1)],
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

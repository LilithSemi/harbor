import 'package:rohd/rohd.dart';

import '../arith/fpu_config.dart';
import '../bus/port/memory_waist.dart';

/// System-domain burst fetcher: reads a scanline from memory over a memory
/// master waist and streams it into an external line buffer.
///
/// On a [fetchStart] pulse it reads [words] sequential 32-bit words starting
/// at [fetchAddr] (a waist of 64 bits gives two words in each beat, low word
/// first, and rounds [words] up to whole beats; [fetchAddr] must then be a
/// multiple of 8 and the line buffer takes one word each cycle, so the beat
/// after one waits a cycle), driving [wrEn]/[wrIdx]/[wrData] to write each word into
/// the buffer selected by [fillSel]. The inputs go through one register, so
/// the line starts one cycle after [fetchStart]. [busy] is high from the
/// cycle after [fetchStart] until the line is complete, [done] pulses for one
/// cycle when the line is complete.
///
/// Reads only, one ID (0), so responses stay in order. Each request is INCR,
/// with the size of the waist word, and LEN set for `beats = min(burstWords,
/// beats left in the line, beats to the next 4 KB boundary)`. [burstWords] is
/// the beats per request, 1 to 256: the next request goes out as soon as
/// [waist] takes the previous one, so [waist]'s `outstanding` is what limits
/// how far a line can pipeline. A beat with RDATA_ERR still writes zero into
/// the line buffer and counts towards the line, and pulses [err] for that
/// one cycle.
class HarborLineFetcher extends Module {
  /// Line-buffer write stream.
  Logic get wrEn => output('wr_en');
  Logic get wrSel => output('wr_sel');
  Logic get wrIdx => output('wr_idx');
  Logic get wrData => output('wr_data');

  /// High during a burst.
  Logic get busy => output('busy');

  /// Pulses for one cycle when a line finishes.
  Logic get done => output('done');

  /// Pulses for one cycle on a read beat with RDATA_ERR.
  Logic get err => output('err');

  final int maxWords;

  /// Beats requested at a time, 1 to 256.
  final int burstWords;

  HarborLineFetcher({
    required Logic clk,
    required Logic reset,
    required Logic fetchStart,
    required Logic fetchAddr,
    required Logic words,
    required Logic fillSel,
    required HarborMemoryWaist waist,
    this.maxWords = 1024,
    this.burstWords = 16,
    super.name = 'line_fetcher',
  }) : super(
         definitionName: harborStableDefinitionName('HarborLineFetcher', [
           if (waist.config.dataWidth == 64) 'd64',
           'b$burstWords',
           'w$maxWords',
           'i${waist.config.idWidth}',
           'n${waist.config.outstanding}',
         ]),
       ) {
    if (waist.config.addressWidth != 32 ||
        (waist.config.dataWidth != 32 && waist.config.dataWidth != 64)) {
      throw ArgumentError(
        'HarborLineFetcher needs a 32-bit address and a 32 or 64-bit data '
        'waist, got ${waist.config}',
      );
    }
    if (burstWords < 1 || burstWords > 256) {
      throw ArgumentError.value(burstWords, 'burstWords', 'must be 1 to 256');
    }
    final idxW = (maxWords - 1).bitLength < 1 ? 1 : (maxWords - 1).bitLength;
    const ww = 17;
    const lenW = HarborMemoryWaistConfig.lenWidth;
    const sizeW = HarborMemoryWaistConfig.sizeWidth;
    const burstW = HarborMemoryWaistConfig.burstWidth;
    final idW = waist.config.idWidth;
    final dataW = waist.config.dataWidth;
    final strbW = waist.config.strbWidth;
    // Words of 32 bits in each beat, and the byte size of a beat as a log2.
    final wpb = dataW ~/ 32;
    final beatLog2 = wpb == 2 ? 3 : 2;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    fetchStart = addInput('fetch_start', fetchStart);
    fetchAddr = addInput('fetch_addr', fetchAddr, width: 32);
    words = addInput('words', words, width: 16);
    fillSel = addInput('fill_sel', fillSel);

    addOutput('wr_en');
    addOutput('wr_sel');
    addOutput('wr_idx', width: idxW);
    addOutput('wr_data', width: 32);
    addOutput('busy');
    addOutput('done');
    addOutput('err');

    final m = waist.clone()
      ..pairConnectIO(this, waist, PairRole.provider, uniquify: (n) => 'm_$n');

    Logic minOf(Logic a, Logic b) => mux(a.lt(b), a, b);
    Logic beatsFor(Logic addrIn, Logic remain, String tag) {
      final off = addrIn
          .getRange(beatLog2, 12)
          .zeroExtend(ww)
          .named('page_off_$tag');
      final toBoundary = (Const(4096 >> beatLog2, width: ww) - off).named(
        'to_boundary_$tag',
      );
      return minOf(
        minOf(remain, Const(burstWords, width: ww)),
        toBoundary,
      ).named('beats_$tag');
    }

    final reading = Logic(name: 'reading');
    final reqValid = Logic(name: 'req_valid_reg');
    final addr = Logic(name: 'addr', width: 32);
    final len = Logic(name: 'len', width: lenW);
    final reqLeft = Logic(name: 'req_left', width: ww);
    final idx = Logic(name: 'idx', width: idxW);
    final rdLeft = Logic(name: 'rd_left', width: ww);
    final fillReg = Logic(name: 'fill_reg');
    final doneReg = Logic(name: 'done_reg');

    // The start inputs can come from far away, so they get a register here.
    final start1 = Logic(name: 'start_s1');
    final addr1 = Logic(name: 'addr_s1', width: 32);
    final words1 = Logic(name: 'words_s1', width: 16);
    final fill1 = Logic(name: 'fill_s1');

    // Beats of the line.
    final total =
        (wpb == 2
                ? (words1.zeroExtend(ww) + Const(1, width: ww)) >>
                      Const(1, width: ww)
                : words1.zeroExtend(ww))
            .named('total');
    final firstBeats = beatsFor(addr1, total, 'first');

    // The first request goes out from the start register in the start cycle.
    // When it is taken there, the registers load it as usual and advance one
    // cycle later, with the request held low in that cycle.
    final first = (start1 & ~reading).named('first');
    final firstValid = (first & words1.neq(0)).named('first_valid');
    final advance = Logic(name: 'advance');
    final reqOut = ((reqValid & ~advance) | firstValid).named('req_out');
    final reqFire = (reqOut & m.reqReady & ~first).named('req_fire');
    final firstFire = (firstValid & m.reqReady).named('first_fire');
    final beatsThis = (len.zeroExtend(ww) + Const(1, width: ww)).named(
      'beats_this',
    );
    // addr/len describe the request just fired. reqLeft already excludes
    // it, so the next request's length comes from reqLeft directly, not
    // reqLeft - beatsThis again.
    final nextAddr = (addr + (beatsThis.zeroExtend(32) << beatLog2)).named(
      'next_addr',
    );
    final nextBeats = beatsFor(nextAddr, reqLeft, 'next');

    final rdataFire = Logic(name: 'rdata_fire');

    // Request channel: reads only, one ID, INCR, 32-bit beats.
    m.reqValid <= reqOut;
    m.reqId <= Const(0, width: idW);
    m.reqWrite <= Const(0);
    m.reqAddr <= mux(first, addr1, addr);
    m.reqLen <= mux(first, (firstBeats - 1).getRange(0, lenW), len);
    m.reqSize <= Const(beatLog2, width: sizeW);
    m.reqBurst <= Const(HarborMemoryBurst.incr.value, width: burstW);
    m.reqExclusive <= Const(0);

    // Never writes.
    m.wdataValid <= Const(0);
    m.wdataData <= Const(0, width: dataW);
    m.wdataStrb <= Const(0, width: strbW);
    m.wdataLast <= Const(0);
    m.wrespReady <= Const(0);

    // A 64-bit beat writes its high word in the cycle after the beat.
    final hiPend = Logic(name: 'hi_pend');
    final hiData = Logic(name: 'hi_data', width: 32);
    final lastBeat = Logic(name: 'last_beat');

    // Ready for read data while a line is in flight.
    m.rdataReady <= (wpb == 2 ? (reading & ~hiPend) : (reading | firstValid));
    rdataFire <= m.rdataValid & m.rdataReady;

    // Write stream straight through on each captured beat. An errored beat
    // still writes zero and still counts.
    // A memory can answer in the cycle it takes the first request.
    wrEn <= (wpb == 2 ? (rdataFire | hiPend) : rdataFire);
    wrSel <= mux(first, fill1, fillReg);
    wrIdx <= mux(first, Const(0, width: idxW), idx);
    final lowWord = mux(
      m.rdataErr,
      Const(0, width: 32),
      (wpb == 1 ? m.rdataData : m.rdataData.getRange(0, 32)),
    );
    wrData <= (wpb == 2 ? mux(hiPend, hiData, lowWord) : lowWord);
    err <= rdataFire & m.rdataErr;

    busy <= reading | start1;
    done <= doneReg;

    Sequential(clk, [addr1 < fetchAddr, words1 < words, fill1 < fillSel]);
    Sequential(clk, reset: reset, [
      start1 < fetchStart,
      doneReg < Const(0),
      if (wpb == 2) ...[hiPend < Const(0), lastBeat < Const(0)],
      advance < firstFire,
      If(
        ~reading,
        then: [
          If(
            start1,
            then: [
              addr < addr1,
              len < (firstBeats - 1).getRange(0, lenW),
              reqLeft < (total - firstBeats),
              reqValid < words1.neq(0),
              idx < rdataFire.zeroExtend(idxW),
              rdLeft < total - rdataFire.zeroExtend(ww),
              fillReg < fill1,
              reading < words1.neq(0) & ~(rdataFire & total.eq(1)),
              doneReg < rdataFire & total.eq(1),
            ],
          ),
        ],
        orElse: [
          If(
            reqFire | advance,
            then: [
              addr < nextAddr,
              len < (nextBeats - 1).getRange(0, lenW),
              reqValid < reqLeft.neq(0),
              reqLeft < (reqLeft - nextBeats),
            ],
          ),
          If(
            rdataFire,
            then: [
              idx < (idx + Const(1, width: idxW)),
              rdLeft < (rdLeft - Const(1, width: ww)),
              if (wpb == 2) ...[
                hiPend < Const(1),
                hiData <
                    mux(
                      m.rdataErr,
                      Const(0, width: 32),
                      m.rdataData.getRange(32, 64),
                    ),
                If(rdLeft.eq(1), then: [lastBeat < Const(1)]),
              ] else
                If(
                  rdLeft.eq(1),
                  then: [reading < Const(0), doneReg < Const(1)],
                ),
            ],
          ),
          if (wpb == 2)
            If(
              hiPend,
              then: [
                idx < (idx + Const(1, width: idxW)),
                hiPend < Const(0),
                If(
                  lastBeat,
                  then: [
                    lastBeat < Const(0),
                    reading < Const(0),
                    doneReg < Const(1),
                  ],
                ),
              ],
            ),
        ],
      ),
    ]);
  }
}

/// Line fetcher for a read port that bursts, such as a [HarborSdram]
/// scanout port.
///
/// The port carries 16-bit words. A request asks for `rq_words` of them
/// from the byte address `rq_addr` and is taken on a cycle with `rq_valid`
/// and `rq_ready` high. The data comes back in order on `rd_valid` and
/// `rd_data` with no back pressure. A request never crosses an aligned group
/// of [maxBurst] words, so it never crosses a memory page.
///
/// Every port signal goes straight to or from a register, so the port
/// can be far from the fetcher. Any `rq_ready` pattern is correct. A take
/// clears `rq_valid` on its edge, and the next request comes two cycles
/// after the take, so a port can take at most every other cycle. The data reaches the
/// line buffer one cycle after `rd_valid`. Each pair of 16-bit words, low word first, makes one 32-bit line
/// buffer write. The fetcher ignores the low 2 bits of [fetchAddr], so a
/// line always starts on a 4-byte word. The start inputs go through three
/// registers, so the first request comes three cycles after [fetchStart].
/// Pulse [fetchStart] only while [busy] is low. The [words], [fillSel],
/// [busy] and [done] ports work as in [HarborLineFetcher].
class HarborScanoutFetcher extends Module {
  Logic get rqValid => output('rq_valid');
  Logic get rqAddr => output('rq_addr');
  Logic get rqWords => output('rq_words');

  /// Line-buffer write stream.
  Logic get wrEn => output('wr_en');
  Logic get wrSel => output('wr_sel');
  Logic get wrIdx => output('wr_idx');
  Logic get wrData => output('wr_data');

  /// High from the start of a line until its last word is back.
  Logic get busy => output('busy');

  /// Pulses for one cycle when a line finishes.
  Logic get done => output('done');

  final int maxWords;

  /// Largest request in 16-bit words, a power of two.
  final int maxBurst;

  /// Width of `rq_words`.
  static const rqWordsWidth = 4;

  HarborScanoutFetcher({
    required Logic clk,
    required Logic reset,
    required Logic fetchStart,
    required Logic fetchAddr,
    required Logic words,
    required Logic fillSel,
    required Logic rqReady,
    required Logic rdValid,
    required Logic rdData,
    this.maxWords = 1024,
    this.maxBurst = 8,
    super.name = 'scanout_fetcher',
  }) : super(definitionName: 'HarborScanoutFetcher_b${maxBurst}_w$maxWords') {
    if (maxBurst < 2 ||
        (maxBurst & (maxBurst - 1)) != 0 ||
        maxBurst >= (1 << rqWordsWidth)) {
      throw ArgumentError.value(
        maxBurst,
        'maxBurst',
        'must be a power of two from 2 to ${1 << (rqWordsWidth - 1)}',
      );
    }
    final idxW = (maxWords - 1).bitLength < 1 ? 1 : (maxWords - 1).bitLength;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    fetchStart = addInput('fetch_start', fetchStart);
    fetchAddr = addInput('fetch_addr', fetchAddr, width: 32);
    words = addInput('words', words, width: 16);
    fillSel = addInput('fill_sel', fillSel);
    rqReady = addInput('rq_ready', rqReady);
    rdValid = addInput('rd_valid', rdValid);
    rdData = addInput('rd_data', rdData, width: 16);

    addOutput('rq_valid');
    addOutput('rq_addr', width: 32);
    addOutput('rq_words', width: rqWordsWidth);
    addOutput('wr_en');
    addOutput('wr_sel');
    addOutput('wr_idx', width: idxW);
    addOutput('wr_data', width: 32);
    addOutput('busy');
    addOutput('done');

    const lw = 17;
    final burstBits = maxBurst.bitLength - 1;

    final reading = Logic(name: 'reading');
    final fillReg = Logic(name: 'fill_reg');
    final doneReg = Logic(name: 'done_reg');
    // The request on offer, and the 16-bit words after it.
    final valid = Logic(name: 'rq_valid_reg');
    final addr = Logic(name: 'addr', width: 32);
    final len = Logic(name: 'len', width: rqWordsWidth);
    final reqLeft = Logic(name: 'req_left', width: lw);
    // 16-bit words not yet back, and the low half of a pair.
    final rdLeft = Logic(name: 'rd_left', width: lw);
    final odd = Logic(name: 'odd');
    final low = Logic(name: 'low', width: 16);
    final idx = Logic(name: 'idx', width: idxW);
    final wrEnReg = Logic(name: 'wr_en_reg');
    final wrDataReg = Logic(name: 'wr_data_reg', width: 32);
    final wrIdxReg = Logic(name: 'wr_idx_reg', width: idxW);

    Logic minOf(Logic a, Logic b) => mux(a.lt(b), a, b);

    // Stage 1 takes the start inputs from a far source. Stage 2 holds the
    // first request and starts the read side. Stage 3 is a copy of the
    // request in stage 2 next to the request side, which can be far.
    final start1 = Logic(name: 'start_s1');
    final addr1 = Logic(name: 'addr_s1', width: 30);
    final words1 = Logic(name: 'words_s1', width: 16);
    final fill1 = Logic(name: 'fill_s1');
    final start2 = Logic(name: 'start_s2');
    final addr2 = Logic(name: 'addr_s2', width: 32);
    final len2 = Logic(name: 'len_s2', width: rqWordsWidth);
    final left2 = Logic(name: 'left_s2', width: lw);
    final total2 = Logic(name: 'total_s2', width: lw);
    final any2 = Logic(name: 'any_s2');
    final fill2 = Logic(name: 'fill_s2');
    final start3 = Logic(name: 'start_s3');
    final addr3 = Logic(name: 'addr_s3', width: 32);
    final len3 = Logic(name: 'len_s3', width: rqWordsWidth);
    final left3 = Logic(name: 'left_s3', width: lw);
    final any3 = Logic(name: 'any_s3');

    final startAddr = [addr1, Const(0, width: 2)].concat().named('start_addr');
    // The first request runs to the end of its group.
    final total = [words1, Const(0)].concat().named('total');
    final toGroupEnd =
        (Const(maxBurst, width: lw) -
                startAddr.getRange(1, 1 + burstBits).zeroExtend(lw))
            .named('to_group_end');
    final firstLen = minOf(total, toGroupEnd).named('first_len');

    // Every later request starts on a group, so it asks for
    // min(req_left, maxBurst). The left_* registers hold this for req_left.
    // A start loads them with req_left, so they are correct at the first
    // offer. A take makes them one cycle late, and a take never comes in the
    // cycle after a take.
    final leftSub = Logic(name: 'left_sub', width: lw);
    final leftBig = Logic(name: 'left_big');
    final leftLow = Logic(name: 'left_low');
    final take = Logic(name: 'take');
    final rdValidReg = Logic(name: 'rd_valid_reg');
    final rdDataReg = Logic(name: 'rd_data_reg', width: 16);
    final got = (reading & rdValidReg).named('got');
    final leftSrc = mux(start3, left3, reqLeft).named('left_src');

    rqValid <= valid;
    rqAddr <= addr;
    rqWords <= len;
    wrEn <= wrEnReg;
    wrSel <= fillReg;
    wrIdx <= wrIdxReg;
    wrData <= wrDataReg;
    busy <= reading | start1 | start2 | start3;
    done <= doneReg;

    // Only the control flops reset, so the reset net stays small. A start
    // loads the data flops straight from a start stage, so a synthesis tool
    // that turns a constant load into a set or reset uses that flop.
    Sequential(clk, [
      doneReg < Const(0),
      wrEnReg < Const(0),
      take < valid & rqReady,
      start1 < fetchStart,
      addr1 < fetchAddr.getRange(2),
      words1 < words,
      fill1 < fillSel,
      start2 < start1,
      addr2 < startAddr,
      len2 < firstLen.getRange(0, rqWordsWidth),
      left2 < total - firstLen,
      total2 < total,
      any2 < words1.neq(0),
      fill2 < fill1,
      start3 < start2,
      addr3 < addr2,
      len3 < len2,
      left3 < left2,
      any3 < any2,
      leftSub < leftSrc - maxBurst,
      leftBig < leftSrc.getRange(burstBits).or(),
      leftLow < leftSrc.getRange(0, burstBits).or(),
      rdValidReg < rdValid,
      rdDataReg < rdData,
      If(
        start3,
        then: [addr < addr3, len < len3, valid < any3, reqLeft < left3],
        orElse: [
          If(
            take,
            then: [
              addr < addr + [len, Const(0)].concat().zeroExtend(32),
              len <
                  mux(
                    leftBig,
                    Const(maxBurst, width: rqWordsWidth),
                    reqLeft.getRange(0, burstBits).zeroExtend(rqWordsWidth),
                  ),
              valid < leftBig | leftLow,
              reqLeft < mux(leftBig, leftSub, Const(0, width: lw)),
            ],
            orElse: [
              If(rqReady, then: [valid < Const(0)]),
            ],
          ),
        ],
      ),
      If(
        start2,
        then: [
          rdLeft < total2,
          idx < Const(0, width: idxW),
          odd < Const(0),
          fillReg < fill2,
          reading < any2,
        ],
        orElse: [
          If(
            got,
            then: [
              odd < ~odd,
              If(
                odd,
                then: [
                  wrEnReg < Const(1),
                  wrDataReg < [rdDataReg, low].concat(),
                  wrIdxReg < idx,
                  idx < idx + 1,
                ],
                orElse: [low < rdDataReg],
              ),
              rdLeft < rdLeft - 1,
              If(rdLeft.eq(1), then: [reading < Const(0), doneReg < Const(1)]),
            ],
          ),
        ],
      ),
      If(
        reset,
        then: [
          reading < Const(0),
          valid < Const(0),
          take < Const(0),
          start1 < Const(0),
          start2 < Const(0),
          start3 < Const(0),
          rdValidReg < Const(0),
        ],
      ),
    ]);
  }
}

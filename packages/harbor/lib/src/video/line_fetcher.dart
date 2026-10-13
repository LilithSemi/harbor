import 'package:rohd/rohd.dart';

/// System-domain burst fetcher: reads a scanline from memory over a
/// Wishbone-style master and streams it into an external line buffer.
///
/// On a [fetchStart] pulse it reads [words] sequential 32-bit words from
/// [fetchAddr] (advancing on each `ack`), driving [wrEn]/[wrIdx]/[wrData] to
/// write each word into the buffer selected by [fillSel]. The inputs go
/// through one register, so the line starts one cycle after [fetchStart].
/// [busy] is high from the cycle after [fetchStart] until the line is
/// complete, [done] pulses for one cycle when the line is complete.
///
/// After every [burstWords] words the fetcher drops `cyc` for one cycle, so a
/// shared bus arbiter that locks its grant on `cyc` can serve other masters
/// inside a line.
class HarborLineFetcher extends Module {
  /// Wishbone master outputs.
  Logic get mStb => output('m_stb');
  Logic get mCyc => output('m_cyc');
  Logic get mWe => output('m_we');
  Logic get mAddr => output('m_adr');
  Logic get mSel => output('m_sel');
  Logic get mDataOut => output('m_dat_o');

  /// Line-buffer write stream.
  Logic get wrEn => output('wr_en');
  Logic get wrSel => output('wr_sel');
  Logic get wrIdx => output('wr_idx');
  Logic get wrData => output('wr_data');

  /// High during a burst.
  Logic get busy => output('busy');

  /// Pulses for one cycle when a line finishes.
  Logic get done => output('done');

  final int maxWords;

  /// Words read under one `cyc` before the fetcher gives the bus back.
  final int burstWords;

  HarborLineFetcher({
    required Logic clk,
    required Logic reset,
    required Logic fetchStart,
    required Logic fetchAddr,
    required Logic words,
    required Logic fillSel,
    required Logic mDataIn,
    required Logic mAck,
    this.maxWords = 1024,
    this.burstWords = 16,
    super.name = 'line_fetcher',
  }) : super(definitionName: 'HarborLineFetcher_b$burstWords') {
    if (burstWords < 1) {
      throw ArgumentError.value(burstWords, 'burstWords', 'must be >= 1');
    }
    final idxW = (maxWords - 1).bitLength < 1 ? 1 : (maxWords - 1).bitLength;

    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    fetchStart = addInput('fetch_start', fetchStart);
    fetchAddr = addInput('fetch_addr', fetchAddr, width: 32);
    words = addInput('words', words, width: 16);
    fillSel = addInput('fill_sel', fillSel);
    mDataIn = addInput('m_dat_i', mDataIn, width: 32);
    mAck = addInput('m_ack', mAck);

    addOutput('m_stb');
    addOutput('m_cyc');
    addOutput('m_we');
    addOutput('m_adr', width: 32);
    addOutput('m_sel', width: 4);
    addOutput('m_dat_o', width: 32);
    addOutput('wr_en');
    addOutput('wr_sel');
    addOutput('wr_idx', width: idxW);
    addOutput('wr_data', width: 32);
    addOutput('busy');
    addOutput('done');

    final reading = Logic(name: 'reading');
    final addr = Logic(name: 'addr', width: 32);
    final cnt = Logic(name: 'cnt', width: 16);
    final idx = Logic(name: 'idx', width: idxW);
    final fillReg = Logic(name: 'fill_reg');
    final doneReg = Logic(name: 'done_reg');
    final burstW = burstWords.bitLength;
    final beat = Logic(name: 'beat', width: burstW);
    final yieldBus = Logic(name: 'yield_bus');
    final active = (reading & ~yieldBus).named('active');
    // The start inputs can come from far away, so they get a register here.
    final start1 = Logic(name: 'start_s1');
    final addr1 = Logic(name: 'addr_s1', width: 32);
    final words1 = Logic(name: 'words_s1', width: 16);
    final fill1 = Logic(name: 'fill_s1');

    final capture = active & mAck;

    // Master port.
    mStb <= active;
    mCyc <= active;
    mWe <= Const(0);
    mAddr <= addr;
    mSel <= Const(0xF, width: 4);
    mDataOut <= Const(0, width: 32);

    // Write stream straight through on each captured word.
    wrEn <= capture;
    wrSel <= fillReg;
    wrIdx <= idx;
    wrData <= mDataIn;

    busy <= reading | start1;
    done <= doneReg;

    Sequential(clk, [addr1 < fetchAddr, words1 < words, fill1 < fillSel]);
    Sequential(clk, reset: reset, [
      start1 < fetchStart,
      doneReg < Const(0),
      yieldBus < Const(0),
      If(
        ~reading,
        then: [
          If(
            start1,
            then: [
              addr < addr1,
              cnt < words1,
              idx < Const(0, width: idxW),
              fillReg < fill1,
              beat < Const(0, width: burstW),
              reading < Const(1),
            ],
          ),
        ],
        orElse: [
          If(
            capture,
            then: [
              addr < (addr + Const(4, width: 32)),
              idx < (idx + Const(1, width: idxW)),
              If(
                beat.eq(burstWords - 1),
                then: [
                  beat < Const(0, width: burstW),
                  yieldBus < Const(1),
                ],
                orElse: [beat < beat + 1],
              ),
              If(
                cnt.eq(1),
                then: [reading < Const(0), doneReg < Const(1)],
                orElse: [cnt < (cnt - Const(1, width: 16))],
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
/// line always starts on a 4-byte word. The start inputs go through two
/// registers, so the first request comes two cycles after [fetchStart].
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
    // first request.
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

    final startAddr = [addr1, Const(0, width: 2)].swizzle().named('start_addr');
    // The first request runs to the end of its group.
    final total = [words1, Const(0)].swizzle().named('total');
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
    final leftSrc = mux(start2, left2, reqLeft).named('left_src');

    rqValid <= valid;
    rqAddr <= addr;
    rqWords <= len;
    wrEn <= wrEnReg;
    wrSel <= fillReg;
    wrIdx <= wrIdxReg;
    wrData <= wrDataReg;
    busy <= reading | start1 | start2;
    done <= doneReg;

    // Only the control flops reset, so the reset net stays small. A start
    // loads the data flops straight from start_s2, so a synthesis tool
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
      leftSub < leftSrc - maxBurst,
      leftBig < leftSrc.getRange(burstBits).or(),
      leftLow < leftSrc.getRange(0, burstBits).or(),
      rdValidReg < rdValid,
      rdDataReg < rdData,
      If(
        start2,
        then: [
          addr < addr2,
          len < len2,
          valid < any2,
          reqLeft < left2,
          rdLeft < total2,
          idx < Const(0, width: idxW),
          odd < Const(0),
          fillReg < fill2,
          reading < any2,
        ],
        orElse: [
          If(
            take,
            then: [
              addr < addr + [len, Const(0)].swizzle().zeroExtend(32),
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
          If(
            got,
            then: [
              odd < ~odd,
              If(
                odd,
                then: [
                  wrEnReg < Const(1),
                  wrDataReg < [rdDataReg, low].swizzle(),
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
          rdValidReg < Const(0),
        ],
      ),
    ]);
  }
}

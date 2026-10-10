import 'package:rohd/rohd.dart';

/// System-domain burst fetcher: reads a scanline from memory over a
/// Wishbone-style master and streams it into an external line buffer.
///
/// On a [fetchStart] pulse it reads [words] sequential 32-bit words from
/// [fetchAddr] (advancing on each `ack`), driving [wrEn]/[wrIdx]/[wrData] to
/// write each word into the buffer selected by [fillSel]. [busy] is high during
/// the line, [done] pulses for one cycle when the line is complete.
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

    busy <= reading;
    done <= doneReg;

    Sequential(clk, reset: reset, [
      doneReg < Const(0),
      yieldBus < Const(0),
      If(
        ~reading,
        then: [
          If(
            fetchStart,
            then: [
              addr < fetchAddr,
              cnt < words,
              idx < Const(0, width: idxW),
              fillReg < fillSel,
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

import 'package:rohd/rohd.dart';

import '../soc/target.dart';
import 'double_line_buffer.dart';
import 'line_fetcher.dart';

/// Dual-clock framebuffer scanout for shared main memory.
///
/// The system domain ([sysClk]) bursts scanlines from memory into a double line
/// buffer at full bus speed. The pixel domain ([pixelClk]) scans the prefetched
/// buffer out. The two domains are linked by a req/done toggle handshake: the
/// pixel side issues a request (carrying the line's byte address and the buffer
/// to fill, held stable as a quasi-static multi-cycle path) and the system side
/// toggles done when the burst finishes. Only the two 1-bit toggles cross
/// through synchronizers.
///
/// A [frameStart] pulse primes both buffers (row 0 then row 1). Each
/// [lineStart] swaps to the prefetched buffer and requests the next line into
/// the freed one. [pixel] is `buffer[col]`, [underrun] latches if a requested
/// line had not completed by the swap.
///
/// [pixel] is registered: it is the word at the [col] of the cycle before.
class HarborDualClockScanout extends Module {
  /// Pixel word for the previous cycle's [col] in the active buffer.
  Logic get pixel => output('pixel');

  /// Latches if a line was not ready at a swap.
  Logic get underrun => output('underrun');

  /// Wishbone master (system domain).
  Logic get mStb => output('m_stb');
  Logic get mCyc => output('m_cyc');
  Logic get mWe => output('m_we');
  Logic get mAddr => output('m_adr');
  Logic get mSel => output('m_sel');
  Logic get mDataOut => output('m_dat_o');

  final int maxWords;

  /// The block RAM cell for the line buffers, or null for flops.
  final HarborBlockRam? blockRam;

  HarborDualClockScanout({
    required Logic pixelClk,
    required Logic pixelReset,
    required Logic sysClk,
    required Logic sysReset,
    required Logic frameStart,
    required Logic lineStart,
    required Logic col,
    required Logic fbBase,
    required Logic stride,
    required Logic wordsPerLine,
    required Logic mDataIn,
    required Logic mAck,
    this.maxWords = 1024,
    this.blockRam,
    super.name = 'dual_clock_scanout',
  }) : super(definitionName: 'HarborDualClockScanout') {
    pixelClk = addInput('pixel_clk', pixelClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    sysClk = addInput('sys_clk', sysClk);
    sysReset = addInput('sys_reset', sysReset);
    frameStart = addInput('frame_start', frameStart);
    lineStart = addInput('line_start', lineStart);
    col = addInput('col', col, width: col.width);
    fbBase = addInput('fb_base', fbBase, width: 32);
    stride = addInput('stride', stride, width: 32);
    wordsPerLine = addInput('words_per_line', wordsPerLine, width: 16);
    mDataIn = addInput('m_dat_i', mDataIn, width: 32);
    mAck = addInput('m_ack', mAck);

    addOutput('pixel', width: 32);
    addOutput('underrun');
    addOutput('m_stb');
    addOutput('m_cyc');
    addOutput('m_we');
    addOutput('m_adr', width: 32);
    addOutput('m_sel', width: 4);
    addOutput('m_dat_o', width: 32);

    final reqToggle = Logic(name: 'req_toggle'); // pixel domain
    final reqAddr = Logic(name: 'req_addr', width: 32); // pixel, quasi-static
    final reqFill = Logic(name: 'req_fill'); // pixel, quasi-static
    final doneToggle = Logic(name: 'done_toggle'); // system domain

    final phase = Logic(
      name: 'phase',
      width: 2,
    ); // 0 idle,1 primeA,2 primeB,3 run
    final readSel = Logic(name: 'read_sel');
    final fetchAddr = Logic(name: 'fetch_addr', width: 32);
    final outstanding = Logic(name: 'outstanding');
    final underrunReg = Logic(name: 'underrun_reg');
    final dSync0 = Logic(name: 'd_sync0');
    final dSync1 = Logic(name: 'd_sync1');
    final dPrev = Logic(name: 'd_prev');
    final doneEdge = dSync1 ^ dPrev;

    final sysBusy = Logic(name: 'sys_busy');
    final reqAddrLatched = Logic(name: 'req_addr_l', width: 32);
    final reqFillLatched = Logic(name: 'req_fill_l');
    final fetchStartReg = Logic(name: 'fetch_start_reg');
    final rSync0 = Logic(name: 'r_sync0');
    final rSync1 = Logic(name: 'r_sync1');
    final rPrev = Logic(name: 'r_prev');
    final reqEdge = rSync1 ^ rPrev;

    final fetcher = HarborLineFetcher(
      clk: sysClk,
      reset: sysReset,
      fetchStart: fetchStartReg,
      fetchAddr: reqAddrLatched,
      words: wordsPerLine,
      fillSel: reqFillLatched,
      mDataIn: mDataIn,
      mAck: mAck,
      maxWords: maxWords,
    );
    final buffer = HarborDoubleLineBuffer(
      wrClk: sysClk,
      wrEn: fetcher.wrEn,
      wrSel: fetcher.wrSel,
      wrIdx: fetcher.wrIdx,
      wrData: fetcher.wrData,
      rdClk: pixelClk,
      rdReset: pixelReset,
      rdSel: readSel,
      rdCol: col,
      maxWords: maxWords,
      blockRam: blockRam,
    );

    mStb <= fetcher.mStb;
    mCyc <= fetcher.mCyc;
    mWe <= fetcher.mWe;
    mAddr <= fetcher.mAddr;
    mSel <= fetcher.mSel;
    mDataOut <= fetcher.mDataOut;
    pixel <= buffer.rdData;
    underrun <= underrunReg;

    // Issue a request: toggle req, latch payload, advance the line pointer.
    List<Conditional> issue(Logic addr, Logic fill) => [
      reqAddr < addr,
      reqFill < fill,
      reqToggle < ~reqToggle,
      fetchAddr < (addr + stride),
      outstanding < Const(1),
    ];

    // Pixel-domain sequential.
    Sequential(pixelClk, reset: pixelReset, [
      dSync0 < doneToggle,
      dSync1 < dSync0,
      dPrev < dSync1,
      If(doneEdge, then: [outstanding < Const(0)]),
      If(
        frameStart,
        then: [
          readSel < Const(0),
          underrunReg < Const(0),
          phase < Const(1, width: 2),
          ...issue(fbBase, Const(0)),
        ],
        orElse: [
          Case(phase, [
            CaseItem(Const(1, width: 2), [
              If(
                doneEdge,
                then: [
                  ...issue(fetchAddr, Const(1)),
                  phase < Const(2, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(2, width: 2), [
              If(doneEdge, then: [phase < Const(3, width: 2)]),
            ]),
            CaseItem(Const(3, width: 2), [
              If(
                lineStart,
                then: [
                  readSel < ~readSel,
                  If(outstanding & ~doneEdge, then: [underrunReg < Const(1)]),
                  ...issue(fetchAddr, readSel),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);

    // System-domain sequential.
    Sequential(sysClk, reset: sysReset, [
      rSync0 < reqToggle,
      rSync1 < rSync0,
      rPrev < rSync1,
      fetchStartReg < Const(0),
      If(
        ~sysBusy,
        then: [
          If(
            reqEdge,
            then: [
              reqAddrLatched < reqAddr,
              reqFillLatched < reqFill,
              fetchStartReg < Const(1),
              sysBusy < Const(1),
            ],
          ),
        ],
        orElse: [
          If(
            fetcher.done,
            then: [doneToggle < ~doneToggle, sysBusy < Const(0)],
          ),
        ],
      ),
    ]);
  }
}

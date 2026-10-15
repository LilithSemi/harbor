import 'package:rohd/rohd.dart';

import '../arith/fpu_config.dart';
import '../bus/port/memory_waist.dart';
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
/// The system side reads memory through one of two ports. Give [memory] for
/// a memory master waist (a [HarborLineFetcher]), which issues a new
/// [burstWords]-beat request as soon as the waist takes the previous one.
/// Give [rqReady], [rdValid] and [rdData] for a scanout port (`rq_*`, a
/// [HarborScanoutFetcher]), such as a [HarborSdram] scanout port. Then
/// [sysClk] and [sysReset] are the clock and reset of that port, and the
/// low 2 bits of [fbBase] and [stride] are ignored.
class HarborDualClockScanout extends Module {
  /// Pixel word for the previous cycle's [col] in the active buffer.
  Logic get pixel => output('pixel');

  /// Latches if a line was not ready at a swap.
  Logic get underrun => output('underrun');

  /// Scanout port requests (system domain).
  Logic get rqValid => output('rq_valid');
  Logic get rqAddr => output('rq_addr');
  Logic get rqWords => output('rq_words');

  /// True when the system side is a scanout port.
  final bool scanoutPort;

  final int maxWords;

  /// Words the fetcher reads under one `cyc`.
  final int burstWords;

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
    HarborMemoryWaist? memory,
    Logic? rqReady,
    Logic? rdValid,
    Logic? rdData,
    this.maxWords = 1024,
    this.burstWords = 16,
    this.blockRam,
    super.name = 'dual_clock_scanout',
  }) : scanoutPort = rqReady != null,
       super(
         definitionName: harborStableDefinitionName(
           rqReady != null
               ? 'HarborDualClockScanoutPort'
               : 'HarborDualClockScanout',
           [
             'w$maxWords',
             'ram${blockRam?.name ?? "flop"}',
             if (memory != null) ...[
               'b$burstWords',
               'i${memory.config.idWidth}',
               'n${memory.config.outstanding}',
             ],
           ],
         ),
       ) {
    final mem = memory != null;
    final port = rqReady != null && rdValid != null && rdData != null;
    if (mem == port) {
      throw ArgumentError('give either memory, or rqReady, rdValid and rdData');
    }
    pixelClk = addInput('pixel_clk', pixelClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    sysClk = addInput('sys_clk', sysClk);
    sysReset = addInput('sys_reset', sysReset);
    frameStart = addInput('frame_start', frameStart);
    lineStart = addInput('line_start', lineStart);
    col = addInput('col', col, width: col.width);
    fbBase = addInput('fb_base', fbBase, width: 32);
    stride = addInput('stride', stride, width: 32);
    if (port) {
      // fb_base can come from a CSR, so a scanout port forces both to whole
      // 32-bit words.
      fbBase = [fbBase.getRange(2), Const(0, width: 2)].swizzle();
      stride = [stride.getRange(2), Const(0, width: 2)].swizzle();
    }
    wordsPerLine = addInput('words_per_line', wordsPerLine, width: 16);

    addOutput('pixel', width: 32);
    addOutput('underrun');

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
    // A register with the value of `r_sync1 ^ r_sync1 one cycle ago`, so the
    // request edge is a flop next to the loads it enables.
    final reqEdge = Logic(name: 'req_edge');

    final Logic fetchDone;
    final Logic wrEn;
    final Logic wrSel;
    final Logic wrIdx;
    final Logic wrData;
    if (port) {
      final f = HarborScanoutFetcher(
        clk: sysClk,
        reset: sysReset,
        fetchStart: fetchStartReg,
        fetchAddr: reqAddrLatched,
        words: wordsPerLine,
        fillSel: reqFillLatched,
        rqReady: addInput('rq_ready', rqReady),
        rdValid: addInput('rd_valid', rdValid),
        rdData: addInput('rd_data', rdData, width: 16),
        maxWords: maxWords,
      );
      addOutput('rq_valid') <= f.rqValid;
      addOutput('rq_addr', width: 32) <= f.rqAddr;
      addOutput('rq_words', width: f.rqWords.width) <= f.rqWords;
      (fetchDone, wrEn, wrSel, wrIdx, wrData) = (
        f.done,
        f.wrEn,
        f.wrSel,
        f.wrIdx,
        f.wrData,
      );
    } else {
      final mWaist = memory!.clone()
        ..pairConnectIO(
          this,
          memory,
          PairRole.provider,
          uniquify: (n) => 'm_$n',
        );
      final f = HarborLineFetcher(
        clk: sysClk,
        reset: sysReset,
        fetchStart: fetchStartReg,
        fetchAddr: reqAddrLatched,
        words: wordsPerLine,
        fillSel: reqFillLatched,
        waist: mWaist,
        maxWords: maxWords,
        burstWords: burstWords,
      );
      (fetchDone, wrEn, wrSel, wrIdx, wrData) = (
        f.done,
        f.wrEn,
        f.wrSel,
        f.wrIdx,
        f.wrData,
      );
    }
    final buffer = HarborDoubleLineBuffer(
      wrClk: sysClk,
      wrEn: wrEn,
      wrSel: wrSel,
      wrIdx: wrIdx,
      wrData: wrData,
      rdClk: pixelClk,
      rdReset: pixelReset,
      rdSel: readSel,
      rdCol: col,
      maxWords: maxWords,
      blockRam: blockRam,
    );

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
      reqEdge < rSync0 ^ rSync1,
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
          If(fetchDone, then: [doneToggle < ~doneToggle, sysBusy < Const(0)]),
        ],
      ),
    ]);
  }
}

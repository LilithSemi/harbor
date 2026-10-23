import 'package:rohd/rohd.dart';

import '../arith/fpu_config.dart';
import '../bus/port/memory_waist.dart';
import '../peripherals/display.dart';
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
///
/// [formats] is the set of pixel formats that the build can scan. A build
/// with one format of one plane uses [wordsPerLine] and [maxWords] as given.
/// Any other build is planar: it needs [hActive] and [vActive], takes the
/// line size of each plane from [HarborPixelFormat.lineBytes], and has one
/// double line buffer for each plane. Planar inputs, sampled at
/// [frameStart] and held for the frame:
/// - `format_sel`, an index into [formats], only when there is more than
///   one format.
/// - [fbBase] and [stride] for plane 0, `plane_base_<n>` and
///   `plane_pitch_<n>` ([planeBase], [planePitch]) for plane n. A pitch
///   must be a multiple of 4 and at least the line bytes of its plane.
///   A scanout port ignores the low 2 bits of each base and pitch.
///
/// All planes share the memory port. Plane 0 is fetched one line ahead, as
/// above. A plane with a vertical subsampling of 2 has one line for two
/// luma lines. Its next line is fetched at the start of each even luma
/// line, after the plane 0 line, so it has two line times to complete.
/// The lines of one line start cross to the system side as one request,
/// and the system side fetches them in plane order. When more than one
/// plane waits, the lowest plane goes first. No line past the frame is
/// fetched.
///
/// The pixel domain reads plane n with `plane_col_<n>` ([planeCol]), the
/// word index in the line, and gets [planeData] one [pixelClk] cycle later.
/// Plane 0 uses [col] and [pixel]. [planeUnderrun] has one bit per plane,
/// and [underrun] is their OR.
class HarborDualClockScanout extends Module {
  /// Pixel word for the previous cycle's [col] in the active buffer.
  Logic get pixel => output('pixel');

  /// Latches if a line was not ready at a swap.
  Logic get underrun => output('underrun');

  /// The word of plane [n] at the previous cycle's column of that plane.
  Logic planeData(int n) => n == 0 ? pixel : output('plane_data_$n');

  /// One underrun bit for each plane, present only on a planar build.
  Logic get planeUnderrun => output('plane_underrun');

  /// The format index of the frame, present only on a planar build with
  /// more than one format.
  Logic get format => output('format');

  /// Scanout port requests (system domain).
  Logic get rqValid => output('rq_valid');
  Logic get rqAddr => output('rq_addr');
  Logic get rqWords => output('rq_words');

  /// True when the system side is a scanout port.
  final bool scanoutPort;

  /// Line buffer words of plane 0.
  final int maxWords;

  /// Words the fetcher reads under one `cyc`.
  final int burstWords;

  /// The block RAM cell for the line buffers, or null for flops.
  final HarborBlockRam? blockRam;

  /// The pixel formats of the build, in `format_sel` order.
  final List<HarborPixelFormat> formats;

  /// True for a build with per plane buffers.
  final bool planar;

  /// Line buffer words of each plane.
  final List<int> planeMaxWords;

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
    Logic? wordsPerLine,
    HarborMemoryWaist? memory,
    Logic? rqReady,
    Logic? rdValid,
    Logic? rdData,
    int maxWords = 1024,
    this.burstWords = 16,
    this.blockRam,
    List<HarborPixelFormat> formats = const [HarborPixelFormat.xrgb8888],
    int? hActive,
    int? vActive,
    Logic? formatSel,
    List<Logic> planeBase = const [],
    List<Logic> planePitch = const [],
    List<Logic> planeCol = const [],
    super.name = 'dual_clock_scanout',
  }) : scanoutPort = rqReady != null,
       formats = List.unmodifiable(formats),
       planar = isPlanar(formats),
       planeMaxWords = isPlanar(formats)
           ? _planeMax(formats, hActive ?? 1)
           : [maxWords],
       maxWords = isPlanar(formats)
           ? _planeMax(formats, hActive ?? 1).first
           : maxWords,
       super(
         definitionName: isPlanar(formats)
             ? harborStableDefinitionName(
                 rqReady != null
                     ? 'HarborPlaneScanoutPort'
                     : 'HarborPlaneScanout',
                 [
                   'f${formats.map(harborPixelFormatBitOrder.indexOf).join('x')}',
                   'h${hActive}v$vActive',
                   'ram${blockRam?.name ?? "flop"}',
                   if (memory != null) ...[
                     'b$burstWords',
                     'i${memory.config.idWidth}',
                     'n${memory.config.outstanding}',
                   ],
                 ],
               )
             : harborStableDefinitionName(
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
    if (!planar) {
      if (wordsPerLine == null) {
        throw ArgumentError('a one plane build needs wordsPerLine');
      }
      _buildSingle(
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        sysClk: sysClk,
        sysReset: sysReset,
        frameStart: frameStart,
        lineStart: lineStart,
        col: col,
        fbBase: fbBase,
        stride: stride,
        wordsPerLine: wordsPerLine,
        memory: memory,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
      );
      return;
    }
    if (hActive == null || vActive == null || hActive < 1 || vActive < 1) {
      throw ArgumentError('a planar build needs hActive and vActive');
    }
    if (wordsPerLine != null) {
      throw ArgumentError(
        'a planar build takes the line size from formats, not wordsPerLine',
      );
    }
    _buildPlanes(
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
      frameStart: frameStart,
      lineStart: lineStart,
      col: col,
      fbBase: fbBase,
      stride: stride,
      memory: memory,
      rqReady: rqReady,
      rdValid: rdValid,
      rdData: rdData,
      hActive: hActive,
      vActive: vActive,
      formatSel: formatSel,
      planeBase: planeBase,
      planePitch: planePitch,
      planeCol: planeCol,
    );
  }

  /// True when [formats] needs a planar build.
  static bool isPlanar(List<HarborPixelFormat> formats) =>
      formats.length != 1 || formats.single.planes.length != 1;

  /// Words of [plane] in one line of [hActive] pixels, or 0 if [format]
  /// has no such plane.
  static int planeWords(HarborPixelFormat format, int plane, int hActive) =>
      plane < format.planes.length
      ? (format.lineBytes(plane, hActive) + 3) ~/ 4
      : 0;

  static List<int> _planeMax(List<HarborPixelFormat> formats, int hActive) {
    var planes = 0;
    for (final f in formats) {
      if (f.planes.length > planes) planes = f.planes.length;
    }
    return [
      for (var k = 0; k < planes; k++)
        formats
            .map((f) => planeWords(f, k, hActive))
            .fold(1, (a, b) => a > b ? a : b),
    ];
  }

  void _buildSingle({
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
    required HarborMemoryWaist? memory,
    required Logic? rqReady,
    required Logic? rdValid,
    required Logic? rdData,
  }) {
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

  void _buildPlanes({
    required Logic pixelClk,
    required Logic pixelReset,
    required Logic sysClk,
    required Logic sysReset,
    required Logic frameStart,
    required Logic lineStart,
    required Logic col,
    required Logic fbBase,
    required Logic stride,
    required HarborMemoryWaist? memory,
    required Logic? rqReady,
    required Logic? rdValid,
    required Logic? rdData,
    required int hActive,
    required int vActive,
    required Logic? formatSel,
    required List<Logic> planeBase,
    required List<Logic> planePitch,
    required List<Logic> planeCol,
  }) {
    final mem = memory != null;
    final port = rqReady != null && rdValid != null && rdData != null;
    if (mem == port) {
      throw ArgumentError('give either memory, or rqReady, rdValid and rdData');
    }
    if (formats.isEmpty || formats.toSet().length != formats.length) {
      throw ArgumentError.value(
        formats,
        'formats',
        'must be distinct, not empty',
      );
    }
    final planes = planeMaxWords.length;
    if (planes > 3) {
      throw ArgumentError('a format has more than 3 planes');
    }
    for (final f in formats) {
      for (var k = 0; k < f.planes.length; k++) {
        final p = f.planes[k];
        final bpg = p.bytesPerGroup;
        final ppg = p.pixelsPerGroup;
        if (bpg & (bpg - 1) != 0 || ppg & (ppg - 1) != 0 || bpg > 4) {
          throw ArgumentError(
            '${f.name} plane $k does not fit the 32-bit scanout word layout.',
          );
        }
        if (p.vSub != (k == 0 ? 1 : 2)) {
          throw ArgumentError(
            '${f.name} plane $k has a vertical subsampling of ${p.vSub}, '
            'the scanout supports 1 for plane 0 and 2 for the other planes',
          );
        }
      }
    }
    if (planeBase.length != planes - 1 ||
        planePitch.length != planes - 1 ||
        planeCol.length != planes - 1) {
      throw ArgumentError(
        'give planeBase, planePitch and planeCol for planes 1 to ${planes - 1}',
      );
    }
    final multi = formats.length > 1;
    if (multi != (formatSel != null)) {
      throw ArgumentError(
        'give formatSel only when there is more than one '
        'format',
      );
    }
    final selW = (formats.length - 1).bitLength;
    final chromaLines = (vActive + 1) ~/ 2;
    final fetchMax = planeMaxWords.reduce((a, b) => a > b ? a : b);
    if (fetchMax > 0xffff) {
      throw ArgumentError('a plane line of $fetchMax words is too long');
    }

    pixelClk = addInput('pixel_clk', pixelClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    sysClk = addInput('sys_clk', sysClk);
    sysReset = addInput('sys_reset', sysReset);
    frameStart = addInput('frame_start', frameStart);
    lineStart = addInput('line_start', lineStart);
    if (multi) {
      formatSel = addInput('format_sel', formatSel!, width: selW);
    }

    Logic word32(Logic v) =>
        port ? [v.getRange(2), Const(0, width: 2)].swizzle() : v;
    final base = [
      word32(addInput('fb_base', fbBase, width: 32)),
      for (var k = 1; k < planes; k++)
        word32(addInput('plane_base_$k', planeBase[k - 1], width: 32)),
    ];
    final pitchIn = [
      word32(addInput('stride', stride, width: 32)),
      for (var k = 1; k < planes; k++)
        word32(addInput('plane_pitch_$k', planePitch[k - 1], width: 32)),
    ];
    final idxW = [
      for (final w in planeMaxWords)
        (w - 1).bitLength < 1 ? 1 : (w - 1).bitLength,
    ];
    Logic fit(Logic v, int w) =>
        v.width >= w ? v.getRange(0, w) : v.zeroExtend(w);
    final cols = [
      fit(addInput('col', col, width: col.width), idxW[0]),
      for (var k = 1; k < planes; k++)
        fit(
          addInput(
            'plane_col_$k',
            planeCol[k - 1],
            width: planeCol[k - 1].width,
          ),
          idxW[k],
        ),
    ];

    addOutput('pixel', width: 32);
    for (var k = 1; k < planes; k++) {
      addOutput('plane_data_$k', width: 32);
    }
    addOutput('underrun');
    addOutput('plane_underrun', width: planes);

    // Line words of each plane for the format on format_sel.
    Logic pick(List<Logic> values) {
      var out = values.last;
      for (var i = values.length - 2; i >= 0; i--) {
        out = mux(formatSel!.eq(i), values[i], out);
      }
      return out;
    }

    final wordsSel = [
      for (var k = 0; k < planes; k++)
        pick([
          for (final f in formats) Const(planeWords(f, k, hActive), width: 16),
        ]).named('words_sel_$k'),
    ];

    // Pixel domain, per plane.
    List<Logic> regs(String n, [int w = 1]) => [
      for (var k = 0; k < planes; k++) Logic(name: 'p${k}_$n', width: w),
    ];
    final reqToggle = Logic(name: 'req_toggle');
    final reqMask = Logic(name: 'req_mask', width: planes);
    final want = regs('want');
    final reqAddr = regs('req_addr', 32);
    final reqFill = regs('req_fill');
    final nextAddr = regs('next_addr', 32);
    final pitch = regs('pitch', 32);
    final words = regs('words', 16);
    final active = regs('active');
    final dSync0 = regs('d_sync0');
    final dSync1 = regs('d_sync1');
    final underrunReg = regs('underrun_reg');
    final doneToggle = [
      for (var k = 0; k < planes; k++) Logic(name: 's${k}_done_toggle'),
    ];
    final outstanding = [
      for (var k = 0; k < planes; k++)
        (want[k] ^ dSync1[k]).named('p${k}_outstanding'),
    ];
    final allIdle = outstanding
        .map((o) => ~o)
        .reduce((a, b) => a & b)
        .named('all_idle');

    final phase = Logic(
      name: 'phase',
      width: 2,
    ); // 0 idle,1 primeA,2 primeB,3 run
    final readSel = Logic(name: 'read_sel');
    final chromaSel = Logic(name: 'chroma_sel');
    final lineNo = Logic(name: 'line_no', width: 16);
    final chromaNo = Logic(name: 'chroma_no', width: 16);
    final fmt = multi ? Logic(name: 'format_reg', width: selW) : null;

    // One request carries the lines of all planes for a line start. The
    // system side takes them together, so it fetches them in plane order.
    // Each entry is (fetch, address, fill, pitch), null for no fetch.
    List<Conditional> issue(List<(Logic, Logic, Logic, Logic)?> lines) {
      if (lines.every((l) => l == null)) return [];
      final fetch = [for (final l in lines) l?.$1 ?? Const(0)];
      return [
        If(
          fetch.reduce((a, b) => a | b),
          then: [
            reqToggle < ~reqToggle,
            reqMask < fetch.rswizzle(),
            for (var k = 0; k < planes; k++)
              if (lines[k] case (final f, final addr, final fill, final step))
                If(
                  f,
                  then: [
                    reqAddr[k] < addr,
                    reqFill[k] < fill,
                    want[k] < ~want[k],
                    nextAddr[k] < (addr + step),
                  ],
                ),
          ],
        ),
      ];
    }

    // A line that is not ready when its read starts.
    List<Conditional> late(int k) => [
      If(outstanding[k], then: [underrunReg[k] < Const(1)]),
    ];

    Sequential(pixelClk, reset: pixelReset, [
      for (var k = 0; k < planes; k++) ...[
        dSync0[k] < doneToggle[k],
        dSync1[k] < dSync0[k],
      ],
      If(
        frameStart,
        then: [
          readSel < Const(0),
          chromaSel < Const(0),
          phase < Const(1, width: 2),
          lineNo < Const(1, width: 16),
          chromaNo < Const(1, width: 16),
          if (fmt != null) fmt < formatSel!,
          for (var k = 0; k < planes; k++) ...[
            underrunReg[k] < Const(0),
            words[k] < wordsSel[k],
            pitch[k] < pitchIn[k],
            active[k] < wordsSel[k].neq(0),
          ],
          ...issue([
            for (var k = 0; k < planes; k++)
              (
                k == 0 ? Const(1) : wordsSel[k].neq(0),
                base[k],
                Const(0),
                pitchIn[k],
              ),
          ]),
        ],
        orElse: [
          Case(phase, [
            CaseItem(Const(1, width: 2), [
              If(
                allIdle,
                then: [
                  ...issue([
                    for (var k = 0; k < planes; k++)
                      if (k == 0 ? vActive > 1 : chromaLines > 1)
                        (
                          k == 0 ? Const(1) : active[k],
                          nextAddr[k],
                          Const(1),
                          pitch[k],
                        )
                      else
                        null,
                  ]),
                  if (vActive > 1) lineNo < Const(2, width: 16),
                  if (chromaLines > 1) chromaNo < Const(2, width: 16),
                  phase < Const(2, width: 2),
                ],
              ),
            ]),
            CaseItem(Const(2, width: 2), [
              If(allIdle, then: [phase < Const(3, width: 2)]),
            ]),
            CaseItem(Const(3, width: 2), [
              If(
                lineStart,
                then: [
                  readSel < ~readSel,
                  ...late(0),
                  If(lineNo.lt(vActive), then: [lineNo < lineNo + 1]),
                  // The line after an odd line is even: swap the chroma
                  // lines and fetch the next one after the luma line.
                  ...issue([
                    for (var k = 0; k < planes; k++)
                      (
                        k == 0
                            ? lineNo.lt(vActive)
                            : readSel & chromaNo.lt(chromaLines) & active[k],
                        nextAddr[k],
                        k == 0 ? readSel : chromaSel,
                        pitch[k],
                      ),
                  ]),
                  if (planes > 1)
                    If(
                      readSel,
                      then: [
                        chromaSel < ~chromaSel,
                        for (var k = 1; k < planes; k++) ...late(k),
                        If(
                          chromaNo.lt(chromaLines),
                          then: [chromaNo < chromaNo + 1],
                        ),
                      ],
                    ),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);

    // System domain: one pending request for each plane, the lowest plane
    // goes first.
    List<Logic> sregs(String n, [int w = 1]) => [
      for (var k = 0; k < planes; k++) Logic(name: 's${k}_$n', width: w),
    ];
    final rSync0 = Logic(name: 'r_sync0');
    final rSync1 = Logic(name: 'r_sync1');
    final reqEdge = Logic(name: 'req_edge');
    final pending = sregs('pending');
    final pendAddr = sregs('pend_addr', 32);
    final pendWords = sregs('pend_words', 16);
    final pendFill = sregs('pend_fill');
    final pendTog = sregs('pend_tog');
    final planeW = (planes - 1).bitLength < 1 ? 1 : (planes - 1).bitLength;
    final sysBusy = Logic(name: 'sys_busy');
    final curPlane = Logic(name: 'cur_plane', width: planeW);
    final curTog = Logic(name: 'cur_tog');
    final curAddr = Logic(name: 'cur_addr', width: 32);
    final curWords = Logic(name: 'cur_words', width: 16);
    final curFill = Logic(name: 'cur_fill');
    final fetchStartReg = Logic(name: 'fetch_start_reg');

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
        fetchAddr: curAddr,
        words: curWords,
        fillSel: curFill,
        rqReady: addInput('rq_ready', rqReady),
        rdValid: addInput('rd_valid', rdValid),
        rdData: addInput('rd_data', rdData, width: 16),
        maxWords: fetchMax,
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
        fetchAddr: curAddr,
        words: curWords,
        fillSel: curFill,
        waist: mWaist,
        maxWords: fetchMax,
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

    final rd = <Logic>[];
    for (var k = 0; k < planes; k++) {
      final buffer = HarborDoubleLineBuffer(
        wrClk: sysClk,
        wrEn: planes == 1 ? wrEn : (wrEn & curPlane.eq(k)),
        wrSel: wrSel,
        wrIdx: fit(wrIdx, idxW[k]),
        wrData: wrData,
        rdClk: pixelClk,
        rdReset: pixelReset,
        rdSel: k == 0 ? readSel : chromaSel,
        rdCol: cols[k],
        maxWords: planeMaxWords[k],
        blockRam: blockRam,
        uniqueName: true,
        name: 'plane${k}_lines',
      );
      rd.add(buffer.rdData);
    }
    pixel <= rd[0];
    for (var k = 1; k < planes; k++) {
      output('plane_data_$k') <= rd[k];
    }
    planeUnderrun <= underrunReg.rswizzle();
    underrun <= underrunReg.reduce((a, b) => a | b);
    if (fmt != null) addOutput('format', width: selW) <= fmt;

    Conditional pickNext(int k) => If(
      pending[k],
      then: [
        curAddr < pendAddr[k],
        curWords < pendWords[k],
        curFill < pendFill[k],
        curTog < pendTog[k],
        curPlane < Const(k, width: planeW),
        pending[k] < Const(0),
        fetchStartReg < Const(1),
        sysBusy < Const(1),
      ],
      orElse: [if (k + 1 < planes) pickNext(k + 1)],
    );

    Sequential(sysClk, reset: sysReset, [
      rSync0 < reqToggle,
      rSync1 < rSync0,
      reqEdge < rSync0 ^ rSync1,
      fetchStartReg < Const(0),
      If(
        ~sysBusy,
        then: [pickNext(0)],
        orElse: [
          If(
            fetchDone,
            then: [
              for (var k = 0; k < planes; k++)
                If(curPlane.eq(k), then: [doneToggle[k] < curTog]),
              sysBusy < Const(0),
            ],
          ),
        ],
      ),
      // The want value is the request it serves, so a done for an older
      // request leaves a newer one outstanding.
      If(
        reqEdge,
        then: [
          for (var k = 0; k < planes; k++)
            If(
              reqMask[k],
              then: [
                pending[k] < Const(1),
                pendAddr[k] < reqAddr[k],
                pendWords[k] < words[k],
                pendFill[k] < reqFill[k],
                pendTog[k] < want[k],
              ],
            ),
        ],
      ),
    ]);
  }
}

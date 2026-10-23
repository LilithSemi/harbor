import 'dart:math';

import 'package:rohd/rohd.dart';

import '../arith/fpu_config.dart';
import '../bus/port/memory_waist.dart';
import '../peripherals/display.dart';
import '../soc/target.dart';
import 'double_line_buffer.dart';
import 'line_fetcher.dart';

/// The overlay plane inputs of a [HarborDualClockScanout], in the pixel
/// domain and sampled at frame start.
///
/// The overlay shows source pixels [srcX] to `srcX + width - 1` of source
/// lines [srcY] to `srcY + height - 1` at screen pixel [dstX], line [dstY].
/// Plane n starts at [base] n and has a pitch of [pitch] n, with the rules
/// of the primary planes. [col] n is the word index of plane n in the
/// fetched part of the line.
class HarborScanoutOverlay {
  /// The overlay formats, in [formatSel] order.
  final List<HarborPixelFormat> formats;
  final Logic enable;

  /// The format index, only when there is more than one format.
  final Logic? formatSel;
  final List<Logic> base;
  final List<Logic> pitch;
  final Logic srcX;
  final Logic srcY;
  final Logic dstX;
  final Logic dstY;
  final Logic width;
  final Logic height;
  final List<Logic> col;

  HarborScanoutOverlay({
    required List<HarborPixelFormat> formats,
    required this.enable,
    this.formatSel,
    required this.base,
    required this.pitch,
    required this.srcX,
    required this.srcY,
    required this.dstX,
    required this.dstY,
    required this.width,
    required this.height,
    required this.col,
  }) : formats = List.unmodifiable(formats);

  /// The most planes of a format in [formats].
  int get planes => formats.map((f) => f.planes.length).reduce(max);

  /// True when [plane] of [f] reads one pixel ahead, as
  /// [HarborPixelUnpack] does.
  static bool lookahead(HarborPixelFormat f, int plane) =>
      f.yuv && (plane > 0 || f.planes.length == 1);

  /// The right shift from a pixel x to its word in [plane] of [f].
  static int wordShift(HarborPixelFormat f, int plane) {
    final p = f.planes[plane];
    return p.pixelsPerGroup.bitLength - 1 + 2 - (p.bytesPerGroup.bitLength - 1);
  }

  /// Line buffer words of each plane: the words of [hActive] pixels that
  /// start at any pixel, plus one.
  List<int> maxWords(int hActive) => [
    for (var k = 0; k < planes; k++)
      formats
          .map(
            (f) => k < f.planes.length
                ? HarborDualClockScanout.planeWords(f, k, hActive) + 1
                : 1,
          )
          .reduce(max),
  ];
}

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
/// The lines of one line start cross to the system side as one request.
/// When more than one plane waits, plane 0 goes first, then overlay plane
/// 0, then the other planes in plane order. No line past the frame is
/// fetched. If the first line start comes before the prime ends, the prime
/// stops there. A line that was not requested in time counts as an
/// underrun, and the lines after it go to the correct buffers.
///
/// The pixel domain reads plane n with `plane_col_<n>` ([planeCol]), the
/// word index in the line, and gets [planeData] one [pixelClk] cycle later.
/// Plane 0 uses [col] and [pixel]. [planeUnderrun] has one bit per plane,
/// and [underrun] is their OR.
///
/// Give [overlay] to fetch an overlay plane on the same memory port. It
/// makes a planar build. The overlay planes come after the primary planes
/// in the request mask. Overlay plane 0 goes before the primary chroma
/// planes, because they have two line times. An overlay
/// plane line holds only the words from the word of the first source pixel
/// to the word of the last visible source pixel, plus one word when the
/// plane reads one pixel ahead and the screen edge clips the crop. The scanout fetches overlay lines only for
/// the screen lines in the overlay. Overlay line r (source line
/// `src_y + r`) is in buffer `r & 1`, and overlay chroma line c in buffer
/// `c & 1`. Overlay line 0 goes with primary line 1 at frame start, when
/// the address of the first source line is ready. Overlay line 1 goes when
/// that request is done. After that each line start fetches the next
/// line, as for the primary planes.
///
/// The scanout aligns the source origin to the chroma samples: it clears
/// bit 0 of `src_x` for a 4:2:2 or 4:2:0 format and bit 0 of `src_y` for
/// a 4:2:0 format. The [overlayUnderrun] bits and the
/// [overlayUnderrunCount] counts are for the overlay planes. [underrun] is
/// the OR of the primary and overlay bits.
class HarborDualClockScanout extends Module {
  /// Pixel word for the previous cycle's [col] in the active buffer.
  Logic get pixel => output('pixel');

  /// Latches if a line was not ready at a swap.
  Logic get underrun => output('underrun');

  /// The word of plane [n] at the previous cycle's column of that plane.
  Logic planeData(int n) => n == 0 ? pixel : output('plane_data_$n');

  /// One underrun bit for each plane, present only on a planar build.
  Logic get planeUnderrun => output('plane_underrun');

  /// Lines of plane [n] that were not ready when their read started, on
  /// [sysClk]. It stops at 0xffff and only the system reset clears it.
  /// Present only on a planar build.
  Logic planeUnderrunCount(int n) => output('plane_underrun_count_$n');

  /// The format index of the frame, present only on a planar build with
  /// more than one format.
  Logic get format => output('format');

  /// The word of overlay plane [n] at the previous cycle's `overlay_col_n`.
  Logic overlayData(int n) => output('overlay_data_$n');

  /// One underrun bit for each overlay plane.
  Logic get overlayUnderrun => output('overlay_underrun');

  /// Lines of overlay plane [n] that were not ready, as
  /// [planeUnderrunCount].
  Logic overlayUnderrunCount(int n) => output('overlay_underrun_count_$n');

  /// The overlay state of the frame. [overlayOn] is high when the overlay
  /// is enabled and has a visible part. [overlaySrcX] is the aligned
  /// source x.
  Logic get overlayOn => output('overlay_on');
  Logic get overlayFormat => output('overlay_frame_format');
  Logic get overlaySrcX => output('overlay_frame_src_x');
  Logic get overlayDstX => output('overlay_frame_dst_x');
  Logic get overlayDstY => output('overlay_frame_dst_y');
  Logic get overlayWidth => output('overlay_frame_width');
  Logic get overlayHeight => output('overlay_frame_height');

  /// The overlay inputs, or null.
  final HarborScanoutOverlay? overlay;

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
    this.overlay,
    super.name = 'dual_clock_scanout',
  }) : scanoutPort = rqReady != null,
       formats = List.unmodifiable(formats),
       planar = isPlanar(formats) || overlay != null,
       planeMaxWords = isPlanar(formats) || overlay != null
           ? _planeMax(formats, hActive ?? 1)
           : [maxWords],
       maxWords = isPlanar(formats) || overlay != null
           ? _planeMax(formats, hActive ?? 1).first
           : maxWords,
       super(
         definitionName: overlay != null
             ? harborStableDefinitionName(
                 rqReady != null
                     ? 'HarborOverlayScanoutPort'
                     : 'HarborOverlayScanout',
                 [
                   'f${formats.map(harborPixelFormatBitOrder.indexOf).join('x')}',
                   'o${overlay.formats.map(harborPixelFormatBitOrder.indexOf).join('x')}',
                   'h${hActive}v$vActive',
                   'x${overlay.srcX.width}y${overlay.srcY.width}',
                   'ram${blockRam?.name ?? "flop"}',
                   if (memory != null) ...[
                     'b$burstWords',
                     'i${memory.config.idWidth}',
                     'n${memory.config.outstanding}',
                   ],
                 ],
               )
             : isPlanar(formats)
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
      overlay: overlay,
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
    required HarborScanoutOverlay? overlay,
  }) {
    final mem = memory != null;
    final port = rqReady != null && rdValid != null && rdData != null;
    if (mem == port) {
      throw ArgumentError('give either memory, or rqReady, rdValid and rdData');
    }
    void checkFormats(List<HarborPixelFormat> formats, String name) {
      if (formats.isEmpty || formats.toSet().length != formats.length) {
        throw ArgumentError.value(formats, name, 'must be distinct, not empty');
      }
      if (formats.any((f) => f.planes.length > 3)) {
        throw ArgumentError('a format has more than 3 planes');
      }
    }

    checkFormats(formats, 'formats');
    final planes = planeMaxWords.length;
    final ovFormats = overlay?.formats ?? const <HarborPixelFormat>[];
    if (overlay != null) checkFormats(ovFormats, 'overlay.formats');
    for (final f in {...formats, ...ovFormats}) {
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
    // The overlay planes come after the primary planes.
    final ovMax = overlay?.maxWords(hActive) ?? const <int>[];
    final ovPlanes = ovMax.length;
    final all = planes + ovPlanes;
    final allMax = [...planeMaxWords, ...ovMax];
    if (overlay != null) {
      if (overlay.base.length != ovPlanes ||
          overlay.pitch.length != ovPlanes ||
          overlay.col.length != ovPlanes) {
        throw ArgumentError(
          'give overlay base, pitch and col for planes 0 to ${ovPlanes - 1}',
        );
      }
      if ((ovFormats.length > 1) != (overlay.formatSel != null)) {
        throw ArgumentError(
          'give the overlay formatSel only when there is more than one '
          'overlay format',
        );
      }
      if (overlay.srcY.width > 15 || overlay.dstY.width > 15) {
        throw ArgumentError('the overlay y inputs have at most 15 bits');
      }
    }
    final fetchMax = allMax.reduce((a, b) => a > b ? a : b);
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
      for (final w in allMax) (w - 1).bitLength < 1 ? 1 : (w - 1).bitLength,
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
      for (var j = 0; j < ovPlanes; j++)
        fit(
          addInput(
            'overlay_col_$j',
            overlay!.col[j],
            width: overlay.col[j].width,
          ),
          idxW[planes + j],
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
      for (var k = 0; k < all; k++) Logic(name: 'p${k}_$n', width: w),
    ];
    final reqToggle = Logic(name: 'req_toggle');
    final reqMask = Logic(name: 'req_mask', width: all);
    final want = regs('want');
    final underrunTog = regs('underrun_toggle');
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
      for (var k = 0; k < all; k++) Logic(name: 's${k}_done_toggle'),
    ];
    final outstanding = [
      for (var k = 0; k < all; k++)
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
    final ov = overlay == null
        ? null
        : _overlayState(
            overlay: overlay,
            pixelClk: pixelClk,
            pixelReset: pixelReset,
            frameStart: frameStart,
            word32: word32,
            hActive: hActive,
            vActive: vActive,
            pitch: pitch.sublist(planes),
            active: active.sublist(planes),
            words: words.sublist(planes),
          );
    late final ovRow = Logic(name: 'ov_row', width: 16);
    late final rEnter = (ovRow + 1).named('ov_row_next');
    Logic r17(Logic v) => v.zeroExtend(17);

    // One request carries the lines of all planes for a line start. The
    // system side takes them together.
    // Each entry is (fetch, address, fill, pitch), null for no fetch.
    List<Conditional> issue(List<(Logic, Logic, Logic, Logic)?> lines) {
      lines = [...lines, for (var k = lines.length; k < all; k++) null];
      if (lines.every((l) => l == null)) return [];
      final fetch = [for (final l in lines) l?.$1 ?? Const(0)];
      return [
        If(
          fetch.reduce((a, b) => a | b),
          then: [
            reqToggle < ~reqToggle,
            reqMask < fetch.rswizzle(),
            for (var k = 0; k < all; k++)
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
      If(
        outstanding[k],
        then: [underrunReg[k] < Const(1), underrunTog[k] < ~underrunTog[k]],
      ),
    ];

    // A line that was not requested before its read starts.
    List<Conditional> miss(int k) => [
      underrunReg[k] < Const(1),
      underrunTog[k] < ~underrunTog[k],
    ];

    // The primary planes at a line start. The line after an odd line is
    // even: swap the chroma lines and fetch the next one after the luma
    // line.
    List<Conditional> primaryState() => [
      readSel < ~readSel,
      ...late(0),
      If(lineNo.lt(vActive), then: [lineNo < lineNo + 1]),
      if (planes > 1)
        If(
          readSel,
          then: [
            chromaSel < ~chromaSel,
            for (var k = 1; k < planes; k++) ...late(k),
            If(chromaNo.lt(chromaLines), then: [chromaNo < chromaNo + 1]),
          ],
        ),
    ];
    List<(Logic, Logic, Logic, Logic)?> primaryLines() => [
      for (var k = 0; k < planes; k++)
        (
          k == 0
              ? lineNo.lt(vActive)
              : readSel & chromaNo.lt(chromaLines) & active[k],
          nextAddr[k],
          k == 0 ? readSel : chromaSel,
          pitch[k],
        ),
    ];

    // The overlay planes at a line start in the run phase.
    List<Conditional> overlayState() => [
      // Source line rEnter of the overlay starts.
      If(
        ov!.on & rEnter.gte(1) & r17(rEnter).lt(r17(ov.height)),
        then: late(planes),
      ),
      for (var j = 1; j < ovPlanes; j++)
        If(
          ov.on &
              active[planes + j] &
              ~rEnter[0] &
              rEnter.gte(2) &
              r17(rEnter).lt(r17(ov.height)),
          then: late(planes + j),
        ),
      ovRow < rEnter,
    ];
    // The next source line, and at an even source line the chroma line
    // after the one that starts.
    List<(Logic, Logic, Logic, Logic)?> overlayLines() => [
      for (var j = 0; j < ovPlanes; j++)
        (
          j == 0
              ? ov!.on &
                    rEnter.gte(1) &
                    (r17(rEnter) + 1).lt(r17(ov.height)) &
                    lineNo.lt(vActive)
              : ov!.on &
                    active[planes + j] &
                    ~rEnter[0] &
                    rEnter.gte(2) &
                    (r17(rEnter) + 2).lt(r17(ov.height)) &
                    lineNo.lt(max(vActive - 1, 0)),
          nextAddr[planes + j],
          j == 0 ? ~rEnter[0] : ~rEnter[1],
          pitch[planes + j],
        ),
    ];
    // Overlay line 1 and overlay chroma line 1, if they are on the screen.
    Logic ovSecond(int j) => j == 0
        ? ov!.on & ov.height.gt(1) & ov.dstY.lt(max(vActive - 1, 0))
        : ov!.on &
              active[planes + j] &
              ov.height.gt(2) &
              ov.dstY.lt(max(vActive - 2, 0));

    // A line start before the request of prime phase 1 goes. Line 1 of
    // plane 0 was not requested, so it is late and the line start requests
    // line 2. Primary chroma line 1 has one more line time, so it goes now.
    // Overlay line 0 goes now if it starts at screen line 2 or lower.
    // Otherwise the overlay lines that start before the next line start are
    // late, and the next overlay lines go now.
    List<Conditional> primeLine1() {
      final early = ov?.dstY.gte(2);
      final y0 = ov?.dstY.eq(0);
      final y1 = ov?.dstY.eq(1);
      return [
        readSel < Const(1),
        ...miss(0),
        for (var k = 1; k < planes; k++) ...late(k),
        lineNo < Const(min(3, vActive), width: 16),
        if (chromaLines > 1) chromaNo < Const(2, width: 16),
        if (ov != null) ...[
          If(ov.on & ~early!, then: miss(planes)),
          for (var j = 1; j < ovPlanes; j++)
            If(ov.on & active[planes + j] & ~early, then: miss(planes + j)),
          ovRow < rEnter,
        ],
        ...issue([
          for (var k = 0; k < planes; k++)
            if (k == 0 && vActive > 2)
              (Const(1), nextAddr[0] + pitch[0], Const(0), pitch[0])
            else if (k > 0 && chromaLines > 1)
              (active[k], nextAddr[k], Const(1), pitch[k])
            else
              null,
          if (ov != null)
            for (var j = 0; j < ovPlanes; j++)
              j == 0
                  ? (
                      ov.on &
                          (vActive > 2
                              ? early! |
                                    (y0! & ov.height.gt(2)) |
                                    (y1! & ov.height.gt(1))
                              : early!),
                      ov.rowAddr[0] +
                          mux(
                            y0!,
                            pitch[planes] << 1,
                            mux(y1!, pitch[planes], Const(0, width: 32)),
                          ),
                      y1,
                      pitch[planes],
                    )
                  : (
                      ov.on &
                          active[planes + j] &
                          (early! | ov.height.gt(2)) &
                          (early | ov.dstY.lt(max(vActive - 2, 0))),
                      ov.rowAddr[j] +
                          mux(early, Const(0, width: 32), pitch[planes + j]),
                      ~early,
                      pitch[planes + j],
                    ),
        ]),
        phase <
            (early == null
                ? Const(3, width: 2)
                : mux(early, Const(2, width: 2), Const(3, width: 2))),
      ];
    }

    // A line start before the request of prime phase 2 goes. The primary
    // planes go on as in the run phase. Overlay line 1 goes now, or if it
    // starts now, it is late and line 2 goes.
    List<Conditional> primeLine2() {
      final e0 = ov == null ? null : rEnter.eq(0);
      final e1 = ov == null ? null : rEnter.eq(1);
      return [
        ...primaryState(),
        if (ov != null) ...[
          If(ov.on & e1! & ov.height.gt(1), then: miss(planes)),
          If(ov.on & e0!, then: late(planes)),
          for (var j = 1; j < ovPlanes; j++)
            If(ov.on & active[planes + j] & (e0 | e1), then: late(planes + j)),
          ovRow < rEnter,
        ],
        ...issue([
          ...primaryLines(),
          if (ov != null)
            for (var j = 0; j < ovPlanes; j++)
              j == 0
                  ? (
                      mux(e1!, overlayLines()[0]!.$1, ovSecond(0)),
                      nextAddr[planes] +
                          mux(e1, pitch[planes], Const(0, width: 32)),
                      ~e1,
                      pitch[planes],
                    )
                  : (
                      ovSecond(j),
                      nextAddr[planes + j],
                      Const(1),
                      pitch[planes + j],
                    ),
        ]),
        phase < Const(3, width: 2),
      ];
    }

    Sequential(pixelClk, reset: pixelReset, [
      for (var k = 0; k < all; k++) ...[
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
          for (var k = planes; k < all; k++) underrunReg[k] < Const(0),
          if (ov != null)
            ovRow < Const(0, width: 16) - ov.dstYIn.zeroExtend(16),
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
            // A line start ends the prime, so the line state does not
            // fall behind and no prime request uses a buffer that is in
            // use.
            CaseItem(Const(1, width: 2), [
              If(
                lineStart,
                then: primeLine1(),
                orElse: [
                  If(
                    ov == null ? allIdle : allIdle & ov.ready,
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
                        // Overlay line 0.
                        if (ov != null)
                          for (var j = 0; j < ovPlanes; j++)
                            (
                              ov.on & active[planes + j],
                              ov.rowAddr[j],
                              Const(0),
                              pitch[planes + j],
                            ),
                      ]),
                      if (vActive > 1) lineNo < Const(2, width: 16),
                      if (chromaLines > 1) chromaNo < Const(2, width: 16),
                      phase < Const(2, width: 2),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(2, width: 2), [
              If(
                lineStart,
                then: primeLine2(),
                orElse: [
                  If(
                    allIdle,
                    then: [
                      if (ov != null)
                        ...issue([
                          for (var k = 0; k < planes; k++) null,
                          for (var j = 0; j < ovPlanes; j++)
                            (
                              ovSecond(j),
                              nextAddr[planes + j],
                              Const(1),
                              pitch[planes + j],
                            ),
                        ]),
                      phase < Const(3, width: 2),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(3, width: 2), [
              If(
                lineStart,
                then: [
                  ...primaryState(),
                  if (ov != null) ...overlayState(),
                  ...issue([
                    ...primaryLines(),
                    if (ov != null) ...overlayLines(),
                  ]),
                ],
              ),
            ]),
          ]),
        ],
      ),
    ]);

    // System domain: one pending request for each plane.
    List<Logic> sregs(String n, [int w = 1]) => [
      for (var k = 0; k < all; k++) Logic(name: 's${k}_$n', width: w),
    ];
    final rSync0 = Logic(name: 'r_sync0');
    final rSync1 = Logic(name: 'r_sync1');
    final reqEdge = Logic(name: 'req_edge');
    final uSync0 = sregs('u_sync0');
    final uSync1 = sregs('u_sync1');
    final uPrev = sregs('u_prev');
    final uCount = sregs('underrun_count', 16);
    final pending = sregs('pending');
    final pendAddr = sregs('pend_addr', 32);
    final pendWords = sregs('pend_words', 16);
    final pendFill = sregs('pend_fill');
    final pendTog = sregs('pend_tog');
    final planeW = (all - 1).bitLength < 1 ? 1 : (all - 1).bitLength;
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
    for (var k = 0; k < all; k++) {
      final o = k >= planes;
      final buffer = HarborDoubleLineBuffer(
        wrClk: sysClk,
        wrEn: all == 1 ? wrEn : (wrEn & curPlane.eq(k)),
        wrSel: wrSel,
        wrIdx: fit(wrIdx, idxW[k]),
        wrData: wrData,
        rdClk: pixelClk,
        rdReset: pixelReset,
        rdSel: o
            ? ovRow[k == planes ? 0 : 1]
            : k == 0
            ? readSel
            : chromaSel,
        rdCol: cols[k],
        maxWords: allMax[k],
        blockRam: blockRam,
        uniqueName: true,
        name: o ? 'overlay${k - planes}_lines' : 'plane${k}_lines',
      );
      rd.add(buffer.rdData);
    }
    pixel <= rd[0];
    for (var k = 1; k < planes; k++) {
      output('plane_data_$k') <= rd[k];
    }
    planeUnderrun <= underrunReg.sublist(0, planes).rswizzle();
    underrun <= underrunReg.reduce((a, b) => a | b);
    if (fmt != null) addOutput('format', width: selW) <= fmt;
    for (var k = 0; k < planes; k++) {
      addOutput('plane_underrun_count_$k', width: 16) <= uCount[k];
    }
    if (ov != null) {
      for (var j = 0; j < ovPlanes; j++) {
        addOutput('overlay_data_$j', width: 32) <= rd[planes + j];
        addOutput('overlay_underrun_count_$j', width: 16) <= uCount[planes + j];
      }
      addOutput('overlay_underrun', width: ovPlanes) <=
          underrunReg.sublist(planes).rswizzle();
      addOutput('overlay_on') <= ov.on;
      if (ov.format != null) {
        addOutput('overlay_frame_format', width: ov.format!.width) <=
            ov.format!;
      }
      for (final (name, v) in [
        ('overlay_frame_src_x', ov.srcX),
        ('overlay_frame_dst_x', ov.dstX),
        ('overlay_frame_dst_y', ov.dstY),
        ('overlay_frame_width', ov.width),
        ('overlay_frame_height', ov.height),
      ]) {
        addOutput(name, width: v.width) <= v;
      }
    }

    // The planes that the next line needs go first: primary plane 0, then
    // overlay plane 0. The chroma planes have two line times.
    final order = [
      0,
      if (ovPlanes > 0) planes,
      for (var k = 1; k < planes; k++) k,
      for (var j = 1; j < ovPlanes; j++) planes + j,
    ];
    Conditional pickNext(int i) {
      final k = order[i];
      return If(
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
        orElse: [if (i + 1 < all) pickNext(i + 1)],
      );
    }

    Sequential(sysClk, reset: sysReset, [
      rSync0 < reqToggle,
      rSync1 < rSync0,
      reqEdge < rSync0 ^ rSync1,
      for (var k = 0; k < all; k++) ...[
        uSync0[k] < underrunTog[k],
        uSync1[k] < uSync0[k],
        uPrev[k] < uSync1[k],
        If(
          (uSync1[k] ^ uPrev[k]) & ~uCount[k].and(),
          then: [uCount[k] < uCount[k] + 1],
        ),
      ],
      fetchStartReg < Const(0),
      If(
        ~sysBusy,
        then: [pickNext(0)],
        orElse: [
          If(
            fetchDone,
            then: [
              for (var k = 0; k < all; k++)
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
          for (var k = 0; k < all; k++)
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

  /// The overlay inputs, their frame latches and the start of each overlay
  /// plane line. It drives [pitch], [active] and [words] of the overlay
  /// planes.
  _OverlayState _overlayState({
    required HarborScanoutOverlay overlay,
    required Logic pixelClk,
    required Logic pixelReset,
    required Logic frameStart,
    required Logic Function(Logic) word32,
    required int hActive,
    required int vActive,
    required List<Logic> pitch,
    required List<Logic> active,
    required List<Logic> words,
  }) {
    final fs = overlay.formats;
    final n = overlay.planes;
    final xw = overlay.srcX.width;
    final yw = overlay.srcY.width;
    if (overlay.dstX.width != xw ||
        overlay.width.width != xw ||
        overlay.dstY.width != yw ||
        overlay.height.width != yw ||
        xw < 2 ||
        yw < 2 ||
        hActive.bitLength > xw ||
        vActive.bitLength > yw) {
      throw ArgumentError(
        'the overlay x inputs must have one width that holds hActive, and '
        'the y inputs one width that holds vActive',
      );
    }
    final selW = (fs.length - 1).bitLength;
    final enable = addInput('overlay_enable', overlay.enable);
    final selIn = fs.length > 1
        ? addInput('overlay_format_sel', overlay.formatSel!, width: selW)
        : null;
    final baseIn = [
      for (var j = 0; j < n; j++)
        word32(addInput('overlay_base_$j', overlay.base[j], width: 32)),
    ];
    final pitchIn = [
      for (var j = 0; j < n; j++)
        word32(addInput('overlay_pitch_$j', overlay.pitch[j], width: 32)),
    ];
    final srcXIn = addInput('overlay_src_x', overlay.srcX, width: xw);
    final srcYIn = addInput('overlay_src_y', overlay.srcY, width: yw);
    final dstXIn = addInput('overlay_dst_x', overlay.dstX, width: xw);
    final dstYIn = addInput('overlay_dst_y', overlay.dstY, width: yw);
    final widthIn = addInput('overlay_width', overlay.width, width: xw);
    final heightIn = addInput('overlay_height', overlay.height, width: yw);

    // A value for each overlay format, picked by sel.
    Logic pick(Logic? sel, Logic Function(HarborPixelFormat) v) {
      var out = v(fs.last);
      for (var i = fs.length - 2; i >= 0; i--) {
        out = mux(sel!.eq(i), v(fs[i]), out);
      }
      return out;
    }

    Logic flag(Logic? sel, bool Function(HarborPixelFormat) f) =>
        pick(sel, (g) => Const(f(g) ? 1 : 0));
    Logic clear0(Logic v, Logic c) => [v.getRange(1), v[0] & ~c].swizzle();

    final fmt = selIn == null ? null : Logic(name: 'ov_format', width: selW);
    final on = Logic(name: 'ov_on');
    final ready = Logic(name: 'ov_ready');
    final enF = Logic(name: 'ov_enable_frame');
    final srcX = Logic(name: 'ov_src_x', width: xw);
    final srcY = Logic(name: 'ov_src_y', width: yw);
    final dstX = Logic(name: 'ov_dst_x', width: xw);
    final dstY = Logic(name: 'ov_dst_y', width: yw);
    final width = Logic(name: 'ov_width', width: xw);
    final height = Logic(name: 'ov_height', width: yw);
    final base = [
      for (var j = 0; j < n; j++) Logic(name: 'ov${j}_base', width: 32),
    ];

    // Values of the frame, one register stage after the latch each.
    final ew = xw + 2;
    final visible = dstX.zeroExtend(xw + 1).lt(hActive);
    final room = Const(hActive, width: xw + 1) - dstX.zeroExtend(xw + 1);
    final w1 = width.zeroExtend(xw + 1);
    final wVis = flop(
      pixelClk,
      mux(visible, mux(w1.lt(room), w1, room), Const(0, width: xw + 1)),
      reset: pixelReset,
    ).named('ov_width_visible');
    on <=
        flop(
          pixelClk,
          enF &
              width.neq(0) &
              height.neq(0) &
              visible &
              dstY.zeroExtend(yw + 1).lt(vActive),
          reset: pixelReset,
        );
    final srcXe = srcX.zeroExtend(ew);
    final clipped = wVis.lt(w1);
    final startByte = <Logic>[];
    for (var j = 0; j < n; j++) {
      // The last source pixel to fetch: the last visible one, or the one
      // after it for a plane that reads one pixel ahead when the screen
      // clips the crop. At the right edge of the crop, the unpack uses the
      // word before for an odd pixel.
      final ahead =
          flag(
            fmt,
            (f) => j < f.planes.length && HarborScanoutOverlay.lookahead(f, j),
          ) &
          clipped;
      final last = flop(
        pixelClk,
        srcXe +
            wVis.zeroExtend(ew) -
            mux(ahead, Const(0, width: ew), Const(1, width: ew)),
        reset: pixelReset,
      ).named('ov${j}_last_pixel');
      final count = pick(fmt, (f) {
        if (j >= f.planes.length) return Const(0, width: ew);
        final sh = HarborScanoutOverlay.wordShift(f, j);
        return (last >>> sh) - (srcXe >>> sh) + 1;
      });
      words[j] <=
          flop(
            pixelClk,
            count.width >= 16 ? count.getRange(0, 16) : count.zeroExtend(16),
            reset: pixelReset,
          ).named('ov${j}_words');
      startByte.add(
        pick(fmt, (f) {
          if (j >= f.planes.length) return Const(0, width: 32);
          final sh = HarborScanoutOverlay.wordShift(f, j);
          return [(srcXe >>> sh).zeroExtend(30), Const(0, width: 2)].swizzle();
        }).named('ov${j}_start_byte'),
      );
    }

    // The address of source line srcY in each plane: base plus srcY times
    // the pitch, one bit of srcY each clock, after the frame values settle.
    const load = 3;
    final stepW = (load + yw + 1).bitLength;
    final step = Logic(name: 'ov_step', width: stepW);
    final acc = [
      for (var j = 0; j < n; j++) Logic(name: 'ov${j}_row_addr', width: 32),
    ];
    final cand = [
      for (var j = 0; j < n; j++) Logic(name: 'ov${j}_mul_pitch', width: 32),
    ];
    final plier = [
      for (var j = 0; j < n; j++) Logic(name: 'ov${j}_mul_line', width: yw),
    ];
    final hHalf = flag(selIn, (f) => f.hSub == 2);
    final vHalf = flag(selIn, (f) => f.vSub == 2);
    Sequential(pixelClk, reset: pixelReset, [
      If(
        frameStart,
        then: [
          enF < enable,
          if (fmt != null) fmt < selIn!,
          srcX < clear0(srcXIn, hHalf),
          srcY < clear0(srcYIn, vHalf),
          dstX < dstXIn,
          dstY < dstYIn,
          width < widthIn,
          height < heightIn,
          for (var j = 0; j < n; j++) ...[
            base[j] < baseIn[j],
            pitch[j] < pitchIn[j],
            active[j] < flag(selIn, (f) => j < f.planes.length),
          ],
          step < Const(0, width: stepW),
          ready < Const(0),
        ],
        orElse: [
          If(
            ~ready,
            then: [
              step < step + 1,
              If(
                step.eq(load),
                then: [
                  for (var j = 0; j < n; j++) ...[
                    acc[j] < base[j] + startByte[j],
                    cand[j] < pitch[j],
                    // A chroma plane has one line for two source lines.
                    plier[j] <
                        (j == 0 ? srcY : srcY.getRange(1).zeroExtend(yw)),
                  ],
                ],
                orElse: [
                  If(
                    step.gt(load),
                    then: [
                      for (var j = 0; j < n; j++) ...[
                        If(plier[j][0], then: [acc[j] < acc[j] + cand[j]]),
                        cand[j] < (cand[j] << 1),
                        plier[j] < (plier[j] >>> 1),
                      ],
                    ],
                  ),
                ],
              ),
              If(step.eq(load + yw), then: [ready < Const(1)]),
            ],
          ),
        ],
      ),
    ]);

    return _OverlayState(
      on: on,
      ready: ready,
      format: fmt,
      rowAddr: acc,
      dstYIn: dstYIn,
      srcX: srcX,
      dstX: dstX,
      dstY: dstY,
      width: width,
      height: height,
    );
  }
}

/// The overlay registers of a frame in [HarborDualClockScanout].
class _OverlayState {
  /// High when the overlay is enabled and has a visible part.
  final Logic on;

  /// High when [rowAddr] holds the address of the first source line.
  final Logic ready;
  final Logic? format;
  final List<Logic> rowAddr;

  /// The `overlay_dst_y` input before the latch.
  final Logic dstYIn;
  final Logic srcX;
  final Logic dstX;
  final Logic dstY;
  final Logic width;
  final Logic height;

  _OverlayState({
    required this.on,
    required this.ready,
    required this.format,
    required this.rowAddr,
    required this.dstYIn,
    required this.srcX,
    required this.dstX,
    required this.dstY,
    required this.width,
    required this.height,
  });
}

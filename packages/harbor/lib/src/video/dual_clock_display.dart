import 'dart:math';

import 'package:rohd/rohd.dart';

import '../arith/fpu_config.dart';
import '../bus/port/memory_waist.dart';
import '../soc/target.dart';
import 'tmds_serializer.dart';

import '../peripherals/display.dart';
import 'alpha_blend.dart';
import 'csc.dart';
import 'display_output.dart';
import 'dual_clock_scanout.dart';
import 'dvi_transmitter.dart';
import 'parallel_rgb_output.dart';
import 'pixel_unpack.dart';
import 'tmds_encoder.dart';
import 'video_timing.dart';

/// A framebuffer display that streams from shared main memory across clock
/// domains: pixel-domain timing + TMDS, system-domain framebuffer DMA.
///
/// The system-domain memory master waist ([memory]) joins the SoC fabric
/// directly (no per-word CDC bridge). The clock crossing lives inside the
/// double line buffer. A new [burstWords]-beat request goes out as soon as
/// the waist takes the previous one, see [HarborDualClockScanout]. Give
/// [rqReady], [rdValid] and [rdData] in place of [memory] to read through a
/// scanout port (`rq_*`), such as a [HarborSdram] scanout port. Then
/// [sysClk] and [sysReset] are that port's clock and reset, and the display
/// ignores the low 2 bits of `fb_base`. [lineStride] is the bytes from one
/// line to the next, the line size by default. Use
/// [HarborSdram.scanoutStride] to start each line on a new sdram row.
///
/// Emits parallel RGB+sync (for a VGA-style backend or observation) and,
/// depending on [outputType], either the four GPDI lanes (dvi/hdmi) or a
/// packed [rgb] plus a forwarded pixel clock [pclk] (parallelRgb). See
/// [HarborFramebufferDisplay] for the single-clock variant used by the
/// test-pattern path. A parallelRgb build has no serializer, so it needs no
/// `shiftClk` or `shiftReset` and has no `shift_*` ports without them.
///
/// The parallel outputs ([de], [hsync], [vsync], [red], [green], [blue], [x],
/// [y], [pixelWord], and for parallelRgb [rgb]/[pclk]) are registered and
/// aligned with each other. They come [pipelineDelay] pixel cycles after the
/// timing generator. The TMDS lanes add the [TmdsEncoder.latency] of the
/// encoders on top of that; parallelRgb adds none, since [rgb]/[pclk] are the
/// same registers as [red]/[green]/[blue]/[hsync]/[vsync]/[de].
///
/// [formats] is the set of pixel formats the build can scan, [pixelFormat]
/// alone by default. A set of more than one format, or a format of more
/// than one plane, makes a planar build (see [HarborDualClockScanout]).
/// It adds `format_sel` (only for more than one format), `plane_pitch_<n>`
/// ([planePitch]) for each plane, and `plane_base_<n>` ([planeBase]) for
/// each plane after plane 0. Plane 0 starts at [fbBase]. A plane pitch
/// must be a multiple of 4 and at least [HarborPixelFormat.lineBytes] of
/// its plane. A scanout port ignores the low 2 bits of each base and
/// pitch. A planar build has no [lineStride] input. It has a
/// [planeUnderrun] output with one bit for each plane and a
/// `plane_underrun_count_<n>` output for each plane, see
/// [HarborDualClockScanout.planeUnderrunCount].
///
/// A build with a YUV format unpacks the plane words with [unpack] and
/// converts a YUV frame to RGB with [csc]. It has the inputs
/// `csc_coeff_0` to `csc_coeff_8`, `csc_in_offset_0` to `_2` and
/// `csc_out_offset_0` to `_2` in the pixel domain, see
/// [HarborCscCoefficients]. The display latches them at frame start, so a
/// change takes effect at the next frame. The latches reset to
/// [HarborCscCoefficients.bt709Limited], and an input that is not given is
/// tied to that value. An RGB frame does not go through [csc].
///
/// [overlayFormats] adds an overlay plane, see [HarborDualClockScanout].
/// Without it the build has no overlay logic or ports. The overlay inputs
/// are in the pixel domain and the display latches them at frame start:
/// - `overlay_enable`, and `overlay_format_sel` for more than one format.
/// - `overlay_base_<n>` and `overlay_pitch_<n>` for each overlay plane,
///   with the rules of the primary planes.
/// - `overlay_src_x`, `overlay_src_y`: the source crop origin.
/// - `overlay_dst_x`, `overlay_dst_y`: the screen origin.
/// - `overlay_width`, `overlay_height`: the size of the crop and of the
///   overlay on the screen.
/// - `overlay_alpha`: 255 shows the overlay, 0 the primary.
/// - `overlay_csc_*` like `csc_*`, only with a YUV overlay format.
///
/// The overlay covers screen pixels x from dst_x to dst_x + width - 1 and
/// lines from dst_y to dst_y + height - 1 in the active area. Screen pixel
/// (x, y) shows source pixel (src_x + x - dst_x, src_y + y - dst_y). The
/// chroma rule of [HarborPixelUnpack] applies to the source columns, and
/// the right edge of the crop repeats its last chroma sample. src_x must
/// be even for a 4:2:2 or 4:2:0 format and src_y even for 4:2:0. If not,
/// the scanout clears bit 0 and the crop moves one pixel left or up. The
/// overlay and the primary go through [HarborAlphaBlend]. An overlay build
/// has the `overlay_underrun` and `overlay_underrun_count_<n>` outputs,
/// and the `plane_underrun` outputs also for one primary plane. Its
/// [underrun] includes the overlay planes.
class HarborDualClockDisplay extends Module {
  /// Pixel cycles from the timing generator to the parallel outputs: one for
  /// the line buffer read and one for the output register. A build with a
  /// YUV format adds the stages of [HarborPixelUnpack] after the read and
  /// the stages of [HarborCsc].
  final int pipelineDelay;

  /// The unpack of a build with a YUV format, null for an RGB build.
  late final HarborPixelUnpack? unpack;

  /// The overlay unpack, color conversion and blend, null without an
  /// overlay. The conversion is null for an RGB overlay set.
  HarborPixelUnpack? overlayUnpack;
  HarborCsc? overlayCsc;
  HarborAlphaBlend? blend;

  /// The overlay formats, or null.
  final List<HarborPixelFormat>? overlayFormats;

  /// The color conversion of a build with a YUV format, null for an RGB
  /// build.
  HarborCsc? get csc => _csc;
  HarborCsc? _csc;

  /// Four serialized TMDS lanes, present only for dvi/hdmi.
  Logic get gpdi => output('gpdi');

  /// The four complement lanes, present only on a target that drives its own
  /// ([TmdsSerializer.needsComplement]).
  Logic get gpdiN => output('gpdi_n');

  /// 24-bit 8:8:8 RGB (red in bits 23:16), present only for parallelRgb.
  Logic get rgb => output('rgb');

  /// The forwarded pixel clock, present only for parallelRgb.
  Logic get pclk => output('pclk');
  Logic get de => output('de');
  Logic get hsync => output('hsync');
  Logic get vsync => output('vsync');
  Logic get red => output('red');
  Logic get green => output('green');
  Logic get blue => output('blue');
  Logic get x => output('x');
  Logic get y => output('y');

  /// The plane 0 word read for the pixel. On a yuyv or uyvy frame, an odd
  /// pixel shows the word of the next pixel.
  Logic get pixelWord => output('pixel_word');
  Logic get underrun => output('underrun');

  /// One underrun bit for each plane, present only on a planar build.
  Logic get planeUnderrun => output('plane_underrun');

  /// Scanout port requests (system domain).
  Logic get rqValid => output('rq_valid');
  Logic get rqAddr => output('rq_addr');
  Logic get rqWords => output('rq_words');

  final HarborDisplayTiming timing;
  final HarborDisplayInterface outputType;

  /// Pixel format read from the framebuffer, the first of [formats].
  final HarborPixelFormat pixelFormat;

  /// The pixel formats of the build, in `format_sel` order.
  final List<HarborPixelFormat> formats;

  /// Bytes from the start of one line to the start of the next. On a
  /// planar build, where `plane_pitch_0` gives the pitch, the largest plane
  /// 0 line.
  final int lineStride;

  HarborDualClockDisplay({
    required this.timing,
    required Logic pixelClk,
    required Logic pixelReset,
    Logic? shiftClk,
    Logic? shiftReset,
    required Logic sysClk,
    required Logic sysReset,
    required Logic enable,
    required Logic fbBase,
    HarborMemoryWaist? memory,
    Logic? rqReady,
    Logic? rdValid,
    Logic? rdData,
    int? lineStride,
    int burstWords = 16,
    this.outputType = HarborDisplayInterface.hdmi,
    HarborPixelFormat pixelFormat = HarborPixelFormat.xrgb8888,
    List<HarborPixelFormat>? formats,
    Logic? formatSel,
    List<Logic> planeBase = const [],
    List<Logic> planePitch = const [],
    List<Logic>? cscCoeff,
    List<Logic>? cscInOffset,
    List<Logic>? cscOutOffset,
    List<HarborPixelFormat>? overlayFormats,
    Logic? overlayEnable,
    Logic? overlayFormatSel,
    List<Logic> overlayBase = const [],
    List<Logic> overlayPitch = const [],
    Logic? overlaySrcX,
    Logic? overlaySrcY,
    Logic? overlayDstX,
    Logic? overlayDstY,
    Logic? overlayWidth,
    Logic? overlayHeight,
    Logic? overlayAlpha,
    List<Logic>? overlayCscCoeff,
    List<Logic>? overlayCscInOffset,
    List<Logic>? overlayCscOutOffset,
    HarborParallelRgbLatchEdge parallelRgbLatchEdge =
        HarborParallelRgbLatchEdge.falling,
    required HarborDeviceTarget target,
    super.name = 'dual_clock_display',
  }) : formats = List.unmodifiable(formats ?? [pixelFormat]),
       pixelFormat = (formats ?? [pixelFormat]).first,
       pipelineDelay = _delay(formats ?? [pixelFormat], overlayFormats),
       overlayFormats = overlayFormats == null
           ? null
           : List.unmodifiable(overlayFormats),
       lineStride = lineStride ?? _lineBytes(timing, formats ?? [pixelFormat]),
       super(
         definitionName:
             _overlayName(
               _name(
                 timing: timing,
                 formats: formats ?? [pixelFormat],
                 stride:
                     lineStride ?? _lineBytes(timing, formats ?? [pixelFormat]),
                 port: rqReady != null,
                 target: target,
                 memory: memory,
                 burstWords: burstWords,
               ),
               timing,
               overlayFormats,
               target,
             ) +
             (outputType == HarborDisplayInterface.parallelRgb
                 ? '_parallelRgb'
                 : ''),
       ) {
    requireDisplayOutputSupported(outputType);
    if (outputType != HarborDisplayInterface.parallelRgb &&
        (shiftClk == null || shiftReset == null)) {
      throw ArgumentError('a TMDS output needs shiftClk and shiftReset');
    }
    final lineBytes = _lineBytes(timing, this.formats);
    final planar = HarborDualClockScanout.isPlanar(this.formats);
    if (planar && lineStride != null) {
      throw ArgumentError(
        'a planar build takes the plane 0 pitch from plane_pitch_0, '
        'not lineStride',
      );
    }
    if (this.lineStride < lineBytes || this.lineStride % 4 != 0) {
      throw ArgumentError.value(
        this.lineStride,
        'lineStride',
        'must be a multiple of 4 and at least the line size $lineBytes',
      );
    }
    if (this.formats.contains(HarborPixelFormat.rgb888)) {
      throw ArgumentError(
        'rgb888 does not fit the 32-bit scanout word layout.',
      );
    }
    if (this.formats.contains(HarborPixelFormat.rgb565) &&
        timing.hActive.isOdd) {
      throw ArgumentError(
        'rgb565 needs an even hActive (got ${timing.hActive}).',
      );
    }
    final rgb565 = this.pixelFormat == HarborPixelFormat.rgb565;
    final hasYuv = this.formats.any((f) => f.yuv);
    final ovFormats = this.overlayFormats;
    final ovYuv = ovFormats != null && ovFormats.any((f) => f.yuv);
    if (!hasYuv &&
        (cscCoeff != null || cscInOffset != null || cscOutOffset != null)) {
      throw ArgumentError('an RGB build has no color conversion inputs');
    }
    if (!ovYuv &&
        (overlayCscCoeff != null ||
            overlayCscInOffset != null ||
            overlayCscOutOffset != null)) {
      throw ArgumentError(
        'a build without a YUV overlay format has no overlay color '
        'conversion inputs',
      );
    }
    // A CSC reads its settings in the clock of the pixel input, and the
    // frame latch changes one clock after the first blank line starts. The
    // other overlay settings are read with the pixel column.
    final minBlank = HarborPixelUnpack.latency - 1;
    if ((hasYuv || ovYuv) && timing.hTotal - timing.hActive < minBlank) {
      throw ArgumentError(
        'a YUV build needs at least $minBlank clocks of horizontal blank '
        '(hFrontPorch + hSyncWidth + hBackPorch), got '
        '${timing.hTotal - timing.hActive}',
      );
    }
    for (final (c, i, o) in [
      (cscCoeff, cscInOffset, cscOutOffset),
      (overlayCscCoeff, overlayCscInOffset, overlayCscOutOffset),
    ]) {
      if ((c != null && c.length != 9) ||
          (i != null && i.length != 3) ||
          (o != null && o.length != 3)) {
        throw ArgumentError('give 9 coefficients and 3 offsets of each kind');
      }
    }
    if (ovFormats != null) {
      if (ovFormats.isEmpty || ovFormats.contains(HarborPixelFormat.rgb888)) {
        throw ArgumentError('overlayFormats must not be empty or hold rgb888');
      }
      final n = ovFormats.map((f) => f.planes.length).reduce(max);
      if (overlayEnable == null ||
          overlaySrcX == null ||
          overlaySrcY == null ||
          overlayDstX == null ||
          overlayDstY == null ||
          overlayWidth == null ||
          overlayHeight == null ||
          overlayAlpha == null ||
          overlayBase.length != n ||
          overlayPitch.length != n ||
          (ovFormats.length > 1) != (overlayFormatSel != null)) {
        throw ArgumentError(
          'an overlay build needs every overlay input, overlayBase and '
          'overlayPitch for planes 0 to ${n - 1}, and overlayFormatSel only '
          'for more than one overlay format',
        );
      }
      // The scanout needs the overlay row address before the first line
      // start.
      final rowClocks =
          max((timing.vTotal - 1).bitLength, timing.vActive.bitLength) + 5;
      if ((timing.vTotal - timing.vActive) * timing.hTotal + timing.hActive <=
          rowClocks) {
        throw ArgumentError(
          'an overlay build needs more than $rowClocks clocks from the frame '
          'start to the first line start',
        );
      }
    } else if (overlayEnable != null) {
      throw ArgumentError('give overlayFormats for an overlay');
    }

    pixelClk = addInput('pixel_clk', pixelClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    if (shiftClk != null) shiftClk = addInput('shift_clk', shiftClk);
    if (shiftReset != null) shiftReset = addInput('shift_reset', shiftReset);
    sysClk = addInput('sys_clk', sysClk);
    sysReset = addInput('sys_reset', sysReset);
    enable = addInput('enable', enable);
    fbBase = addInput('fb_base', fbBase, width: 32);
    final planes = planar
        ? this.formats.map((f) => f.planes.length).reduce(max)
        : 1;
    if (planar) {
      if ((this.formats.length > 1) != (formatSel != null)) {
        throw ArgumentError(
          'give formatSel only when there is more than one format',
        );
      }
      if (planeBase.length != planes - 1 || planePitch.length != planes) {
        throw ArgumentError(
          'give planeBase for planes 1 to ${planes - 1} and planePitch for '
          'planes 0 to ${planes - 1}',
        );
      }
      if (formatSel != null) {
        formatSel = addInput(
          'format_sel',
          formatSel,
          width: (this.formats.length - 1).bitLength,
        );
      }
      planeBase = [
        for (var k = 1; k < planes; k++)
          addInput('plane_base_$k', planeBase[k - 1], width: 32),
      ];
      planePitch = [
        for (var k = 0; k < planes; k++)
          addInput('plane_pitch_$k', planePitch[k], width: 32),
      ];
    }
    HarborMemoryWaist? localMemory;
    if (memory != null) {
      localMemory = memory.clone()
        ..pairConnectIO(
          this,
          memory,
          PairRole.provider,
          uniquify: (n) => 'm_$n',
        );
    }
    if (rqReady != null) rqReady = addInput('rq_ready', rqReady);
    if (rdValid != null) rdValid = addInput('rd_valid', rdValid);
    if (rdData != null) rdData = addInput('rd_data', rdData, width: 16);

    final hbits = (timing.hTotal - 1).bitLength;
    final vbits = (timing.vTotal - 1).bitLength;
    final parallelRgb = outputType == HarborDisplayInterface.parallelRgb;
    final tmdsComplement =
        !parallelRgb && TmdsSerializer.needsComplement(target);
    if (parallelRgb) {
      addOutput('rgb', width: 24);
      addOutput('pclk');
    } else {
      addOutput('gpdi', width: 4);
      if (tmdsComplement) {
        addOutput('gpdi_n', width: 4);
      }
    }
    addOutput('de');
    addOutput('hsync');
    addOutput('vsync');
    addOutput('red', width: 8);
    addOutput('green', width: 8);
    addOutput('blue', width: 8);
    addOutput('x', width: hbits);
    addOutput('y', width: vbits);
    addOutput('pixel_word', width: 32);
    addOutput('underrun');

    final timingGen = VideoTimingGenerator(
      timing: timing,
      clk: pixelClk,
      reset: pixelReset,
    );
    final tx = timingGen.x;
    final ty = timingGen.y;
    final deActive = timingGen.de & enable;

    Logic delay(Logic v, String name) =>
        flop(pixelClk, v, reset: pixelReset).named(name);

    final frameStart = enable & tx.eq(0) & ty.eq(timing.vActive);
    // End of an active line: swap to the prefetched buffer and start the next
    // line's fetch. NOT after the LAST active line: there is no next line, and
    // that pointless fetch is still running when the frame ends, so the
    // scanout's frame-start prime (which issues line 0) lands while the system
    // side is busy and is dropped. The visible result is a blank first row,
    // and only on wide lines, because a short line's fetch finishes inside the
    // horizontal blank and never overlaps.
    final lineStart =
        enable & tx.eq(timing.hActive) & ty.lt(timing.vActive - 1);
    // The first pixel of line 0, where the scanout checks line 0. It is a
    // register, so no compare is on the scanout control path.
    final firstLine = delay(
      enable & tx.eq(timing.hTotal - 1) & ty.eq(timing.vTotal - 1),
      'first_line',
    );

    // rgb565 packs two pixels in each word. The word is tx >> 1 and the half
    // is tx bit 0.
    Logic wordCol(HarborPixelFormat f, int plane) {
      final shift = _wordShift(f, plane);
      return shift == 0
          ? tx
          : tx.getRange(shift, tx.width).zeroExtend(tx.width);
    }

    // The format of the frame comes from the scanout, so the columns
    // change with the fetch at frame start.
    final fmt = planar && this.formats.length > 1
        ? Logic(name: 'frame_format', width: formatSel!.width)
        : null;
    final planeWord = [
      for (var k = 0; k < planes; k++) Logic(name: 'plane${k}_word', width: 32),
    ];
    final unpack = hasYuv
        ? HarborPixelUnpack(
            clk: pixelClk,
            reset: pixelReset,
            x: tx,
            format: fmt,
            planeData: planeWord,
            formats: this.formats,
            hActive: timing.hActive,
          )
        : null;
    this.unpack = unpack;

    // Overlay inputs. The x inputs hold hActive and the y inputs vActive.
    final xw = max(hbits, timing.hActive.bitLength);
    final yw = max(vbits, timing.vActive.bitLength);
    final ovPlanes = ovFormats == null
        ? 0
        : ovFormats.map((f) => f.planes.length).reduce(max);
    final ovCol = [
      for (var j = 0; j < ovPlanes; j++)
        Logic(name: 'overlay${j}_col', width: xw + 2),
    ];
    HarborScanoutOverlay? so;
    Logic? ovAlpha;
    if (ovFormats != null) {
      Logic inX(String n, Logic v) => addInput(n, v, width: xw);
      Logic inY(String n, Logic v) => addInput(n, v, width: yw);
      so = HarborScanoutOverlay(
        formats: ovFormats,
        enable: addInput('overlay_enable', overlayEnable!),
        formatSel: overlayFormatSel == null
            ? null
            : addInput(
                'overlay_format_sel',
                overlayFormatSel,
                width: (ovFormats.length - 1).bitLength,
              ),
        base: [
          for (var j = 0; j < ovPlanes; j++)
            addInput('overlay_base_$j', overlayBase[j], width: 32),
        ],
        pitch: [
          for (var j = 0; j < ovPlanes; j++)
            addInput('overlay_pitch_$j', overlayPitch[j], width: 32),
        ],
        srcX: inX('overlay_src_x', overlaySrcX!),
        srcY: inY('overlay_src_y', overlaySrcY!),
        dstX: inX('overlay_dst_x', overlayDstX!),
        dstY: inY('overlay_dst_y', overlayDstY!),
        width: inX('overlay_width', overlayWidth!),
        height: inY('overlay_height', overlayHeight!),
        col: ovCol,
      );
      ovAlpha = flop(
        pixelClk,
        addInput('overlay_alpha', overlayAlpha!, width: 8),
        en: frameStart,
        reset: pixelReset,
      ).named('overlay_alpha_frame');
    }

    final HarborDualClockScanout scanout;
    Logic? frameFormat;
    if (!planar && so != null) {
      // One primary plane with an overlay: the scanout is planar, the
      // primary keeps its stride.
      final shift = _wordShift(this.pixelFormat, 0);
      scanout = HarborDualClockScanout(
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        sysClk: sysClk,
        sysReset: sysReset,
        frameStart: frameStart,
        lineStart: lineStart,
        firstLine: firstLine,
        col: unpack != null
            ? unpack.planeCol(0)
            : shift == 0
            ? tx
            : tx.getRange(shift, tx.width).zeroExtend(tx.width),
        fbBase: fbBase,
        stride: Const(this.lineStride, width: 32),
        memory: localMemory,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
        burstWords: burstWords,
        blockRam: target.blockRam,
        formats: this.formats,
        hActive: timing.hActive,
        vActive: timing.vActive,
        overlay: so,
      );
      addOutput('plane_underrun') <= scanout.planeUnderrun;
      addOutput('plane_underrun_count_0', width: 16) <=
          scanout.planeUnderrunCount(0);
    } else if (!planar) {
      final wordsPerLine = HarborDualClockScanout.planeWords(
        this.pixelFormat,
        0,
        timing.hActive,
      );
      final shift = _wordShift(this.pixelFormat, 0);
      final scanoutCol = unpack != null
          ? unpack.planeCol(0).getRange(0, tx.width - shift)
          : shift == 0
          ? tx
          : tx.getRange(shift, tx.width);
      scanout = HarborDualClockScanout(
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        sysClk: sysClk,
        sysReset: sysReset,
        frameStart: frameStart,
        lineStart: lineStart,
        firstLine: firstLine,
        col: scanoutCol,
        fbBase: fbBase,
        stride: Const(this.lineStride, width: 32),
        wordsPerLine: Const(wordsPerLine, width: 16),
        vActive: timing.vActive,
        memory: localMemory,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
        maxWords: wordsPerLine,
        burstWords: burstWords,
        blockRam: target.blockRam,
      );
    } else {
      Logic pick(List<Logic> values) {
        var out = values.last;
        for (var i = values.length - 2; i >= 0; i--) {
          out = mux(fmt!.eq(i), values[i], out);
        }
        return out;
      }

      final cols = [
        for (var k = 0; k < planes; k++)
          (unpack != null
                  ? unpack.planeCol(k)
                  : pick([
                      for (final f in this.formats)
                        k < f.planes.length
                            ? wordCol(f, k)
                            : Const(0, width: tx.width),
                    ]))
              .named('plane${k}_col'),
      ];
      scanout = HarborDualClockScanout(
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        sysClk: sysClk,
        sysReset: sysReset,
        frameStart: frameStart,
        lineStart: lineStart,
        firstLine: firstLine,
        col: cols[0],
        fbBase: fbBase,
        stride: planePitch[0],
        memory: localMemory,
        rqReady: rqReady,
        rdValid: rdValid,
        rdData: rdData,
        burstWords: burstWords,
        blockRam: target.blockRam,
        formats: this.formats,
        hActive: timing.hActive,
        vActive: timing.vActive,
        formatSel: formatSel,
        planeBase: planeBase,
        planePitch: planePitch.sublist(1),
        planeCol: cols.sublist(1),
        overlay: so,
      );
      if (fmt != null) {
        fmt <= scanout.format;
        frameFormat = fmt;
      }
      addOutput('plane_underrun', width: planes) <= scanout.planeUnderrun;
      for (var k = 0; k < planes; k++) {
        addOutput('plane_underrun_count_$k', width: 16) <=
            scanout.planeUnderrunCount(k);
      }
    }

    if (so != null) {
      addOutput('overlay_underrun', width: ovPlanes) <= scanout.overlayUnderrun;
      for (var j = 0; j < ovPlanes; j++) {
        addOutput('overlay_underrun_count_$j', width: 16) <=
            scanout.overlayUnderrunCount(j);
      }
    }
    if (scanout.scanoutPort) {
      addOutput('rq_valid') <= scanout.rqValid;
      addOutput('rq_addr', width: 32) <= scanout.rqAddr;
      addOutput('rq_words', width: scanout.rqWords.width) <= scanout.rqWords;
    }
    underrun <= scanout.underrun;
    if (unpack != null) {
      for (var k = 0; k < planes; k++) {
        planeWord[k] <= scanout.planeData(k);
      }
    }

    // The line buffer read is registered, so the word comes one cycle after
    // tx. Stage 1 delays the timing signals to match it.
    final word = scanout.pixel;
    final de1 = delay(deActive, 'de_s1');
    final last = pipelineDelay;
    var deLast = de1;

    Logic r;
    Logic g;
    Logic b;
    final i565 = this.formats.indexOf(HarborPixelFormat.rgb565);
    if (unpack != null) {
      for (var s = 2; s < last; s++) {
        deLast = delay(deLast, 'de_s$s');
      }
      final csc = _conversion(
        prefix: 'csc',
        clk: pixelClk,
        reset: pixelReset,
        frameStart: frameStart,
        target: target,
        unpack: unpack,
        coeff: cscCoeff,
        inOffset: cscInOffset,
        outOffset: cscOutOffset,
      );
      _csc = csc;
      if (this.formats.every((f) => f.yuv)) {
        r = csc.red;
        g = csc.green;
        b = csc.blue;
      } else {
        // An RGB frame skips the conversion, with the same delay.
        final s0 = HarborPixelUnpack.latency;
        Logic match(Logic v, String name) {
          for (var s = s0 + 1; s <= s0 + HarborCsc.stages; s++) {
            v = delay(v, '${name}_s$s');
          }
          return v;
        }

        final isYuv = match(unpack.yuv, 'yuv');
        r = mux(isYuv, csc.red, match(unpack.red, 'rgb_red'));
        g = mux(isYuv, csc.green, match(unpack.green, 'rgb_green'));
        b = mux(isYuv, csc.blue, match(unpack.blue, 'rgb_blue'));
      }
    } else if (planar && i565 >= 0) {
      final halfSel = delay(tx[0], 'half_s1');
      final half = mux(halfSel, word.getRange(16, 32), word.getRange(0, 16));
      final r5 = half.getRange(11, 16);
      final g6 = half.getRange(5, 11);
      final b5 = half.getRange(0, 5);
      final is565 = frameFormat == null
          ? Const(1)
          : frameFormat.eq(i565).named('is_rgb565');
      r = mux(is565, [r5, r5.getRange(2, 5)].swizzle(), word.getRange(16, 24));
      g = mux(is565, [g6, g6.getRange(4, 6)].swizzle(), word.getRange(8, 16));
      b = mux(is565, [b5, b5.getRange(2, 5)].swizzle(), word.getRange(0, 8));
    } else if (rgb565) {
      // Column 0 is the low half (bits 15..0), column 1 the high half
      // (bits 31..16): little-endian memory order.
      final halfSel = delay(tx[0], 'half_s1');
      final half = mux(halfSel, word.getRange(16, 32), word.getRange(0, 16));
      final r5 = half.getRange(11, 16);
      final g6 = half.getRange(5, 11);
      final b5 = half.getRange(0, 5);
      r = [r5, r5.getRange(2, 5)].swizzle();
      g = [g6, g6.getRange(4, 6)].swizzle();
      b = [b5, b5.getRange(2, 5)].swizzle();
    } else {
      // argb8888 behaves like xrgb8888: alpha is ignored.
      r = word.getRange(16, 24);
      g = word.getRange(8, 16);
      b = word.getRange(0, 8);
    }

    if (so != null) {
      if (unpack == null) {
        for (var s = 2; s < last; s++) {
          deLast = delay(deLast, 'de_s$s');
        }
      }
      (r, g, b) = _overlay(
        pixelClk: pixelClk,
        pixelReset: pixelReset,
        frameStart: frameStart,
        target: target,
        scanout: scanout,
        formats: ovFormats!,
        tx: tx,
        ty: ty,
        xw: xw,
        yw: yw,
        col: ovCol,
        alpha: ovAlpha!,
        primary: [r, g, b],
        primaryStage: hasYuv ? HarborPixelUnpack.latency + HarborCsc.stages : 1,
        cscCoeff: overlayCscCoeff,
        cscInOffset: overlayCscInOffset,
        cscOutOffset: overlayCscOutOffset,
      );
    }
    final zero = Const(0, width: 8);

    // The last stage registers every parallel output.
    final de2 = delay(deLast, 'de_s$last');
    // On a parallelRgb pin the sync flops reset to the idle level of the
    // mode's polarity. The TMDS path keeps its reset at 0.
    Logic syncDelay(Logic v, String name, bool positive) =>
        parallelRgb && !positive
        ? flop(pixelClk, v, reset: pixelReset, resetValue: 1).named(name)
        : delay(v, name);
    final hp = timing.hSyncPositive, vp = timing.vSyncPositive;
    Logic chain(Logic v, String name, Logic Function(Logic, String) step) {
      for (var s = 1; s <= last; s++) {
        v = step(v, '${name}_s$s');
      }
      return v;
    }

    final hsync2 = chain(
      timingGen.hsync,
      'hsync',
      (v, n) => syncDelay(v, n, hp),
    );
    final vsync2 = chain(
      timingGen.vsync,
      'vsync',
      (v, n) => syncDelay(v, n, vp),
    );
    final r2 = delay(mux(deLast, r, zero), 'red_s$last');
    final g2 = delay(mux(deLast, g, zero), 'green_s$last');
    final b2 = delay(mux(deLast, b, zero), 'blue_s$last');
    red <= r2;
    green <= g2;
    blue <= b2;
    de <= de2;
    hsync <= hsync2;
    vsync <= vsync2;
    x <= chain(tx, 'x', delay);
    y <= chain(ty, 'y', delay);
    var wordLast = word;
    for (var s = 2; s <= last; s++) {
      wordLast = delay(wordLast, 'pixel_word_s$s');
    }
    pixelWord <= wordLast;

    if (parallelRgb) {
      // No TMDS encoder or serializer, and no shift clock: rgb/hsync/vsync/de
      // are already the registered, pixel-aligned values of the last stage
      // above, and pclk is the pixel clock forwarded through the same edge.
      rgb <= [r2, g2, b2].swizzle();
      pclk <=
          HarborPixelClockForward(
            clk: pixelClk,
            target: target,
            latchEdge: parallelRgbLatchEdge,
          ).q;
    } else {
      final transmitter = DviTransmitter(
        target: target,
        pixelClk: pixelClk,
        shiftClk: shiftClk!, // 5x pixel clock from the SoC's display PLL
        pixelReset: pixelReset,
        shiftReset: shiftReset!,
        de: de2,
        hsync: hsync2,
        vsync: vsync2,
        red: r2,
        green: g2,
        blue: b2,
      );
      gpdi <= transmitter.gpdi;
      if (tmdsComplement) {
        gpdiN <= transmitter.gpdiN;
      }
    }
  }

  /// A color conversion with its settings latched at [frameStart]. The
  /// inputs are `<prefix>_coeff_<k>`, `<prefix>_in_offset_<j>` and
  /// `<prefix>_out_offset_<i>`, tied to BT.709 limited when not given.
  HarborCsc _conversion({
    required String prefix,
    required Logic clk,
    required Logic reset,
    required Logic frameStart,
    required HarborDeviceTarget target,
    required HarborPixelUnpack unpack,
    required List<Logic>? coeff,
    required List<Logic>? inOffset,
    required List<Logic>? outOffset,
    String name = 'csc',
  }) {
    final values = HarborCscCoefficients.bt709Limited.registers();
    Logic setting(String name, Logic? v, int width, int resetValue) {
      final port = addInput(
        name,
        v ?? Const(resetValue, width: width),
        width: width,
      );
      return flop(
        clk,
        port,
        en: frameStart,
        reset: reset,
        resetValue: resetValue,
      ).named('${name}_frame');
    }

    return HarborCsc(
      clk: clk,
      target: target,
      y: unpack.y,
      cb: unpack.cb,
      cr: unpack.cr,
      coeff: [
        for (var k = 0; k < 9; k++)
          setting('${prefix}_coeff_$k', coeff?[k], 16, values[k]),
      ],
      inOffset: [
        for (var j = 0; j < 3; j++)
          setting('${prefix}_in_offset_$j', inOffset?[j], 10, values[9 + j]),
      ],
      outOffset: [
        for (var i = 0; i < 3; i++)
          setting('${prefix}_out_offset_$i', outOffset?[i], 8, values[12 + i]),
      ],
      name: name,
    );
  }

  /// The overlay pixel path: column math, unpack, conversion and blend
  /// with the [primary] R, G and B of stage [primaryStage]. It gives R, G
  /// and B at stage `pipelineDelay - 1`.
  (Logic, Logic, Logic) _overlay({
    required Logic pixelClk,
    required Logic pixelReset,
    required Logic frameStart,
    required HarborDeviceTarget target,
    required HarborDualClockScanout scanout,
    required List<HarborPixelFormat> formats,
    required Logic tx,
    required Logic ty,
    required int xw,
    required int yw,
    required List<Logic> col,
    required Logic alpha,
    required List<Logic> primary,
    required int primaryStage,
    required List<Logic>? cscCoeff,
    required List<Logic>? cscInOffset,
    required List<Logic>? cscOutOffset,
  }) {
    Logic delay(Logic v, String name) =>
        flop(pixelClk, v, reset: pixelReset).named(name);
    Logic reg(Logic v, String name) =>
        flop(pixelClk, v, reset: pixelReset).named(name);
    final fmt = formats.length > 1 ? scanout.overlayFormat : null;
    Logic pick(Logic Function(HarborPixelFormat) v) {
      var out = v(formats.last);
      for (var i = formats.length - 2; i >= 0; i--) {
        out = mux(fmt!.eq(i), v(formats[i]), out);
      }
      return out;
    }

    final srcX = scanout.overlaySrcX;
    final dstX = scanout.overlayDstX;
    final ew = xw + 2;
    // Values of the frame. Source pixel sx = x + (src_x - dst_x), and the
    // word of sx in plane j is (x + rem_j + ahead_j - dst_x) >> shift_j,
    // with rem_j the bits of src_x below the shift.
    final xOffset = reg(
      srcX.zeroExtend(ew) - dstX.zeroExtend(ew),
      'overlay_x_offset',
    );
    final lastX = reg(
      srcX.zeroExtend(xw + 1) + scanout.overlayWidth.zeroExtend(xw + 1) - 1,
      'overlay_last_x',
    );
    final x = tx.zeroExtend(ew);
    final sx = (x + xOffset).getRange(0, xw + 1).named('overlay_sx');
    for (var j = 0; j < col.length; j++) {
      final offset = reg(
        pick((f) {
              if (j >= f.planes.length) return Const(0, width: ew);
              final sh = HarborScanoutOverlay.wordShift(f, j);
              final ahead = HarborScanoutOverlay.lookahead(f, j) ? 1 : 0;
              final rem = sh == 0
                  ? Const(0, width: ew)
                  : srcX.getRange(0, sh).zeroExtend(ew);
              return rem + ahead;
            }) -
            dstX.zeroExtend(ew),
        'overlay${j}_col_offset',
      );
      final at = (x + offset).named('overlay${j}_col_sum');
      col[j] <=
          pick((f) {
            if (j >= f.planes.length) return Const(0, width: ew);
            return at >>> HarborScanoutOverlay.wordShift(f, j);
          });
    }

    // Inside the overlay: alpha, else 0, which gives the primary.
    final relX = tx.zeroExtend(xw + 1) - dstX.zeroExtend(xw + 1);
    final relY = ty.zeroExtend(yw + 1) - scanout.overlayDstY.zeroExtend(yw + 1);
    final inside =
        scanout.overlayOn &
        relX.lt(scanout.overlayWidth.zeroExtend(xw + 1)) &
        relY.lt(scanout.overlayHeight.zeroExtend(yw + 1));
    var a = mux(inside, alpha, Const(0, width: 8)).named('overlay_alpha_s0');

    final unpack = HarborPixelUnpack(
      clk: pixelClk,
      reset: pixelReset,
      x: sx,
      format: fmt,
      planeData: [for (var j = 0; j < col.length; j++) scanout.overlayData(j)],
      formats: formats,
      hActive: timing.hActive,
      lastX: lastX,
      name: 'overlay_unpack',
    );
    overlayUnpack = unpack;
    final yuvSet = formats.any((f) => f.yuv);
    final rgbSet = formats.any((f) => !f.yuv);
    const s0 = HarborPixelUnpack.latency;
    final ovStage = yuvSet ? s0 + HarborCsc.stages : s0;
    final stage = max(ovStage, primaryStage);
    Logic match(Logic v, int from, String name) {
      for (var s = from + 1; s <= stage; s++) {
        v = delay(v, '${name}_s$s');
      }
      return v;
    }

    List<Logic> ov;
    if (yuvSet) {
      final csc = _conversion(
        prefix: 'overlay_csc',
        clk: pixelClk,
        reset: pixelReset,
        frameStart: frameStart,
        target: target,
        unpack: unpack,
        coeff: cscCoeff,
        inOffset: cscInOffset,
        outOffset: cscOutOffset,
        name: 'overlay_csc',
      );
      overlayCsc = csc;
      ov = [csc.red, csc.green, csc.blue];
      if (rgbSet) {
        // An RGB frame skips the conversion, with the same delay.
        Logic skip(Logic v, String name) {
          for (var s = s0 + 1; s <= ovStage; s++) {
            v = delay(v, '${name}_s$s');
          }
          return v;
        }

        final isYuv = skip(unpack.yuv, 'overlay_yuv');
        ov = [
          mux(isYuv, csc.red, skip(unpack.red, 'overlay_rgb_red')),
          mux(isYuv, csc.green, skip(unpack.green, 'overlay_rgb_green')),
          mux(isYuv, csc.blue, skip(unpack.blue, 'overlay_rgb_blue')),
        ];
      }
    } else {
      ov = [unpack.red, unpack.green, unpack.blue];
    }
    const names = ['red', 'green', 'blue'];
    a = match(a, 0, 'overlay_alpha');
    // Alpha 0 takes no overlay data, so a line that was not fetched does
    // not reach the blend.
    final use = a.neq(0).named('overlay_use');
    final blend = HarborAlphaBlend(
      clk: pixelClk,
      overlay: [
        for (var i = 0; i < 3; i++)
          mux(
            use,
            match(ov[i], ovStage, 'overlay_${names[i]}'),
            Const(0, width: 8),
          ),
      ],
      primary: [
        for (var i = 0; i < 3; i++)
          match(primary[i], primaryStage, 'primary_${names[i]}'),
      ],
      alpha: a,
      target: target,
    );
    this.blend = blend;
    return (blend.red, blend.green, blend.blue);
  }

  /// Pixel cycles from the timing generator to the outputs.
  static int _delay(
    List<HarborPixelFormat> formats,
    List<HarborPixelFormat>? overlay,
  ) {
    const unpacked = HarborPixelUnpack.latency;
    const converted = unpacked + HarborCsc.stages;
    final primary = formats.any((f) => f.yuv) ? converted : 1;
    if (overlay == null) return primary + 1;
    final ov = overlay.any((f) => f.yuv) ? converted : unpacked;
    return max(primary, ov) + HarborAlphaBlend.latency + 1;
  }

  /// [name] with the overlay parameters, or [name] without an overlay.
  static String _overlayName(
    String name,
    HarborDisplayTiming t,
    List<HarborPixelFormat>? overlay,
    HarborDeviceTarget target,
  ) => overlay == null
      ? name
      : harborStableDefinitionName('HarborDualClockDisplayOverlay', [
          name,
          'o${overlay.map(harborPixelFormatBitOrder.indexOf).join('x')}',
          't${t.hActive}_${t.hFrontPorch}_${t.hSyncWidth}_${t.hBackPorch}'
              '_${t.vActive}_${t.vFrontPorch}_${t.vSyncWidth}_${t.vBackPorch}'
              '_${t.hSyncPositive ? 1 : 0}${t.vSyncPositive ? 1 : 0}',
          target is HarborFpgaTarget ? target.vendor.name : 'generic',
        ]);

  /// The largest plane 0 line in bytes over [formats].
  static int _lineBytes(HarborDisplayTiming t, List<HarborPixelFormat> fs) =>
      fs.map((f) => f.lineBytes(0, t.hActive)).reduce(max);

  /// The right shift from a pixel x to its word in [plane] of [f].
  static int _wordShift(HarborPixelFormat f, int plane) {
    final p = f.planes[plane];
    return p.pixelsPerGroup.bitLength - 1 + 2 - (p.bytesPerGroup.bitLength - 1);
  }

  static String _name({
    required HarborDisplayTiming timing,
    required List<HarborPixelFormat> formats,
    required int stride,
    required bool port,
    required HarborDeviceTarget target,
    required HarborMemoryWaist? memory,
    required int burstWords,
  }) {
    final lineBytes = _lineBytes(timing, formats);
    final mem = [
      if (memory != null) ...[
        'b$burstWords',
        'i${memory.config.idWidth}',
        'n${memory.config.outstanding}',
      ],
    ];
    if (HarborDualClockScanout.isPlanar(formats)) {
      final t = timing;
      return harborStableDefinitionName(
        port
            ? 'HarborDualClockDisplayPlanesPort'
            : 'HarborDualClockDisplayPlanes',
        [
          'f${formats.map(harborPixelFormatBitOrder.indexOf).join('x')}',
          't${t.hActive}_${t.hFrontPorch}_${t.hSyncWidth}_${t.hBackPorch}'
              '_${t.vActive}_${t.vFrontPorch}_${t.vSyncWidth}_${t.vBackPorch}'
              '_${t.hSyncPositive ? 1 : 0}${t.vSyncPositive ? 1 : 0}',
          'ram${target.blockRam?.name ?? "flop"}',
          ...mem,
        ],
      );
    }
    // A one plane YUV format reads words like rgb565, so its name has the
    // format to keep the two apart.
    final yuv = formats.single.yuv ? '_${formats.single.name}' : '';
    return (port
            ? 'HarborDualClockDisplayPort_s${stride}_w${lineBytes ~/ 4}'
            : harborStableDefinitionName('HarborDualClockDisplay', [
                's$stride',
                'w${lineBytes ~/ 4}',
                'ram${target.blockRam?.name ?? "flop"}',
                ...mem,
              ])) +
        yuv;
  }
}

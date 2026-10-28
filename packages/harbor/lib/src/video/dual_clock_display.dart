import 'dart:math';

import 'package:rohd/rohd.dart';

import '../arith/fpu_config.dart';
import '../bus/port/memory_waist.dart';
import '../clock/cdc.dart';
import '../soc/target.dart';
import 'tmds_serializer.dart';

import '../peripherals/display.dart';
import 'alpha_blend.dart';
import 'csc.dart';
import 'display_output.dart';
import 'dual_clock_scanout.dart';
import 'dvi_transmitter.dart';
import 'hdmi_framer.dart';
import 'hdmi_packets.dart';
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
/// The control inputs are `enable`, `fb_base`, `format_sel`,
/// `plane_base_<n>`, `plane_pitch_<n>`, `csc_*` and all `overlay_*`
/// inputs. They are in the control domain, `control_clk` and
/// `control_reset`, which are [sysClk] and [sysReset] when not given. A
/// pulse of one clock on [update] copies all of them into a shadow set.
/// The pixel side takes the full set at the next frame start of the timing
/// generator, also with the display off, so all planes, both color
/// conversions, the overlay and `enable` change on the same frame. A
/// change of an input without [update] changes nothing. [updatePending] is
/// high from the clock after the pulse until the control side sees that
/// the pixel side took the set. An [update] while [updatePending] is high
/// waits, and the display copies the inputs again when it took the set
/// before. The set crosses as data that does not change for at least two
/// pixel clocks before the take, and each path goes from one control flop
/// to one pixel flop. openXC7 nextpnr has no false path or clock group
/// constraint, so it times these paths as related clocks.
///
/// [update] can be tied high. Then the display copies the inputs each time
/// the pixel side took the set before, and a change shows after 1 to 2
/// frames.
///
/// A reset of the control or of the pixel domain resets the handshake of
/// both sides. After a control reset, the display copies the live inputs.
/// After a pixel reset alone, it sends the last shadow set again, so a
/// change of an input without [update] still changes nothing. The pixel
/// side takes the set at the next frame start, and [updatePending] is high
/// from the reset until that take. Until then, a pixel reset sets the
/// pixel side values to 0, and the `csc_*` and `overlay_csc_*` values to
/// [HarborCscCoefficients.bt709Limited]. A control reset does not reset
/// the pixel side. The shadow set has no reset.
///
/// A reset of one clock is sufficient. The control side stays in reset
/// until the pixel side was in reset and left it, so it copies no input
/// while the pixel side can take the set from before the reset. After a
/// pixel reset alone, [updatePending] goes high up to three control clocks
/// late. It stays high while the pixel clock is stopped or in reset, so a
/// wait for it to clear needs a limit.
///
/// The status outputs `underrun`, `plane_underrun`, `overlay_underrun`,
/// `plane_underrun_count_<n>` and `overlay_underrun_count_<n>` are in the
/// control domain. A count crosses as gray code when `control_clk` is not
/// [sysClk]. Then a control reset alone sets a count to 0 for about two
/// control clocks, until the count from [sysClk] arrives again.
///
/// A pitch input is in bytes. The display ignores its low 2 bits, so a
/// pitch is a multiple of 4. It must be at least
/// [HarborPixelFormat.lineBytes] of its plane. On a [HarborSdram] scanout
/// port, start each plane at an sdram row and use a pitch from
/// [HarborSdram.scanoutStride], so each line starts on a new row.
///
/// The constant outputs tell the build: `plane_count` (4 bits) is
/// [planeCount], `plane_formats_0` and, with an overlay, `plane_formats_1`
/// are [planeFormats], and `overlay_present` is [overlayPresent].
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
/// each plane after plane 0. Plane 0 starts at [fbBase]. A scanout port
/// ignores the low 2 bits of each base. A planar build has no
/// [lineStride] input. It has a
/// [planeUnderrun] output with one bit for each plane and a
/// `plane_underrun_count_<n>` output for each plane, see
/// [HarborDualClockScanout.planeUnderrunCount].
///
/// A build with a YUV format unpacks the plane words with [unpack] and
/// converts a YUV frame to RGB with [csc]. It has the inputs
/// `csc_coeff_0` to `csc_coeff_8`, `csc_in_offset_0` to `_2` and
/// `csc_out_offset_0` to `_2`, see [HarborCscCoefficients]. An input that
/// is not given is tied to [HarborCscCoefficients.bt709Limited]. An RGB
/// frame does not go through [csc].
///
/// [overlayFormats] adds an overlay plane, see [HarborDualClockScanout].
/// Without it the build has no overlay logic or ports. The overlay inputs:
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
///
/// [hdmi] adds an [HdmiFramer] to a TMDS build. It has the
/// `hdmi_enable` input (control domain). It is not in the update shadow
/// set. It crosses through two flops and applies at the next vertical
/// blank. The `hdmi_active` output (control domain) is the applied value.
/// With [hdmiPacketValid], the build has the packet inputs
/// `hdmi_packet_valid`, `hdmi_packet_header` and `hdmi_packet_subpacket_0`
/// to `_3` and the `hdmi_packet_ready` output (pixel domain), see
/// [HdmiFramer]. `hdmi_packet_ready` follows `hdmi_packet_valid`
/// combinationally, so a source must not make valid depend on ready. The
/// `hdmi_packets_dropped` output (control domain, binary) counts the
/// packets accepted while HDMI is not active. It stops at 0xffff. With
/// `hdmi_enable` at 0 the lanes are the same as a build without [hdmi].
/// The TMDS latency does not change.
///
/// With [audioValid] in place of the packet inputs, an [HdmiPacketScheduler]
/// sends the packets: ACR, 2-channel L-PCM audio samples, the AVI InfoFrame
/// and the Audio InfoFrame. The inputs are in the control domain:
/// - `hdmi_vic` (7 bits), in the update shadow set. 0 when not known.
/// - `audio_fs_sel`: 0 is 32 kHz, 1 is 44.1 kHz, 2 and 3 are 48 kHz. It
///   crosses through two flops.
/// - `audio_valid`, `audio_left`, `audio_right` (24 bits each) and the
///   output `audio_ready`: a stereo sample stream into a FIFO of
///   [audioFifoDepth] samples. The sample strobe on the pixel clock takes
///   one sample out.
///
/// N and CTS come from [HdmiAcr] for the pixel clock of [timing], so it
/// must be the real pixel clock. The AVI InfoFrame says limited range RGB
/// when the frame is YUV and an applied `csc_out_offset` value is not 0,
/// else full range. The status outputs (control domain, binary, stop at
/// 0xffff) are `audio_underrun_count` (strobes with an empty FIFO, each
/// sends a zero sample), `hdmi_packets_missed` (clocks where a packet
/// source missed its slot) and `hdmi_packets_dropped`.
class HarborDualClockDisplay extends Module {
  /// Stereo samples in the audio FIFO of an hdmi audio build.
  static const audioFifoDepth = 32;

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

  /// The TMDS transmitter, null for parallelRgb.
  DviTransmitter? transmitter;

  /// The HDMI framer, null without [hdmi].
  HdmiFramer? framer;

  /// HDMI periods on the TMDS lanes, see [HdmiFramer].
  final bool hdmi;

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

  /// The value of the `plane_count` output: the most primary planes of a
  /// format in [formats], plus 1 for an overlay.
  final int planeCount;

  /// The values of the `plane_formats_<n>` outputs: [formatMask] of
  /// [formats], then of [overlayFormats] if there is an overlay.
  final List<int> planeFormats;

  /// The value of the `overlay_present` output.
  bool get overlayPresent => overlayFormats != null;

  /// High from the clock after an `update` pulse until the control side
  /// sees that the pixel side took the set (control domain). It is also
  /// high after a reset until the first take.
  Logic get updatePending => output('update_pending');

  /// One bit for each format in [formats], at its index in
  /// [harborPixelFormatBitOrder].
  static int formatMask(List<HarborPixelFormat> formats) => formats.fold(
    0,
    (m, f) => m | (1 << harborPixelFormatBitOrder.indexOf(f)),
  );

  HarborDualClockDisplay({
    required this.timing,
    required Logic pixelClk,
    required Logic pixelReset,
    Logic? shiftClk,
    Logic? shiftReset,
    required Logic sysClk,
    required Logic sysReset,
    Logic? controlClk,
    Logic? controlReset,
    required Logic enable,
    required Logic update,
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
    this.hdmi = false,
    Logic? hdmiEnable,
    Logic? hdmiPacketValid,
    Logic? hdmiPacketHeader,
    List<Logic>? hdmiPacketSubpacket,
    Logic? hdmiVic,
    Logic? audioFsSel,
    Logic? audioValid,
    Logic? audioLeft,
    Logic? audioRight,
    required HarborDeviceTarget target,
    super.name = 'dual_clock_display',
  }) : formats = List.unmodifiable(formats ?? [pixelFormat]),
       pixelFormat = (formats ?? [pixelFormat]).first,
       pipelineDelay = _delay(formats ?? [pixelFormat], overlayFormats),
       overlayFormats = overlayFormats == null
           ? null
           : List.unmodifiable(overlayFormats),
       lineStride = lineStride ?? _lineBytes(timing, formats ?? [pixelFormat]),
       planeCount =
           (HarborDualClockScanout.isPlanar(formats ?? [pixelFormat])
               ? (formats ?? [pixelFormat])
                     .map((f) => f.planes.length)
                     .reduce(max)
               : 1) +
           (overlayFormats == null ? 0 : 1),
       planeFormats = [
         formatMask(formats ?? [pixelFormat]),
         if (overlayFormats != null) formatMask(overlayFormats),
       ],
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
                 : '') +
             (hdmi
                 ? (audioValid != null
                       ? '_hdmi_audio_p${timing.pixelClock}'
                       : hdmiPacketValid == null
                       ? '_hdmi'
                       : '_hdmi_pkt')
                 : ''),
       ) {
    requireDisplayOutputSupported(outputType);
    if (hdmi) {
      if (outputType == HarborDisplayInterface.parallelRgb) {
        throw ArgumentError('hdmi needs a TMDS output');
      }
      if (hdmiEnable == null) {
        throw ArgumentError('an hdmi build needs hdmiEnable');
      }
      if ((hdmiPacketValid == null) != (hdmiPacketHeader == null) ||
          (hdmiPacketValid == null) != (hdmiPacketSubpacket == null)) {
        throw ArgumentError(
          'give hdmiPacketValid, hdmiPacketHeader and hdmiPacketSubpacket '
          'together',
        );
      }
      final audioIn = [hdmiVic, audioFsSel, audioValid, audioLeft, audioRight];
      if (audioIn.any((v) => v == null) && audioIn.any((v) => v != null)) {
        throw ArgumentError(
          'give hdmiVic, audioFsSel, audioValid, audioLeft and audioRight '
          'together',
        );
      }
      if (audioValid != null && hdmiPacketValid != null) {
        throw ArgumentError('an audio build has no packet inputs');
      }
    } else if (hdmiEnable != null ||
        hdmiPacketValid != null ||
        audioValid != null) {
      throw ArgumentError('give hdmi: true for the hdmi inputs');
    }
    if (timing.hTotal < 2 || timing.vActive < 1) {
      throw ArgumentError('the timing needs hTotal 2 or more and vActive 1');
    }
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
    if ((controlClk == null) != (controlReset == null)) {
      throw ArgumentError('give controlClk and controlReset together');
    }
    final ownControl = controlClk != null;
    final ctrlClk = ownControl ? addInput('control_clk', controlClk) : sysClk;
    final ctrlReset = ownControl
        ? addInput('control_reset', controlReset!)
        : sysReset;
    update = addInput('update', update);
    addOutput('update_pending');
    final shadow = _ShadowSet();
    enable = shadow.add(addInput('enable', enable), early: true);
    fbBase = shadow.add(addInput('fb_base', fbBase, width: 32), early: true);
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
        formatSel = shadow.add(
          addInput(
            'format_sel',
            formatSel,
            width: (this.formats.length - 1).bitLength,
          ),
          early: true,
        );
      }
      planeBase = [
        for (var k = 1; k < planes; k++)
          shadow.add(
            addInput('plane_base_$k', planeBase[k - 1], width: 32),
            early: true,
          ),
      ];
      planePitch = [
        for (var k = 0; k < planes; k++)
          shadow.add(
            addInput('plane_pitch_$k', planePitch[k], width: 32),
            word: true,
            early: true,
          ),
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

    // A sticky flag goes to the control domain through two flops for each
    // bit.
    Logic status(Logic v, String name) {
      for (var i = 0; i < 2; i++) {
        v = flop(ctrlClk, v, reset: ctrlReset).named('${name}_underrun_sync$i');
      }
      return v;
    }

    // A count goes to the control domain as gray code.
    Logic count(Logic v, String name) => ownControl
        ? _grayCross(
            v,
            srcClk: sysClk,
            srcReset: sysReset,
            dstClk: ctrlClk,
            dstReset: ctrlReset,
            name: name,
          )
        : v;

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
      Logic inX(String n, Logic v, {bool early = false}) =>
          shadow.add(addInput(n, v, width: xw), early: early);
      Logic inY(String n, Logic v, {bool early = false}) =>
          shadow.add(addInput(n, v, width: yw), early: early);
      so = HarborScanoutOverlay(
        formats: ovFormats,
        enable: shadow.add(addInput('overlay_enable', overlayEnable!)),
        formatSel: overlayFormatSel == null
            ? null
            : shadow.add(
                addInput(
                  'overlay_format_sel',
                  overlayFormatSel,
                  width: (ovFormats.length - 1).bitLength,
                ),
                early: true,
              ),
        base: [
          for (var j = 0; j < ovPlanes; j++)
            shadow.add(addInput('overlay_base_$j', overlayBase[j], width: 32)),
        ],
        pitch: [
          for (var j = 0; j < ovPlanes; j++)
            shadow.add(
              addInput('overlay_pitch_$j', overlayPitch[j], width: 32),
              word: true,
            ),
        ],
        srcX: inX('overlay_src_x', overlaySrcX!, early: true),
        srcY: inY('overlay_src_y', overlaySrcY!, early: true),
        dstX: inX('overlay_dst_x', overlayDstX!),
        dstY: inY('overlay_dst_y', overlayDstY!, early: true),
        width: inX('overlay_width', overlayWidth!),
        height: inY('overlay_height', overlayHeight!),
        col: ovCol,
      );
      ovAlpha = flop(
        pixelClk,
        shadow.add(addInput('overlay_alpha', overlayAlpha!, width: 8)),
        en: shadow.load,
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
        frameLoad: shadow.load,
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
      addOutput('plane_underrun') <= status(scanout.planeUnderrun, 'plane');
      addOutput('plane_underrun_count_0', width: 16) <=
          count(scanout.planeUnderrunCount(0), 'plane_underrun_count_0');
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
        frameLoad: shadow.load,
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
      addOutput('plane_underrun', width: planes) <=
          status(scanout.planeUnderrun, 'plane');
      for (var k = 0; k < planes; k++) {
        addOutput('plane_underrun_count_$k', width: 16) <=
            count(scanout.planeUnderrunCount(k), 'plane_underrun_count_$k');
      }
    }

    if (so != null) {
      addOutput('overlay_underrun', width: ovPlanes) <=
          status(scanout.overlayUnderrun, 'overlay');
      for (var j = 0; j < ovPlanes; j++) {
        addOutput('overlay_underrun_count_$j', width: 16) <=
            count(scanout.overlayUnderrunCount(j), 'overlay_underrun_count_$j');
      }
    }
    if (scanout.scanoutPort) {
      addOutput('rq_valid') <= scanout.rqValid;
      addOutput('rq_addr', width: 32) <= scanout.rqAddr;
      addOutput('rq_words', width: scanout.rqWords.width) <= scanout.rqWords;
    }
    underrun <= status(scanout.underrun, 'all');
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
        target: target,
        unpack: unpack,
        shadow: shadow,
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
        shadow: shadow,
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

    final audio = hdmi && audioValid != null;
    final vic = audio
        ? shadow.add(addInput('hdmi_vic', hdmiVic!, width: 7), early: true)
        : null;

    // The take is in the clock before the frame start of the timing
    // generator, also with the display off.
    shadow.build(
      ctrlClk: ctrlClk,
      ctrlReset: ctrlReset,
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      update: update,
      take: delay(
        tx.eq(timing.hTotal - 2) & ty.eq(timing.vActive - 1),
        'pre_frame',
      ),
      pending: output('update_pending'),
    );

    addOutput('plane_count', width: 4) <= Const(planeCount, width: 4);
    for (final (n, m) in planeFormats.indexed) {
      addOutput('plane_formats_$n', width: harborPixelFormatBitOrder.length) <=
          Const(m, width: harborPixelFormatBitOrder.length);
    }
    addOutput('overlay_present') <= Const(overlayPresent ? 1 : 0);

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
      HdmiFramer? f;
      if (hdmi) {
        var on = addInput('hdmi_enable', hdmiEnable!);
        for (var i = 0; i < 2; i++) {
          on = flop(
            pixelClk,
            on,
            reset: pixelReset,
          ).named('hdmi_enable_sync$i');
        }
        Logic pv;
        Logic ph;
        List<Logic> ps;
        final ready = Logic();
        if (audio) {
          final sched = _audio(
            ctrlClk: ctrlClk,
            ctrlReset: ctrlReset,
            pixelClk: pixelClk,
            pixelReset: pixelReset,
            target: target,
            tx: tx,
            ty: ty,
            vic: vic!,
            formatSel: formatSel,
            fsSel: audioFsSel!,
            valid: audioValid,
            left: audioLeft!,
            right: audioRight!,
            ready: ready,
          );
          pv = sched.packetValid;
          ph = sched.packetHeader;
          ps = [for (var k = 0; k < 4; k++) sched.packetSubpacket(k)];
        } else {
          pv = hdmiPacketValid == null
              ? Const(0)
              : addInput('hdmi_packet_valid', hdmiPacketValid);
          ph = hdmiPacketHeader == null
              ? Const(0, width: 24)
              : addInput('hdmi_packet_header', hdmiPacketHeader, width: 24);
          ps = [
            for (var k = 0; k < 4; k++)
              hdmiPacketSubpacket == null
                  ? Const(0, width: 56)
                  : addInput(
                      'hdmi_packet_subpacket_$k',
                      hdmiPacketSubpacket[k],
                      width: 56,
                    ),
          ];
        }
        f = HdmiFramer(
          timing: timing,
          clk: pixelClk,
          reset: pixelReset,
          hdmiEnable: on,
          videoEnable: enable,
          de: de2,
          hsync: hsync2,
          vsync: vsync2,
          x: x,
          y: y,
          packetValid: pv,
          packetHeader: ph,
          packetSubpacket: ps,
        );
        var act = f.active;
        for (var i = 0; i < 2; i++) {
          act = flop(
            ctrlClk,
            act,
            reset: ctrlReset,
          ).named('hdmi_active_sync$i');
        }
        addOutput('hdmi_active') <= act;
        ready <= f.packetReady;
        if (hdmiPacketValid != null || audio) {
          if (!audio) addOutput('hdmi_packet_ready') <= ready;
          final dropped = Logic(name: 'hdmi_dropped', width: 16);
          final drop = pv & ~f.active;
          dropped <=
              flop(
                pixelClk,
                mux(dropped.eq(0xffff), dropped, dropped + 1),
                en: drop,
                reset: pixelReset,
              );
          addOutput('hdmi_packets_dropped', width: 16) <=
              _grayCross(
                dropped,
                srcClk: pixelClk,
                srcReset: pixelReset,
                dstClk: ctrlClk,
                dstReset: ctrlReset,
                name: 'hdmi_dropped',
              );
        }
        framer = f;
      }
      final t = DviTransmitter(
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
        hdmiMode: f?.mode,
        hdmiAux: f?.aux,
        hdmiCtl: f?.ctl,
      );
      transmitter = t;
      gpdi <= t.gpdi;
      if (tmdsComplement) {
        gpdiN <= t.gpdiN;
      }
    }
  }

  /// The audio path of an hdmi audio build: the sample FIFO from the
  /// control domain, the [HdmiPacketScheduler] and its status outputs.
  HdmiPacketScheduler _audio({
    required Logic ctrlClk,
    required Logic ctrlReset,
    required Logic pixelClk,
    required Logic pixelReset,
    required HarborDeviceTarget target,
    required Logic tx,
    required Logic ty,
    required Logic vic,
    required Logic? formatSel,
    required Logic fsSel,
    required Logic valid,
    required Logic left,
    required Logic right,
    required Logic ready,
  }) {
    var sel = addInput('audio_fs_sel', fsSel, width: 2);
    for (var i = 0; i < 2; i++) {
      sel = flop(pixelClk, sel, reset: pixelReset).named('audio_fs_sel_sync$i');
    }
    // Each side of the FIFO resets when either side resets.
    final fifo = HarborCdcFifo(
      dataWidth: 48,
      depth: audioFifoDepth,
      target: target,
      blockRam: true,
      name: 'audio_fifo',
    );
    fifo.input('wr_clk').srcConnection! <= ctrlClk;
    fifo.input('wr_reset').srcConnection! <=
        harborCdcJoinReset(ctrlClk, ctrlReset, pixelReset, name: 'audio_wr');
    fifo.input('wr_en').srcConnection! <= addInput('audio_valid', valid);
    fifo.input('wr_data').srcConnection! <=
        [
          addInput('audio_right', right, width: 24),
          addInput('audio_left', left, width: 24),
        ].swizzle();
    fifo.input('rd_clk').srcConnection! <= pixelClk;
    fifo.input('rd_reset').srcConnection! <=
        harborCdcJoinReset(pixelClk, pixelReset, ctrlReset, name: 'audio_rd');
    addOutput('audio_ready') <= ~fifo.output('wr_full');

    // The CSC sends limited range RGB when it adds an output offset. An
    // RGB frame does not go through the CSC and is full range.
    Logic limited = Const(0);
    final c = _csc;
    if (c != null) {
      final offset = [
        for (var i = 0; i < 3; i++) c.input('out_offset_$i').srcConnection!,
      ];
      final yuv = formats.length == 1
          ? Const(1)
          : [
              for (final (i, f) in formats.indexed)
                if (f.yuv) formatSel!.eq(i),
            ].reduce((a, b) => a | b);
      limited = (yuv & offset.map((o) => o.or()).reduce((a, b) => a | b)).named(
        'hdmi_limited',
      );
    }

    final rdData = fifo.output('rd_data');
    final sched = HdmiPacketScheduler(
      clk: pixelClk,
      reset: pixelReset,
      frame: flop(
        pixelClk,
        tx.eq(4) & ty.eq(timing.vActive),
        reset: pixelReset,
      ).named('hdmi_frame'),
      vic: vic,
      limited: limited,
      fsSel: sel,
      sampleValid: ~fifo.output('rd_empty'),
      sampleLeft: rdData.getRange(0, 24),
      sampleRight: rdData.getRange(24, 48),
      packetReady: ready,
      pixelClock: timing.pixelClock,
    );
    fifo.input('rd_en').srcConnection! <= sched.samplePop;

    Logic count(Logic event, String name) {
      final n = Logic(name: name, width: 16);
      n <=
          flop(
            pixelClk,
            mux(n.eq(0xffff), n, n + 1),
            en: event,
            reset: pixelReset,
          );
      return _grayCross(
        n,
        srcClk: pixelClk,
        srcReset: pixelReset,
        dstClk: ctrlClk,
        dstReset: ctrlReset,
        name: name,
      );
    }

    addOutput('audio_underrun_count', width: 16) <=
        count(sched.underrun, 'audio_underrun');
    addOutput('hdmi_packets_missed', width: 16) <=
        count(sched.missed, 'hdmi_missed');
    return sched;
  }

  /// A color conversion with its settings latched at the take. The
  /// inputs are `<prefix>_coeff_<k>`, `<prefix>_in_offset_<j>` and
  /// `<prefix>_out_offset_<i>`, tied to BT.709 limited when not given.
  HarborCsc _conversion({
    required String prefix,
    required Logic clk,
    required Logic reset,
    required HarborDeviceTarget target,
    required HarborPixelUnpack unpack,
    required _ShadowSet shadow,
    required List<Logic>? coeff,
    required List<Logic>? inOffset,
    required List<Logic>? outOffset,
    String name = 'csc',
  }) {
    final values = HarborCscCoefficients.bt709Limited.registers();
    Logic setting(String name, Logic? v, int width, int resetValue) {
      final port = shadow.add(
        addInput(name, v ?? Const(resetValue, width: width), width: width),
        resetValue: resetValue,
      );
      return flop(
        clk,
        port,
        en: shadow.load,
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
    required _ShadowSet shadow,
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
        target: target,
        unpack: unpack,
        shadow: shadow,
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

  /// [bin] from the [srcClk] domain in the [dstClk] domain. [bin] must
  /// change by at most 1 in each clock of [srcClk].
  static Logic _grayCross(
    Logic bin, {
    required Logic srcClk,
    required Logic srcReset,
    required Logic dstClk,
    required Logic dstReset,
    required String name,
  }) {
    var g = flop(
      srcClk,
      bin ^ (bin >>> 1),
      reset: srcReset,
    ).named('${name}_gray');
    for (var i = 0; i < 2; i++) {
      g = flop(dstClk, g, reset: dstReset).named('${name}_gray_sync$i');
    }
    final bits = <Logic>[g[g.width - 1]];
    for (var i = g.width - 2; i >= 0; i--) {
      bits.add(bits.last ^ g[i]);
    }
    return bits.swizzle().named('${name}_sync');
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
          _timingName(t),
          target is HarborFpgaTarget ? target.vendor.name : 'generic',
        ]);

  static String _timingName(HarborDisplayTiming t) =>
      't${t.hActive}_${t.hFrontPorch}_${t.hSyncWidth}_${t.hBackPorch}'
      '_${t.vActive}_${t.vFrontPorch}_${t.vSyncWidth}_${t.vBackPorch}'
      '_${t.hSyncPositive ? 1 : 0}${t.vSyncPositive ? 1 : 0}';

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
          _timingName(t),
          'ram${target.blockRam?.name ?? "flop"}',
          ...mem,
        ],
      );
    }
    // A one plane YUV format reads words like rgb565, so its name has the
    // format to keep the two apart.
    final yuv = formats.single.yuv ? '_${formats.single.name}' : '';
    return harborStableDefinitionName(
          port ? 'HarborDualClockDisplayPort' : 'HarborDualClockDisplay',
          [
            's$stride',
            'w${lineBytes ~/ 4}',
            _timingName(timing),
            'ram${target.blockRam?.name ?? "flop"}',
            ...mem,
          ],
        ) +
        yuv;
  }
}

/// The control inputs that the control side copies at an `update` pulse
/// and that the pixel side takes at a frame start.
///
/// The copy is a shadow set on the control clock. A toggle tells the pixel
/// side that a new set is there, and the pixel side toggles an ack back
/// when it takes the set. The shadow set does not change from the copy
/// until the control side sees the ack, so it crosses as quasi-static
/// data. An `update` in that time waits, and the control side copies the
/// inputs when the ack comes.
///
/// An early field has a pixel copy that loads in the clock before the
/// frame start. A late field has no pixel copy here: the caller loads the
/// shadow value into its frame register when [load] is high, in the frame
/// start clock. The ack changes in that clock too. A field that goes
/// through logic before its frame register must be early, so that each
/// path from the control clock goes from one flop to one flop.
class _ShadowSet {
  final _fields = <(Logic, Logic, Logic?, int, int)>[];

  /// High in the clock where the late fields load.
  final load = Logic(name: 'update_load');

  /// Adds [input] to the set. It gives the pixel copy of an [early] field,
  /// else the shadow value. With [word], the set ignores the low 2 bits
  /// and gives them as 0.
  Logic add(
    Logic input, {
    int resetValue = 0,
    bool word = false,
    bool early = false,
  }) {
    final low = word ? 2 : 0;
    final name = input.name;
    final w = input.width - low;
    final shadow = Logic(name: '${name}_shadow', width: w);
    final applied = early ? Logic(name: '${name}_applied', width: w) : null;
    _fields.add((input, shadow, applied, resetValue >> low, low));
    final v = applied ?? shadow;
    return low == 0 ? v : [v, Const(0, width: low)].swizzle();
  }

  void build({
    required Logic ctrlClk,
    required Logic ctrlReset,
    required Logic pixelClk,
    required Logic pixelReset,
    required Logic update,
    required Logic take,
    required Logic pending,
  }) {
    // A reset of one side also resets the handshake of the other side.
    // Each side uses a copy of its join reset that changes only on its own
    // clock edges.
    final ctrlSync = harborCdcSyncReset(
      ctrlClk,
      ctrlReset,
      harborCdcJoinReset(
        ctrlClk,
        ctrlReset,
        pixelReset,
        name: 'update_ctrl_join',
      ),
      name: 'update_ctrl_sync',
    );
    final pixelSync = harborCdcSyncReset(
      pixelClk,
      pixelReset,
      harborCdcJoinReset(
        pixelClk,
        pixelReset,
        ctrlReset,
        name: 'update_pixel_join',
      ),
      name: 'update_pixel_sync',
    );
    // The control side then stays in reset until the pixel side was in
    // reset and left it.
    final req = Logic(name: 'update_reset_req');
    final reqSync0 = Logic(name: 'update_reset_req_sync0');
    final reqSync1 = Logic(name: 'update_reset_req_sync1');
    final doneSync0 = Logic(name: 'update_reset_done_sync0');
    final doneSync1 = Logic(name: 'update_reset_done_sync1');
    Sequential(
      ctrlClk,
      reset: ctrlSync,
      resetValues: {req: 1},
      [
        doneSync0 < reqSync1,
        doneSync1 < doneSync0,
        If(doneSync1, then: [req < Const(0)]),
      ],
    );
    Sequential(
      pixelClk,
      reset: pixelSync,
      resetValues: {reqSync0: 1, reqSync1: 1},
      [reqSync0 < req, reqSync1 < reqSync0],
    );
    final ctrlJoin = (ctrlSync | req | doneSync1).named('update_ctrl_reset');
    final pixelJoin = (pixelSync | reqSync1).named('update_pixel_reset');
    final toggle = Logic(name: 'update_toggle');
    final held = Logic(name: 'update_held');
    final resend = Logic(name: 'update_resend');
    final ack = Logic(name: 'update_ack');
    final aSync0 = Logic(name: 'update_ack_sync0');
    final aSync1 = Logic(name: 'update_ack_sync1');
    final uSync0 = Logic(name: 'update_sync0');
    final uSync1 = Logic(name: 'update_sync1');
    final takeLate = Logic(name: 'update_take_late');
    final inFlight = (toggle ^ aSync1).named('update_in_flight');
    final idle = (~ctrlJoin & ~inFlight).named('update_idle');
    final capture = (idle & (update | held)).named('update_capture');
    // After a reset of the handshake the toggle flips again, so the pixel
    // side takes the shadow set again. held resets to 1 on a control reset
    // only, so that reset copies the live inputs first.
    final send = (capture | (idle & resend)).named('update_send');
    Sequential(
      ctrlClk,
      reset: ctrlJoin,
      resetValues: {resend: 1},
      [
        aSync0 < ack,
        aSync1 < aSync0,
        If(send, then: [toggle < ~toggle, resend < Const(0)]),
      ],
    );
    Sequential(
      ctrlClk,
      reset: ctrlReset,
      resetValues: {held: 1},
      [
        If(
          capture,
          then: [held < Const(0)],
          orElse: [
            If(update, then: [held < Const(1)]),
          ],
        ),
      ],
    );
    // The shadow set has no reset. A reset that changed it could tear a
    // take that is in progress.
    Sequential(ctrlClk, [
      If(
        capture,
        then: [
          for (final (input, shadow, _, _, low) in _fields)
            shadow < input.getRange(low),
        ],
      ),
    ]);
    pending <= inFlight | held | resend;
    final takeNow = (take & (uSync1 ^ ack) & ~pixelJoin).named('update_take');
    // A take always gives its load, so the early and late fields do not
    // tear.
    load <= takeLate;
    Sequential(pixelClk, reset: pixelJoin, [
      uSync0 < toggle,
      uSync1 < uSync0,
      takeLate < takeNow,
      If(load, then: [ack < uSync1]),
    ]);
    final early = [
      for (final f in _fields)
        if (f.$3 != null) f,
    ];
    if (early.isEmpty) return;
    Sequential(
      pixelClk,
      reset: pixelReset,
      resetValues: {for (final f in early) f.$3!: f.$4},
      [
        If(
          takeNow,
          then: [
            for (final (_, shadow, applied, _, _) in early) applied! < shadow,
          ],
        ),
      ],
    );
  }
}

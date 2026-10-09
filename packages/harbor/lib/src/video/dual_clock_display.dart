import 'package:rohd/rohd.dart';

import '../soc/target.dart';
import 'tmds_serializer.dart';

import '../peripherals/display.dart';
import 'display_output.dart';
import 'dual_clock_scanout.dart';
import 'dvi_transmitter.dart';
import 'tmds_encoder.dart';
import 'video_timing.dart';

/// A framebuffer display that streams from shared main memory across clock
/// domains: pixel-domain timing + TMDS, system-domain framebuffer DMA.
///
/// The system-domain Wishbone master ([mStb] etc.) joins the SoC fabric
/// directly (no per-word CDC bridge). The clock crossing lives inside the
/// double line buffer. Emits parallel RGB+sync (for a VGA-style backend or
/// observation) and the four GPDI lanes. See [HarborFramebufferDisplay] for the
/// single-clock variant used by the test-pattern path.
///
/// The parallel outputs ([de], [hsync], [vsync], [red], [green], [blue], [x],
/// [y], [pixelWord]) are registered and aligned with each other. They come
/// [pipelineDelay] pixel cycles after the timing generator. The TMDS lanes add
/// the [TmdsEncoder.latency] of the encoders on top of that.
class HarborDualClockDisplay extends Module {
  /// Pixel cycles from the timing generator to the parallel outputs: one for
  /// the line buffer read and one for the output register.
  static const pipelineDelay = 2;

  Logic get gpdi => output('gpdi');

  /// The four complement lanes, present only on a target that drives its own
  /// ([TmdsSerializer.needsComplement]).
  Logic get gpdiN => output('gpdi_n');
  Logic get de => output('de');
  Logic get hsync => output('hsync');
  Logic get vsync => output('vsync');
  Logic get red => output('red');
  Logic get green => output('green');
  Logic get blue => output('blue');
  Logic get x => output('x');
  Logic get y => output('y');
  Logic get pixelWord => output('pixel_word');
  Logic get underrun => output('underrun');

  /// Wishbone master (system domain) for framebuffer reads.
  Logic get mStb => output('m_stb');
  Logic get mCyc => output('m_cyc');
  Logic get mWe => output('m_we');
  Logic get mAddr => output('m_adr');
  Logic get mSel => output('m_sel');
  Logic get mDataOut => output('m_dat_o');

  final HarborDisplayTiming timing;
  final HarborDisplayInterface outputType;

  /// Pixel format read from the framebuffer.
  final HarborPixelFormat pixelFormat;

  HarborDualClockDisplay({
    required this.timing,
    required Logic pixelClk,
    required Logic pixelReset,
    required Logic shiftClk,
    required Logic shiftReset,
    required Logic sysClk,
    required Logic sysReset,
    required Logic enable,
    required Logic fbBase,
    required Logic mDataIn,
    required Logic mAck,
    this.outputType = HarborDisplayInterface.hdmi,
    this.pixelFormat = HarborPixelFormat.xrgb8888,
    required HarborDeviceTarget target,
    super.name = 'dual_clock_display',
  }) : super(definitionName: 'HarborDualClockDisplay') {
    requireDisplayOutputSupported(outputType);
    if (pixelFormat == HarborPixelFormat.rgb888) {
      throw ArgumentError(
        'rgb888 does not fit the 32-bit scanout word layout.',
      );
    }
    if (pixelFormat == HarborPixelFormat.rgb565 && timing.hActive.isOdd) {
      throw ArgumentError(
        'rgb565 needs an even hActive (got ${timing.hActive}).',
      );
    }
    final rgb565 = pixelFormat == HarborPixelFormat.rgb565;

    pixelClk = addInput('pixel_clk', pixelClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    shiftClk = addInput('shift_clk', shiftClk);
    shiftReset = addInput('shift_reset', shiftReset);
    sysClk = addInput('sys_clk', sysClk);
    sysReset = addInput('sys_reset', sysReset);
    enable = addInput('enable', enable);
    fbBase = addInput('fb_base', fbBase, width: 32);
    mDataIn = addInput('m_dat_i', mDataIn, width: 32);
    mAck = addInput('m_ack', mAck);

    final hbits = (timing.hTotal - 1).bitLength;
    final vbits = (timing.vTotal - 1).bitLength;
    addOutput('gpdi', width: 4);
    final tmdsComplement = TmdsSerializer.needsComplement(target);
    if (tmdsComplement) {
      addOutput('gpdi_n', width: 4);
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
    addOutput('m_stb');
    addOutput('m_cyc');
    addOutput('m_we');
    addOutput('m_adr', width: 32);
    addOutput('m_sel', width: 4);
    addOutput('m_dat_o', width: 32);

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

    // rgb565 packs two pixels in each word. The word is tx >> 1 and the half
    // is tx bit 0.
    final wordsPerLine = rgb565 ? timing.hActive ~/ 2 : timing.hActive;
    final scanoutCol = rgb565 ? tx.getRange(1, tx.width) : tx;

    final scanout = HarborDualClockScanout(
      pixelClk: pixelClk,
      pixelReset: pixelReset,
      sysClk: sysClk,
      sysReset: sysReset,
      frameStart: frameStart,
      lineStart: lineStart,
      col: scanoutCol,
      fbBase: fbBase,
      stride: Const(timing.hActive * (rgb565 ? 2 : 4), width: 32),
      wordsPerLine: Const(wordsPerLine, width: 16),
      mDataIn: mDataIn,
      mAck: mAck,
      maxWords: wordsPerLine,
      blockRam: target.blockRam,
    );

    mStb <= scanout.mStb;
    mCyc <= scanout.mCyc;
    mWe <= scanout.mWe;
    mAddr <= scanout.mAddr;
    mSel <= scanout.mSel;
    mDataOut <= scanout.mDataOut;
    underrun <= scanout.underrun;

    // The line buffer read is registered, so the word comes one cycle after
    // tx. Stage 1 delays the timing signals to match it.
    final word = scanout.pixel;
    final de1 = delay(deActive, 'de_s1');

    Logic r;
    Logic g;
    Logic b;
    if (rgb565) {
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
    final zero = Const(0, width: 8);

    // Stage 2 registers every parallel output.
    final de2 = delay(de1, 'de_s2');
    final hsync2 = delay(delay(timingGen.hsync, 'hsync_s1'), 'hsync_s2');
    final vsync2 = delay(delay(timingGen.vsync, 'vsync_s1'), 'vsync_s2');
    final r2 = delay(mux(de1, r, zero), 'red_s2');
    final g2 = delay(mux(de1, g, zero), 'green_s2');
    final b2 = delay(mux(de1, b, zero), 'blue_s2');
    red <= r2;
    green <= g2;
    blue <= b2;
    de <= de2;
    hsync <= hsync2;
    vsync <= vsync2;
    x <= delay(delay(tx, 'x_s1'), 'x_s2');
    y <= delay(delay(ty, 'y_s1'), 'y_s2');
    pixelWord <= delay(word, 'pixel_word_s2');

    final transmitter = DviTransmitter(
      target: target,
      pixelClk: pixelClk,
      shiftClk: shiftClk, // 5x pixel clock from the SoC's display PLL
      pixelReset: pixelReset,
      shiftReset: shiftReset,
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

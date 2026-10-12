import 'package:rohd/rohd.dart';

import '../soc/target.dart';
import 'tmds_serializer.dart';

import '../peripherals/display.dart';
import 'display_output.dart';
import 'double_buffer_scanout.dart';
import 'dvi_transmitter.dart';
import 'parallel_rgb_output.dart';
import 'video_timing.dart';

/// A framebuffer display datapath: timing generator + double-buffer scanout DMA
/// + RGB extraction + a dvi/hdmi/parallelRgb output stage.
///
/// Reads an `0xXXRRGGBB` framebuffer from memory (one 32-bit word per pixel)
/// over a Wishbone-style master, scans it out for [timing], and emits parallel
/// RGB+sync (for observation, or as the parallelRgb output itself) plus,
/// depending on [outputType], either the four serialized GPDI lanes (dvi/hdmi)
/// or a packed [rgb] and a forwarded pixel clock [pclk] (parallelRgb). The
/// whole datapath is in the pixel clock domain. The system-bus clock crossing
/// is handled outside via a Wishbone CDC bridge.
///
/// `frameStart` is pulsed at the top of vertical blanking to prime the line
/// buffers before the next frame. `lineStart` is pulsed during each active
/// line's horizontal blanking to swap to the prefetched line and fetch the
/// next, so the buffer is settled before the next line's first pixel.
class HarborFramebufferDisplay extends Module {
  /// Serialized TMDS lanes ({clk, red, green, blue} from MSB), present only
  /// for dvi/hdmi.
  Logic get gpdi => output('gpdi');

  /// The four complement lanes, present only on a target that drives its own
  /// ([TmdsSerializer.needsComplement]).
  Logic get gpdiN => output('gpdi_n');

  /// 24-bit 8:8:8 RGB (red in bits 23:16), present only for parallelRgb.
  Logic get rgb => output('rgb');

  /// The forwarded pixel clock, present only for parallelRgb.
  Logic get pclk => output('pclk');

  /// Parallel video (for a VGA-style backend or observation).
  Logic get de => output('de');
  Logic get hsync => output('hsync');
  Logic get vsync => output('vsync');
  Logic get red => output('red');
  Logic get green => output('green');
  Logic get blue => output('blue');

  /// Current scan coordinates and the raw framebuffer word (observability).
  Logic get x => output('x');
  Logic get y => output('y');
  Logic get pixelWord => output('pixel_word');

  /// Wishbone master (framebuffer reads).
  Logic get mStb => output('m_stb');
  Logic get mCyc => output('m_cyc');
  Logic get mWe => output('m_we');
  Logic get mAddr => output('m_adr');
  Logic get mSel => output('m_sel');
  Logic get mDataOut => output('m_dat_o');

  final HarborDisplayTiming timing;

  /// The display output type (dvi, hdmi, or parallelRgb).
  final HarborDisplayInterface outputType;

  HarborFramebufferDisplay({
    required this.timing,
    required Logic pixelClk,
    required Logic pixelReset,
    required Logic shiftClk,
    required Logic shiftReset,
    required Logic enable,
    required Logic fbBase,
    required Logic mDataIn,
    required Logic mAck,
    this.outputType = HarborDisplayInterface.hdmi,
    HarborParallelRgbLatchEdge parallelRgbLatchEdge =
        HarborParallelRgbLatchEdge.falling,
    required HarborDeviceTarget target,
    super.name = 'framebuffer_display',
  }) : super(
         definitionName:
             'HarborFramebufferDisplay'
             '${outputType == HarborDisplayInterface.parallelRgb ? '_parallelRgb' : ''}',
       ) {
    // dvi/hdmi share the TMDS transmitter, parallelRgb forwards the pixel
    // clock instead. Reject types without a backend.
    requireDisplayOutputSupported(outputType);

    pixelClk = addInput('pixel_clk', pixelClk);
    pixelReset = addInput('pixel_reset', pixelReset);
    shiftClk = addInput('shift_clk', shiftClk);
    shiftReset = addInput('shift_reset', shiftReset);
    enable = addInput('enable', enable);
    fbBase = addInput('fb_base', fbBase, width: 32);
    mDataIn = addInput('m_dat_i', mDataIn, width: 32);
    mAck = addInput('m_ack', mAck);

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

    if (!parallelRgb) {
      x <= tx;
      y <= ty;
    }

    // frameStart: one pulse at the top of vertical blanking, leaving the whole
    // blanking period to prime the next frame's first two lines.
    final frameStart = enable & tx.eq(0) & ty.eq(timing.vActive);
    // lineStart: pulsed in each active line's horizontal blanking (x == hActive)
    // so the buffer swap settles before the next line's first pixel.
    final lineStart = enable & tx.eq(timing.hActive) & ty.lt(timing.vActive);

    final scanout = HarborDoubleBufferScanout(
      clk: pixelClk,
      reset: pixelReset,
      frameStart: frameStart,
      lineStart: lineStart,
      col: tx,
      fbBase: fbBase,
      stride: Const(timing.hActive * 4, width: 32),
      wordsPerLine: Const(timing.hActive, width: 16),
      mDataIn: mDataIn,
      mAck: mAck,
      maxWords: timing.hActive,
    );

    // Master port passthrough.
    mStb <= scanout.mStb;
    mCyc <= scanout.mCyc;
    mWe <= scanout.mWe;
    mAddr <= scanout.mAddr;
    mSel <= scanout.mSel;
    mDataOut <= scanout.mDataOut;

    final word = scanout.pixel;
    if (parallelRgb) {
      pixelWord <= flop(pixelClk, word, reset: pixelReset).named('prgb_word');
    } else {
      pixelWord <= word;
    }

    // 0xXXRRGGBB, blanked outside the active region.
    final r = mux(deActive, word.getRange(16, 24), Const(0, width: 8));
    final g = mux(deActive, word.getRange(8, 16), Const(0, width: 8));
    final b = mux(deActive, word.getRange(0, 8), Const(0, width: 8));
    if (!parallelRgb) {
      red <= r;
      green <= g;
      blue <= b;
    }

    if (parallelRgb) {
      // timingGen's de/hsync/vsync are plain decode of its counters, not
      // flops, so they are not safe to hand straight to a pin. One register
      // here, shared by rgb/hsync/vsync/de, puts all four on the pixel clock
      // and keeps them aligned to the same pixel for the transmitter's
      // setup/hold. No TMDS encoder or serializer, and no shift clock.
      // Sync flops reset to the idle level of the mode's polarity.
      Logic reg(Logic v, String n, {bool idle = false}) => flop(
        pixelClk,
        v,
        reset: pixelReset,
        resetValue: idle ? 1 : 0,
      ).named(n);
      final rReg = reg(r, 'prgb_red');
      final gReg = reg(g, 'prgb_green');
      final bReg = reg(b, 'prgb_blue');
      final deReg = reg(deActive, 'prgb_de');
      final hsyncReg = reg(
        timingGen.hsync,
        'prgb_hsync',
        idle: !timing.hSyncPositive,
      );
      final vsyncReg = reg(
        timingGen.vsync,
        'prgb_vsync',
        idle: !timing.vSyncPositive,
      );
      red <= rReg;
      green <= gReg;
      blue <= bReg;
      x <= reg(tx, 'prgb_x');
      y <= reg(ty, 'prgb_y');
      rgb <= [rReg, gReg, bReg].swizzle();
      de <= deReg;
      hsync <= hsyncReg;
      vsync <= vsyncReg;
      pclk <=
          HarborPixelClockForward(
            clk: pixelClk,
            target: target,
            latchEdge: parallelRgbLatchEdge,
          ).q;
    } else {
      de <= deActive;
      hsync <= timingGen.hsync;
      vsync <= timingGen.vsync;
      final transmitter = DviTransmitter(
        target: target,
        pixelClk: pixelClk,
        shiftClk: shiftClk,
        pixelReset: pixelReset,
        shiftReset: shiftReset,
        de: deActive,
        hsync: timingGen.hsync,
        vsync: timingGen.vsync,
        red: r,
        green: g,
        blue: b,
      );
      gpdi <= transmitter.gpdi;
      if (tmdsComplement) {
        gpdiN <= transmitter.gpdiN;
      }
    }
  }
}
